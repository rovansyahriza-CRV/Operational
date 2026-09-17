BEGIN;
CREATE TABLE operational.auth_gate(id boolean PRIMARY KEY DEFAULT true CHECK(id),login_enabled boolean NOT NULL DEFAULT false);
INSERT INTO operational.auth_gate(id,login_enabled) VALUES(true,false);
ALTER TABLE operational.auth_gate ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.auth_gate FROM PUBLIC,anon,authenticated;
COMMENT ON TABLE operational.auth_gate IS 'Login paused while the shared SMMS credential table permits anonymous reads. Enable only after reviewing credential exposure and password/reset RPCs. Never expose this switch to browser roles.';
CREATE OR REPLACE FUNCTION operational.check_session(p_token text,p_pic text[],p_author text DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE who bigint; pics text[]; authors text[];
BEGIN
 IF NOT (SELECT login_enabled FROM operational.auth_gate WHERE id=true) THEN RAISE EXCEPTION 'Login Operational belum diaktifkan: pengamanan akses akun SMMS diperlukan.' USING ERRCODE='28000'; END IF;
 IF p_token IS NULL OR length(p_token)<>64 THEN RAISE EXCEPTION 'Sesi tidak valid. Login kembali.' USING ERRCODE='28000'; END IF;
 SELECT s.employee_id,operational.tokens(coalesce(nullif(btrim(p."PIC"),''),p.pic)),operational.tokens(p."Author") INTO who,pics,authors
 FROM operational.sessions s JOIN public."paswordTbl" p ON p."Id"=s.employee_id
 WHERE s.token_hash=sha256(convert_to(p_token,'UTF8')) AND s.expires_at>now() AND p."IsActive"=true
 AND s.credential_hash=sha256(convert_to(coalesce(p."PasswordHas",''),'UTF8'));
 IF who IS NULL THEN RAISE EXCEPTION 'Sesi berakhir atau akun dinonaktifkan.' USING ERRCODE='28000'; END IF;
 IF NOT (pics && p_pic) THEN RAISE EXCEPTION 'PIC tidak mengizinkan halaman atau operasi ini.' USING ERRCODE='42501'; END IF;
 IF p_author IS NOT NULL AND NOT(p_author=ANY(authors)) THEN RAISE EXCEPTION 'Author tidak mengizinkan approval ini.' USING ERRCODE='42501'; END IF;
 RETURN who;
END $$;

CREATE OR REPLACE FUNCTION public.op_login(p_id bigint,p_password text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u record; a operational.login_attempts; token text; credential text; pages text[];
BEGIN
 IF NOT (SELECT login_enabled FROM operational.auth_gate WHERE id=true) THEN RETURN jsonb_build_object('error','Login Operational belum diaktifkan: pengamanan akses akun SMMS diperlukan.'); END IF;
 IF p_id IS NULL OR p_password IS NULL OR length(p_password)>1024 THEN RETURN jsonb_build_object('error','Login gagal. Periksa akun dan akses Operational.'); END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('operational-login:'||p_id::text,0));
 DELETE FROM operational.sessions WHERE expires_at<now();
 DELETE FROM operational.login_attempts WHERE window_start<now()-interval '15 minutes';
 SELECT * INTO a FROM operational.login_attempts WHERE employee_id=p_id;
 IF a.attempts>=5 THEN RETURN jsonb_build_object('error','Terlalu banyak percobaan. Coba lagi setelah 15 menit.'); END IF;
 INSERT INTO operational.login_attempts VALUES(p_id,1,now()) ON CONFLICT(employee_id) DO UPDATE SET attempts=operational.login_attempts.attempts+1;
 SELECT * INTO u FROM public.verify_login(p_id,p_password) LIMIT 1;
 IF u.id IS NULL THEN RETURN jsonb_build_object('error','Login gagal. Periksa akun dan akses Operational.'); END IF;
 SELECT operational.tokens(coalesce(nullif(btrim(p."PIC"),''),p.pic)) INTO pages FROM public."paswordTbl" p WHERE p."Id"=p_id;
 IF NOT(pages && ARRAY['operational master komersial','operational wo','operational progress','operational resources']) THEN
 RETURN jsonb_build_object('error','Login gagal. Periksa akun dan akses Operational.'); END IF;
 SELECT "PasswordHas" INTO credential FROM public."paswordTbl" WHERE "Id"=p_id AND "IsActive"=true;
 token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 INSERT INTO operational.sessions(token_hash,employee_id,credential_hash,expires_at) VALUES(sha256(convert_to(token,'UTF8')),p_id,sha256(convert_to(credential,'UTF8')),now()+interval '8 hours');
 DELETE FROM operational.login_attempts WHERE employee_id=p_id;
 RETURN jsonb_build_object('token',token,'name',u.nama,'pic',pages,'author',operational.tokens(u.author),'expiresAt',now()+interval '8 hours');
END $$;

COMMIT;
