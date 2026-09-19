BEGIN;
-- Modul Daily Report: breakdown eksekusi (WBS) di bawah satu item SMS, buat tracking progress
-- harian + (nanti) resource. Item SMS tetap layer komersial (harga/qty yang di-invoice) -- gak
-- diubah. Breakdown ini murni buat checklist lapangan: Group (dari katalog aktivitas standar,
-- bisa terus nambah) -> leaf sub-item (diketik manual, beda2 tiap job: nomor line, ukuran pipa,
-- dst) -> progress harian per leaf (qty yang selesai hari itu, dicicil sampai qty leaf terpenuhi).

CREATE TABLE operational.activity_library (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 category text NOT NULL CHECK(btrim(category)<>''),
 name text NOT NULL CHECK(btrim(name)<>''),
 created_by bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(category,name)
);

CREATE TABLE operational.sms_item_details (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 sms_item_id uuid NOT NULL REFERENCES operational.sms_items(id),
 parent_id uuid REFERENCES operational.sms_item_details(id),
 row_kind text NOT NULL CHECK(row_kind IN ('GROUP','ITEM')),
 activity_id uuid REFERENCES operational.activity_library(id),
 description text NOT NULL CHECK(btrim(description)<>''),
 unit text,
 qty numeric CHECK(qty IS NULL OR (qty>0 AND qty::text NOT IN ('NaN','Infinity','-Infinity'))),
 sort_order integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(row_kind='ITEM' OR (unit IS NULL AND qty IS NULL)),
 CHECK(row_kind='GROUP' OR (unit IS NOT NULL AND qty IS NOT NULL))
);
CREATE INDEX ON operational.sms_item_details(sms_item_id);
CREATE INDEX ON operational.sms_item_details(parent_id);

