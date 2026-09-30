-- Register Alat: status Rental/Aset + pembagi diisi otomatis dari SMMS (PO detail -> RFQ detail -> Request),
-- admin tinggal konfirmasi (Simpan). Aturan saran:
--   RENTAL kalau satuan harga PO berbasis waktu (hari/minggu/bulan/jam), ATAU Request punya Duration + DurUnit.
--          (Kolom durasi di form request nanti dikunci cuma buat Tools/Heavy Equipment + Sewa.)
--     pembagi: satuan PO berbasis waktu -> jam per satuan itu (hari 8, minggu 48, bulan 200, jam 1);
--              satuan PO bukan waktu (unit/ea) -> harga PO dianggap total 1 periode sewa request
--              -> Duration x jam per DurUnit (contoh 1 unit crane, 1 Bulan -> 200 jam).
--   ASET   selain itu (dibeli putus). Pembagi = durasi penyusutan (bulan) -- wajib diisi admin, gak ada saran.
-- confirmed=false -> nilai masih saran; begitu admin Simpan, setelan admin yang dipakai.

DROP FUNCTION IF EXISTS operational.equipment_list();
CREATE FUNCTION operational.equipment_list()
 RETURNS TABLE(po_detail_id bigint, po_number text, po_status text, item_group text, description text, unit text,
  qty numeric, qty_received numeric, unit_price numeric, req_duration numeric, req_dur_unit text,
  ownership text, divisor numeric, confirmed boolean, suggested_ownership text, suggested_divisor numeric,
  hours_basis numeric, rate_per_hour numeric, notes text, updated_at timestamptz)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $fn$
 WITH base AS (
  SELECT pod."PODetailID" AS id, po."DocNumber" AS po_number, po."Status" AS po_status, pod."ItemGroup" AS item_group,
   pod."ItemDescription" AS description, pod."Unit" AS unit, pod."Qty" AS qty, coalesce(rc.qty,0) AS qty_received,
   pod."UnitPrice" AS unit_price, rq."Duration" AS req_duration, nullif(btrim(rq."DurUnit"),'') AS req_dur_unit,
   operational.equipment_default_divisor(pod."Unit") AS po_unit_hours,
   er.ownership AS saved_own, er.divisor AS saved_div, er.notes, er.updated_at
  FROM public."purchaseOrderDetail" pod
  JOIN public."purchaseOrder" po ON po."POID"=pod."POID"
  LEFT JOIN public."rfqDetail" rd ON rd."RFQDetailID"=pod."RFQDetailID"
  LEFT JOIN public.request rq ON rq."ID"=rd."RequestID"
  LEFT JOIN operational.equipment_register er ON er.po_detail_id=pod."PODetailID"
  LEFT JOIN LATERAL (SELECT sum(sr."QtyReceived") AS qty FROM public.delivery dl
   JOIN public."siteReceiving" sr ON sr."DeliveryID"=dl."DeliveryID" WHERE dl."PODetailID"=pod."PODetailID") rc ON true
  WHERE pod."ItemGroup" ~* '(tool|equip|alat|heavy)'
 ), sug AS (
  SELECT b.*,
   CASE WHEN b.po_unit_hours IS NOT NULL OR (b.req_duration>0 AND b.req_dur_unit IS NOT NULL) THEN 'RENTAL' ELSE 'ASSET' END AS s_own,
   CASE WHEN b.po_unit_hours IS NOT NULL THEN b.po_unit_hours
        WHEN b.req_duration>0 THEN b.req_duration*operational.equipment_default_divisor(b.req_dur_unit) END AS s_div
  FROM base b
 ), eff AS (
  SELECT s.*, s.saved_own IS NOT NULL AS is_confirmed,
   coalesce(s.saved_own,s.s_own) AS e_own,
   CASE WHEN s.saved_own IS NOT NULL THEN s.saved_div WHEN s.s_own='RENTAL' THEN s.s_div END AS e_div
  FROM sug s
 )
 SELECT e.id, e.po_number, e.po_status, e.item_group, e.description, e.unit, e.qty, e.qty_received, e.unit_price,
  e.req_duration, e.req_dur_unit, e.e_own, e.e_div, e.is_confirmed, e.s_own, CASE WHEN e.s_own='RENTAL' THEN e.s_div END,
  CASE e.e_own WHEN 'RENTAL' THEN e.e_div WHEN 'ASSET' THEN e.e_div*200 END,
  CASE WHEN e.e_div>0 AND e.unit_price IS NOT NULL THEN
   round(e.unit_price/CASE e.e_own WHEN 'RENTAL' THEN e.e_div WHEN 'ASSET' THEN e.e_div*200 END,2) END,
  e.notes, e.updated_at
 FROM eff e
$fn$;
REVOKE ALL ON FUNCTION operational.equipment_list() FROM PUBLIC;
