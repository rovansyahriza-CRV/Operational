BEGIN;
-- Revisi dari feedback: (1) beberapa entri progress di leaf yang sama+tanggal yang sama
-- harus digabung jadi satu baris di Daily Report (qty dijumlah, foto digabung), bukan
-- ditampilkan terpisah-pisah. (2) Cuaca dipindah dari level leaf (detail item) ke level
-- "main group" -- yaitu commercial item SMS (sms_items), satu nilai cuaca per sms_item per
-- tanggal, berlaku buat semua leaf di bawahnya hari itu.

-- Backfill: satu-satunya weather yang sempat kesimpen di sms_item_progress (data asli user,
-- WO-001 2026-09-19, CERAH) dipindah dulu ke tabel baru sebelum kolomnya didrop.
CREATE TABLE operational.sms_item_weather (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 sms_item_id uuid NOT NULL REFERENCES operational.sms_items(id),
 report_date date NOT NULL,
 weather text NOT NULL CHECK(weather IN ('CERAH','BERAWAN','HUJAN_RINGAN','HUJAN_LEBAT')),
 recorded_by bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(sms_item_id,report_date)
);
ALTER TABLE operational.sms_item_weather ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.sms_item_weather FROM PUBLIC,anon,authenticated;

INSERT INTO operational.sms_item_weather(sms_item_id,report_date,weather,recorded_by)
SELECT DISTINCT ON (d.sms_item_id,pr.report_date) d.sms_item_id,pr.report_date,pr.weather,pr.recorded_by
FROM operational.sms_item_progress pr
JOIN operational.sms_item_details d ON d.id=pr.detail_id
WHERE pr.weather IS NOT NULL
ORDER BY d.sms_item_id,pr.report_date,pr.created_at DESC
ON CONFLICT (sms_item_id,report_date) DO NOTHING;

ALTER TABLE operational.sms_item_progress DROP COLUMN weather;

CREATE OR REPLACE FUNCTION public.op_daily_report(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; n integer:=0; aid uuid; did uuid; sid uuid; pid uuid; phid uuid; wid uuid; detail operational.sms_item_details; parent operational.sms_item_details;
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
  IF detail.qty IS NOT NULL AND (SELECT coalesce(sum(qty),0) FROM operational.sms_item_progress WHERE detail_id=did)+(p_data->>'qty')::numeric > detail.qty THEN
   RAISE EXCEPTION 'Qty progress melebihi total qty sub-item ini';
  END IF;
  INSERT INTO operational.sms_item_progress(detail_id,report_date,qty,notes,recorded_by)
  VALUES(did,(p_data->>'reportDate')::date,(p_data->>'qty')::numeric,coalesce(p_data->>'notes',''),actor)
  RETURNING id INTO pid;
  RETURN jsonb_build_object('id',pid);
 ELSIF p_action='save_item_weather' THEN
  sid:=(p_data->>'smsItemId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.sms_items WHERE id=sid) THEN RAISE EXCEPTION 'Item SMS tidak ditemukan'; END IF;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  IF p_data->>'weather' NOT IN ('CERAH','BERAWAN','HUJAN_RINGAN','HUJAN_LEBAT') THEN RAISE EXCEPTION 'Kondisi cuaca tidak valid'; END IF;
  INSERT INTO operational.sms_item_weather(sms_item_id,report_date,weather,recorded_by)
  VALUES(sid,(p_data->>'reportDate')::date,p_data->>'weather',actor)
  ON CONFLICT (sms_item_id,report_date) DO UPDATE SET weather=excluded.weather,recorded_by=excluded.recorded_by
  RETURNING id INTO wid;
  RETURN jsonb_build_object('id',wid);
 ELSIF p_action='list_item_weather' THEN
  sid:=(p_data->>'smsId')::uuid;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('smsItemId',w.sms_item_id,'weather',w.weather)) FROM operational.sms_item_weather w
   JOIN operational.sms_items si ON si.id=w.sms_item_id
   WHERE si.sms_id=sid AND w.report_date=(p_data->>'reportDate')::date),'[]');
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
  RETURN coalesce((
   SELECT jsonb_agg(jsonb_build_object(
    'smsItemId',grp.sms_item_id,'itemCode',grp.item_code,'itemDescription',grp.item_description,
    'weather',(SELECT w.weather FROM operational.sms_item_weather w WHERE w.sms_item_id=grp.sms_item_id AND w.report_date=(p_data->>'reportDate')::date),
    'entries',grp.entries
   ) ORDER BY grp.item_code)
   FROM (
    SELECT si.id AS sms_item_id, si.code_snapshot AS item_code, si.description_snapshot AS item_description,
     jsonb_agg(jsonb_build_object(
      'detailId',e.detail_id,'description',e.description,'unit',e.unit,
      'qty',e.total_qty,'notes',e.notes_joined,'recordedByNames',e.recorded_by_names,
      'lastUpdatedAt',e.last_created_at,'photos',e.photos
     ) ORDER BY e.sort_order) AS entries
    FROM operational.sms_items si
    JOIN (
     SELECT d.sms_item_id,d.id AS detail_id,d.sort_order,d.description,d.unit,
      sum(pr.qty) AS total_qty,
      nullif(string_agg(NULLIF(btrim(pr.notes),''),'; '),'') AS notes_joined,
      string_agg(DISTINCT k."NamaPersonnel",', ') AS recorded_by_names,
      max(pr.created_at) AS last_created_at,
      (SELECT coalesce(jsonb_agg(jsonb_build_object('id',ph.id,'mimeType',ph.mime_type,'photoData',ph.photo_data) ORDER BY ph.uploaded_at),'[]')
       FROM operational.sms_item_progress_photos ph WHERE ph.progress_id IN (
        SELECT id FROM operational.sms_item_progress WHERE detail_id=d.id AND report_date=(p_data->>'reportDate')::date
       )) AS photos
     FROM operational.sms_item_details d
     JOIN operational.sms_item_progress pr ON pr.detail_id=d.id AND pr.report_date=(p_data->>'reportDate')::date
     LEFT JOIN public."karyawanTbl" k ON k."Id"=pr.recorded_by
     GROUP BY d.sms_item_id,d.id,d.sort_order,d.description,d.unit
    ) e ON e.sms_item_id=si.id
    GROUP BY si.id,si.code_snapshot,si.description_snapshot
   ) grp
  ),'[]');
 ELSE RAISE EXCEPTION 'Operasi tidak tersedia';
 END IF;
END $function$;
COMMIT;
