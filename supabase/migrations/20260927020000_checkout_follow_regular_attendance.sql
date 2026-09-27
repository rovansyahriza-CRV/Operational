BEGIN;
-- Check-out WO Manpower (dan Alat & Tools) ngikut absen pulang REGULER di hari yang SAMA.
--
-- Masalah sebelumnya: trigger absen pulang nutup SEMUA sesi yang masih kebuka, dari tanggal
-- berapa pun. Contoh nyata: check-in WO 19 Sep 15:24, tanggal 19 gak ada absen pulang, sesi baru
-- ketutup pas absen pulang 24 Sep 17:31 -> tercatat 122 jam. Plus kalau JamPulang < jam check-in
-- WO, UPDATE-nya melanggar CHECK(check_out_at>=check_in_at) dan ikut menggagalkan simpan absen
-- di Fusion4.
--
-- Aturan baru (tanggal lokal WITA / Asia/Makassar, sama kaya absensiTbl."Tanggal"):
--  1. Absen pulang tanggal D cuma nutup sesi yang check-in di tanggal D, di jam
--     max(JamPulang, jam check-in) -- gak pernah melanggar constraint.
--  2. Sesi yang lewat hari (check-in sebelum hari ini) dan masih kebuka ditutup otomatis:
--     pakai JamPulang tanggal check-in kalau ada, kalau gak ada ditutup di akhir shift
--     Lembur (21:30) tanggal itu. Dijalankan tiap ada absen pulang dan tiap op_manpower dipanggil.

-- Jam check-out "akhir hari" buat satu sesi: JamPulang absen reguler di tanggal check-in kalau
-- ada, kalau gak ada jam 21:30 (akhir shift Lembur) tanggal itu. Gak pernah sebelum jam check-in.
CREATE OR REPLACE FUNCTION operational.day_end_checkout(p_employee_id bigint, p_check_in timestamptz)
 RETURNS timestamptz
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT greatest(p_check_in,coalesce(
  (SELECT max(a."JamPulang") FROM public."absensiTbl" a
   JOIN public."karyawanTbl" k ON upper(trim(k."QrCodeId"))=upper(trim(a."QrCodeId"))
   WHERE k."Id"=p_employee_id AND a."JamPulang" IS NOT NULL
    AND a."Tanggal"=(p_check_in AT TIME ZONE 'Asia/Makassar')::date),
  (((p_check_in AT TIME ZONE 'Asia/Makassar')::date + time '21:30') AT TIME ZONE 'Asia/Makassar')))
