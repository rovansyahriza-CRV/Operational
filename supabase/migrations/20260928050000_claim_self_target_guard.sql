-- WO sumber sering ikut nongol di dropdown "WO Released tujuan" (karena dia sendiri lolos filter
-- DIRECT/non-internal), jadi gampang ketuker sama WO Released yang beneran. Kalau keklaim balik ke
-- WO sumbernya sendiri, klaimnya gak ngefek ke Dashboard manapun tapi tetap makan jatah "sisa progress
-- yang bisa diklaim". Tambah guard: WO tujuan gak boleh sama dengan WO sumber si SMS Item.

CREATE OR REPLACE FUNCTION public.op_daily_report(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; n integer:=0; aid uuid; did uuid; sid uuid; pid uuid; phid uuid; wid uuid; woid uuid; pjid uuid; cid bigint; uid uuid; balance numeric; ckid uuid; detail operational.sms_item_details; parent operational.sms_item_details; hdr record;
r jsonb; itemid uuid; rcid uuid; first_claim_id uuid; start_d date; end_d date; source_wo_id uuid;
BEGIN
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 IF p_action='list_activities' THEN
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.parent_id NULLS FIRST,a.name) FROM operational.activity_library a),'[]');
 ELSIF p_action='add_activity' THEN
  IF nullif(btrim(p_data->>'name'),'') IS NULL THEN RAISE EXCEPTION 'Nama wajib diisi'; END IF;
  IF nullif(p_data->>'parentId','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM operational.activity_library WHERE id=(p_data->>'parentId')::uuid) THEN
   RAISE EXCEPTION 'Induk aktivitas tidak ditemukan';
  END IF;
  IF nullif(p_data->>'parentId','') IS NULL THEN
   INSERT INTO operational.activity_library(name,created_by) VALUES(btrim(p_data->>'name'),actor)
   ON CONFLICT (name) WHERE parent_id IS NULL DO NOTHING
   RETURNING id INTO aid;
  ELSE
   INSERT INTO operational.activity_library(parent_id,name,created_by) VALUES((p_data->>'parentId')::uuid,btrim(p_data->>'name'),actor)
   ON CONFLICT ON CONSTRAINT activity_library_parent_name_key DO NOTHING
   RETURNING id INTO aid;
  END IF;
  IF aid IS NULL THEN
   SELECT id INTO aid FROM operational.activity_library WHERE name=btrim(p_data->>'name') AND parent_id IS NOT DISTINCT FROM nullif(p_data->>'parentId','')::uuid;
  END IF;
  RETURN jsonb_build_object('id',aid);
 ELSIF p_action='add_detail_row' THEN
  sid:=(p_data->>'smsItemId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.sms_items WHERE id=sid) THEN RAISE EXCEPTION 'Item SMS tidak ditemukan'; END IF;
  IF p_data->>'rowKind' NOT IN ('GROUP','ITEM') THEN RAISE EXCEPTION 'Jenis baris tidak valid'; END IF;
  IF nullif(btrim(p_data->>'description'),'') IS NULL THEN RAISE EXCEPTION 'Uraian wajib diisi'; END IF;
  IF nullif(p_data->>'parentId','') IS NOT NULL THEN
   SELECT * INTO parent FROM operational.sms_item_details WHERE id=(p_data->>'parentId')::uuid AND sms_item_id=sid AND row_kind='GROUP';
   IF parent.id IS NULL THEN RAISE EXCEPTION 'Induk harus Group pada item SMS yang sama'; END IF;
  END IF;
  IF p_data->>'rowKind'='ITEM' THEN
   IF nullif(btrim(p_data->>'unit'),'') IS NULL THEN RAISE EXCEPTION 'Satuan wajib diisi'; END IF;
  END IF;
  SELECT coalesce(max(sort_order),0)+1 INTO n FROM operational.sms_item_details WHERE sms_item_id=sid;
  INSERT INTO operational.sms_item_details(sms_item_id,parent_id,row_kind,activity_id,description,unit,qty,sort_order)
  VALUES(sid,nullif(p_data->>'parentId','')::uuid,p_data->>'rowKind',nullif(p_data->>'activityId','')::uuid,btrim(p_data->>'description'),
   CASE WHEN p_data->>'rowKind'='ITEM' THEN btrim(p_data->>'unit') END,
   CASE WHEN p_data->>'rowKind'='ITEM' THEN nullif(p_data->>'qty','')::numeric END,
   n)
  RETURNING id INTO did;
  RETURN jsonb_build_object('id',did);
 ELSIF p_action='delete_detail_row' THEN
  did:=(p_data->>'detailId')::uuid;
  SELECT * INTO detail FROM operational.sms_item_details WHERE id=did;
  IF detail.id IS NULL THEN RAISE EXCEPTION 'Baris tidak ditemukan'; END IF;
  IF EXISTS(SELECT 1 FROM operational.sms_item_details WHERE parent_id=did) THEN RAISE EXCEPTION 'Hapus dulu sub-item di bawahnya sebelum menghapus Group ini'; END IF;
  IF EXISTS(SELECT 1 FROM operational.sms_item_progress WHERE detail_id=did) THEN RAISE EXCEPTION 'Sub-item ini sudah punya progress tercatat, gak bisa dihapus'; END IF;
  DELETE FROM operational.sms_item_details WHERE id=did;
  RETURN jsonb_build_object('deleted',true);
 ELSIF p_action='read_sms_item_details' THEN
  sid:=(p_data->>'smsItemId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.sort_order) FROM operational.sms_item_details d WHERE d.sms_item_id=sid),'[]');
 ELSIF p_action='list_sms_details' THEN
  sid:=(p_data->>'smsId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.item_code,x.sort_order) FROM (
   SELECT d.*, si.code_snapshot AS item_code, si.description_snapshot AS item_description,
    (SELECT coalesce(sum(p.qty),0) FROM operational.sms_item_progress p WHERE p.detail_id=d.id) AS progress_total
   FROM operational.sms_item_details d
   JOIN operational.sms_items si ON si.id=d.sms_item_id
   WHERE si.sms_id=sid) x
  ),'[]');
 ELSIF p_action='save_progress' THEN
  did:=(p_data->>'detailId')::uuid;
  SELECT * INTO detail FROM operational.sms_item_details WHERE id=did;
  IF detail.id IS NULL THEN RAISE EXCEPTION 'Sub-item tidak ditemukan'; END IF;
  IF detail.row_kind<>'ITEM' THEN RAISE EXCEPTION 'Progress cuma bisa diisi di leaf item, bukan Group'; END IF;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  IF nullif(p_data->>'qty','') IS NULL OR (p_data->>'qty')::numeric<=0 THEN RAISE EXCEPTION 'Qty tidak valid'; END IF;
  IF detail.qty IS NOT NULL AND (SELECT coalesce(sum(qty),0) FROM operational.sms_item_progress WHERE detail_id=did)+(p_data->>'qty')::numeric > detail.qty THEN
   RAISE EXCEPTION 'Qty progress melebihi total qty sub-item ini';
  END IF;
  INSERT INTO operational.sms_item_progress(detail_id,report_date,qty,notes,recorded_by)
  VALUES(did,(p_data->>'reportDate')::date,(p_data->>'qty')::numeric,coalesce(p_data->>'notes',''),actor)
  RETURNING id INTO pid;
  RETURN jsonb_build_object('id',pid);
 ELSIF p_action='save_item_weather' THEN
  sid:=(p_data->>'smsItemId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.sms_items WHERE id=sid) THEN RAISE EXCEPTION 'Item SMS tidak ditemukan'; END IF;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  IF p_data->>'shift' NOT IN ('PAGI','SIANG','LEMBUR') THEN RAISE EXCEPTION 'Shift tidak valid'; END IF;
  IF p_data->>'weather' NOT IN ('CERAH','BERAWAN','HUJAN_RINGAN','HUJAN_LEBAT') THEN RAISE EXCEPTION 'Kondisi cuaca tidak valid'; END IF;
  INSERT INTO operational.sms_item_weather(sms_item_id,report_date,shift,weather,temperature_c,effective_hours,recorded_by)
  VALUES(sid,(p_data->>'reportDate')::date,p_data->>'shift',p_data->>'weather',nullif(p_data->>'temperatureC','')::numeric,nullif(p_data->>'effectiveHours','')::numeric,actor)
  ON CONFLICT (sms_item_id,report_date,shift) DO UPDATE SET weather=excluded.weather,temperature_c=excluded.temperature_c,effective_hours=excluded.effective_hours,recorded_by=excluded.recorded_by
  RETURNING id INTO wid;
  RETURN jsonb_build_object('id',wid);
 ELSIF p_action='list_item_weather' THEN
  sid:=(p_data->>'smsId')::uuid;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('smsItemId',w.sms_item_id,'shift',w.shift,'weather',w.weather,'temperatureC',w.temperature_c,'effectiveHours',w.effective_hours)) FROM operational.sms_item_weather w
   JOIN operational.sms_items si ON si.id=w.sms_item_id
   WHERE si.sms_id=sid AND w.report_date=(p_data->>'reportDate')::date),'[]');
 ELSIF p_action='add_progress_photo' THEN
  pid:=(p_data->>'progressId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.sms_item_progress WHERE id=pid) THEN RAISE EXCEPTION 'Progress tidak ditemukan'; END IF;
  IF nullif(p_data->>'photoData','') IS NULL THEN RAISE EXCEPTION 'Foto kosong'; END IF;
  IF length(p_data->>'photoData')>2800000 THEN RAISE EXCEPTION 'Ukuran foto terlalu besar'; END IF;
  IF (SELECT count(*) FROM operational.sms_item_progress_photos WHERE progress_id=pid)>=3 THEN RAISE EXCEPTION 'Maksimal 3 foto per entri progress'; END IF;
  INSERT INTO operational.sms_item_progress_photos(progress_id,photo_data,mime_type,uploaded_by)
  VALUES(pid,p_data->>'photoData',coalesce(nullif(p_data->>'mimeType',''),'image/jpeg'),actor)
  RETURNING id INTO phid;
  RETURN jsonb_build_object('id',phid);
 ELSIF p_action='delete_progress_photo' THEN
  phid:=(p_data->>'photoId')::uuid;
  DELETE FROM operational.sms_item_progress_photos WHERE id=phid AND uploaded_by=actor;
  IF NOT FOUND THEN RAISE EXCEPTION 'Foto tidak ditemukan atau bukan milik kamu'; END IF;
  RETURN jsonb_build_object('deleted',true);
 ELSIF p_action='list_progress' THEN
  did:=(p_data->>'detailId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.report_date DESC) FROM (
   SELECT pr.*, k."NamaPersonnel" AS recorded_by_name FROM operational.sms_item_progress pr LEFT JOIN public."karyawanTbl" k ON k."Id"=pr.recorded_by WHERE pr.detail_id=did) x),'[]');
 ELSIF p_action='get_report_header' THEN
  woid:=(p_data->>'woId')::uuid;
  SELECT w.number AS wo_number,w.title AS wo_title,w.start_date AS wo_start_date,w.end_date AS wo_end_date,
   p.id AS project_id,p.name AS project_name,p.client,p.location,
   c.number AS contract_number,p.supervisor_consultant,p.contractor_name
  INTO hdr
  FROM operational.work_orders w
  JOIN operational.contracts c ON c.id=w.contract_id
  JOIN operational.projects p ON p.id=c.project_id
  WHERE w.id=woid;
  IF hdr.wo_number IS NULL THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  RETURN jsonb_build_object('woNumber',hdr.wo_number,'woTitle',hdr.wo_title,'projectId',hdr.project_id,'projectName',hdr.project_name,
   'client',hdr.client,'location',hdr.location,'contractNumber',hdr.contract_number,'startDate',hdr.wo_start_date,
   'endDate',hdr.wo_end_date,'supervisorConsultant',hdr.supervisor_consultant,'contractorName',hdr.contractor_name);
 ELSIF p_action='save_report_header' THEN
  woid:=(p_data->>'woId')::uuid;
  SELECT c.project_id INTO pjid FROM operational.work_orders w JOIN operational.contracts c ON c.id=w.contract_id WHERE w.id=woid;
  IF pjid IS NULL THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  IF (nullif(p_data->>'startDate','') IS NULL) <> (nullif(p_data->>'endDate','') IS NULL) THEN
   RAISE EXCEPTION 'Isi Mulai dan Akhir WO dua-duanya, atau kosongkan dua-duanya';
  END IF;
  IF nullif(p_data->>'startDate','') IS NOT NULL AND (p_data->>'endDate')::date<(p_data->>'startDate')::date THEN
   RAISE EXCEPTION 'Akhir WO tidak boleh lebih awal dari Mulai WO';
  END IF;
  UPDATE operational.projects SET
   location=coalesce(p_data->>'location',location)
  WHERE id=pjid;
  UPDATE operational.work_orders SET
   start_date=nullif(p_data->>'startDate','')::date,
   end_date=nullif(p_data->>'endDate','')::date
  WHERE id=woid;
  RETURN jsonb_build_object('saved',true);
 ELSIF p_action='list_material_received' THEN
  woid:=(p_data->>'woId')::uuid;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
    'confirmationId',eur."ConfirmationID",'itemDescription',pod."ItemDescription",'unit',pod."Unit",
    'qty',eur."QtyConfirmed",'notes',eur."Notes",'confirmedAt',eur."ConfirmedDate",
    'issuedByName',ki."NamaPersonnel",'confirmedByName',kc."NamaPersonnel",
    'category',CASE WHEN pod."ItemGroup" ILIKE ANY(ARRAY['Tools','Heavy Equipment','HeavyEquipment']) THEN 'EQUIPMENT' ELSE 'MATERIAL' END
   ) ORDER BY eur."ConfirmedDate")
   FROM public."endUserReceiving" eur
   JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
   JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID"
   JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
   LEFT JOIN public."karyawanTbl" ki ON ki."Id"=eur."IssuedBy"
   LEFT JOIN public."karyawanTbl" kc ON kc."Id"=eur."ConfirmedBy"
   WHERE eur."woID"=woid AND eur."ConfirmedDate"::date=(p_data->>'reportDate')::date
  ),'[]');
 ELSIF p_action='list_material_balance' THEN
  woid:=(p_data->>'woId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
    'confirmationId',x."ConfirmationID",'itemDescription',x."ItemDescription",'unit',x."Unit",
    'qtyConfirmed',x."QtyConfirmed",'qtyUsed',x.qty_used,'balance',x.balance,'category',x.category
   ) ORDER BY x."ItemDescription")
   FROM (
    SELECT eur."ConfirmationID",pod."ItemDescription",pod."Unit",eur."QtyConfirmed",
     CASE WHEN pod."ItemGroup" ILIKE ANY(ARRAY['Tools','Heavy Equipment','HeavyEquipment']) THEN 'EQUIPMENT' ELSE 'MATERIAL' END AS category,
     coalesce((SELECT sum(mu.qty) FROM operational.material_usage_log mu WHERE mu.confirmation_id=eur."ConfirmationID"),0) AS qty_used,
     eur."QtyConfirmed"
      - coalesce((SELECT sum(mr."QtyReturned") FROM public."materialReturn" mr WHERE mr."ConfirmationID"=eur."ConfirmationID"),0)
      - coalesce((SELECT sum(mu.qty) FROM operational.material_usage_log mu WHERE mu.confirmation_id=eur."ConfirmationID"),0) AS balance
    FROM public."endUserReceiving" eur
    JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
    JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID"
    JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
    WHERE eur."woID"=woid
   ) x
   WHERE x.balance>0 OR x.category='EQUIPMENT'
  ),'[]');
 ELSIF p_action='save_material_usage' THEN
  cid:=(p_data->>'confirmationId')::bigint;
  woid:=(p_data->>'woId')::uuid;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  IF nullif(p_data->>'qty','') IS NULL OR (p_data->>'qty')::numeric<=0 THEN RAISE EXCEPTION 'Qty tidak valid'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public."endUserReceiving" eur JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
    JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID" JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
    WHERE eur."ConfirmationID"=cid AND eur."woID"=woid AND NOT (pod."ItemGroup" ILIKE ANY(ARRAY['Tools','Heavy Equipment','HeavyEquipment']))) THEN
   RAISE EXCEPTION 'Item material tidak ditemukan untuk WO ini, atau item ini adalah Alat/Tools (pakai check-in/check-out, bukan qty)';
  END IF;
  SELECT eur."QtyConfirmed"
    - coalesce((SELECT sum(mr."QtyReturned") FROM public."materialReturn" mr WHERE mr."ConfirmationID"=eur."ConfirmationID"),0)
    - coalesce((SELECT sum(mu.qty) FROM operational.material_usage_log mu WHERE mu.confirmation_id=eur."ConfirmationID"),0)
  INTO balance
  FROM public."endUserReceiving" eur WHERE eur."ConfirmationID"=cid;
  IF (p_data->>'qty')::numeric > balance THEN RAISE EXCEPTION 'Qty melebihi sisa material yang tersedia (sisa %)',balance; END IF;
  INSERT INTO operational.material_usage_log(confirmation_id,wo_id,usage_date,qty,notes,recorded_by)
  VALUES(cid,woid,(p_data->>'reportDate')::date,(p_data->>'qty')::numeric,coalesce(p_data->>'notes',''),actor)
  RETURNING id INTO uid;
  RETURN jsonb_build_object('id',uid);
 ELSIF p_action='list_material_usage' THEN
  woid:=(p_data->>'woId')::uuid;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
    'id',mu.id,'itemDescription',pod."ItemDescription",'unit',pod."Unit",'qty',mu.qty,'notes',mu.notes,
    'recordedByName',k."NamaPersonnel"
   ) ORDER BY mu.created_at)
   FROM operational.material_usage_log mu
   JOIN public."endUserReceiving" eur ON eur."ConfirmationID"=mu.confirmation_id
   JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
   JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID"
   JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
   LEFT JOIN public."karyawanTbl" k ON k."Id"=mu.recorded_by
   WHERE mu.wo_id=woid AND mu.usage_date=(p_data->>'reportDate')::date
    AND NOT (pod."ItemGroup" ILIKE ANY(ARRAY['Tools','Heavy Equipment','HeavyEquipment']))
  ),'[]');
 ELSIF p_action='equipment_checkin' THEN
  cid:=(p_data->>'confirmationId')::bigint;
  woid:=(p_data->>'woId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public."endUserReceiving" WHERE "ConfirmationID"=cid AND "woID"=woid) THEN
   RAISE EXCEPTION 'Alat tidak ditemukan untuk WO ini';
  END IF;
  IF EXISTS(SELECT 1 FROM operational.equipment_checkin WHERE confirmation_id=cid AND check_out_at IS NULL) THEN
   RAISE EXCEPTION 'Alat ini masih dalam status check-in, check-out dulu';
  END IF;
  INSERT INTO operational.equipment_checkin(wo_id,confirmation_id,recorded_by) VALUES(woid,cid,actor) RETURNING id INTO ckid;
  RETURN jsonb_build_object('id',ckid);
 ELSIF p_action='equipment_checkout' THEN
  cid:=(p_data->>'confirmationId')::bigint;
  UPDATE operational.equipment_checkin SET check_out_at=now() WHERE confirmation_id=cid AND check_out_at IS NULL RETURNING id INTO ckid;
  IF ckid IS NULL THEN RAISE EXCEPTION 'Alat ini belum check-in'; END IF;
  RETURN jsonb_build_object('id',ckid);
 ELSIF p_action='list_equipment_checkins' THEN
  woid:=(p_data->>'woId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.check_in_at DESC) FROM (
   SELECT c.id,c.confirmation_id,c.check_in_at,c.check_out_at,pod."ItemDescription" AS item_description,pod."Unit" AS unit,
    eur."QtyConfirmed" AS qty,
    k."NamaPersonnel" AS recorded_by_name,
    EXTRACT(EPOCH FROM (coalesce(c.check_out_at,now())-c.check_in_at))/3600 AS hours
   FROM operational.equipment_checkin c
   JOIN public."endUserReceiving" eur ON eur."ConfirmationID"=c.confirmation_id
   JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
   JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID"
   JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
   LEFT JOIN public."karyawanTbl" k ON k."Id"=c.recorded_by
   WHERE c.wo_id=woid) x
  ),'[]');
 ELSIF p_action='read_daily_report' THEN
  sid:=(p_data->>'smsId')::uuid;
  IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
  RETURN coalesce((
   SELECT jsonb_agg(jsonb_build_object(
    'smsItemId',grp.sms_item_id,'itemCode',grp.item_code,'itemDescription',grp.item_description,
    'weatherShifts',(SELECT coalesce(jsonb_agg(jsonb_build_object('shift',w.shift,'weather',w.weather,'temperatureC',w.temperature_c,'effectiveHours',w.effective_hours) ORDER BY array_position(ARRAY['PAGI','SIANG','LEMBUR'],w.shift)),'[]')
     FROM operational.sms_item_weather w WHERE w.sms_item_id=grp.sms_item_id AND w.report_date=(p_data->>'reportDate')::date),
    'entries',grp.entries
   ) ORDER BY grp.item_code)
   FROM (
    SELECT si.id AS sms_item_id, si.code_snapshot AS item_code, si.description_snapshot AS item_description,
     jsonb_agg(jsonb_build_object(
      'detailId',e.detail_id,'description',e.description,'unit',e.unit,
      'qty',e.total_qty,'notes',e.notes_joined,'recordedByNames',e.recorded_by_names,
      'lastUpdatedAt',e.last_created_at,'photos',e.photos
     ) ORDER BY e.sort_order) AS entries
    FROM operational.sms_items si
    JOIN (
     SELECT d.sms_item_id,d.id AS detail_id,d.sort_order,d.description,d.unit,
      sum(pr.qty) AS total_qty,
      nullif(string_agg(NULLIF(btrim(pr.notes),''),'; '),'') AS notes_joined,
      string_agg(DISTINCT k."NamaPersonnel",', ') AS recorded_by_names,
      max(pr.created_at) AS last_created_at,
      (SELECT coalesce(jsonb_agg(jsonb_build_object('id',ph.id,'mimeType',ph.mime_type,'photoData',ph.photo_data) ORDER BY ph.uploaded_at),'[]')
       FROM operational.sms_item_progress_photos ph WHERE ph.progress_id IN (
        SELECT id FROM operational.sms_item_progress WHERE detail_id=d.id AND report_date=(p_data->>'reportDate')::date
       )) AS photos
     FROM operational.sms_item_details d
     JOIN operational.sms_item_progress pr ON pr.detail_id=d.id AND pr.report_date=(p_data->>'reportDate')::date
     LEFT JOIN public."karyawanTbl" k ON k."Id"=pr.recorded_by
     GROUP BY d.sms_item_id,d.id,d.sort_order,d.description,d.unit
    ) e ON e.sms_item_id=si.id
    GROUP BY si.id,si.code_snapshot,si.description_snapshot
   ) grp
  ),'[]');

 -- ============ BARU: Klaim Progress & Resource ke WO-Released ============
 ELSIF p_action='list_claimable_progress' THEN
  woid:=(p_data->>'sourceWoId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=woid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.item_code) FROM (
   SELECT si.id AS sms_item_id, si.code_snapshot AS item_code, si.description_snapshot AS item_description,
    si.unit_snapshot AS unit, si.commercial_item_id,
    coalesce((SELECT sum(pr.qty) FROM operational.sms_item_progress pr JOIN operational.sms_item_details d ON d.id=pr.detail_id WHERE d.sms_item_id=si.id),0) AS total_progress,
    coalesce((SELECT sum(c.qty) FROM operational.wo_release_claims c WHERE c.source_sms_item_id=si.id),0) AS total_claimed
   FROM operational.sms_items si WHERE si.wo_id=woid
  ) x WHERE x.total_progress - x.total_claimed > 0),'[]');

 ELSIF p_action='list_release_target_items' THEN
  wid:=(p_data->>'targetWoId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=wid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('commercialItemId',si.commercial_item_id,'code',i.code,'description',i.description) ORDER BY i.code)
   FROM operational.dashboard_wo_items(wid) i
   JOIN operational.sms_items si ON si.id=i.sms_item_id
  ),'[]');

 ELSIF p_action='list_claimable_resources' THEN
  woid:=(p_data->>'sourceWoId')::uuid;
  start_d:=nullif(p_data->>'startDate','')::date; end_d:=nullif(p_data->>'endDate','')::date;
  RETURN jsonb_build_object(
   'manpower', coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (
     SELECT c.id, c.employee_id, k."NamaPersonnel" AS employee_name, c.check_in_at, c.check_out_at,
      round((EXTRACT(EPOCH FROM (coalesce(c.check_out_at,now())-c.check_in_at))/3600)::numeric,2) AS total_hours,
      coalesce((SELECT sum(portion) FROM operational.wo_release_resource_claims WHERE resource_type='MANPOWER' AND resource_id=c.id),0) AS claimed_hours
     FROM operational.wo_manpower_checkin c LEFT JOIN public."karyawanTbl" k ON k."Id"=c.employee_id
     WHERE c.wo_id=woid AND (start_d IS NULL OR c.check_in_at::date>=start_d) AND (end_d IS NULL OR c.check_in_at::date<=end_d)
    ) x WHERE x.total_hours - x.claimed_hours > 0),'[]'),
   'material', coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (
     SELECT mu.id, pod."ItemDescription" AS item_description, pod."Unit" AS unit, mu.usage_date, mu.qty AS total_qty,
      coalesce((SELECT sum(portion) FROM operational.wo_release_resource_claims WHERE resource_type='MATERIAL' AND resource_id=mu.id),0) AS claimed_qty
     FROM operational.material_usage_log mu
     JOIN public."endUserReceiving" eur ON eur."ConfirmationID"=mu.confirmation_id
     JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
     JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID"
     JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
     WHERE mu.wo_id=woid AND (start_d IS NULL OR mu.usage_date>=start_d) AND (end_d IS NULL OR mu.usage_date<=end_d)
    ) x WHERE x.total_qty - x.claimed_qty > 0),'[]'),
   'equipment', coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (
     SELECT c.id, pod."ItemDescription" AS item_description, c.check_in_at, c.check_out_at,
      round((EXTRACT(EPOCH FROM (coalesce(c.check_out_at,now())-c.check_in_at))/3600)::numeric,2) AS total_hours,
      coalesce((SELECT sum(portion) FROM operational.wo_release_resource_claims WHERE resource_type='EQUIPMENT' AND resource_id=c.id),0) AS claimed_hours
     FROM operational.equipment_checkin c
     JOIN public."endUserReceiving" eur ON eur."ConfirmationID"=c.confirmation_id
     JOIN public."siteReceiving" sr ON sr."ReceivingID"=eur."ReceivingID"
     JOIN public."delivery" dl ON dl."DeliveryID"=sr."DeliveryID"
     JOIN public."purchaseOrderDetail" pod ON pod."PODetailID"=dl."PODetailID"
     WHERE c.wo_id=woid AND (start_d IS NULL OR c.check_in_at::date>=start_d) AND (end_d IS NULL OR c.check_in_at::date<=end_d)
    ) x WHERE x.total_hours - x.claimed_hours > 0),'[]')
  );

 ELSIF p_action='claim_progress_to_release' THEN
  first_claim_id:=NULL;
  IF jsonb_typeof(coalesce(p_data->'progressClaims','[]'::jsonb)) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Daftar klaim progress tidak valid'; END IF;
  FOR r IN SELECT value FROM jsonb_array_elements(coalesce(p_data->'progressClaims','[]'::jsonb)) LOOP
   sid:=(r->>'sourceSmsItemId')::uuid; wid:=(r->>'targetWoId')::uuid; itemid:=(r->>'targetCommercialItemId')::uuid;
   SELECT wo_id INTO source_wo_id FROM operational.sms_items WHERE id=sid;
   IF source_wo_id IS NULL THEN RAISE EXCEPTION 'SMS Item sumber tidak ditemukan'; END IF;
   IF NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=wid) THEN RAISE EXCEPTION 'WO tujuan tidak ditemukan'; END IF;
   IF wid=source_wo_id THEN RAISE EXCEPTION 'WO tujuan gak boleh sama dengan WO sumber -- pilih WO Released yang beda'; END IF;
   IF NOT EXISTS(SELECT 1 FROM operational.commercial_items WHERE id=itemid) THEN RAISE EXCEPTION 'Item komersial tujuan tidak ditemukan'; END IF;
   IF NOT EXISTS(SELECT 1 FROM operational.dashboard_wo_items(wid) i JOIN operational.sms_items si ON si.id=i.sms_item_id WHERE si.commercial_item_id=itemid) THEN
    RAISE EXCEPTION 'Item tujuan belum ada di SMS WO Released ini -- tambahkan item itu dulu lewat "+ Buat WO-SMS" (opsi Tambah SMS ke WO yang sudah ada), baru bisa diklaim ke sini';
   END IF;
   IF nullif(r->>'qty','') IS NULL OR (r->>'qty')::numeric<=0 THEN RAISE EXCEPTION 'Qty klaim tidak valid'; END IF;
   balance:=coalesce((SELECT sum(pr.qty) FROM operational.sms_item_progress pr JOIN operational.sms_item_details d ON d.id=pr.detail_id WHERE d.sms_item_id=sid),0)
          - coalesce((SELECT sum(qty) FROM operational.wo_release_claims WHERE source_sms_item_id=sid),0);
   IF (r->>'qty')::numeric > balance THEN RAISE EXCEPTION 'Qty klaim melebihi sisa progress yang tersedia (sisa %)',balance; END IF;
   INSERT INTO operational.wo_release_claims(source_sms_item_id,target_wo_id,target_commercial_item_id,qty,claim_date,notes,claimed_by)
   VALUES(sid,wid,itemid,(r->>'qty')::numeric,coalesce(nullif(r->>'claimDate','')::date,current_date),nullif(r->>'notes',''),actor)
   RETURNING id INTO rcid;
   IF first_claim_id IS NULL THEN first_claim_id:=rcid; END IF;
  END LOOP;

  IF jsonb_typeof(coalesce(p_data->'resourceClaims','[]'::jsonb)) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Daftar klaim resource tidak valid'; END IF;
  FOR r IN SELECT value FROM jsonb_array_elements(coalesce(p_data->'resourceClaims','[]'::jsonb)) LOOP
   IF r->>'resourceType' NOT IN ('MANPOWER','MATERIAL','EQUIPMENT') THEN RAISE EXCEPTION 'Jenis resource tidak valid'; END IF;
   IF nullif(r->>'portion','') IS NULL OR (r->>'portion')::numeric<=0 THEN RAISE EXCEPTION 'Portion klaim tidak valid'; END IF;
   IF NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=(r->>'targetWoId')::uuid) THEN RAISE EXCEPTION 'WO tujuan resource tidak ditemukan'; END IF;
   IF r->>'resourceType'='MANPOWER' THEN
    SELECT round((EXTRACT(EPOCH FROM (coalesce(check_out_at,now())-check_in_at))/3600)::numeric,2) INTO balance FROM operational.wo_manpower_checkin WHERE id=(r->>'resourceId')::uuid;
    IF balance IS NULL THEN RAISE EXCEPTION 'Manpower checkin tidak ditemukan'; END IF;
   ELSIF r->>'resourceType'='MATERIAL' THEN
    SELECT qty INTO balance FROM operational.material_usage_log WHERE id=(r->>'resourceId')::uuid;
    IF balance IS NULL THEN RAISE EXCEPTION 'Material usage tidak ditemukan'; END IF;
   ELSE
    SELECT round((EXTRACT(EPOCH FROM (coalesce(check_out_at,now())-check_in_at))/3600)::numeric,2) INTO balance FROM operational.equipment_checkin WHERE id=(r->>'resourceId')::uuid;
    IF balance IS NULL THEN RAISE EXCEPTION 'Equipment checkin tidak ditemukan'; END IF;
   END IF;
   balance:=balance - coalesce((SELECT sum(portion) FROM operational.wo_release_resource_claims WHERE resource_type=r->>'resourceType' AND resource_id=(r->>'resourceId')::uuid),0);
   IF (r->>'portion')::numeric > balance THEN RAISE EXCEPTION 'Portion klaim melebihi sisa resource (sisa %)',balance; END IF;
   INSERT INTO operational.wo_release_resource_claims(release_claim_id,target_wo_id,resource_type,resource_id,portion,claim_date,claimed_by)
   VALUES(first_claim_id,(r->>'targetWoId')::uuid,r->>'resourceType',(r->>'resourceId')::uuid,(r->>'portion')::numeric,coalesce(nullif(r->>'claimDate','')::date,current_date),actor);
  END LOOP;

  INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'CLAIM_PROGRESS_TO_RELEASE',first_claim_id);
  RETURN jsonb_build_object('firstClaimId',first_claim_id);

 ELSIF p_action='list_wo_release_claims' THEN
  wid:=(p_data->>'targetWoId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.claim_date DESC) FROM (
   SELECT c.id,c.qty,c.claim_date,c.notes,
    ci.code AS target_item_code, ci.description AS target_item_description,
    si.code_snapshot AS source_item_code, si.description_snapshot AS source_item_description,
    sw.number AS source_wo_number,
    k."NamaPersonnel" AS claimed_by_name
   FROM operational.wo_release_claims c
   JOIN operational.commercial_items ci ON ci.id=c.target_commercial_item_id
   JOIN operational.sms_items si ON si.id=c.source_sms_item_id
   JOIN operational.work_orders sw ON sw.id=si.wo_id
   LEFT JOIN public."karyawanTbl" k ON k."Id"=c.claimed_by
   WHERE c.target_wo_id=wid) x
  ),'[]');

 ELSIF p_action='list_wo_release_resource_claims' THEN
  wid:=(p_data->>'targetWoId')::uuid;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.claim_date DESC) FROM (
   SELECT rc.id,rc.resource_type,rc.portion,rc.claim_date,
    k."NamaPersonnel" AS claimed_by_name
   FROM operational.wo_release_resource_claims rc
   LEFT JOIN public."karyawanTbl" k ON k."Id"=rc.claimed_by
   WHERE rc.target_wo_id=wid) x
  ),'[]');

 ELSE RAISE EXCEPTION 'Operasi tidak tersedia';
 END IF;
END $function$
