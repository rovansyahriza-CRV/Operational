BEGIN;
-- Project List (menu 01) nampilin WO turunan tiap project. op_dashboard dapat action 'wo_tree'
-- (semua WO dikelompokkan per project, satu panggilan) yang boleh dipanggil akun Operational WO
-- ATAU Operational Master Komersial -- Project List dibuka akun Master Komersial juga. Action lain
-- tetap khusus Operational WO. Sisa fungsi sama persis dengan 20260927030000_dashboard_progress.sql.
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
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'projectId', x->>'number') FROM (
   SELECT jsonb_build_object('projectId',c.project_id,'id',w.id,'number',w.number,'title',w.title,'status',w.status,
    'contractNumber',c.number,'startDate',w.start_date,'endDate',w.end_date,
    'value',(SELECT coalesce(sum(i.amount),0) FROM operational.dashboard_wo_items(w.id) i),
    'progress',(SELECT coalesce(sum(i.weight*coalesce(i.progress,0)),0) FROM operational.dashboard_wo_items(w.id) i)) AS x
   FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id) s),'[]');
 END IF;
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 IF p_action='projects' THEN
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'name',p.name,'client',p.client,'location',p.location,'status',p.status,
    'woCount',(SELECT count(*) FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id WHERE c.project_id=p.id))
   ORDER BY p.status='CLOSED', p.code) FROM operational.projects p),'[]');
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
   WHERE c.project_id=pid) s),'[]'));
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
