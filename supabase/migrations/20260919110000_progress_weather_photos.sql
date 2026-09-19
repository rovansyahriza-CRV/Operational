BEGIN;
-- Tiap entri progress (per leaf breakdown, per hari) sekarang bisa bawa kondisi cuaca +
-- sampai 3 foto lapangan. Disajikan nanti sebagai "Daily Report" (read_daily_report) di
-- progress.html -- rekap satu SMS+tanggal: qty, cuaca, catatan, dan foto per baris.
-- Foto disimpan base64 langsung di kolom text (pola yang sama kaya evidence_data di
-- sms_documents -- bukan Supabase Storage), dikompres di sisi client dulu (~≤2MB base64)
-- biar gak bengkak.
ALTER TABLE operational.sms_item_progress
 ADD COLUMN weather text CHECK(weather IS NULL OR weather IN ('CERAH','BERAWAN','HUJAN_RINGAN','HUJAN_LEBAT'));

CREATE TABLE operational.sms_item_progress_photos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 progress_id uuid NOT NULL REFERENCES operational.sms_item_progress(id) ON DELETE CASCADE,
 photo_data text NOT NULL CHECK(length(photo_data)<=2800000),
 mime_type text NOT NULL DEFAULT 'image/jpeg',
 uploaded_by bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON operational.sms_item_progress_photos(progress_id);
