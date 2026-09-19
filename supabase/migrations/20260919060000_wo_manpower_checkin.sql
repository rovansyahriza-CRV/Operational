BEGIN;
-- Manpower checkin per WO: layer kedua di atas absensi reguler Fusion4 (absensiTbl, gak
-- disentuh sama sekali). PIC/Foreman pegang satu HP, pilih WO, lalu check-in/out tiap
-- anggota tim pakai PIN masing-masing (DigitalPIN di karyawanTbl -- sudah ada infrastrukturnya,
-- gak bikin skema PIN baru). Satu orang cuma boleh punya satu sesi checkin terbuka di satu
-- waktu (dijaga UNIQUE index, bukan cuma app-level check, biar aman dari race condition).
--
-- Catatan keamanan (sudah didiskusikan & disetujui buat lanjut): karyawanTbl punya policy
-- anon_select_karyawanTbl yang expose DigitalPIN ke anon read tanpa syarat. PIN checkin ini
-- jadi "cukup" (nyegah salah pencet/jejak audit) tapi belum "kuat" (bukan proteksi dari orang
-- yang niat query database langsung) sampai policy itu dibenahi terpisah.

CREATE TABLE operational.wo_manpower_checkin (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 wo_id uuid NOT NULL REFERENCES operational.work_orders(id),
 employee_id bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 check_in_at timestamptz NOT NULL DEFAULT now(),
 check_out_at timestamptz,
 recorded_by bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(check_out_at IS NULL OR check_out_at>=check_in_at)
);
CREATE INDEX ON operational.wo_manpower_checkin(wo_id);
CREATE UNIQUE INDEX wo_manpower_checkin_one_open_per_employee ON operational.wo_manpower_checkin(employee_id) WHERE check_out_at IS NULL;
ALTER TABLE operational.wo_manpower_checkin ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.wo_manpower_checkin FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.op_manpower(p_token text,p_action text,p_data jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor bigint; empid bigint; pin bigint; row_id uuid; emp record; wid uuid;
BEGIN
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 IF p_action='checkin' THEN
  wid:=(p_data->>'woId')::uuid;
  empid:=nullif(p_data->>'employeeId','')::bigint;
  IF wid IS NULL THEN RAISE EXCEPTION 'WO wajib dipilih'; END IF;
  IF empid IS NULL THEN RAISE EXCEPTION 'Karyawan wajib dipilih'; END IF;
  IF NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=wid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  IF nullif(btrim(p_data->>'pin'),'') IS NULL OR p_data->>'pin' !~ '^\d+$' THEN RAISE EXCEPTION 'PIN tidak valid'; END IF;
  pin:=(p_data->>'pin')::bigint;
  SELECT "Id","NamaPersonnel","DigitalPIN","IsActive" INTO emp FROM public."karyawanTbl" WHERE "Id"=empid;
  IF emp."Id" IS NULL OR NOT emp."IsActive" THEN RAISE EXCEPTION 'Karyawan tidak ditemukan atau tidak aktif'; END IF;
  IF emp."DigitalPIN" IS NULL OR emp."DigitalPIN"<>pin THEN RAISE EXCEPTION 'PIN salah'; END IF;
  IF EXISTS(SELECT 1 FROM operational.wo_manpower_checkin WHERE employee_id=empid AND check_out_at IS NULL) THEN
   RAISE EXCEPTION 'Karyawan ini masih check-in di WO lain, check-out dulu sebelum check-in baru';
  END IF;
  INSERT INTO operational.wo_manpower_checkin(wo_id,employee_id,recorded_by) VALUES(wid,empid,actor) RETURNING id INTO row_id;
  RETURN jsonb_build_object('id',row_id,'employeeName',emp."NamaPersonnel");
 ELSIF p_action='checkout' THEN
  empid:=nullif(p_data->>'employeeId','')::bigint;
  IF empid IS NULL THEN RAISE EXCEPTION 'Karyawan wajib dipilih'; END IF;
  IF nullif(btrim(p_data->>'pin'),'') IS NULL OR p_data->>'pin' !~ '^\d+$' THEN RAISE EXCEPTION 'PIN tidak valid'; END IF;
  pin:=(p_data->>'pin')::bigint;
  SELECT "Id","NamaPersonnel","DigitalPIN" INTO emp FROM public."karyawanTbl" WHERE "Id"=empid;
  IF emp."Id" IS NULL THEN RAISE EXCEPTION 'Karyawan tidak ditemukan'; END IF;
  IF emp."DigitalPIN" IS NULL OR emp."DigitalPIN"<>pin THEN RAISE EXCEPTION 'PIN salah'; END IF;
  UPDATE operational.wo_manpower_checkin SET check_out_at=now() WHERE employee_id=empid AND check_out_at IS NULL RETURNING id INTO row_id;
  IF row_id IS NULL THEN RAISE EXCEPTION 'Karyawan ini belum check-in'; END IF;
  RETURN jsonb_build_object('id',row_id,'employeeName',emp."NamaPersonnel");
 ELSIF p_action='active_checkins' THEN
  wid:=nullif(p_data->>'woId','')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.check_in_at) FROM (
   SELECT c.id,c.wo_id,c.employee_id,c.check_in_at,k."NamaPersonnel" AS employee_name,w.number AS wo_number
   FROM operational.wo_manpower_checkin c
   JOIN public."karyawanTbl" k ON k."Id"=c.employee_id
   JOIN operational.work_orders w ON w.id=c.wo_id
   WHERE c.check_out_at IS NULL AND (wid IS NULL OR c.wo_id=wid)) x
  ),'[]');
 ELSIF p_action='list_checkins' THEN
  wid:=(p_data->>'woId')::uuid;
  IF wid IS NULL THEN RAISE EXCEPTION 'WO wajib dipilih'; END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.check_in_at DESC) FROM (
   SELECT c.id,c.employee_id,c.check_in_at,c.check_out_at,k."NamaPersonnel" AS employee_name,
    EXTRACT(EPOCH FROM (coalesce(c.check_out_at,now())-c.check_in_at))/3600 AS hours
   FROM operational.wo_manpower_checkin c
   JOIN public."karyawanTbl" k ON k."Id"=c.employee_id
   WHERE c.wo_id=wid) x
  ),'[]');
 ELSE RAISE EXCEPTION 'Operasi tidak tersedia';
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.op_manpower(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_manpower(text,text,jsonb) TO anon,authenticated;
COMMIT;
