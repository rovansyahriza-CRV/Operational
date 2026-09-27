BEGIN;
-- Dashboard: pilih project -> progress per WO (realisasi vs rencana) + kurva-S per WO.
--
-- Rumus (bobot nilai, standar laporan konstruksi):
--  - sub-item (sms_item_details ITEM dengan target qty>0): min(total progress / target, 1)
--  - item SMS: rata-rata sub-item di bawahnya (NULL kalau belum ada breakdown ber-target)
--  - WO: rata-rata item dibobot nilai item (sms_items.amount); kalau semua nilai 0, rata-rata biasa
--  - Rencana: linier dari work_orders.start_date (0%) ke end_date (100%)
-- Cuma revisi SMS terakhir per nomor urut yang dihitung, biar nilai item gak dobel.

CREATE OR REPLACE FUNCTION operational.dashboard_wo_items(p_wo uuid)
 RETURNS TABLE(sms_item_id uuid, code text, description text, amount numeric, weight numeric, progress numeric, leaf_count int)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 WITH docs AS (
  SELECT DISTINCT ON (d.sequence_no) d.id
  FROM operational.sms_documents d
  WHERE d.wo_id=p_wo
  ORDER BY d.sequence_no, nullif(regexp_replace(d.revision,'\D','','g'),'')::int DESC NULLS LAST, d.created_at DESC
 ), items AS (
  SELECT si.id, si.code_snapshot, si.description_snapshot, coalesce(si.amount,0) AS amount
  FROM operational.sms_items si WHERE si.sms_id IN (SELECT id FROM docs)
 ), leaves AS (
  SELECT d.sms_item_id, least(coalesce((SELECT sum(p.qty) FROM operational.sms_item_progress p WHERE p.detail_id=d.id),0)/d.qty,1) AS ratio
  FROM operational.sms_item_details d
  WHERE d.row_kind='ITEM' AND d.qty>0 AND d.sms_item_id IN (SELECT id FROM items)
 ), totals AS (SELECT sum(amount) AS total, count(*) AS n FROM items)
 SELECT i.id, i.code_snapshot, i.description_snapshot, i.amount,
  CASE WHEN t.total>0 THEN i.amount/t.total ELSE 1.0/nullif(t.n,0) END,
  (SELECT avg(l.ratio) FROM leaves l WHERE l.sms_item_id=i.id),
  (SELECT count(*)::int FROM leaves l WHERE l.sms_item_id=i.id)
 FROM items i CROSS JOIN totals t
$function$;
REVOKE ALL ON FUNCTION operational.dashboard_wo_items(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.op_dashboard(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; pid uuid; woid uuid; today date:=(now() AT TIME ZONE 'Asia/Makassar')::date;
BEGIN
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
