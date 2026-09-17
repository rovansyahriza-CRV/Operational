BEGIN;
CREATE TABLE operational.fusion_sessions (
 token_hash bytea PRIMARY KEY, employee_id bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 credential_hash bytea NOT NULL, expires_at timestamptz NOT NULL
);
ALTER TABLE operational.fusion_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.fusion_sessions FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.fusion_login(p_id bigint,p_password text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u record; token text; attempts integer; credential text;
BEGIN
 IF p_id IS NULL OR p_password IS NULL OR length(p_password)>1024 THEN RETURN jsonb_build_object('error','Login gagal'); END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('operational-login:'||p_id::text,0));
 DELETE FROM operational.login_attempts WHERE window_start<now()-interval '15 minutes';
 SELECT a.attempts INTO attempts FROM operational.login_attempts a WHERE employee_id=p_id;
 IF attempts>=5 THEN RETURN jsonb_build_object('error','Terlalu banyak percobaan. Tunggu 15 menit.'); END IF;
 INSERT INTO operational.login_attempts VALUES(p_id,1,now()) ON CONFLICT(employee_id) DO UPDATE SET attempts=operational.login_attempts.attempts+1;
 SELECT * INTO u FROM public.verify_login(p_id,p_password) LIMIT 1;
 IF u.id IS NULL THEN RETURN jsonb_build_object('error','ID atau password salah'); END IF;
 SELECT "PasswordHas" INTO credential FROM public."paswordTbl" WHERE "Id"=p_id AND "IsActive"=true;
 token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 DELETE FROM operational.fusion_sessions WHERE expires_at<now();
 INSERT INTO operational.fusion_sessions VALUES(sha256(convert_to(token,'UTF8')),p_id,sha256(convert_to(credential,'UTF8')),now()+interval '8 hours');
 DELETE FROM operational.login_attempts WHERE employee_id=p_id;
 RETURN jsonb_build_object('user',to_jsonb(u),'token',token,'expiresAt',now()+interval '8 hours');
END $$;
CREATE FUNCTION operational.check_fusion_session(p_token text,p_permission text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor bigint; pics text[];
BEGIN
 SELECT s.employee_id,operational.tokens(coalesce(nullif(btrim(p."PIC"),''),p.pic)) INTO actor,pics
 FROM operational.fusion_sessions s JOIN public."paswordTbl" p ON p."Id"=s.employee_id
 WHERE s.token_hash=sha256(convert_to(p_token,'UTF8')) AND s.expires_at>now() AND p."IsActive"=true
 AND s.credential_hash=sha256(convert_to(coalesce(p."PasswordHas",''),'UTF8'));
 IF actor IS NULL THEN RAISE EXCEPTION 'Login Fusion4 kembali untuk operasi admin.' USING ERRCODE='28000'; END IF;
 IF NOT ('all'=ANY(pics) OR p_permission=ANY(pics)) THEN RAISE EXCEPTION 'PIC tidak mengizinkan operasi admin ini.' USING ERRCODE='42501'; END IF;
 RETURN actor;
END $$;
-- Add authenticated counterparts while old clients continue operating until coordinated cutover.
DO $$
DECLARE r record; args text; callargs text; permission text; body text;
BEGIN
 FOR r IN SELECT p.* FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('admin_reset_password_absensi','update_karyawan_core','create_karyawan_full','update_karyawan_badge_info') LOOP
 args:=pg_get_function_arguments(r.oid);
 SELECT string_agg(format('%I',x),',' ORDER BY ord) INTO callargs FROM unnest(r.proargnames) WITH ORDINALITY AS t(x,ord);
 permission:=CASE r.proname WHEN 'admin_reset_password_absensi' THEN 'gp' WHEN 'update_karyawan_badge_info' THEN 'kdb' ELSE 'dk' END;
 body:=format('BEGIN PERFORM operational.check_fusion_session(p_session_token,%L); %s public.%I(%s); %s END',permission,CASE WHEN r.prorettype='void'::regtype THEN 'PERFORM' ELSE 'RETURN' END,r.proname,callargs,CASE WHEN r.prorettype='void'::regtype THEN 'RETURN;' ELSE '' END);
 EXECUTE format('CREATE FUNCTION public.%I(%s,p_session_token text DEFAULT NULL) RETURNS %s LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS %L',r.proname||'_secure',args,pg_get_function_result(r.oid),body);
 EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s,text) FROM PUBLIC',r.proname||'_secure',oidvectortypes(r.proargtypes));
 EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s,text) TO anon,authenticated',r.proname||'_secure',oidvectortypes(r.proargtypes));
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION operational.check_fusion_session(text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.fusion_login(bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fusion_login(bigint,text) TO anon,authenticated;
COMMIT;
