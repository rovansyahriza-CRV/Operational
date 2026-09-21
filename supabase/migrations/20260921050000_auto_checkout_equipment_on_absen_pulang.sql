BEGIN;
-- Extend trigger auto-checkout (20260919100000): begitu absensi REGULER karyawan "Pulang"
-- (JamPulang keisi), selain nutup WO Manpower checkin, sekarang juga nutup checkin
-- Alat/Tools (operational.equipment_checkin) yang DICATAT (recorded_by) sama karyawan itu.
--
-- Catatan desain (sudah didiskusikan & disetujui): recorded_by di equipment_checkin itu PIC/
-- site engineer yang login Daily Progress dan mencet tombol Check-in, BUKAN identitas fisik
-- pemakai alat (gak ada verifikasi PIN per-alat kayak Manpower). Jadi trigger ini nutup alat
-- berdasarkan jadwal pulang PIC pencatatnya.
--
-- Lembur ditangani terpisah (dikonfirmasi user): absen Pulang reguler tetap nutup sesi ini di
-- jam normal; kalau lanjut lembur, itu sesi baru (voucher lembur, overtimeTbl.JamMulaiOT) yang
-- butuh check-in manual lagi di Daily Progress -- bukan otomatis, karena secara sistem itu
-- emang sesi yang berbeda dari absensi reguler.
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
   SET check_out_at=NEW."JamPulang"
   WHERE employee_id=emp_id AND check_out_at IS NULL;
   UPDATE operational.equipment_checkin
   SET check_out_at=NEW."JamPulang"
   WHERE recorded_by=emp_id AND check_out_at IS NULL;
  END IF;
 END IF;
 RETURN NEW;
END;
$function$;
COMMIT;
