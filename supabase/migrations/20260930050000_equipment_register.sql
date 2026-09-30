-- Register Alat: semua baris PO SMMS grup Tools / Heavy Equipment ditarik otomatis (gak perlu sync --
-- daftar = PO line, setelan disimpan terpisah per PODetailID). Admin (PIC Operational Cost) nyetel:
--   RENTAL : pembagi = jam per satuan sewa PO. Rate/jam = Unit Price PO / pembagi
--            (contoh 800 rb per hari / 8 jam = 100 rb/jam). Default dari satuan PO: hari 8, minggu 48,
--            bulan 200, jam 1.
--   ASET   : pembagi = durasi penyusutan (bulan). Rate/jam = Unit Price PO / (bulan x 200 jam)
--            -- 200 jam/bulan = 25 hari kerja x 8 jam.
-- Rate per unit alat. Belum dipakai buat biaya WO -- skenario pembebanan (check-in, pindah WO, demob)
-- nyusul di migration berikutnya.

CREATE TABLE IF NOT EXISTS operational.equipment_register(
 po_detail_id bigint PRIMARY KEY,
 ownership text CHECK (ownership IN ('RENTAL','ASSET')),
 divisor numeric CHECK (divisor IS NULL OR divisor>0),
 notes text,
 updated_by bigint,
 updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE operational.equipment_register ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.equipment_register FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION operational.equipment_default_divisor(p_unit text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $fn$
 SELECT CASE
  WHEN p_unit ~* '(hari|day)' THEN 8
  WHEN p_unit ~* '(minggu|week)' THEN 48
  WHEN p_unit ~* '(bulan|month)' THEN 200
  WHEN p_unit ~* '(jam|hour)' THEN 1
 END
$fn$;

CREATE OR REPLACE FUNCTION operational.equipment_list()
 RETURNS TABLE(po_detail_id bigint, po_number text, po_status text, item_group text, description text, unit text,
  qty numeric, qty_received numeric, unit_price numeric, ownership text, divisor numeric, hours_basis numeric,
  rate_per_hour numeric, notes text, updated_at timestamptz)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $fn$
 SELECT pod."PODetailID", po."DocNumber", po."Status", pod."ItemGroup", pod."ItemDescription", pod."Unit",
  pod."Qty", coalesce(rc.qty,0), pod."UnitPrice", er.ownership, er.divisor,
  CASE er.ownership WHEN 'RENTAL' THEN er.divisor WHEN 'ASSET' THEN er.divisor*200 END,
  CASE WHEN er.divisor>0 AND pod."UnitPrice" IS NOT NULL THEN
   round(pod."UnitPrice"/CASE er.ownership WHEN 'RENTAL' THEN er.divisor WHEN 'ASSET' THEN er.divisor*200 END,2) END,
  er.notes, er.updated_at
 FROM public."purchaseOrderDetail" pod
 JOIN public."purchaseOrder" po ON po."POID"=pod."POID"
 LEFT JOIN operational.equipment_register er ON er.po_detail_id=pod."PODetailID"
 LEFT JOIN LATERAL (SELECT sum(sr."QtyReceived") AS qty FROM public.delivery dl
  JOIN public."siteReceiving" sr ON sr."DeliveryID"=dl."DeliveryID" WHERE dl."PODetailID"=pod."PODetailID") rc ON true
 WHERE pod."ItemGroup" ~* '(tool|equip|alat|heavy)'
$fn$;
REVOKE ALL ON FUNCTION operational.equipment_list() FROM PUBLIC;

-- op_cost + aksi equipment_list / equipment_save (sisanya sama persis kayak 20260930030000).
CREATE OR REPLACE FUNCTION public.op_cost(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; pid uuid; woid uuid; podid bigint; own text; div numeric;
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
   'manpower',coalesce((SELECT jsonb_agg(jsonb_build_object('group',x.grp,'people',x.people,'hours',x.hours,'cost',x.cost,'unpricedHours',x.unpriced) ORDER BY x.cost DESC NULLS LAST) FROM (
     SELECT l.grp, count(DISTINCT l.label) AS people, sum(l.qty) AS hours, sum(l.cost) AS cost, coalesce(sum(l.qty) FILTER (WHERE l.cost IS NULL),0) AS unpriced
     FROM operational.cost_wo_lines(woid) l WHERE l.kind='MANPOWER' GROUP BY l.grp) x),'[]'),
   'material',coalesce((SELECT jsonb_agg(jsonb_build_object('item',x.label,'unit',x.unit,'qty',x.qty,'unitPrice',x.price,'cost',x.cost) ORDER BY x.cost DESC NULLS LAST) FROM (
     SELECT l.label, l.unit, sum(l.qty) AS qty, max(l.rate) AS price, sum(l.cost) AS cost
     FROM operational.cost_wo_lines(woid) l WHERE l.kind='MATERIAL' GROUP BY l.label, l.unit) x),'[]'));
 ELSIF p_action='equipment_list' THEN
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(e)||jsonb_build_object('default_divisor',operational.equipment_default_divisor(e.unit))
    ORDER BY e.item_group, e.description) FROM operational.equipment_list() e),'[]');
 ELSIF p_action='equipment_save' THEN
  podid:=nullif(p_data->>'poDetailId','')::bigint;
  IF podid IS NULL OR NOT EXISTS(SELECT 1 FROM operational.equipment_list() e WHERE e.po_detail_id=podid) THEN RAISE EXCEPTION 'Item alat tidak ditemukan'; END IF;
  own:=nullif(p_data->>'ownership','');
  IF own IS NOT NULL AND own NOT IN ('RENTAL','ASSET') THEN RAISE EXCEPTION 'Status kepemilikan tidak valid'; END IF;
  div:=nullif(p_data->>'divisor','')::numeric;
  IF div IS NOT NULL AND div<=0 THEN RAISE EXCEPTION 'Pembagi harus lebih dari 0'; END IF;
  IF own IS NULL THEN div:=NULL; END IF;
  INSERT INTO operational.equipment_register(po_detail_id,ownership,divisor,notes,updated_by,updated_at)
  VALUES(podid,own,div,nullif(btrim(p_data->>'notes'),''),actor,now())
  ON CONFLICT(po_detail_id) DO UPDATE SET ownership=excluded.ownership,divisor=excluded.divisor,notes=excluded.notes,updated_by=excluded.updated_by,updated_at=now();
  RETURN (SELECT to_jsonb(e) FROM operational.equipment_list() e WHERE e.po_detail_id=podid);
 END IF;
 RAISE EXCEPTION 'Aksi tidak dikenal';
END;
$function$;
