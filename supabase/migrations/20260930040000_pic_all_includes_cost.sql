-- PIC 'all' dijabarkan server ke daftar PIC tetap; 'operational cost' (menu Cost vs Progress) belum masuk,
-- jadi akun ber-PIC 'all' lihat menunya (client anggap 'all' = semua) tapi op_cost nolak.
CREATE OR REPLACE FUNCTION operational.tokens(p_text text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
 WITH parsed AS (
 SELECT coalesce(array_agg(lower(btrim(x))) FILTER(WHERE btrim(x)<>''),ARRAY[]::text[]) AS values
 FROM regexp_split_to_table(coalesce(p_text,''),'[,;\n\r]+') x
 ) SELECT CASE WHEN 'all'=ANY(values) THEN values || ARRAY[
 'operational master komersial','operational wo','operational progress','operational resources','operational approval wo','operational cost'
 ] ELSE values END FROM parsed;
$function$;
