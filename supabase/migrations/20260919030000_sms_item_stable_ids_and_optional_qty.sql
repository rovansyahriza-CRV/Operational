BEGIN;
-- Dua fix penting ketemu sebelum sempat kepakai beneran:
--
-- 1) qty di sms_item_details ternyata gak perlu -- qty yang beneran cuma ada di
--    sms_item_progress (dicatat harian). Field qty pas "Tambah Sub-item" dihapus,
--    cuma satuan yang wajib. save_progress juga disesuaikan: cek "gak boleh melebihi
--    qty leaf" cuma jalan kalau leaf itu KEBETULAN punya qty (opsional, buat kompatibel
--    ke depan), gak lagi wajib.
--
-- 2) save_sms (di op_api) ternyata sama persis kena bug yang sama kayak
--    save_sms_item_details sebelumnya: dia DELETE semua sms_items lalu INSERT ulang
--    dari nol tiap kali SMS yang SAMA disimpan lagi -- assign ID baru semua. Begitu ada
--    breakdown (sms_item_details) yang nempel ke salah satu item, re-save SMS itu bakal
--    gagal foreign_key_violation (atau, kalau breakdown belum ada, diam-diam bikin ID
--    lama jadi basi/orphan). Diganti jadi upsert per item (match by sms_id+commercial_item_id
--    +package_id, ID lama dipertahankan kalau item itu masih ada di daftar baru), dan
--    item yang mau dibuang ditolak kalau masih punya breakdown/progress nempel.

ALTER TABLE operational.sms_item_details DROP CONSTRAINT sms_item_details_check1;
ALTER TABLE operational.sms_item_details ADD CONSTRAINT sms_item_details_check1 CHECK(row_kind='GROUP' OR unit IS NOT NULL);

ALTER TABLE operational.sms_items ADD CONSTRAINT sms_items_sms_commercial_package_key UNIQUE(sms_id,commercial_item_id,package_id);

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
 ELSIF p_action='list_progress' THEN
  did:=(p_data->>'detailId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.report_date DESC) FROM (
   SELECT pr.*, k."NamaPersonnel" AS recorded_by_name FROM operational.sms_item_progress pr LEFT JOIN public."karyawanTbl" k ON k."Id"=pr.recorded_by WHERE pr.detail_id=did) x),'[]');
 ELSE RAISE EXCEPTION 'Operasi tidak tersedia';
 END IF;
END $$;

