-- Halaman "Cost vs Progress": biaya resource yang kepakai per WO dibanding nilai progress (earned value)
-- dari akumulasi Daily Progress. Cuma WO Kerja (release_role=WORKING) -- di situ resource & progress dicatat;
-- WO Released cuma tujuan klaim, kalau ikut dihitung earned-nya dobel.
--
-- Resource diambil dari Daily Progress:
--   Manpower : jam check-in WO (wo_manpower_checkin) x biaya per jam dari Smartgate Fusion 4:
--              (Gaji Pokok + semua tunjangan + BPJS perusahaan) payroll bulan itu / 173 jam.
--              Belum ada payroll bulan itu -> payroll terakhir sebelumnya -> kontrak aktif (tanpa BPJS).
--   Material : qty pemakaian (material_usage_log) x Unit Price PO SMMS (material yang udah diterima di site).
--   Alat     : belum dihitung biayanya.
-- Earned value = nilai item SMS x progress item (sama persis kayak Dashboard).
-- Akses: PIC baru 'Operational Cost' (data biaya/gaji), op_login ikut nerima PIC ini.

CREATE OR REPLACE FUNCTION operational.mp_hourly_cost(p_emp bigint, p_date date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $fn$
 SELECT coalesce(
  (SELECT (coalesce(p."GajiPokok",0)+coalesce(p."TunjanganJabatan",0)+coalesce(p."TunjanganTransport",0)+coalesce(p."TunjanganMakan",0)
           +coalesce(p."TunjanganLain",0)+coalesce(p."TunjanganKehadiran",0)+coalesce(p."TotalBpjsPerusahaan",0))/173
   FROM public."payrollBulananTbl" p
   WHERE p."KaryawanId"=p_emp AND p."Tahun"*100+p."Bulan"<=extract(year FROM p_date)::int*100+extract(month FROM p_date)::int
   ORDER BY p."Tahun" DESC, p."Bulan" DESC LIMIT 1),
  (SELECT (coalesce(k."GajiPokok",0)+coalesce(k."TunjanganJabatan",0)+coalesce(k."TunjanganTransport",0)+coalesce(k."TunjanganMakan",0)
           +coalesce(k."TunjanganLain",0)+coalesce(k."TunjanganKehadiran",0))/173
   FROM public."kontrakKaryawanTbl" k
   WHERE k."KaryawanID"=p_emp AND k."TanggalMulai"<=p_date
   ORDER BY k."TanggalMulai" DESC LIMIT 1))
$fn$;
REVOKE ALL ON FUNCTION operational.mp_hourly_cost(bigint,date) FROM PUBLIC;

-- Satu baris per pemakaian resource di WO. rate/cost NULL = belum ada harga (gak ada payroll/kontrak/PO price).
CREATE OR REPLACE FUNCTION operational.cost_wo_lines(p_wo uuid)
 RETURNS TABLE(kind text, cost_date date, grp text, label text, unit text, qty numeric, rate numeric, cost numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $fn$
 SELECT 'MANPOWER', (m.check_in_at AT TIME ZONE 'Asia/Makassar')::date,
  coalesce(nullif(btrim(k."Kualifikasi"),''),'Tanpa kualifikasi'), m.employee_id::text, 'jam',
  h.hours, r.rate, round(h.hours*r.rate,0)
 FROM operational.wo_manpower_checkin m
 LEFT JOIN public."karyawanTbl" k ON k."Id"=m.employee_id
 CROSS JOIN LATERAL (SELECT round((EXTRACT(EPOCH FROM (coalesce(m.check_out_at,now())-m.check_in_at))/3600)::numeric,2) AS hours) h
 CROSS JOIN LATERAL (SELECT operational.mp_hourly_cost(m.employee_id,(m.check_in_at AT TIME ZONE 'Asia/Makassar')::date) AS rate) r
 WHERE m.wo_id=p_wo
 UNION ALL
 SELECT 'MATERIAL', mu.usage_date, coalesce(nullif(btrim(pod."ItemGroup"),''),'Material'), pod."ItemDescription", pod."Unit",
  mu.qty, pod."UnitPrice", round(mu.qty*pod."UnitPrice",0)
 FROM operational.material_usage_log mu
 JOIN public."endUserReceiving" eur ON eur."ConfirmationID"=mu.confirmation_id
 JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
 JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID"
 JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
 WHERE mu.wo_id=p_wo
$fn$;
REVOKE ALL ON FUNCTION operational.cost_wo_lines(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.op_cost(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; pid uuid; woid uuid;
BEGIN
 actor:=operational.check_session(p_token,ARRAY['operational cost']);
 IF p_action='projects' THEN
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'code',p.code,'name',p.name,'woCount',x.n) ORDER BY p.status='CLOSED', p.code)
   FROM operational.projects p
   CROSS JOIN LATERAL (SELECT count(*) AS n FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id
                       WHERE c.project_id=p.id AND w.release_role='WORKING') x
   WHERE x.n>0),'[]');
 ELSIF p_action='project' THEN
  pid:=nullif(p_data->>'projectId','')::uuid;
  IF pid IS NULL OR NOT EXISTS(SELECT 1 FROM operational.projects WHERE id=pid) THEN RAISE EXCEPTION 'Project tidak ditemukan'; END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.kind, s.number) FROM (
   SELECT w.id, w.number, w.title, w.wo_kind AS kind, w.status,
    (SELECT coalesce(sum(i.amount),0) FROM operational.dashboard_wo_items(w.id) i) AS value,
    (SELECT coalesce(sum(i.amount*coalesce(i.progress,0)),0) FROM operational.dashboard_wo_items(w.id) i) AS earned,
    coalesce(sum(l.qty) FILTER (WHERE l.kind='MANPOWER'),0) AS mp_hours,
    coalesce(sum(l.cost) FILTER (WHERE l.kind='MANPOWER'),0) AS mp_cost,
    coalesce(sum(l.qty) FILTER (WHERE l.kind='MANPOWER' AND l.cost IS NULL),0) AS mp_unpriced_hours,
    coalesce(sum(l.cost) FILTER (WHERE l.kind='MATERIAL'),0) AS material_cost,
    count(*) FILTER (WHERE l.kind='MATERIAL' AND l.cost IS NULL) AS material_unpriced
   FROM operational.work_orders w
   JOIN operational.contracts c ON c.id=w.contract_id
   LEFT JOIN LATERAL operational.cost_wo_lines(w.id) l ON true
   WHERE c.project_id=pid AND w.release_role='WORKING'
   GROUP BY w.id) s),'[]');
 ELSIF p_action='wo_detail' THEN
  woid:=nullif(p_data->>'woId','')::uuid;
  IF woid IS NULL OR NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=woid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  RETURN jsonb_build_object(
   'series',coalesce((SELECT jsonb_agg(jsonb_build_object('date',c.d,'earned',c.earned,'manpower',c.mp,'material',c.mat) ORDER BY c.d) FROM (
     SELECT g.d, sum(g.earned) OVER (ORDER BY g.d) AS earned, sum(g.mp) OVER (ORDER BY g.d) AS mp, sum(g.mat) OVER (ORDER BY g.d) AS mat
     FROM (
      SELECT u.d, sum(u.earned) AS earned, sum(u.mp) AS mp, sum(u.mat) AS mat FROM (
       SELECT p.report_date AS d, p.qty/sd.qty/i.leaf_count*i.amount AS earned, 0::numeric AS mp, 0::numeric AS mat
       FROM operational.sms_item_progress p
       JOIN operational.sms_item_details sd ON sd.id=p.detail_id AND sd.row_kind='ITEM' AND sd.qty>0
       JOIN operational.dashboard_wo_items(woid) i ON i.sms_item_id=sd.sms_item_id
       UNION ALL
       SELECT l.cost_date, 0, CASE WHEN l.kind='MANPOWER' THEN coalesce(l.cost,0) ELSE 0 END, CASE WHEN l.kind='MATERIAL' THEN coalesce(l.cost,0) ELSE 0 END
       FROM operational.cost_wo_lines(woid) l
      ) u GROUP BY u.d
     ) g
    ) c),'[]'),
   -- Manpower diringkas per Kualifikasi (bukan per orang) biar rate gaji individu gak kebaca.
   'manpower',coalesce((SELECT jsonb_agg(jsonb_build_object('group',x.grp,'people',x.people,'hours',x.hours,'cost',x.cost,'unpricedHours',x.unpriced) ORDER BY x.cost DESC NULLS LAST) FROM (
     SELECT l.grp, count(DISTINCT l.label) AS people, sum(l.qty) AS hours, sum(l.cost) AS cost, coalesce(sum(l.qty) FILTER (WHERE l.cost IS NULL),0) AS unpriced
     FROM operational.cost_wo_lines(woid) l WHERE l.kind='MANPOWER' GROUP BY l.grp) x),'[]'),
   'material',coalesce((SELECT jsonb_agg(jsonb_build_object('item',x.label,'unit',x.unit,'qty',x.qty,'unitPrice',x.price,'cost',x.cost) ORDER BY x.cost DESC NULLS LAST) FROM (
     SELECT l.label, l.unit, sum(l.qty) AS qty, max(l.rate) AS price, sum(l.cost) AS cost
     FROM operational.cost_wo_lines(woid) l WHERE l.kind='MATERIAL' GROUP BY l.label, l.unit) x),'[]'));
 END IF;
 RAISE EXCEPTION 'Aksi tidak dikenal';
END;
$function$;
REVOKE ALL ON FUNCTION public.op_cost(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_cost(text,text,jsonb) TO anon,authenticated;

-- op_login: PIC 'Operational Cost' saja juga boleh masuk.
DO $do$
DECLARE d text;
  a text := $q$'operational progress','operational resources']$q$;
  b text := $q$'operational progress','operational resources','operational cost']$q$;
BEGIN
 d := pg_get_functiondef('public.op_login(bigint,text)'::regprocedure);
 IF position(b IN d)>0 THEN RETURN; END IF;
 IF (length(d)-length(replace(d,a,'')))/length(a)<>1 THEN RAISE EXCEPTION 'op_login patch mismatch'; END IF;
 EXECUTE replace(d,a,b);
END
$do$;
