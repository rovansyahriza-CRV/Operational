BEGIN;
-- Resolusi QrCodeId -> karyawanTbl.Id, dipakai flow Scan QR / Scan Wajah di manpower.html
-- (Scan Wajah nge-match descriptor client-side lewat get_all_face_data yang sudah publik,
-- lalu hasilnya cuma qrCodeId -- perlu ditukar ke Id numerik biar bisa dipakai checkin/checkout).
-- Tetap di balik session token (bukan fungsi anon lepas kaya get_all_face_data), dan checkin/checkout
-- masih wajib PIN sendiri -- QR/Wajah cuma gantiin langkah "cari nama", bukan gantiin PIN.
CREATE OR REPLACE FUNCTION public.op_manpower(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; empid bigint; pin bigint; row_id uuid; emp record; wid uuid; qrcode text;
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
 ELSIF p_action='find_by_qrcode' THEN
  qrcode:=nullif(btrim(p_data->>'qrCode'),'');
  IF qrcode IS NULL THEN RAISE EXCEPTION 'QR code kosong'; END IF;
  SELECT "Id","NamaPersonnel","IsActive" INTO emp FROM public."karyawanTbl" WHERE upper(trim("QrCodeId"))=upper(qrcode);
  IF emp."Id" IS NULL THEN RAISE EXCEPTION 'QR tidak dikenali (karyawan tidak ditemukan)'; END IF;
  IF NOT emp."IsActive" THEN RAISE EXCEPTION 'Karyawan ini tidak aktif'; END IF;
  RETURN jsonb_build_object('employeeId',emp."Id",'name',emp."NamaPersonnel");
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
END $function$;
COMMIT;
