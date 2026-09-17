BEGIN;
ALTER TABLE operational.commercial_items ADD CONSTRAINT finite_commercial_numbers CHECK (
 (unit_price IS NULL OR unit_price::text NOT IN ('NaN','Infinity','-Infinity')) AND
 (reference_qty IS NULL OR reference_qty::text NOT IN ('NaN','Infinity','-Infinity')) AND
 (source_amount IS NULL OR source_amount::text NOT IN ('NaN','Infinity','-Infinity'))
);
ALTER TABLE operational.wo_items ADD CONSTRAINT finite_wo_numbers CHECK(qty::text NOT IN ('NaN','Infinity','-Infinity') AND unit_price_snapshot::text NOT IN ('NaN','Infinity','-Infinity'));
CREATE TABLE operational.sessions (
 token_hash bytea PRIMARY KEY, employee_id bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 credential_hash bytea NOT NULL, expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE operational.login_attempts (employee_id bigint PRIMARY KEY, attempts integer NOT NULL, window_start timestamptz NOT NULL);
CREATE TABLE operational.audit_log (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),employee_id bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),action text NOT NULL,entity_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE operational.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.login_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.audit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.sessions,operational.login_attempts,operational.audit_log FROM PUBLIC,anon,authenticated;
CREATE INDEX ON operational.sessions(expires_at);
CREATE FUNCTION operational.tokens(p_text text) RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT COALESCE(array_agg(lower(btrim(x))) FILTER(WHERE btrim(x)<>''),ARRAY[]::text[]) FROM regexp_split_to_table(coalesce(p_text,''),'[,;\n\r]+') x;
$$;
CREATE FUNCTION operational.check_session(p_token text,p_pic text[],p_author text DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE who bigint; pics text[]; authors text[];
BEGIN
 IF p_token IS NULL OR length(p_token)<>64 THEN RAISE EXCEPTION 'Sesi tidak valid. Login kembali.' USING ERRCODE='28000'; END IF;
 SELECT s.employee_id,operational.tokens(p.pic),operational.tokens(p."Author") INTO who,pics,authors
 FROM operational.sessions s JOIN public."paswordTbl" p ON p."Id"=s.employee_id
 WHERE s.token_hash=sha256(convert_to(p_token,'UTF8')) AND s.expires_at>now() AND p."IsActive"=true
 AND s.credential_hash=sha256(convert_to(coalesce(p."PasswordHas",''),'UTF8'));
 IF who IS NULL THEN RAISE EXCEPTION 'Sesi berakhir atau akun dinonaktifkan.' USING ERRCODE='28000'; END IF;
 IF NOT (pics && p_pic) THEN RAISE EXCEPTION 'PIC tidak mengizinkan halaman atau operasi ini.' USING ERRCODE='42501'; END IF;
 IF p_author IS NOT NULL AND NOT(p_author=ANY(authors)) THEN RAISE EXCEPTION 'Author tidak mengizinkan approval ini.' USING ERRCODE='42501'; END IF;
 RETURN who;
END $$;
CREATE FUNCTION public.op_login(p_id bigint,p_password text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u record; a operational.login_attempts; token text; credential text; pages text[];
BEGIN
 IF p_id IS NULL OR p_password IS NULL OR length(p_password)>1024 THEN RETURN jsonb_build_object('error','Login gagal. Periksa akun dan akses Operational.'); END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('operational-login:'||p_id::text,0));
 DELETE FROM operational.sessions WHERE expires_at<now();
 DELETE FROM operational.login_attempts WHERE window_start<now()-interval '15 minutes';
 SELECT * INTO a FROM operational.login_attempts WHERE employee_id=p_id;
 IF a.attempts>=5 THEN RETURN jsonb_build_object('error','Terlalu banyak percobaan. Coba lagi setelah 15 menit.'); END IF;
 INSERT INTO operational.login_attempts VALUES(p_id,1,now()) ON CONFLICT(employee_id) DO UPDATE SET attempts=operational.login_attempts.attempts+1;
 SELECT * INTO u FROM public.verify_login(p_id,p_password) LIMIT 1;
 IF u.id IS NULL THEN RETURN jsonb_build_object('error','Login gagal. Periksa akun dan akses Operational.'); END IF;
 pages:=operational.tokens(u.pic);
 IF NOT(pages && ARRAY['operational master komersial','operational wo','operational progress','operational resources']) THEN
 RETURN jsonb_build_object('error','Login gagal. Periksa akun dan akses Operational.'); END IF;
 SELECT "PasswordHas" INTO credential FROM public."paswordTbl" WHERE "Id"=p_id AND "IsActive"=true;
 token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 INSERT INTO operational.sessions(token_hash,employee_id,credential_hash,expires_at) VALUES(sha256(convert_to(token,'UTF8')),p_id,sha256(convert_to(credential,'UTF8')),now()+interval '8 hours');
 DELETE FROM operational.login_attempts WHERE employee_id=p_id;
 RETURN jsonb_build_object('token',token,'name',u.nama,'pic',pages,'author',operational.tokens(u.author),'expiresAt',now()+interval '8 hours');
END $$;
CREATE FUNCTION public.op_logout(p_token text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 DELETE FROM operational.sessions WHERE token_hash=sha256(convert_to(p_token,'UTF8'));
$$;
CREATE FUNCTION public.op_api(p_token text,p_action text,p_data jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor bigint; pid uuid; cid uuid; wid uuid; packid uuid; itemid uuid; r jsonb; ids jsonb:='{}'; rowids text[]:=ARRAY[]::text[]; n integer:=0; w operational.work_orders; needed text; outdata jsonb;
BEGIN
 IF p_action IN ('contracts','master') THEN
  actor:=operational.check_session(p_token,ARRAY['operational master komersial','operational wo']);
 ELSIF p_action='import_master' THEN actor:=operational.check_session(p_token,ARRAY['operational master komersial']);
 ELSIF p_action='approve_wo' THEN actor:=operational.check_session(p_token,ARRAY['operational wo'],'operational approval wo');
 ELSIF p_action IN ('save_wo','list_wo','read_wo') THEN actor:=operational.check_session(p_token,ARRAY['operational wo']);
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
 END IF;
 RAISE EXCEPTION 'Operasi tidak tersedia';
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA operational FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.op_login(bigint,text),public.op_logout(text),public.op_api(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_login(bigint,text),public.op_logout(text),public.op_api(text,text,jsonb) TO anon,authenticated;
DO $$
DECLARE result jsonb; tok text; cid uuid; wid uuid; itemid uuid; bad boolean; idmap jsonb;
BEGIN
 INSERT INTO public."karyawanTbl"("Id","NamaPersonnel","DigitalPIN","IsActive") VALUES(-910016,'Operational rollback test',-910016,true);
 INSERT INTO public."paswordTbl"("Id","PasswordHas","IsActive",pic,"Author") VALUES(-910016,'test-password-only',true,'Operational Master Komersial, Operational WO','');
 result:=public.op_login(-910016,'wrong');
 IF NOT(result ? 'error') THEN RAISE EXCEPTION 'TEST: bad password accepted'; END IF;
 result:=public.op_login(-910016,'test-password-only'); tok:=result->>'token';
 IF tok IS NULL THEN RAISE EXCEPTION 'TEST: valid login failed %',result; END IF;
 bad:=false;
 BEGIN PERFORM public.op_api('invalid','contracts'); EXCEPTION WHEN invalid_authorization_specification THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: invalid session accepted'; END IF;
 result:=public.op_api(tok,'import_master',jsonb_build_object('projectCode','__OP_ROLLBACK_TEST__','projectName','Test','contractNo','CTR-TEST','contractType','BLANKET_ORDER','items',jsonb_build_array(
 jsonb_build_object('id','g','code','G','description','Group','rowKind','GROUP'),
 jsonb_build_object('id','i','parentId','g','code','1','description','Welder','rowKind','ITEM','unit','Hari','price',123.456789,'qty',20)
 ))); cid:=(result->>'contractId')::uuid; itemid:=(result->'itemIds'->>'i')::uuid;
 result:=public.op_api(tok,'save_wo',jsonb_build_object('contractId',cid,'number','WO-1','title','Test','items',jsonb_build_array(jsonb_build_object('sourceId',itemid,'qty',2,'price',1,'package','Package')))); wid:=(result->>'woId')::uuid;
 IF (SELECT amount FROM operational.wo_items WHERE wo_id=wid)<>246.913578 THEN RAISE EXCEPTION 'TEST: client controlled price or precision lost'; END IF;
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'approve_wo',jsonb_build_object('woId',wid)); EXCEPTION WHEN insufficient_privilege THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: PIC alone allowed approval'; END IF;
 UPDATE public."paswordTbl" SET "Author"='Operational Approval WO',pic='Unrelated' WHERE "Id"=-910016;
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'approve_wo',jsonb_build_object('woId',wid)); EXCEPTION WHEN insufficient_privilege THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: Author without PIC allowed page access'; END IF;
 UPDATE public."paswordTbl" SET pic='Operational WO' WHERE "Id"=-910016;
 PERFORM public.op_api(tok,'approve_wo',jsonb_build_object('woId',wid));
 IF (SELECT status FROM operational.work_orders WHERE id=wid)<>'APPROVED' THEN RAISE EXCEPTION 'TEST: approval failed'; END IF;
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'import_master','{}'); EXCEPTION WHEN insufficient_privilege THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: revoked PIC remained active'; END IF;
 PERFORM public.op_logout(tok);
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'contracts'); EXCEPTION WHEN invalid_authorization_specification THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: logout did not invalidate session'; END IF;
 IF has_table_privilege('anon','operational.sessions','SELECT') OR has_function_privilege('anon','operational.check_session(text,text[],text)','EXECUTE') THEN RAISE EXCEPTION 'TEST: private API accessible'; END IF;
END $$;
SELECT 'PASS: login, invalid session, import hierarchy, server price, PIC vs Author, revoked rights, approval, logout, private access' AS result;

ROLLBACK;


