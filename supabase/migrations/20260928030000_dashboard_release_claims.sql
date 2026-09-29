-- Dashboard WO belum ngitung progress yang masuk lewat wo_release_claims (klaim dari WO-Internal
-- ke WO-Released). Utk item yang belum ada breakdown/Detail treatment (leaf_count=0) -- kasus umum
-- di WO-Released yang isinya murni dari klaim -- progress-nya sekarang fallback ke qty diklaim / qty
-- item. Item yang punya breakdown tetap pakai cara lama (avg ratio leaf), gak kesentuh.

CREATE OR REPLACE FUNCTION operational.dashboard_wo_items(p_wo uuid)
 RETURNS TABLE(sms_item_id uuid, code text, description text, amount numeric, weight numeric, progress numeric, leaf_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 WITH docs AS (
  SELECT DISTINCT ON (d.sequence_no) d.id
  FROM operational.sms_documents d
  WHERE d.wo_id=p_wo
  ORDER BY d.sequence_no, nullif(regexp_replace(d.revision,'\D','','g'),'')::int DESC NULLS LAST, d.created_at DESC
 ), items AS (
  SELECT si.id, si.code_snapshot, si.description_snapshot, coalesce(si.amount,0) AS amount,
   si.commercial_item_id, si.qty
  FROM operational.sms_items si WHERE si.sms_id IN (SELECT id FROM docs)
 ), leaves AS (
  SELECT d.sms_item_id, least(coalesce((SELECT sum(p.qty) FROM operational.sms_item_progress p WHERE p.detail_id=d.id),0)/d.qty,1) AS ratio
  FROM operational.sms_item_details d
  WHERE d.row_kind='ITEM' AND d.qty>0 AND d.sms_item_id IN (SELECT id FROM items)
 ), claims AS (
  SELECT target_commercial_item_id, sum(qty) AS claimed_qty
  FROM operational.wo_release_claims
  WHERE target_wo_id=p_wo
  GROUP BY target_commercial_item_id
 ), totals AS (SELECT sum(amount) AS total, count(*) AS n FROM items)
 SELECT i.id, i.code_snapshot, i.description_snapshot, i.amount,
  CASE WHEN t.total>0 THEN i.amount/t.total ELSE 1.0/nullif(t.n,0) END,
  coalesce(
   (SELECT avg(l.ratio) FROM leaves l WHERE l.sms_item_id=i.id),
   CASE WHEN i.qty>0 THEN least(1, coalesce((SELECT cl.claimed_qty FROM claims cl WHERE cl.target_commercial_item_id=i.commercial_item_id),0)/i.qty) END
  ),
  (SELECT count(*)::int FROM leaves l WHERE l.sms_item_id=i.id)
 FROM items i CROSS JOIN totals t
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
   'series',coalesce((SELECT jsonb_agg(jsonb_build_object('date',s.report_date,'progress',s.cum) ORDER BY s.report_date) FROM (
    SELECT g.report_date, sum(g.contrib) OVER (ORDER BY g.report_date) AS cum FROM (
     SELECT p.report_date, sum(p.qty/d.qty/i.leaf_count*i.weight) AS contrib
     FROM operational.sms_item_progress p
     JOIN operational.sms_item_details d ON d.id=p.detail_id AND d.row_kind='ITEM' AND d.qty>0
     JOIN operational.dashboard_wo_items(woid) i ON i.sms_item_id=d.sms_item_id
     GROUP BY p.report_date
     UNION ALL
     SELECT c.claim_date, sum(c.qty/si.qty*i.weight) AS contrib
     FROM operational.wo_release_claims c
     JOIN operational.dashboard_wo_items(woid) i ON i.leaf_count=0
     JOIN operational.sms_items si ON si.id=i.sms_item_id AND si.commercial_item_id=c.target_commercial_item_id
     WHERE c.target_wo_id=woid AND si.qty>0
     GROUP BY c.claim_date) g) s),'[]'));
 END IF;
 RAISE EXCEPTION 'Aksi tidak dikenal';
END;
$function$;