CREATE OR REPLACE FUNCTION public.op_api(p_token text,p_action text,p_data jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor bigint; pid uuid; cid uuid; wid uuid; packid uuid; itemid uuid; r jsonb; ids jsonb:='{}'; rowids text[]:=ARRAY[]::text[]; n integer:=0; w operational.work_orders; needed text; outdata jsonb; draft operational.master_drafts; expected_ts timestamptz; next_revision text;
smsid uuid; smsrow operational.sms_documents; sms_seq integer; sms_rev text; routing_ok boolean; target_status text; evidence_b64 text; keep_ids uuid[];
BEGIN
 IF p_action IN ('contracts','master') THEN
  actor:=operational.check_session(p_token,ARRAY['operational master komersial','operational wo']);
 ELSIF p_action IN ('import_master','add_master_item','update_master') THEN actor:=operational.check_session(p_token,ARRAY['operational master komersial']);
 ELSIF p_action='approve_wo' THEN actor:=operational.check_session(p_token,ARRAY['operational wo'],'operational approval wo');
 ELSIF p_action IN ('save_wo','list_wo','read_wo','revise_wo','save_sms','list_sms','read_sms') THEN actor:=operational.check_session(p_token,ARRAY['operational wo']);
 ELSIF p_action IN ('save_draft','load_draft','list_drafts','delete_draft') THEN actor:=operational.check_session(p_token,ARRAY['operational master komersial']);
 ELSE RAISE EXCEPTION 'Operasi tidak tersedia'; END IF;
 IF p_action='contracts' THEN
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT c.*,p.name AS project_name,p.code AS project_code FROM operational.contracts c JOIN operational.projects p ON p.id=c.project_id ORDER BY c.created_at DESC) x),'[]');
 ELSIF p_action='master' THEN
  cid:=(p_data->>'contractId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY sort_order) FROM operational.commercial_items i WHERE contract_id=cid),'[]');
 ELSIF p_action='import_master' THEN
  IF jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Daftar item wajib diisi'; END IF;
  IF jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 5000 THEN RAISE EXCEPTION 'Import dibatasi 1 sampai 5000 baris'; END IF;
  IF nullif(btrim(p_data->>'projectCode'),'') IS NULL OR nullif(btrim(p_data->>'projectName'),'') IS NULL OR nullif(btrim(p_data->>'contractNo'),'') IS NULL THEN RAISE EXCEPTION 'Project dan nomor kontrak wajib diisi'; END IF;
  INSERT INTO operational.projects(code,name) VALUES(btrim(p_data->>'projectCode'),btrim(p_data->>'projectName')) ON CONFLICT(code) DO NOTHING;
  SELECT id INTO pid FROM operational.projects WHERE code=btrim(p_data->>'projectCode');
  INSERT INTO operational.contracts(project_id,number,contract_type,revision) VALUES(pid,btrim(p_data->>'contractNo'),p_data->>'contractType',coalesce(nullif(btrim(p_data->>'revision'),''),'01')) RETURNING id INTO cid;
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
   IF nullif(r->>'id','') IS NULL OR (r->>'id')=ANY(rowids) THEN RAISE EXCEPTION 'ID baris kosong atau duplikat'; END IF;
   rowids:=array_append(rowids,r->>'id'); n:=n+1;
   IF nullif(btrim(r->>'description'),'') IS NULL THEN RAISE EXCEPTION 'Uraian kosong'; END IF;
   INSERT INTO operational.commercial_items(contract_id,code,description,row_kind,rate_kind,unit,reference_qty,unit_price,source_file,source_sheet,source_row,source_amount,source_unit,sort_order)
   VALUES(cid,r->>'code',r->>'description',r->>'rowKind',coalesce(r->>'rate','STANDARD'),r->>'unit',(r->>'qty')::numeric,(r->>'price')::numeric,p_data->>'sourceFile',p_data->>'sourceSheet',(r->>'sourceRow')::integer,(r->>'amount')::numeric,r->>'unit',n) RETURNING id INTO itemid;
   ids:=ids||jsonb_build_object(r->>'id',itemid);
  END LOOP;
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
   IF nullif(r->>'parentId','') IS NOT NULL THEN
    IF NOT(ids ? (r->>'parentId')) THEN RAISE EXCEPTION 'Induk tidak ditemukan'; END IF;
    UPDATE operational.commercial_items SET parent_id=(ids->>(r->>'parentId'))::uuid WHERE id=(ids->>(r->>'id'))::uuid;
   END IF;
  END LOOP;
  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'IMPORT_MASTER',cid);
  DELETE FROM operational.master_drafts WHERE project_code=btrim(p_data->>'projectCode') AND contract_no=btrim(p_data->>'contractNo') AND revision=coalesce(nullif(btrim(p_data->>'revision'),''),'01');
  RETURN jsonb_build_object('contractId',cid,'itemIds',ids);
 ELSIF p_action='update_master' THEN
  cid:=(p_data->>'contractId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.contracts WHERE id=cid) THEN RAISE EXCEPTION 'Kontrak tidak ditemukan'; END IF;
  IF jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Daftar item wajib diisi'; END IF;
  IF jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 5000 THEN RAISE EXCEPTION 'Import dibatasi 1 sampai 5000 baris'; END IF;
  UPDATE operational.commercial_items SET parent_id=NULL WHERE contract_id=cid;
  DELETE FROM operational.commercial_items WHERE contract_id=cid AND row_kind='GROUP';
  DELETE FROM operational.commercial_items ci
   WHERE ci.contract_id=cid AND ci.row_kind='ITEM'
   AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_data->'items') x WHERE x->>'code'=ci.code)
   AND NOT EXISTS(SELECT 1 FROM operational.wo_items wi WHERE wi.commercial_item_id=ci.id);
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
   IF nullif(r->>'id','') IS NULL OR (r->>'id')=ANY(rowids) THEN RAISE EXCEPTION 'ID baris kosong atau duplikat'; END IF;
   rowids:=array_append(rowids,r->>'id'); n:=n+1;
   IF nullif(btrim(r->>'description'),'') IS NULL THEN RAISE EXCEPTION 'Uraian kosong'; END IF;
   itemid:=NULL;
   IF r->>'rowKind'='ITEM' THEN
    SELECT id INTO itemid FROM operational.commercial_items WHERE contract_id=cid AND row_kind='ITEM' AND code=r->>'code';
   END IF;
   IF itemid IS NOT NULL THEN
    UPDATE operational.commercial_items SET description=r->>'description',rate_kind=coalesce(r->>'rate','STANDARD'),unit=r->>'unit',reference_qty=(r->>'qty')::numeric,unit_price=(r->>'price')::numeric,source_file=p_data->>'sourceFile',source_sheet=p_data->>'sourceSheet',source_row=(r->>'sourceRow')::integer,source_amount=(r->>'amount')::numeric,source_unit=r->>'unit',sort_order=n WHERE id=itemid;
   ELSE
    INSERT INTO operational.commercial_items(contract_id,code,description,row_kind,rate_kind,unit,reference_qty,unit_price,source_file,source_sheet,source_row,source_amount,source_unit,sort_order)
    VALUES(cid,r->>'code',r->>'description',r->>'rowKind',coalesce(r->>'rate','STANDARD'),r->>'unit',(r->>'qty')::numeric,(r->>'price')::numeric,p_data->>'sourceFile',p_data->>'sourceSheet',(r->>'sourceRow')::integer,(r->>'amount')::numeric,r->>'unit',n) RETURNING id INTO itemid;
   END IF;
   ids:=ids||jsonb_build_object(r->>'id',itemid);
  END LOOP;
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
   IF nullif(r->>'parentId','') IS NOT NULL THEN
    IF NOT(ids ? (r->>'parentId')) THEN RAISE EXCEPTION 'Induk tidak ditemukan'; END IF;
    UPDATE operational.commercial_items SET parent_id=(ids->>(r->>'parentId'))::uuid WHERE id=(ids->>(r->>'id'))::uuid;
   END IF;
  END LOOP;
  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'UPDATE_MASTER',cid);
  DELETE FROM operational.master_drafts WHERE project_code=(SELECT p.code FROM operational.projects p JOIN operational.contracts c ON c.project_id=p.id WHERE c.id=cid) AND contract_no=(SELECT number FROM operational.contracts WHERE id=cid) AND revision=(SELECT revision FROM operational.contracts WHERE id=cid);
  RETURN jsonb_build_object('contractId',cid,'itemIds',ids);
 ELSIF p_action='add_master_item' THEN
  cid:=(p_data->>'contractId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.contracts WHERE id=cid) THEN RAISE EXCEPTION 'Kontrak tidak ditemukan'; END IF;
  IF nullif(btrim(p_data->>'description'),'') IS NULL THEN RAISE EXCEPTION 'Uraian wajib diisi'; END IF;
  IF nullif(btrim(p_data->>'unit'),'') IS NULL THEN RAISE EXCEPTION 'Satuan wajib diisi'; END IF;
  IF nullif(p_data->>'price','') IS NULL OR (p_data->>'price')::numeric<0 THEN RAISE EXCEPTION 'Harga tidak valid'; END IF;
  IF nullif(p_data->>'parentId','') IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM operational.commercial_items WHERE id=(p_data->>'parentId')::uuid AND contract_id=cid AND row_kind='GROUP'
  ) THEN RAISE EXCEPTION 'Induk harus kelompok pada kontrak yang sama'; END IF;
  SELECT coalesce(max(sort_order),0)+1 INTO n FROM operational.commercial_items WHERE contract_id=cid;
  INSERT INTO operational.commercial_items(contract_id,parent_id,code,description,row_kind,rate_kind,unit,reference_qty,unit_price,sort_order)
  VALUES(cid,nullif(p_data->>'parentId','')::uuid,coalesce(nullif(btrim(p_data->>'code'),''),'MANUAL-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')),btrim(p_data->>'description'),'ITEM',coalesce(nullif(p_data->>'rateKind',''),'STANDARD'),btrim(p_data->>'unit'),nullif(p_data->>'qty','')::numeric,(p_data->>'price')::numeric,n)
  RETURNING id INTO itemid;
  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'ADD_MASTER_ITEM',cid);
  RETURN jsonb_build_object('itemId',itemid);
 ELSIF p_action='save_wo' THEN
  cid:=(p_data->>'contractId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.contracts WHERE id=cid AND contract_type='BLANKET_ORDER') THEN RAISE EXCEPTION 'Pilih kontrak Blanket Order'; END IF;
  IF jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Item WO wajib diisi'; END IF;
  IF jsonb_array_length(p_data->'items') NOT BETWEEN 0 AND 1000 THEN RAISE EXCEPTION 'Jumlah item WO tidak valid'; END IF;
  IF nullif(btrim(p_data->>'number'),'') IS NULL OR nullif(btrim(p_data->>'title'),'') IS NULL THEN RAISE EXCEPTION 'Nomor dan nama WO wajib diisi'; END IF;
  INSERT INTO operational.work_orders(contract_id,number,title) VALUES(cid,btrim(p_data->>'number'),btrim(p_data->>'title')) RETURNING id INTO wid;
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
   needed:=coalesce(nullif(btrim(r->>'package'),''),'Paket 1');
   SELECT id INTO packid FROM operational.wo_packages WHERE wo_id=wid AND name=needed LIMIT 1;
   IF packid IS NULL THEN n:=n+1; INSERT INTO operational.wo_packages(wo_id,code,name) VALUES(wid,'P'||n,needed) RETURNING id INTO packid; END IF;
   INSERT INTO operational.wo_items(wo_id,package_id,commercial_item_id,qty) VALUES(wid,packid,(r->>'sourceId')::uuid,(r->>'qty')::numeric);
  END LOOP;
  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'CREATE_WO',wid);
  RETURN jsonb_build_object('woId',wid);
 ELSIF p_action='revise_wo' THEN
  wid:=(p_data->>'sourceWoId')::uuid;
  SELECT * INTO w FROM operational.work_orders WHERE id=wid;
  IF w.id IS NULL THEN RAISE EXCEPTION 'WO sumber tidak ditemukan'; END IF;
  IF jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Item WO wajib diisi'; END IF;
  IF jsonb_array_length(p_data->'items') NOT BETWEEN 0 AND 1000 THEN RAISE EXCEPTION 'Jumlah item WO tidak valid'; END IF;
  SELECT to_char(coalesce(max(nullif(revision,'')::int),0)+1,'FM00') INTO next_revision
   FROM operational.work_orders WHERE contract_id=w.contract_id AND number=w.number AND revision~'^\d+$';
  next_revision:=coalesce(next_revision,'02');
  INSERT INTO operational.work_orders(contract_id,number,title,revision) VALUES(w.contract_id,w.number,coalesce(nullif(btrim(p_data->>'title'),''),w.title),next_revision) RETURNING id INTO wid;
  n:=0;
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
   needed:=coalesce(nullif(btrim(r->>'package'),''),'Paket 1');
   SELECT id INTO packid FROM operational.wo_packages WHERE wo_id=wid AND name=needed LIMIT 1;
   IF packid IS NULL THEN n:=n+1; INSERT INTO operational.wo_packages(wo_id,code,name) VALUES(wid,'P'||n,needed) RETURNING id INTO packid; END IF;
   INSERT INTO operational.wo_items(wo_id,package_id,commercial_item_id,qty) VALUES(wid,packid,(r->>'sourceId')::uuid,(r->>'qty')::numeric);
  END LOOP;
  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'REVISE_WO',wid);
  RETURN jsonb_build_object('woId',wid,'revision',next_revision);
 ELSIF p_action='list_wo' THEN
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT wo.*,c.number AS contract_number,coalesce((SELECT sum(i.amount) FROM operational.wo_items i WHERE i.wo_id=wo.id),0) AS total FROM operational.work_orders wo JOIN operational.contracts c ON c.id=wo.contract_id ORDER BY wo.created_at DESC) x),'[]');
 ELSIF p_action='read_wo' THEN
  wid:=(p_data->>'woId')::uuid; SELECT * INTO w FROM operational.work_orders WHERE id=wid;
  IF w.id IS NULL THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  RETURN jsonb_build_object('header',to_jsonb(w),'items',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT i.*,p.name AS package_name FROM operational.wo_items i JOIN operational.wo_packages p ON p.id=i.package_id WHERE i.wo_id=wid ORDER BY i.created_at,i.id) x),'[]'));
 ELSIF p_action='approve_wo' THEN
  wid:=(p_data->>'woId')::uuid; SELECT * INTO w FROM operational.work_orders WHERE id=wid FOR UPDATE;
  IF w.id IS NULL OR w.status<>'DRAFT' THEN RAISE EXCEPTION 'Hanya WO Draft yang dapat disetujui'; END IF;
   UPDATE operational.work_orders SET status='APPROVED' WHERE id=wid;
  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'APPROVE_WO',wid);
  RETURN jsonb_build_object('woId',wid,'status','APPROVED');
 ELSIF p_action='save_sms' THEN
  wid:=(p_data->>'woId')::uuid;
  SELECT * INTO w FROM operational.work_orders WHERE id=wid;
  IF w.id IS NULL THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  IF nullif(p_data->>'documentDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal SMS wajib diisi'; END IF;
  IF nullif(btrim(p_data->>'contractor'),'') IS NULL OR nullif(btrim(p_data->>'proposer'),'') IS NULL OR nullif(btrim(p_data->>'proposerRole'),'') IS NULL THEN RAISE EXCEPTION 'Nama kontraktor, nama, dan jabatan proposer wajib diisi'; END IF;
  IF jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Item SMS wajib diisi'; END IF;
  IF jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'Jumlah item SMS tidak valid'; END IF;

  smsid:=nullif(p_data->>'smsId','')::uuid;
  IF smsid IS NOT NULL THEN
   SELECT * INTO smsrow FROM operational.sms_documents WHERE id=smsid AND wo_id=wid;
   IF smsrow.id IS NULL THEN RAISE EXCEPTION 'Dokumen SMS tidak ditemukan'; END IF;
   IF smsrow.status='APPROVED' THEN RAISE EXCEPTION 'SMS yang sudah disetujui tidak bisa diubah lagi.'; END IF;
   sms_seq:=smsrow.sequence_no; sms_rev:=smsrow.revision;
  ELSIF nullif(p_data->>'reviseFromId','') IS NOT NULL THEN
   SELECT * INTO smsrow FROM operational.sms_documents WHERE id=(p_data->>'reviseFromId')::uuid AND wo_id=wid;
   IF smsrow.id IS NULL THEN RAISE EXCEPTION 'SMS sumber revisi tidak ditemukan'; END IF;
   sms_seq:=smsrow.sequence_no;
   SELECT to_char(coalesce(max(nullif(revision,'')::int),0)+1,'FM00') INTO sms_rev FROM operational.sms_documents WHERE wo_id=wid AND sequence_no=sms_seq AND revision~'^\d+$';
   sms_rev:=coalesce(sms_rev,'02');
  ELSE
   SELECT coalesce(max(sequence_no),0)+1 INTO sms_seq FROM operational.sms_documents WHERE wo_id=wid;
   sms_rev:='01';
  END IF;

  routing_ok:=coalesce((p_data->>'routingPropose')::boolean,false) AND coalesce((p_data->>'routingSupervisor')::boolean,false) AND coalesce((p_data->>'routingSuperintendent')::boolean,false) AND coalesce((p_data->>'routingRequester')::boolean,false);
  target_status:=coalesce(nullif(p_data->>'status',''),'DRAFT');
  IF target_status NOT IN ('DRAFT','SUBMITTED','APPROVED') THEN RAISE EXCEPTION 'Status SMS tidak valid'; END IF;
  evidence_b64:=nullif(p_data->>'evidenceBase64','');
  IF evidence_b64 IS NOT NULL AND length(evidence_b64)>12*1024*1024 THEN RAISE EXCEPTION 'Bukti PDF terlalu besar'; END IF;
  IF target_status='APPROVED' THEN
   IF NOT routing_ok THEN RAISE EXCEPTION 'Centang semua routing sebelum menandai SMS disetujui'; END IF;
   IF evidence_b64 IS NULL AND (smsid IS NULL OR smsrow.evidence_data IS NULL) THEN RAISE EXCEPTION 'Lampirkan bukti PDF sebelum menandai SMS disetujui'; END IF;
  END IF;

  IF smsid IS NULL THEN
   INSERT INTO operational.sms_documents(wo_id,sequence_no,revision,number,document_date,notification_number,location,contractor,proposer,proposer_role,status,routing_propose,routing_supervisor,routing_superintendent,routing_requester,approval_recorded_by,approval_date,evidence_path,evidence_data,created_by)
   VALUES(wid,sms_seq,sms_rev,'BIMA-SMS/'||w.number||'-'||lpad(sms_seq::text,3,'0'),(p_data->>'documentDate')::date,coalesce(p_data->>'notificationNumber',''),coalesce(p_data->>'location',''),btrim(p_data->>'contractor'),btrim(p_data->>'proposer'),btrim(p_data->>'proposerRole'),target_status,
   coalesce((p_data->>'routingPropose')::boolean,false),coalesce((p_data->>'routingSupervisor')::boolean,false),coalesce((p_data->>'routingSuperintendent')::boolean,false),coalesce((p_data->>'routingRequester')::boolean,false),
   CASE WHEN target_status='APPROVED' THEN actor END, CASE WHEN target_status='APPROVED' THEN coalesce(nullif(p_data->>'approvalDate','')::date,current_date) END,
   nullif(p_data->>'evidenceFilename',''),evidence_b64,actor)
   RETURNING id INTO smsid;
  ELSE
   UPDATE operational.sms_documents SET
    document_date=(p_data->>'documentDate')::date, notification_number=coalesce(p_data->>'notificationNumber',''), location=coalesce(p_data->>'location',''),
    contractor=btrim(p_data->>'contractor'), proposer=btrim(p_data->>'proposer'), proposer_role=btrim(p_data->>'proposerRole'), status=target_status,
    routing_propose=coalesce((p_data->>'routingPropose')::boolean,false), routing_supervisor=coalesce((p_data->>'routingSupervisor')::boolean,false),
    routing_superintendent=coalesce((p_data->>'routingSuperintendent')::boolean,false), routing_requester=coalesce((p_data->>'routingRequester')::boolean,false),
    approval_recorded_by=CASE WHEN target_status='APPROVED' THEN actor ELSE approval_recorded_by END,
    approval_date=CASE WHEN target_status='APPROVED' THEN coalesce(nullif(p_data->>'approvalDate','')::date,current_date) ELSE approval_date END,
    evidence_path=coalesce(nullif(p_data->>'evidenceFilename',''),evidence_path), evidence_data=coalesce(evidence_b64,evidence_data)
   WHERE id=smsid;
  END IF;

  keep_ids:=ARRAY[]::uuid[];
  FOR r IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
   needed:=coalesce(nullif(btrim(r->>'package'),''),'Paket 1');
   SELECT id INTO packid FROM operational.wo_packages WHERE wo_id=wid AND name=needed LIMIT 1;
   IF packid IS NULL THEN n:=n+1; INSERT INTO operational.wo_packages(wo_id,code,name) VALUES(wid,'P'||n,needed) RETURNING id INTO packid; END IF;
   SELECT id INTO itemid FROM operational.sms_items WHERE sms_id=smsid AND commercial_item_id=(r->>'sourceId')::uuid AND package_id=packid;
   IF itemid IS NOT NULL THEN
    UPDATE operational.sms_items SET qty=(r->>'qty')::numeric WHERE id=itemid;
   ELSE
    itemid:=NULL;
    INSERT INTO operational.sms_items(sms_id,wo_id,package_id,commercial_item_id,code_snapshot,description_snapshot,unit_snapshot,unit_price_snapshot,qty)
    SELECT smsid,wid,packid,ci.id,ci.code,ci.description,ci.unit,ci.unit_price,(r->>'qty')::numeric
    FROM operational.commercial_items ci WHERE ci.id=(r->>'sourceId')::uuid
    RETURNING id INTO itemid;
    IF itemid IS NULL THEN RAISE EXCEPTION 'Item master tidak ditemukan untuk salah satu baris SMS'; END IF;
   END IF;
   keep_ids:=array_append(keep_ids,itemid);
  END LOOP;
  IF EXISTS(
   SELECT 1 FROM operational.sms_items si WHERE si.sms_id=smsid AND NOT(si.id=ANY(keep_ids))
   AND EXISTS(SELECT 1 FROM operational.sms_item_details d WHERE d.sms_item_id=si.id)
  ) THEN RAISE EXCEPTION 'Ada item SMS yang mau dihapus tapi sudah punya breakdown/progress -- hapus dulu breakdown-nya sebelum menghapus item ini dari SMS'; END IF;
  DELETE FROM operational.sms_items WHERE sms_id=smsid AND NOT(id=ANY(keep_ids));

  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'SAVE_SMS',smsid);
  RETURN jsonb_build_object('smsId',smsid,'number','BIMA-SMS/'||w.number||'-'||lpad(sms_seq::text,3,'0'),'revision',sms_rev,'status',target_status);
 ELSIF p_action='list_sms' THEN
  wid:=(p_data->>'woId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.sequence_no,x.revision) FROM (
   SELECT id,sequence_no,revision,number,status,document_date FROM operational.sms_documents WHERE wo_id=wid) x),'[]');
 ELSIF p_action='read_sms' THEN
  smsid:=(p_data->>'smsId')::uuid;
  SELECT * INTO smsrow FROM operational.sms_documents WHERE id=smsid;
  IF smsrow.id IS NULL THEN RAISE EXCEPTION 'Dokumen SMS tidak ditemukan'; END IF;
  RETURN jsonb_build_object('header',to_jsonb(smsrow),'items',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT i.*,pk.name AS package_name FROM operational.sms_items i JOIN operational.wo_packages pk ON pk.id=i.package_id WHERE i.sms_id=smsid ORDER BY i.id) x),'[]'));
 ELSIF p_action='save_draft' THEN
  IF nullif(btrim(p_data->>'projectCode'),'') IS NULL OR nullif(btrim(p_data->>'contractNo'),'') IS NULL THEN RAISE EXCEPTION 'Kode project dan nomor kontrak wajib diisi'; END IF;
  IF p_data->'payload' IS NULL THEN RAISE EXCEPTION 'Payload draft kosong'; END IF;
  expected_ts:=nullif(p_data->>'expectedUpdatedAt','')::timestamptz;
  SELECT * INTO draft FROM operational.master_drafts
   WHERE project_code=btrim(p_data->>'projectCode') AND contract_no=btrim(p_data->>'contractNo') AND revision=coalesce(nullif(btrim(p_data->>'revision'),''),'01')
   FOR UPDATE;
  IF draft.id IS NOT NULL AND draft.updated_at IS DISTINCT FROM expected_ts THEN
   RAISE EXCEPTION 'Draft sudah diperbarui orang lain sejak terakhir dimuat. Muat ulang draft sebelum menyimpan.' USING ERRCODE='40001';
  END IF;
  INSERT INTO operational.master_drafts(project_code,contract_no,revision,contract_type,source_file,source_sheet,payload,updated_by)
  VALUES(btrim(p_data->>'projectCode'),btrim(p_data->>'contractNo'),coalesce(nullif(btrim(p_data->>'revision'),''),'01'),p_data->>'contractType',p_data->>'sourceFile',p_data->>'sourceSheet',p_data->'payload',actor)
  ON CONFLICT(project_code,contract_no,revision) DO UPDATE SET contract_type=excluded.contract_type,source_file=excluded.source_file,source_sheet=excluded.source_sheet,payload=excluded.payload,updated_by=excluded.updated_by,updated_at=now()
  RETURNING * INTO draft;
  RETURN jsonb_build_object('updatedAt',draft.updated_at);
 ELSIF p_action='load_draft' THEN
  SELECT * INTO draft FROM operational.master_drafts WHERE project_code=btrim(p_data->>'projectCode') AND contract_no=btrim(p_data->>'contractNo') AND revision=coalesce(nullif(btrim(p_data->>'revision'),''),'01');
  IF draft.id IS NULL THEN RAISE EXCEPTION 'Draft tidak ditemukan'; END IF;
  RETURN jsonb_build_object('payload',draft.payload,'contractType',draft.contract_type,'sourceFile',draft.source_file,'sourceSheet',draft.source_sheet,'updatedAt',draft.updated_at);
 ELSIF p_action='list_drafts' THEN
  IF nullif(btrim(p_data->>'projectCode'),'') IS NULL THEN RAISE EXCEPTION 'Kode project wajib diisi'; END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.updated_at DESC) FROM (
   SELECT d.contract_no,d.revision,d.contract_type,d.updated_at,k."NamaPersonnel" AS updated_by_name
   FROM operational.master_drafts d LEFT JOIN public."karyawanTbl" k ON k."Id"=d.updated_by
   WHERE d.project_code=btrim(p_data->>'projectCode')) x),'[]');
 ELSIF p_action='delete_draft' THEN
  DELETE FROM operational.master_drafts WHERE project_code=btrim(p_data->>'projectCode') AND contract_no=btrim(p_data->>'contractNo') AND revision=coalesce(nullif(btrim(p_data->>'revision'),''),'01');
  RETURN jsonb_build_object('deleted',true);
 END IF;
 RAISE EXCEPTION 'Operasi tidak tersedia';
END $$;
COMMIT;
