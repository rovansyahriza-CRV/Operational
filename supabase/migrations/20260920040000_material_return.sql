BEGIN;
-- Feedback: "ambil" material/consumables udah kepegang endUserReceiving (+woID). Yang belum
-- ada: "kembalikan ke gudang" (dipakai lebih dari 1 hari, sisa dibalikin). materialReturn
-- baru, referensi ke ConfirmationID (transaksi ambil yang mana yang lagi dikembalikan
-- sebagian/semua). Balance = QtyConfirmed - sum(QtyReturned).
--
-- Grant/RLS disamain persis kayak endUserReceiving (RLS off, full CRUD anon/authenticated) --
-- bukan standar baru, ngikutin postur keamanan yang sudah ada di tabel kakaknya biar konsisten
-- (bukan celah baru, keterbatasan yang sama sudah didiskusikan & diketahui).
CREATE TABLE public."materialReturn" (
 "ReturnID" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 "ConfirmationID" bigint NOT NULL REFERENCES public."endUserReceiving"("ConfirmationID"),
 "QtyReturned" numeric NOT NULL CHECK("QtyReturned">0),
 "ReturnedBy" bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 "ReturnDate" timestamptz NOT NULL DEFAULT now(),
 "Notes" text,
 "PhotoURL" text,
 "PhotoFileID" text,
 "created_at" timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON public."materialReturn"("ConfirmationID");
GRANT SELECT,INSERT,UPDATE,DELETE ON public."materialReturn" TO anon,authenticated;
GRANT USAGE ON SEQUENCE public."materialReturn_ReturnID_seq" TO anon,authenticated;

-- Publik (gak butuh session token, sama kayak op_list_work_orders_public) -- daftar transaksi
-- ambil yang masih ada sisa (balance>0) buat WO tertentu, dipakai UI "Kembalikan Barang".
CREATE OR REPLACE FUNCTION public.op_list_outstanding_material(p_wo_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'confirmationId',x."ConfirmationID",'itemDescription',x."ItemDescription",'unit',x."Unit",
   'qtyConfirmed',x."QtyConfirmed",'qtyReturned',x.qty_returned,'balance',x."QtyConfirmed"-x.qty_returned,
   'confirmedByName',x.confirmed_by_name,'confirmedAt',x."ConfirmedDate"
  ) ORDER BY x."ConfirmedDate"),'[]')
 FROM (
  SELECT eur."ConfirmationID",pod."ItemDescription",pod."Unit",eur."QtyConfirmed",eur."ConfirmedDate",
   kc."NamaPersonnel" AS confirmed_by_name,
   coalesce((SELECT sum(mr."QtyReturned") FROM public."materialReturn" mr WHERE mr."ConfirmationID"=eur."ConfirmationID"),0) AS qty_returned
  FROM public."endUserReceiving" eur
  JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
  JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID"
  JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
  LEFT JOIN public."karyawanTbl" kc ON kc."Id"=eur."ConfirmedBy"
  WHERE eur."woID"=p_wo_id
 ) x
 WHERE x."QtyConfirmed"-x.qty_returned>0;
$function$;
REVOKE ALL ON FUNCTION public.op_list_outstanding_material(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_list_outstanding_material(uuid) TO anon,authenticated;
COMMIT;
