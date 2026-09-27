BEGIN;
-- Project & WO NON-PROJECT (internal / overhead): Divisi = Project (kode 9xx), Departemen = WO
-- (WO-<kode divisi>-<singkatan dept>). WO internal permanen; rekap per waktu diambil dari
-- tanggal transaksi (request/pemakaian/check-in), bukan WO per bulan. Kegiatan khusus nanti
-- bisa dapat WO tambahan WO-9xx-XXX-01 dst.
-- Nama Divisi/Departemen disalin persis dari karyawanTbl biar request bisa default ke WO
-- departemen pemohon. Civil/Mechanical Construction & Project sengaja gak dapat WO internal:
-- biayanya selalu ke WO project client.

ALTER TABLE operational.projects
 ADD COLUMN project_type text NOT NULL DEFAULT 'CLIENT' CHECK(project_type IN ('CLIENT','INTERNAL')),
 ADD COLUMN divisi text NOT NULL DEFAULT '';
ALTER TABLE operational.work_orders ADD COLUMN departemen text NOT NULL DEFAULT '';
-- Project internal gak punya kontrak client, tapi WO wajib nempel ke contracts -> 1 kontrak
-- administratif per project internal dengan tipe INTERNAL.
ALTER TABLE operational.contracts DROP CONSTRAINT contracts_contract_type_check;
ALTER TABLE operational.contracts ADD CONSTRAINT contracts_contract_type_check CHECK(contract_type IN ('LUMPSUM','BLANKET_ORDER','INTERNAL'));

WITH src(code,name,divisi) AS (VALUES
 ('901','Direksi (Non-Project)','Direksi'),
 ('902','Business Development (Non-Project)','Bussiness Development'),
 ('903','Human Resources (Non-Project)','Human Resources'),
 ('904','Supply Chains (Non-Project)','Supply Chains'),
 ('905','Operation Overhead (Non-Project)','Operation'))
INSERT INTO operational.projects(code,name,client,location,contract_number,status,project_type,divisi)
SELECT code,name,'Internal BIMA','','INT-'||code,'ACTIVE','INTERNAL',divisi FROM src
ON CONFLICT (code) DO NOTHING;

INSERT INTO operational.contracts(project_id,number,contract_type,currency,revision)
SELECT p.id,'INT-'||p.code,'INTERNAL','IDR','01' FROM operational.projects p
WHERE p.project_type='INTERNAL' AND p.code IN ('901','902','903','904','905')
ON CONFLICT (project_id,number,revision) DO NOTHING;

WITH src(pcode,number,departemen) AS (VALUES
 ('901','WO-901-BOD','Board of Directors'),
 ('902','WO-902-TND','Tender & Proposal (Bidding)'),
 ('903','WO-903-HRA','HR Operations / HR Admin'),
 ('904','WO-904-PRC','Procurement / Purchasing'),
 ('904','WO-904-LOG','Logistics & Distribution'),
 ('904','WO-904-WHS','Warehousing & Inventory Control'),
 ('905','WO-905-HSE','HSE'),
 ('905','WO-905-PCT','Project Control'),
 ('905','WO-905-QAC','QAC'),
 ('905','WO-905-DPU','Direct Project (Umum)'))
INSERT INTO operational.work_orders(contract_id,number,title,status,revision,departemen)
SELECT c.id,s.number,s.departemen||' — Overhead Departemen','APPROVED','01',s.departemen
FROM src s JOIN operational.projects p ON p.code=s.pcode AND p.project_type='INTERNAL'
JOIN operational.contracts c ON c.project_id=p.id AND c.number='INT-'||p.code AND c.revision='01'
ON CONFLICT (contract_id,number,revision) DO NOTHING;

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
    'contractNumber',c.number,'startDate',w.start_date,'endDate',w.end_date,'departemen',w.departemen,
    'value',(SELECT coalesce(sum(i.amount),0) FROM operational.dashboard_wo_items(w.id) i),
    'progress',(SELECT coalesce(sum(i.weight*coalesce(i.progress,0)),0) FROM operational.dashboard_wo_items(w.id) i)) AS x
   FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id) s),'[]'));
 END IF;
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 IF p_action='projects' THEN
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'name',p.name,'client',p.client,'location',p.location,'status',p.status,
    'woCount',(SELECT count(*) FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id WHERE c.project_id=p.id))
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
