DO $$
DECLARE result jsonb; tok text; cid uuid; wid uuid; itemid uuid; bad boolean; idmap jsonb;
BEGIN
 INSERT INTO public."karyawanTbl"("Id","NamaPersonnel","DigitalPIN","IsActive") VALUES(-910016,'Operational rollback test',-910016,true);
 INSERT INTO public."paswordTbl"("Id","PasswordHas","IsActive",pic,"Author") VALUES(-910016,'test-password-only',true,'Operational Master Komersial, Operational WO','');
 result:=public.op_login(-910016,'wrong');
 IF NOT(result ? 'error') THEN RAISE EXCEPTION 'TEST: bad password accepted'; END IF;
 result:=public.op_login(-910016,'test-password-only'); tok:=result->>'token';
 IF tok IS NULL THEN RAISE EXCEPTION 'TEST: valid login failed %',result; END IF;
 bad:=false;
 BEGIN PERFORM public.op_api('invalid','contracts'); EXCEPTION WHEN invalid_authorization_specification THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: invalid session accepted'; END IF;
 result:=public.op_api(tok,'import_master',jsonb_build_object('projectCode','__OP_ROLLBACK_TEST__','projectName','Test','contractNo','CTR-TEST','contractType','BLANKET_ORDER','items',jsonb_build_array(
 jsonb_build_object('id','g','code','G','description','Group','rowKind','GROUP'),
 jsonb_build_object('id','i','parentId','g','code','1','description','Welder','rowKind','ITEM','unit','Hari','price',123.456789,'qty',20)
 ))); cid:=(result->>'contractId')::uuid; itemid:=(result->'itemIds'->>'i')::uuid;
 result:=public.op_api(tok,'save_wo',jsonb_build_object('contractId',cid,'number','WO-1','title','Test','items',jsonb_build_array(jsonb_build_object('sourceId',itemid,'qty',2,'price',1,'package','Package')))); wid:=(result->>'woId')::uuid;
 IF (SELECT amount FROM operational.wo_items WHERE wo_id=wid)<>246.913578 THEN RAISE EXCEPTION 'TEST: client controlled price or precision lost'; END IF;
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'approve_wo',jsonb_build_object('woId',wid)); EXCEPTION WHEN insufficient_privilege THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: PIC alone allowed approval'; END IF;
 UPDATE public."paswordTbl" SET "Author"='Operational Approval WO',pic='Unrelated' WHERE "Id"=-910016;
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'approve_wo',jsonb_build_object('woId',wid)); EXCEPTION WHEN insufficient_privilege THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: Author without PIC allowed page access'; END IF;
 UPDATE public."paswordTbl" SET pic='Operational WO' WHERE "Id"=-910016;
 PERFORM public.op_api(tok,'approve_wo',jsonb_build_object('woId',wid));
 IF (SELECT status FROM operational.work_orders WHERE id=wid)<>'APPROVED' THEN RAISE EXCEPTION 'TEST: approval failed'; END IF;
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'import_master','{}'); EXCEPTION WHEN insufficient_privilege THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: revoked PIC remained active'; END IF;
 UPDATE public."paswordTbl" SET "PIC"='Unrelated' WHERE "Id"=-910016;
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'list_wo'); EXCEPTION WHEN insufficient_privilege THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: uppercase PIC precedence not enforced'; END IF;
 UPDATE public."paswordTbl" SET "PIC"=NULL WHERE "Id"=-910016;
 PERFORM public.op_logout(tok);
 bad:=false;
 BEGIN PERFORM public.op_api(tok,'contracts'); EXCEPTION WHEN invalid_authorization_specification THEN bad:=true; END;
 IF NOT bad THEN RAISE EXCEPTION 'TEST: logout did not invalidate session'; END IF;
 IF has_table_privilege('anon','operational.sessions','SELECT') OR has_function_privilege('anon','operational.check_session(text,text[],text)','EXECUTE') THEN RAISE EXCEPTION 'TEST: private API accessible'; END IF;
END $$;
SELECT 'PASS: login, invalid session, import hierarchy, server price, PIC vs Author, revoked rights, approval, logout, private access' AS result;

