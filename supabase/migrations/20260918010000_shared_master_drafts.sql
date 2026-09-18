BEGIN;
-- Shared pre-commit master drafts so multiple PIC-authorized users can collaborate
-- on the same import before it is committed to operational.contracts/commercial_items.
-- Keyed by project/contract/revision text (these may not exist yet in operational.projects
-- at draft time). Optimistic concurrency via updated_at prevents silent overwrites.
CREATE TABLE operational.master_drafts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 project_code text NOT NULL CHECK (btrim(project_code) <> ''),
 contract_no text NOT NULL CHECK (btrim(contract_no) <> ''),
 revision text NOT NULL DEFAULT '01' CHECK (btrim(revision) <> ''),
 contract_type text NOT NULL CHECK (contract_type IN ('LUMPSUM','BLANKET_ORDER')),
 source_file text, source_sheet text,
 payload jsonb NOT NULL,
 updated_by bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 updated_at timestamptz NOT NULL DEFAULT now(),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(project_code,contract_no,revision)
);
CREATE INDEX ON operational.master_drafts(project_code);
ALTER TABLE operational.master_drafts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.master_drafts FROM PUBLIC,anon,authenticated;
COMMENT ON TABLE operational.master_drafts IS 'Shared pre-commit master drafts, editable by anyone with Operational Master Komersial PIC. Optimistic concurrency via updated_at; not a substitute for the committed contracts/commercial_items tables.';

CREATE OR REPLACE FUNCTION public.op_api(p_token text,p_action text,p_data jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor bigint; pid uuid; cid uuid; wid uuid; packid uuid; itemid uuid; r jsonb; ids jsonb:='{}'; rowids text[]:=ARRAY[]::text[]; n integer:=0; w operational.work_orders; needed text; outdata jsonb; draft operational.master_drafts; expected_ts timestamptz;
BEGIN
 IF p_action IN ('contracts','master') THEN
  actor:=operational.check_session(p_token,ARRAY['operational master komersial','operational wo']);
 ELSIF p_action='import_master' THEN actor:=operational.check_session(p_token,ARRAY['operational master komersial']);
 ELSIF p_action='approve_wo' THEN actor:=operational.check_session(p_token,ARRAY['operational wo'],'operational approval wo');
 ELSIF p_action IN ('save_wo','list_wo','read_wo') THEN actor:=operational.check_session(p_token,ARRAY['operational wo']);
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
 ELSIF p_action='save_wo' THEN
  cid:=(p_data->>'contractId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.contracts WHERE id=cid AND contract_type='BLANKET_ORDER') THEN RAISE EXCEPTION 'Pilih kontrak Blanket Order'; END IF;
  IF jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Item WO wajib diisi'; END IF;
  IF jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'Jumlah item WO tidak valid'; END IF;
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
 ELSIF p_action='list_wo' THEN
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT w.*,c.number AS contract_number,coalesce((SELECT sum(i.amount) FROM operational.wo_items i WHERE i.wo_id=w.id),0) AS total FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id ORDER BY w.created_at DESC) x),'[]');
 ELSIF p_action='read_wo' THEN
  wid:=(p_data->>'woId')::uuid; SELECT * INTO w FROM operational.work_orders WHERE id=wid;
  IF w.id IS NULL THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  RETURN jsonb_build_object('header',to_jsonb(w),'items',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT i.*,p.name AS package_name FROM operational.wo_items i JOIN operational.wo_packages p ON p.id=i.package_id WHERE i.wo_id=wid ORDER BY i.created_at,i.id) x),'[]'));
 ELSIF p_action='approve_wo' THEN
  wid:=(p_data->>'woId')::uuid; SELECT * INTO w FROM operational.work_orders WHERE id=wid FOR UPDATE;
  IF w.id IS NULL OR w.status<>'DRAFT' THEN RAISE EXCEPTION 'Hanya WO Draft yang dapat disetujui'; END IF;
  IF NOT EXISTS(SELECT 1 FROM operational.wo_items WHERE wo_id=wid) THEN RAISE EXCEPTION 'WO belum memiliki item'; END IF;
  UPDATE operational.work_orders SET status='APPROVED' WHERE id=wid;
  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'APPROVE_WO',wid);
  RETURN jsonb_build_object('woId',wid,'status','APPROVED');
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
REVOKE ALL ON FUNCTION public.op_api(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_api(text,text,jsonb) TO anon,authenticated;
COMMIT;