ALTER TABLE operational.sms_item_progress_photos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.sms_item_progress_photos FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.op_daily_report(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; n integer:=0; aid uuid; did uuid; sid uuid; pid uuid; phid uuid; detail operational.sms_item_details; parent operational.sms_item_details;
BEGIN
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 IF p_action='list_activities' THEN
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.parent_id NULLS FIRST,a.name) FROM operational.activity_library a),'[]');
 ELSIF p_action='add_activity' THEN
  IF nullif(btrim(p_data->>'name'),'') IS NULL THEN RAISE EXCEPTION 'Nama wajib diisi'; END IF;
  IF nullif(p_data->>'parentId','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM operational.activity_library WHERE id=(p_data->>'parentId')::uuid) THEN
   RAISE EXCEPTION 'Induk aktivitas tidak ditemukan';
  END IF;
  IF nullif(p_data->>'parentId','') IS NULL THEN
   INSERT INTO operational.activity_library(name,created_by) VALUES(btrim(p_data->>'name'),actor)
   ON CONFLICT (name) WHERE parent_id IS NULL DO NOTHING
   RETURNING id INTO aid;
  ELSE
   INSERT INTO operational.activity_library(parent_id,name,created_by) VALUES((p_data->>'parentId')::uuid,btrim(p_data->>'name'),actor)
   ON CONFLICT ON CONSTRAINT activity_library_parent_name_key DO NOTHING
   RETURNING id INTO aid;
  END IF;
  IF aid IS NULL THEN
   SELECT id INTO aid FROM operational.activity_library WHERE name=btrim(p_data->>'name') AND parent_id IS NOT DISTINCT FROM nullif(p_data->>'parentId','')::uuid;
  END IF;
  RETURN jsonb_build_object('id',aid);
 ELSIF p_action='add_detail_row' THEN
  sid:=(p_data->>'smsItemId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.sms_items WHERE id=sid) THEN RAISE EXCEPTION 'Item SMS tidak ditemukan'; END IF;
  IF p_data->>'rowKind' NOT IN ('GROUP','ITEM') THEN RAISE EXCEPTION 'Jenis baris tidak valid'; END IF;
  IF nullif(btrim(p_data->>'description'),'') IS NULL THEN RAISE EXCEPTION 'Uraian wajib diisi'; END IF;
  IF nullif(p_data->>'parentId','') IS NOT NULL THEN
   SELECT * INTO parent FROM operational.sms_item_details WHERE id=(p_data->>'parentId')::uuid AND sms_item_id=sid AND row_kind='GROUP';
   IF parent.id IS NULL THEN RAISE EXCEPTION 'Induk harus Group pada item SMS yang sama'; END IF;
  END IF;
  IF p_data->>'rowKind'='ITEM' THEN
   IF nullif(btrim(p_data->>'unit'),'') IS NULL THEN RAISE EXCEPTION 'Satuan wajib diisi'; END IF;
  END IF;
  SELECT coalesce(max(sort_order),0)+1 INTO n FROM operational.sms_item_details WHERE sms_item_id=sid;
  INSERT INTO operational.sms_item_details(sms_item_id,parent_id,row_kind,activity_id,description,unit,qty,sort_order)
  VALUES(sid,nullif(p_data->>'parentId','')::uuid,p_data->>'rowKind',nullif(p_data->>'activityId','')::uuid,btrim(p_data->>'description'),
   CASE WHEN p_data->>'rowKind'='ITEM' THEN btrim(p_data->>'unit') END,
   CASE WHEN p_data->>'rowKind'='ITEM' THEN nullif(p_data->>'qty','')::numeric END,
   n)
  RETURNING id INTO did;
  RETURN jsonb_build_object('id',did);
 ELSIF p_action='delete_detail_row' THEN
  did:=(p_data->>'detailId')::uuid;
  SELECT * INTO detail FROM operational.sms_item_details WHERE id=did;
  IF detail.id IS NULL THEN RAISE EXCEPTION 'Baris tidak ditemukan'; END IF;
  IF EXISTS(SELECT 1 FROM operational.sms_item_details WHERE parent_id=did) THEN RAISE EXCEPTION 'Hapus dulu sub-item di bawahnya sebelum menghapus Group ini'; END IF;
  IF EXISTS(SELECT 1 FROM operational.sms_item_progress WHERE detail_id=did) THEN RAISE EXCEPTION 'Sub-item ini sudah punya progress tercatat, gak bisa dihapus'; END IF;
  DELETE FROM operational.sms_item_details WHERE id=did;
  RETURN jsonb_build_object('deleted',true);
 ELSIF p_action='read_sms_item_details' THEN
  sid:=(p_data->>'smsItemId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.sort_order) FROM operational.sms_item_details d WHERE d.sms_item_id=sid),'[]');
 ELSIF p_action='list_sms_details' THEN
  sid:=(p_data->>'smsId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.item_code,x.sort_order) FROM (
   SELECT d.*, si.code_snapshot AS item_code, si.description_snapshot AS item_description,
    (SELECT coalesce(sum(p.qty),0) FROM operational.sms_item_progress p WHERE p.detail_id=d.id) AS progress_total
   FROM operational.sms_item_details d
   JOIN operational.sms_items si ON si.id=d.sms_item_id
   WHERE si.sms_id=sid) x
  ),'[]');
 ELSIF p_action='save_progress' THEN
  did:=(p_data->>'detailId')::uuid;
  SELECT * INTO detail FROM operational.sms_item_details WHERE id=did;
  IF detail.id IS NULL THEN RAISE EXCEPTION 'Sub-item tidak ditemukan'; END IF;
  IF detail.row_kind<>'ITEM' THEN RAISE EXCEPTION 'Progress cuma bisa diisi di leaf item, bukan Group'; END IF;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  IF nullif(p_data->>'qty','') IS NULL OR (p_data->>'qty')::numeric<=0 THEN RAISE EXCEPTION 'Qty tidak valid'; END IF;
  IF nullif(p_data->>'weather','') IS NOT NULL AND p_data->>'weather' NOT IN ('CERAH','BERAWAN','HUJAN_RINGAN','HUJAN_LEBAT') THEN
   RAISE EXCEPTION 'Kondisi cuaca tidak valid';
  END IF;
  IF detail.qty IS NOT NULL AND (SELECT coalesce(sum(qty),0) FROM operational.sms_item_progress WHERE detail_id=did)+(p_data->>'qty')::numeric > detail.qty THEN
   RAISE EXCEPTION 'Qty progress melebihi total qty sub-item ini';
  END IF;
  INSERT INTO operational.sms_item_progress(detail_id,report_date,qty,notes,weather,recorded_by)
  VALUES(did,(p_data->>'reportDate')::date,(p_data->>'qty')::numeric,coalesce(p_data->>'notes',''),nullif(p_data->>'weather',''),actor)
  RETURNING id INTO pid;
  RETURN jsonb_build_object('id',pid);
 ELSIF p_action='add_progress_photo' THEN
  pid:=(p_data->>'progressId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.sms_item_progress WHERE id=pid) THEN RAISE EXCEPTION 'Progress tidak ditemukan'; END IF;
  IF nullif(p_data->>'photoData','') IS NULL THEN RAISE EXCEPTION 'Foto kosong'; END IF;
  IF length(p_data->>'photoData')>2800000 THEN RAISE EXCEPTION 'Ukuran foto terlalu besar'; END IF;
  IF (SELECT count(*) FROM operational.sms_item_progress_photos WHERE progress_id=pid)>=3 THEN RAISE EXCEPTION 'Maksimal 3 foto per entri progress'; END IF;
  INSERT INTO operational.sms_item_progress_photos(progress_id,photo_data,mime_type,uploaded_by)
  VALUES(pid,p_data->>'photoData',coalesce(nullif(p_data->>'mimeType',''),'image/jpeg'),actor)
  RETURNING id INTO phid;
  RETURN jsonb_build_object('id',phid);
 ELSIF p_action='delete_progress_photo' THEN
  phid:=(p_data->>'photoId')::uuid;
  DELETE FROM operational.sms_item_progress_photos WHERE id=phid AND uploaded_by=actor;
  IF NOT FOUND THEN RAISE EXCEPTION 'Foto tidak ditemukan atau bukan milik kamu'; END IF;
  RETURN jsonb_build_object('deleted',true);
 ELSIF p_action='list_progress' THEN
  did:=(p_data->>'detailId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.report_date DESC) FROM (
   SELECT pr.*, k."NamaPersonnel" AS recorded_by_name FROM operational.sms_item_progress pr LEFT JOIN public."karyawanTbl" k ON k."Id"=pr.recorded_by WHERE pr.detail_id=did) x),'[]');
 ELSIF p_action='read_daily_report' THEN
  sid:=(p_data->>'smsId')::uuid;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.item_code,x.sort_order,x.created_at) FROM (
   SELECT pr.id AS progress_id, pr.detail_id, pr.qty, pr.weather, pr.notes, pr.created_at, pr.recorded_by,
    k."NamaPersonnel" AS recorded_by_name,
    d.description, d.unit, d.sort_order,
    si.code_snapshot AS item_code, si.description_snapshot AS item_description,
    (SELECT coalesce(jsonb_agg(jsonb_build_object('id',ph.id,'mimeType',ph.mime_type,'photoData',ph.photo_data) ORDER BY ph.uploaded_at),'[]')
     FROM operational.sms_item_progress_photos ph WHERE ph.progress_id=pr.id) AS photos
   FROM operational.sms_item_progress pr
   JOIN operational.sms_item_details d ON d.id=pr.detail_id
   JOIN operational.sms_items si ON si.id=d.sms_item_id
   LEFT JOIN public."karyawanTbl" k ON k."Id"=pr.recorded_by
   WHERE si.sms_id=sid AND pr.report_date=(p_data->>'reportDate')::date) x
  ),'[]');
 ELSE RAISE EXCEPTION 'Operasi tidak tersedia';
 END IF;
END $function$;
COMMIT;
