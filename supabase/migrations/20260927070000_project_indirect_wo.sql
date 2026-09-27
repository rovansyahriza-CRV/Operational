BEGIN;
-- Jenis WO sebagai tempat biaya:
--  DIRECT   = WO scope client (WO-001 dst) -- punya nilai komersial & progress
--  INDIRECT = biaya menjalankan project yang gak nempel ke 1 WO scope (Project Management Team,
--             site office, mob-demob) -> WO-<kode>-IND, satu per project client
--  OVERHEAD = Non-Project per divisi (WO-901-BOD ... WO-905-xxx)
-- Margin project = nilai kontrak - (Direct + Indirect). Rekap organisasi: project client
-- bermuara ke Divisi Operation (projects.divisi), Non-Project ke divisinya masing-masing.
ALTER TABLE operational.work_orders ADD COLUMN wo_kind text NOT NULL DEFAULT 'DIRECT' CHECK(wo_kind IN ('DIRECT','INDIRECT','OVERHEAD'));
UPDATE operational.work_orders w SET wo_kind='OVERHEAD'
FROM operational.contracts c JOIN operational.projects p ON p.id=c.project_id
WHERE c.id=w.contract_id AND p.project_type='INTERNAL';
UPDATE operational.projects SET divisi='Operation' WHERE project_type='CLIENT' AND btrim(divisi)='';

-- WO Indirect nempel ke kontrak administratif IND-<kode> (tipe INTERNAL), bukan ke kontrak client,
-- karena biaya indirect milik project (project bisa punya >1 kontrak/revisi).
CREATE OR REPLACE FUNCTION operational.ensure_project_indirect_wo(p_project uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE p operational.projects; cid uuid; wid uuid;
BEGIN
 SELECT * INTO p FROM operational.projects WHERE id=p_project;
 IF p.id IS NULL OR p.project_type<>'CLIENT' THEN RETURN NULL; END IF;
 INSERT INTO operational.contracts(project_id,number,contract_type,currency,revision)
 VALUES(p.id,'IND-'||p.code,'INTERNAL','IDR','01')
 ON CONFLICT (project_id,number,revision) DO NOTHING;
 SELECT id INTO cid FROM operational.contracts WHERE project_id=p.id AND number='IND-'||p.code AND revision='01';
 INSERT INTO operational.work_orders(contract_id,number,title,status,revision,wo_kind)
 VALUES(cid,'WO-'||p.code||'-IND','Project Indirect / PMT — '||p.code,'APPROVED','01','INDIRECT')
 ON CONFLICT (contract_id,number,revision) DO NOTHING;
 SELECT id INTO wid FROM operational.work_orders WHERE contract_id=cid AND number='WO-'||p.code||'-IND' AND revision='01';
 RETURN wid;
END;
$function$;
REVOKE ALL ON FUNCTION operational.ensure_project_indirect_wo(uuid) FROM PUBLIC,anon,authenticated;

-- Project client baru: default divisi Operation + otomatis dapat WO Indirect.
CREATE OR REPLACE FUNCTION operational.project_client_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF TG_OP='INSERT' AND NEW.project_type='CLIENT' AND btrim(NEW.divisi)='' THEN NEW.divisi:='Operation'; END IF;
 RETURN NEW;
END;
$function$;
CREATE OR REPLACE FUNCTION operational.project_client_indirect_wo()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 PERFORM operational.ensure_project_indirect_wo(NEW.id);
 RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_project_client_defaults ON operational.projects;
CREATE TRIGGER trg_project_client_defaults BEFORE INSERT ON operational.projects FOR EACH ROW EXECUTE FUNCTION operational.project_client_defaults();
DROP TRIGGER IF EXISTS trg_project_client_indirect_wo ON operational.projects;
CREATE TRIGGER trg_project_client_indirect_wo AFTER INSERT ON operational.projects FOR EACH ROW EXECUTE FUNCTION operational.project_client_indirect_wo();

SELECT operational.ensure_project_indirect_wo(id) FROM operational.projects WHERE project_type='CLIENT';

-- RPC publik SMMS: tambah woKind (field lain tetap).
CREATE OR REPLACE FUNCTION public.op_list_work_orders_public()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',w.id,'number',w.number,'title',w.title,
   'projectId',p.id,'projectName',p.name,
   'projectCode',p.code,'projectType',p.project_type,'status',w.status,'departemen',w.departemen,
   'woKind',w.wo_kind
 ) ORDER BY p.name,w.number),'[]')
 FROM operational.work_orders w
 JOIN operational.contracts c ON c.id=w.contract_id
 JOIN operational.projects p ON p.id=c.project_id;
$function$;

