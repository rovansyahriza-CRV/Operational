BEGIN;
-- save_sms_item_details (hapus-lalu-buat-ulang seluruh tree tiap simpan) ternyata bakal gagal
-- foreign_key_violation begitu ada progress yang sudah tercatat di salah satu leaf-nya (DELETE
-- ditolak karena masih direferensikan sms_item_progress). Diganti pola tambah satu baris per
-- klik ("Tambah Group"/"Tambah Sub-item" di UI), sesuai cara kerja fitur ini sebenarnya --
-- gak pernah ada "replace semua sekaligus".

CREATE OR REPLACE FUNCTION public.op_daily_report(p_token text,p_action text,p_data jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor bigint; n integer:=0; aid uuid; did uuid; sid uuid; pid uuid; detail operational.sms_item_details; parent operational.sms_item_details;
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
   IF nullif(p_data->>'qty','') IS NULL OR (p_data->>'qty')::numeric<=0 THEN RAISE EXCEPTION 'Qty tidak valid'; END IF;
  END IF;
  SELECT coalesce(max(sort_order),0)+1 INTO n FROM operational.sms_item_details WHERE sms_item_id=sid;
  INSERT INTO operational.sms_item_details(sms_item_id,parent_id,row_kind,activity_id,description,unit,qty,sort_order)
  VALUES(sid,nullif(p_data->>'parentId','')::uuid,p_data->>'rowKind',nullif(p_data->>'activityId','')::uuid,btrim(p_data->>'description'),
   CASE WHEN p_data->>'rowKind'='ITEM' THEN btrim(p_data->>'unit') END,
   CASE WHEN p_data->>'rowKind'='ITEM' THEN (p_data->>'qty')::numeric END,
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
COMMIT;
