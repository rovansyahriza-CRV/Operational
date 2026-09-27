BEGIN;
-- Form Permintaan Material SMMS: Project ID & WO No jadi pilihan (search), bukan ketik bebas.
-- SMMS (anon + login sendiri) pakai RPC publik yang udah ada; di sini cuma NAMBAH field
-- (field lama tetap sama, dipakai end-user-receiving.html):
--  - projects: projectType (CLIENT/INTERNAL), divisi
--  - work orders: projectCode, projectType, status, departemen
-- Di SMMS semua project/WO (client + non-project 9xx) boleh dipilih; di Operational WO 9xx
-- disembunyikan di sisi frontend.

CREATE OR REPLACE FUNCTION public.op_list_projects_public()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',p.id,'code',p.code,'name',p.name,'client',p.client,'location',p.location,
   'contractorName',p.contractor_name,'supervisorConsultant',p.supervisor_consultant,
   'contractNumber',p.contract_number,'startDate',p.start_date,'endDate',p.end_date,
   'status',p.status,'smmsProjectId',p.smms_project_id,
   'projectType',p.project_type,'divisi',p.divisi
  ) ORDER BY p.name),'[]')
 FROM operational.projects p;
$function$;

CREATE OR REPLACE FUNCTION public.op_list_work_orders_public()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',w.id,'number',w.number,'title',w.title,
   'projectId',p.id,'projectName',p.name,
   'projectCode',p.code,'projectType',p.project_type,'status',w.status,'departemen',w.departemen
 ) ORDER BY p.name,w.number),'[]')
 FROM operational.work_orders w
 JOIN operational.contracts c ON c.id=w.contract_id
 JOIN operational.projects p ON p.id=c.project_id;
$function$;
COMMIT;