CREATE TABLE operational.sms_item_progress (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 detail_id uuid NOT NULL REFERENCES operational.sms_item_details(id),
 report_date date NOT NULL,
 qty numeric NOT NULL CHECK(qty>0 AND qty::text NOT IN ('NaN','Infinity','-Infinity')),
 notes text NOT NULL DEFAULT '',
 recorded_by bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON operational.sms_item_progress(detail_id);

ALTER TABLE operational.activity_library ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.sms_item_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.sms_item_progress ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.activity_library,operational.sms_item_details,operational.sms_item_progress FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.op_daily_report(p_token text,p_action text,p_data jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor bigint; r jsonb; n integer:=0; aid uuid; did uuid; sid uuid; pid uuid; ids jsonb:='{}'; rowids text[]:=ARRAY[]::text[]; detail operational.sms_item_details;
BEGIN
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 IF p_action='list_activities' THEN
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.category,a.name) FROM operational.activity_library a),'[]');
 ELSIF p_action='add_activity' THEN
  IF nullif(btrim(p_data->>'category'),'') IS NULL OR nullif(btrim(p_data->>'name'),'') IS NULL THEN RAISE EXCEPTION 'Kategori dan nama aktivitas wajib diisi'; END IF;
  INSERT INTO operational.activity_library(category,name,created_by) VALUES(btrim(p_data->>'category'),btrim(p_data->>'name'),actor)
  ON CONFLICT(category,name) DO NOTHING
  RETURNING id INTO aid;
  IF aid IS NULL THEN SELECT id INTO aid FROM operational.activity_library WHERE category=btrim(p_data->>'category') AND name=btrim(p_data->>'name'); END IF;
  RETURN jsonb_build_object('id',aid);
 ELSIF p_action='save_sms_item_details' THEN
  sid:=(p_data->>'smsItemId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.sms_items WHERE id=sid) THEN RAISE EXCEPTION 'Item SMS tidak ditemukan'; END IF;
  IF jsonb_typeof(p_data->'rows') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Struktur breakdown wajib diisi'; END IF;
  IF jsonb_array_length(p_data->'rows') NOT BETWEEN 0 AND 500 THEN RAISE EXCEPTION 'Jumlah baris breakdown tidak valid'; END IF;
  DELETE FROM operational.sms_item_details WHERE sms_item_id=sid;
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'rows') LOOP
   IF nullif(r->>'id','') IS NULL OR (r->>'id')=ANY(rowids) THEN RAISE EXCEPTION 'ID baris kosong atau duplikat'; END IF;
   rowids:=array_append(rowids,r->>'id');
   IF nullif(btrim(r->>'description'),'') IS NULL THEN RAISE EXCEPTION 'Uraian breakdown kosong'; END IF;
   IF r->>'rowKind' NOT IN ('GROUP','ITEM') THEN RAISE EXCEPTION 'Jenis baris tidak valid'; END IF;
   n:=n+1;
   INSERT INTO operational.sms_item_details(sms_item_id,row_kind,activity_id,description,unit,qty,sort_order)
   VALUES(sid,r->>'rowKind',nullif(r->>'activityId','')::uuid,btrim(r->>'description'),
    CASE WHEN r->>'rowKind'='ITEM' THEN r->>'unit' END,
    CASE WHEN r->>'rowKind'='ITEM' THEN (r->>'qty')::numeric END,
    n)
   RETURNING id INTO did;
   ids:=ids||jsonb_build_object(r->>'id',did);
  END LOOP;
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'rows') LOOP
   IF nullif(r->>'parentId','') IS NOT NULL THEN
    IF NOT(ids ? (r->>'parentId')) THEN RAISE EXCEPTION 'Induk tidak ditemukan'; END IF;
    UPDATE operational.sms_item_details SET parent_id=(ids->>(r->>'parentId'))::uuid WHERE id=(ids->>(r->>'id'))::uuid;
   END IF;
  END LOOP;
  RETURN jsonb_build_object('smsItemId',sid,'ids',ids);
 ELSIF p_action='read_sms_item_details' THEN
  sid:=(p_data->>'smsItemId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.sort_order) FROM operational.sms_item_details d WHERE d.sms_item_id=sid),'[]');
 ELSIF p_action='save_progress' THEN
  did:=(p_data->>'detailId')::uuid;
  SELECT * INTO detail FROM operational.sms_item_details WHERE id=did;
  IF detail.id IS NULL THEN RAISE EXCEPTION 'Sub-item tidak ditemukan'; END IF;
  IF detail.row_kind<>'ITEM' THEN RAISE EXCEPTION 'Progress cuma bisa diisi di leaf item, bukan Group'; END IF;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  IF nullif(p_data->>'qty','') IS NULL OR (p_data->>'qty')::numeric<=0 THEN RAISE EXCEPTION 'Qty tidak valid'; END IF;
  IF (SELECT coalesce(sum(qty),0) FROM operational.sms_item_progress WHERE detail_id=did)+(p_data->>'qty')::numeric > detail.qty THEN
   RAISE EXCEPTION 'Qty progress melebihi total qty sub-item ini';
  END IF;
  INSERT INTO operational.sms_item_progress(detail_id,report_date,qty,notes,recorded_by)
  VALUES(did,(p_data->>'reportDate')::date,(p_data->>'qty')::numeric,coalesce(p_data->>'notes',''),actor)
  RETURNING id INTO pid;
  RETURN jsonb_build_object('id',pid);
 ELSIF p_action='list_progress' THEN
  did:=(p_data->>'detailId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.report_date DESC) FROM (
   SELECT pr.*, k."NamaPersonnel" AS recorded_by_name FROM operational.sms_item_progress pr LEFT JOIN public."karyawanTbl" k ON k."Id"=pr.recorded_by WHERE pr.detail_id=did) x),'[]');
 ELSE RAISE EXCEPTION 'Operasi tidak tersedia';
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.op_daily_report(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_daily_report(text,text,jsonb) TO anon,authenticated;
COMMIT;
