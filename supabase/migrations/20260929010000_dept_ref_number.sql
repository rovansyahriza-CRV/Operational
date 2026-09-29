-- Nomor referensi turunan buat request Overhead (Non-Project) & Indirect (project client) yang
-- Fungsi/bidang biayanya = departemen tertentu -- format WO-<div>-<dept>-<tahun>-<urut>[-<kodeProject>].
-- Base "WO-<div>-<dept>" diambil dari nomor WO departemen yang beneran ada (operational.work_orders,
-- project internal). Urutan per (departemen,tahun), gak per project -- kode project di belakang cuma
-- label tambahan (dipakai kalau CostType=INDIRECT, nunjukkin project mana yang nanggung biaya
-- departemen ini). Ini CUMA nomor referensi buat pengelompokan cost di SMMS (kolom WO_NO di
-- public.request) -- gak bikin row WO baru; WoID tetap nunjuk ke WO asli yang dipilih user.

CREATE TABLE IF NOT EXISTS operational.dept_ref_counters(
  departemen text NOT NULL,
  ref_year integer NOT NULL,
  next_seq integer NOT NULL DEFAULT 1,
  PRIMARY KEY (departemen, ref_year)
);

CREATE OR REPLACE FUNCTION public.op_generate_dept_ref(p_departemen text, p_project_code text DEFAULT NULL)
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
 INSERT INTO operational.dept_ref_counters(departemen,ref_year,next_seq) VALUES(btrim(p_departemen),yr,2)
  ON CONFLICT (departemen,ref_year) DO UPDATE SET next_seq=operational.dept_ref_counters.next_seq+1
  RETURNING next_seq-1 INTO seq;
 RETURN base||'-'||yr||'-'||lpad(seq::text,3,'0')||CASE WHEN nullif(btrim(p_project_code),'') IS NOT NULL THEN '-'||btrim(p_project_code) ELSE '' END;
END;
$function$;
REVOKE ALL ON FUNCTION public.op_generate_dept_ref(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_generate_dept_ref(text,text) TO anon,authenticated;
