BEGIN;
-- Feedback: picker WO di end-user-receiving.html mestinya cascading -- pilih Project dulu,
-- baru WO-nya (bakal makin kepake pas WO makin banyak). op_list_work_orders_public sekarang
-- ikut nyertain projectId+projectName per WO biar client bisa build 2 dropdown (Project lalu WO
-- terfilter) tanpa nambah RPC baru.
CREATE OR REPLACE FUNCTION public.op_list_work_orders_public()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT coalesce(jsonb_agg(jsonb_build_object(
   'id',w.id,'number',w.number,'title',w.title,
   'projectId',p.id,'projectName',p.name
 ) ORDER BY p.name,w.number),'[]')
 FROM operational.work_orders w
 JOIN operational.contracts c ON c.id=w.contract_id
 JOIN operational.projects p ON p.id=c.project_id;
$function$;
COMMIT;
