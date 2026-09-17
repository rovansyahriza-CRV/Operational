BEGIN;
ALTER TABLE operational.projects
 ADD COLUMN client text NOT NULL DEFAULT '',
 ADD COLUMN location text NOT NULL DEFAULT '',
 ADD COLUMN contract_number text NOT NULL DEFAULT '',
 ADD COLUMN start_date date,
 ADD COLUMN end_date date,
 ADD COLUMN status text NOT NULL DEFAULT 'ACTIVE' CHECK(status IN ('ACTIVE','PLANNING','CLOSED')),
 ADD CONSTRAINT project_dates_valid CHECK ((start_date IS NULL AND end_date IS NULL) OR (start_date IS NOT NULL AND end_date IS NOT NULL AND end_date>=start_date));
CREATE TABLE operational.sms_documents (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 wo_id uuid NOT NULL REFERENCES operational.work_orders(id),
 sequence_no integer NOT NULL CHECK(sequence_no>0),
 revision text NOT NULL DEFAULT '01' CHECK(btrim(revision)<>''),
 number text NOT NULL CHECK(btrim(number)<>''),
 document_date date NOT NULL,
 notification_number text NOT NULL DEFAULT '', location text NOT NULL DEFAULT '',
 contractor text NOT NULL DEFAULT '', proposer text NOT NULL DEFAULT '', proposer_role text NOT NULL DEFAULT '',
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN ('DRAFT','SUBMITTED','APPROVED','SUPERSEDED')),
 routing_propose boolean NOT NULL DEFAULT false,
 routing_supervisor boolean NOT NULL DEFAULT false,
 routing_superintendent boolean NOT NULL DEFAULT false,
 routing_requester boolean NOT NULL DEFAULT false,
 approval_recorded_by bigint REFERENCES public."karyawanTbl"("Id"),
 approval_date date,
 evidence_path text,
 created_by bigint NOT NULL REFERENCES public."karyawanTbl"("Id"),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(wo_id,sequence_no,revision), UNIQUE(id,wo_id),
 CHECK(status<>'APPROVED' OR (routing_propose AND routing_supervisor AND routing_superintendent AND routing_requester AND approval_recorded_by IS NOT NULL AND approval_date IS NOT NULL AND nullif(btrim(evidence_path),'') IS NOT NULL))
);
CREATE TABLE operational.sms_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 sms_id uuid NOT NULL,wo_id uuid NOT NULL,
 package_id uuid NOT NULL,
 commercial_item_id uuid NOT NULL REFERENCES operational.commercial_items(id),
 code_snapshot text NOT NULL,description_snapshot text NOT NULL,
 unit_snapshot text NOT NULL,unit_price_snapshot numeric NOT NULL CHECK(unit_price_snapshot>=0 AND unit_price_snapshot::text NOT IN ('NaN','Infinity','-Infinity')),
 qty numeric NOT NULL CHECK(qty>0 AND qty::text NOT IN ('NaN','Infinity','-Infinity')),
 amount numeric GENERATED ALWAYS AS(qty*unit_price_snapshot) STORED,
 FOREIGN KEY(sms_id,wo_id) REFERENCES operational.sms_documents(id,wo_id),
 FOREIGN KEY(package_id,wo_id) REFERENCES operational.wo_packages(id,wo_id)
);
CREATE INDEX ON operational.sms_documents(wo_id);
CREATE INDEX ON operational.sms_items(sms_id);
ALTER TABLE operational.sms_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.sms_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.sms_documents,operational.sms_items FROM PUBLIC,anon,authenticated;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 VALUES('spms-sms-evidence','spms-sms-evidence',false,8388608,ARRAY['application/pdf']);
COMMENT ON TABLE operational.sms_documents IS 'SMS revisions. No browser direct access. Approval requires complete routing and private evidence; authenticated upload and API validation required before activation.';
CREATE FUNCTION public.op_projects(p_token text,p_action text,p_data jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor bigint; result operational.projects;
BEGIN
 actor:=operational.check_session(p_token,ARRAY['operational master komersial','operational wo']);
 IF p_action='list' THEN RETURN coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.code) FROM operational.projects p),'[]'); END IF;
 IF p_action<>'save' THEN RAISE EXCEPTION 'Operasi project tidak tersedia'; END IF;
 actor:=operational.check_session(p_token,ARRAY['operational master komersial']);
 IF nullif(btrim(p_data->>'code'),'') IS NULL OR nullif(btrim(p_data->>'name'),'') IS NULL THEN RAISE EXCEPTION 'Kode dan nama wajib diisi'; END IF;
 IF nullif(p_data->>'id','') IS NULL THEN
 INSERT INTO operational.projects(code,name,client,location,contract_number,start_date,end_date,status)
 VALUES(btrim(p_data->>'code'),btrim(p_data->>'name'),coalesce(p_data->>'client',''),coalesce(p_data->>'location',''),coalesce(p_data->>'contract',''),nullif(p_data->>'startDate','')::date,nullif(p_data->>'endDate','')::date,coalesce(p_data->>'state','ACTIVE')) RETURNING * INTO result;
 ELSE
 UPDATE operational.projects SET code=btrim(p_data->>'code'),name=btrim(p_data->>'name'),client=coalesce(p_data->>'client',''),location=coalesce(p_data->>'location',''),contract_number=coalesce(p_data->>'contract',''),start_date=nullif(p_data->>'startDate','')::date,end_date=nullif(p_data->>'endDate','')::date,status=coalesce(p_data->>'state','ACTIVE') WHERE id=(p_data->>'id')::uuid RETURNING * INTO result;
 IF result.id IS NULL THEN RAISE EXCEPTION 'Project tidak ditemukan'; END IF;
 END IF;
 INSERT INTO operational.audit_log(employee_id,action,entity_id) VALUES(actor,'SAVE_PROJECT',result.id);
 RETURN to_jsonb(result);
END $$;
REVOKE ALL ON FUNCTION public.op_projects(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_projects(text,text,jsonb) TO anon,authenticated;
COMMIT;
