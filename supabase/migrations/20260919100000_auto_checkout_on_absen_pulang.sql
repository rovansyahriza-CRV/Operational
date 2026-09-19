BEGIN;
-- Jaga-jaga lupa check-out: begitu absensi REGULER (Fusion4, absensiTbl) karyawan sudah
-- "Pulang" (JamPulang keisi) buat hari itu, otomatis tutup (check_out_at=JamPulang) checkin
-- WO Manpower yang masih terbuka punya karyawan itu -- gak logis dia masih "di lapangan"
-- kalau absen reguler-nya udah closed. Trigger jalan cuma pas transisi NULL->keisi (bukan
-- tiap update absensiTbl, biar gak nembak berkali-kali), dan gak nyentuh absensiTbl sama
-- sekali (murni efek samping ke operational.wo_manpower_checkin).
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
  END IF;
 END IF;
 RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_auto_checkout_on_absen_pulang ON public."absensiTbl";
CREATE TRIGGER trg_auto_checkout_on_absen_pulang
AFTER INSERT OR UPDATE ON public."absensiTbl"
FOR EACH ROW
EXECUTE FUNCTION operational.auto_checkout_on_absen_pulang();
COMMIT;