$function$;
REVOKE ALL ON FUNCTION operational.day_end_checkout(bigint,timestamptz) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION operational.close_stale_checkins(p_employee_id bigint DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE today date:=(now() AT TIME ZONE 'Asia/Makassar')::date;
BEGIN
 UPDATE operational.wo_manpower_checkin
 SET check_out_at=operational.day_end_checkout(employee_id,check_in_at)
 WHERE check_out_at IS NULL
  AND (check_in_at AT TIME ZONE 'Asia/Makassar')::date<today
  AND (p_employee_id IS NULL OR employee_id=p_employee_id);
 UPDATE operational.equipment_checkin
 SET check_out_at=operational.day_end_checkout(recorded_by,check_in_at)
 WHERE check_out_at IS NULL
  AND (check_in_at AT TIME ZONE 'Asia/Makassar')::date<today
  AND (p_employee_id IS NULL OR recorded_by=p_employee_id);
END;
$function$;
REVOKE ALL ON FUNCTION operational.close_stale_checkins(bigint) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION operational.auto_checkout_on_absen_pulang()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE emp_id bigint;
BEGIN
 IF NEW."JamPulang" IS NOT NULL AND (TG_OP='INSERT' OR OLD."JamPulang" IS NULL) THEN
  SELECT "Id" INTO emp_id FROM public."karyawanTbl" WHERE upper(trim("QrCodeId"))=upper(trim(NEW."QrCodeId"));
  IF emp_id IS NOT NULL THEN
   UPDATE operational.wo_manpower_checkin
   SET check_out_at=greatest(check_in_at,NEW."JamPulang")
   WHERE employee_id=emp_id AND check_out_at IS NULL
    AND (check_in_at AT TIME ZONE 'Asia/Makassar')::date=NEW."Tanggal";
   UPDATE operational.equipment_checkin
   SET check_out_at=greatest(check_in_at,NEW."JamPulang")
   WHERE recorded_by=emp_id AND check_out_at IS NULL
    AND (check_in_at AT TIME ZONE 'Asia/Makassar')::date=NEW."Tanggal";
   PERFORM operational.close_stale_checkins(emp_id);
  END IF;
 END IF;
 RETURN NEW;
END;
$function$;

-- Koreksi data lama dengan aturan yang sama: sesi yang ketutup di hari yang beda dari tanggal
-- check-in dihitung ulang jam check-out-nya (saat migration ini ditulis cuma 1 baris manpower:
-- check-in 19 Sep 15:24 WITA, sebelumnya ditutup 24 Sep 17:31 WITA).
UPDATE operational.wo_manpower_checkin SET check_out_at=operational.day_end_checkout(employee_id,check_in_at)
WHERE check_out_at IS NOT NULL
 AND (check_out_at AT TIME ZONE 'Asia/Makassar')::date>(check_in_at AT TIME ZONE 'Asia/Makassar')::date;
UPDATE operational.equipment_checkin SET check_out_at=operational.day_end_checkout(recorded_by,check_in_at)
WHERE check_out_at IS NOT NULL
 AND (check_out_at AT TIME ZONE 'Asia/Makassar')::date>(check_in_at AT TIME ZONE 'Asia/Makassar')::date;
SELECT operational.close_stale_checkins();

CREATE OR REPLACE FUNCTION public.op_manpower(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; empid bigint; pin bigint; row_id uuid; emp record; wid uuid; qrcode text; match_count int;
BEGIN
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 PERFORM operational.close_stale_checkins();
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
 ELSIF p_action='find_by_qrcode' THEN
  qrcode:=nullif(btrim(p_data->>'qrCode'),'');
  IF qrcode IS NULL THEN RAISE EXCEPTION 'QR code kosong'; END IF;
  SELECT "Id","NamaPersonnel","IsActive" INTO emp FROM public."karyawanTbl" WHERE upper(trim("QrCodeId"))=upper(qrcode);
  IF emp."Id" IS NULL THEN RAISE EXCEPTION 'QR tidak dikenali (karyawan tidak ditemukan)'; END IF;
  IF NOT emp."IsActive" THEN RAISE EXCEPTION 'Karyawan ini tidak aktif'; END IF;
  RETURN jsonb_build_object('employeeId',emp."Id",'name',emp."NamaPersonnel");
 ELSIF p_action='checkin_by_qrcode' THEN
  wid:=(p_data->>'woId')::uuid;
  qrcode:=nullif(btrim(p_data->>'qrCode'),'');
  IF wid IS NULL THEN RAISE EXCEPTION 'WO wajib dipilih'; END IF;
  IF qrcode IS NULL THEN RAISE EXCEPTION 'QR code kosong'; END IF;
  IF NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=wid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  SELECT "Id","NamaPersonnel","IsActive" INTO emp FROM public."karyawanTbl" WHERE upper(trim("QrCodeId"))=upper(qrcode);
  IF emp."Id" IS NULL THEN RAISE EXCEPTION 'QR tidak dikenali (karyawan tidak ditemukan)'; END IF;
  IF NOT emp."IsActive" THEN RAISE EXCEPTION 'Karyawan ini tidak aktif'; END IF;
  IF EXISTS(SELECT 1 FROM operational.wo_manpower_checkin WHERE employee_id=emp."Id" AND check_out_at IS NULL) THEN
   RAISE EXCEPTION 'Karyawan ini masih check-in di WO lain, check-out dulu sebelum check-in baru';
  END IF;
  INSERT INTO operational.wo_manpower_checkin(wo_id,employee_id,recorded_by) VALUES(wid,emp."Id",actor) RETURNING id INTO row_id;
  RETURN jsonb_build_object('id',row_id,'employeeName',emp."NamaPersonnel");
 ELSIF p_action='checkout_by_qrcode' THEN
  qrcode:=nullif(btrim(p_data->>'qrCode'),'');
  IF qrcode IS NULL THEN RAISE EXCEPTION 'QR code kosong'; END IF;
  SELECT "Id","NamaPersonnel" INTO emp FROM public."karyawanTbl" WHERE upper(trim("QrCodeId"))=upper(qrcode);
  IF emp."Id" IS NULL THEN RAISE EXCEPTION 'QR tidak dikenali (karyawan tidak ditemukan)'; END IF;
  UPDATE operational.wo_manpower_checkin SET check_out_at=now() WHERE employee_id=emp."Id" AND check_out_at IS NULL RETURNING id INTO row_id;
  IF row_id IS NULL THEN RAISE EXCEPTION 'Karyawan ini belum check-in'; END IF;
  RETURN jsonb_build_object('id',row_id,'employeeName',emp."NamaPersonnel");
 ELSIF p_action='checkin_by_pin' THEN
  wid:=(p_data->>'woId')::uuid;
  IF wid IS NULL THEN RAISE EXCEPTION 'WO wajib dipilih'; END IF;
  IF nullif(btrim(p_data->>'pin'),'') IS NULL OR p_data->>'pin' !~ '^\d+$' THEN RAISE EXCEPTION 'PIN tidak valid'; END IF;
  pin:=(p_data->>'pin')::bigint;
  IF NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=wid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  SELECT count(*) INTO match_count FROM public."karyawanTbl" WHERE "DigitalPIN"=pin AND "IsActive"=true;
  IF match_count=0 THEN RAISE EXCEPTION 'PIN tidak dikenali'; END IF;
  IF match_count>1 THEN RAISE EXCEPTION 'PIN dipakai lebih dari satu karyawan, hubungi admin'; END IF;
  SELECT "Id","NamaPersonnel" INTO emp FROM public."karyawanTbl" WHERE "DigitalPIN"=pin AND "IsActive"=true;
  IF EXISTS(SELECT 1 FROM operational.wo_manpower_checkin WHERE employee_id=emp."Id" AND check_out_at IS NULL) THEN
   RAISE EXCEPTION 'Karyawan ini masih check-in di WO lain, check-out dulu sebelum check-in baru';
  END IF;
  INSERT INTO operational.wo_manpower_checkin(wo_id,employee_id,recorded_by) VALUES(wid,emp."Id",actor) RETURNING id INTO row_id;
  RETURN jsonb_build_object('id',row_id,'employeeName',emp."NamaPersonnel");
 ELSIF p_action='checkout_by_pin' THEN
  IF nullif(btrim(p_data->>'pin'),'') IS NULL OR p_data->>'pin' !~ '^\d+$' THEN RAISE EXCEPTION 'PIN tidak valid'; END IF;
  pin:=(p_data->>'pin')::bigint;
  SELECT count(*) INTO match_count FROM public."karyawanTbl" WHERE "DigitalPIN"=pin AND "IsActive"=true;
  IF match_count=0 THEN RAISE EXCEPTION 'PIN tidak dikenali'; END IF;
  IF match_count>1 THEN RAISE EXCEPTION 'PIN dipakai lebih dari satu karyawan, hubungi admin'; END IF;
  SELECT "Id","NamaPersonnel" INTO emp FROM public."karyawanTbl" WHERE "DigitalPIN"=pin AND "IsActive"=true;
  UPDATE operational.wo_manpower_checkin SET check_out_at=now() WHERE employee_id=emp."Id" AND check_out_at IS NULL RETURNING id INTO row_id;
  IF row_id IS NULL THEN RAISE EXCEPTION 'Karyawan ini belum check-in'; END IF;
  RETURN jsonb_build_object('id',row_id,'employeeName',emp."NamaPersonnel");
 ELSIF p_action='checkin_self' THEN
  wid:=(p_data->>'woId')::uuid;
  IF wid IS NULL THEN RAISE EXCEPTION 'WO wajib dipilih'; END IF;
  IF NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=wid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  SELECT "Id","NamaPersonnel","IsActive" INTO emp FROM public."karyawanTbl" WHERE "Id"=actor;
  IF emp."Id" IS NULL OR NOT emp."IsActive" THEN
   RETURN jsonb_build_object('status','skipped');
  END IF;
  IF EXISTS(SELECT 1 FROM operational.wo_manpower_checkin WHERE employee_id=actor AND check_out_at IS NULL AND wo_id=wid) THEN
   RETURN jsonb_build_object('status','already','employeeName',emp."NamaPersonnel");
  END IF;
  IF EXISTS(SELECT 1 FROM operational.wo_manpower_checkin WHERE employee_id=actor AND check_out_at IS NULL) THEN
   RETURN jsonb_build_object('status','elsewhere','employeeName',emp."NamaPersonnel");
  END IF;
  INSERT INTO operational.wo_manpower_checkin(wo_id,employee_id,recorded_by) VALUES(wid,actor,actor) RETURNING id INTO row_id;
  RETURN jsonb_build_object('status','ok','id',row_id,'employeeName',emp."NamaPersonnel");
 ELSIF p_action='active_checkins' THEN
  wid:=nullif(p_data->>'woId','')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.check_in_at) FROM (
   SELECT c.id,c.wo_id,c.employee_id,c.check_in_at,k."NamaPersonnel" AS employee_name,k."Kualifikasi" AS kualifikasi,w.number AS wo_number
   FROM operational.wo_manpower_checkin c
   JOIN public."karyawanTbl" k ON k."Id"=c.employee_id
   JOIN operational.work_orders w ON w.id=c.wo_id
   WHERE c.check_out_at IS NULL AND (wid IS NULL OR c.wo_id=wid)) x
  ),'[]');
 ELSIF p_action='list_checkins' THEN
  wid:=(p_data->>'woId')::uuid;
  IF wid IS NULL THEN RAISE EXCEPTION 'WO wajib dipilih'; END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.check_in_at DESC) FROM (
   SELECT c.id,c.employee_id,c.check_in_at,c.check_out_at,k."NamaPersonnel" AS employee_name,k."Kualifikasi" AS kualifikasi,
    EXTRACT(EPOCH FROM (coalesce(c.check_out_at,now())-c.check_in_at))/3600 AS hours
   FROM operational.wo_manpower_checkin c
   JOIN public."karyawanTbl" k ON k."Id"=c.employee_id
   WHERE c.wo_id=wid) x
  ),'[]');
 ELSE RAISE EXCEPTION 'Operasi tidak tersedia';
 END IF;
END $function$;
COMMIT;
