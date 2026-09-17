BEGIN;
REVOKE SELECT ON public."paswordTbl" FROM PUBLIC,anon,authenticated;
REVOKE SELECT("PasswordHas","Password","PIN") ON public."paswordTbl" FROM PUBLIC,anon,authenticated;
GRANT SELECT("Id","IsActive","Author","pic","PIC") ON public."paswordTbl" TO anon,authenticated;
-- NULL old-password must fail, not skip the comparison in PL/pgSQL.
DO $$
DECLARE body text;
BEGIN
 SELECT pg_get_functiondef('public.change_password_absensi_self_service(text,text,text)'::regprocedure) INTO body;
 IF position('IF TRIM(v_pw_db) <> TRIM(p_old_password) THEN' in body)=0 THEN RAISE EXCEPTION 'Unexpected self-service function; review required'; END IF;
 body:=replace(body,'IF TRIM(v_pw_db) <> TRIM(p_old_password) THEN','IF p_old_password IS NULL OR TRIM(v_pw_db) IS DISTINCT FROM TRIM(p_old_password) THEN');
 EXECUTE body;
END $$;
COMMIT;
