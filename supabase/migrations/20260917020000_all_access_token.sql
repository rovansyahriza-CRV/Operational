BEGIN;
-- Expand only the exact ALL token; blank values remain without access.
CREATE OR REPLACE FUNCTION operational.tokens(p_text text) RETURNS text[]
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 WITH parsed AS (
 SELECT coalesce(array_agg(lower(btrim(x))) FILTER(WHERE btrim(x)<>''),ARRAY[]::text[]) AS values
 FROM regexp_split_to_table(coalesce(p_text,''),'[,;\n\r]+') x
 ) SELECT CASE WHEN 'all'=ANY(values) THEN values || ARRAY[
 'operational master komersial','operational wo','operational progress','operational resources','operational approval wo'
 ] ELSE values END FROM parsed;
$$;
REVOKE ALL ON FUNCTION operational.tokens(text) FROM PUBLIC,anon,authenticated;
COMMIT;