CREATE OR REPLACE FUNCTION public.op_dashboard(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; pid uuid; woid uuid; today date:=(now() AT TIME ZONE 'Asia/Makassar')::date;
BEGIN
 IF p_action='wo_tree' THEN
  actor:=operational.check_session(p_token,ARRAY['operational wo','operational master komersial']);
  -- Bentuk baru: {projects:[{id,projectType,divisi}], wos:[...]} -- list_projects (op_api) gak
  -- ngirim project_type, jadi Project List ambil penanda internal dari sini.
  RETURN jsonb_build_object(
   'projects',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'projectType',p.project_type,'divisi',p.divisi)) FROM operational.projects p),'[]'),
   'wos',coalesce((SELECT jsonb_agg(x ORDER BY x->>'projectId', x->>'number') FROM (
   SELECT jsonb_build_object('projectId',c.project_id,'id',w.id,'number',w.number,'title',w.title,'status',w.status,
    'contractNumber',c.number,'startDate',w.start_date,'endDate',w.end_date,'departemen',w.departemen,'woKind',w.wo_kind,
    'value',(SELECT coalesce(sum(i.amount),0) FROM operational.dashboard_wo_items(w.id) i),
    'progress',(SELECT coalesce(sum(i.weight*coalesce(i.progress,0)),0) FROM operational.dashboard_wo_items(w.id) i)) AS x
   FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id) s),'[]'));
 END IF;
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 IF p_action='projects' THEN
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'name',p.name,'client',p.client,'location',p.location,'status',p.status,
    'woCount',(SELECT count(*) FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id WHERE c.project_id=p.id AND w.wo_kind='DIRECT'))
   ORDER BY p.status='CLOSED', p.code) FROM operational.projects p WHERE p.project_type='CLIENT'),'[]');
 ELSIF p_action='project' THEN
  pid:=nullif(p_data->>'projectId','')::uuid;
  IF pid IS NULL OR NOT EXISTS(SELECT 1 FROM operational.projects WHERE id=pid) THEN RAISE EXCEPTION 'Project tidak ditemukan'; END IF;
  RETURN jsonb_build_object('today',today,'wos',coalesce((SELECT jsonb_agg(x ORDER BY x->>'number') FROM (
   SELECT jsonb_build_object('id',w.id,'number',w.number,'title',w.title,'status',w.status,'contractNumber',c.number,
    'startDate',w.start_date,'endDate',w.end_date,
    'value',(SELECT coalesce(sum(i.amount),0) FROM operational.dashboard_wo_items(w.id) i),
    'progress',(SELECT coalesce(sum(i.weight*coalesce(i.progress,0)),0) FROM operational.dashboard_wo_items(w.id) i),
    'itemCount',(SELECT count(*) FROM operational.dashboard_wo_items(w.id) i),
    'itemsNoBreakdown',(SELECT count(*) FROM operational.dashboard_wo_items(w.id) i WHERE i.leaf_count=0),
    'lastProgressDate',(SELECT max(p.report_date) FROM operational.sms_item_progress p JOIN operational.sms_item_details d ON d.id=p.detail_id JOIN operational.sms_items si ON si.id=d.sms_item_id WHERE si.wo_id=w.id),
    'teamToday',(SELECT count(DISTINCT m.employee_id) FROM operational.wo_manpower_checkin m WHERE m.wo_id=w.id AND (m.check_in_at AT TIME ZONE 'Asia/Makassar')::date=today)
   ) AS x
   FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id
   WHERE c.project_id=pid AND w.wo_kind='DIRECT') s),'[]'));
 ELSIF p_action='wo_detail' THEN
  woid:=nullif(p_data->>'woId','')::uuid;
  IF woid IS NULL OR NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=woid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  RETURN jsonb_build_object(
   'items',coalesce((SELECT jsonb_agg(jsonb_build_object('code',i.code,'description',i.description,'amount',i.amount,'weight',i.weight,'progress',i.progress,'leafCount',i.leaf_count) ORDER BY i.code)
    FROM operational.dashboard_wo_items(woid) i),'[]'),
   -- Realisasi kumulatif per tanggal: tiap entri progress nyumbang (qty/target)/jumlah sub-item x bobot item.
   'series',coalesce((SELECT jsonb_agg(jsonb_build_object('date',s.report_date,'progress',s.cum) ORDER BY s.report_date) FROM (
    SELECT g.report_date, sum(g.contrib) OVER (ORDER BY g.report_date) AS cum FROM (
     SELECT p.report_date, sum(p.qty/d.qty/i.leaf_count*i.weight) AS contrib
     FROM operational.sms_item_progress p
     JOIN operational.sms_item_details d ON d.id=p.detail_id AND d.row_kind='ITEM' AND d.qty>0
     JOIN operational.dashboard_wo_items(woid) i ON i.sms_item_id=d.sms_item_id
     GROUP BY p.report_date) g) s),'[]'));
 END IF;
 RAISE EXCEPTION 'Aksi tidak dikenal';
END;
$function$;
REVOKE ALL ON FUNCTION public.op_dashboard(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_dashboard(text,text,jsonb) TO anon,authenticated;
COMMIT;
