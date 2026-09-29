-- Tambah mode peek: preview nomor berikutnya TANPA naikin counter -- dipakai buat live-preview di
-- form (biar orang gak bolak-balik ganti Fungsi terus abandon form, tapi angkanya kepakai/bolong).
-- Konsumsi beneran (peek=false, default) cuma kejadian sekali pas submit.
CREATE OR REPLACE FUNCTION public.op_generate_dept_ref(p_departemen text, p_project_code text DEFAULT NULL, p_peek boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE base text; yr integer:=extract(year from (now() AT TIME ZONE 'Asia/Makassar'))::int; seq integer;
BEGIN
 IF nullif(btrim(p_departemen),'') IS NULL THEN RAISE EXCEPTION 'Departemen wajib diisi'; END IF;
 SELECT w.number INTO base FROM operational.work_orders w
  JOIN operational.contracts c ON c.id=w.contract_id
  JOIN operational.projects p ON p.id=c.project_id
  WHERE p.project_type='INTERNAL' AND w.departemen=btrim(p_departemen)
  ORDER BY w.created_at LIMIT 1;
 IF base IS NULL THEN RAISE EXCEPTION 'WO departemen "%" tidak ditemukan', p_departemen; END IF;
 IF p_peek THEN
  SELECT next_seq INTO seq FROM operational.dept_ref_counters WHERE departemen=btrim(p_departemen) AND ref_year=yr;
  seq:=coalesce(seq,1);
 ELSE
  INSERT INTO operational.dept_ref_counters(departemen,ref_year,next_seq) VALUES(btrim(p_departemen),yr,2)
   ON CONFLICT (departemen,ref_year) DO UPDATE SET next_seq=operational.dept_ref_counters.next_seq+1
   RETURNING next_seq-1 INTO seq;
 END IF;
 RETURN base||'-'||yr||'-'||lpad(seq::text,3,'0')||CASE WHEN nullif(btrim(p_project_code),'') IS NOT NULL THEN '-'||btrim(p_project_code) ELSE '' END;
END;
$function$;
REVOKE ALL ON FUNCTION public.op_generate_dept_ref(text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_generate_dept_ref(text,text,boolean) TO anon,authenticated;

DROP FUNCTION IF EXISTS public.op_generate_dept_ref(text,text);
