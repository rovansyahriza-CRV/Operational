BEGIN;
CREATE SCHEMA operational;
REVOKE ALL ON SCHEMA operational FROM PUBLIC, anon, authenticated;
CREATE TABLE operational.projects (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), code text NOT NULL UNIQUE CHECK (btrim(code) <> ''),
 name text NOT NULL CHECK (btrim(name) <> ''), smms_project_id bigint UNIQUE,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE operational.contracts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES operational.projects(id),
 number text NOT NULL, contract_type text NOT NULL CHECK (contract_type IN ('LUMPSUM','BLANKET_ORDER')),
 currency text NOT NULL DEFAULT 'IDR' CHECK (currency ~ '^[A-Z]{3}$'),
 revision text NOT NULL DEFAULT '01', agreed_value numeric CHECK (agreed_value >= 0),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(project_id,number,revision)
);
CREATE TABLE operational.commercial_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), contract_id uuid NOT NULL REFERENCES operational.contracts(id),
 parent_id uuid, code text NOT NULL CHECK (btrim(code) <> ''), description text NOT NULL,
 row_kind text NOT NULL CHECK (row_kind IN ('GROUP','ITEM')),
 resource_kind text CHECK (resource_kind IN ('SERVICE','MANPOWER','EQUIPMENT','MATERIAL','CONSUMABLE','OTHER')),
 rate_kind text NOT NULL DEFAULT 'STANDARD' CHECK (rate_kind IN ('STANDARD','WORKING','STANDBY')),
 unit text, reference_qty numeric CHECK (reference_qty >= 0), unit_price numeric CHECK (unit_price >= 0),
 source_file text, source_sheet text, source_row integer CHECK (source_row > 0),
 source_amount numeric, source_unit text, import_metadata jsonb NOT NULL DEFAULT '{}', sort_order integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(contract_id,code), UNIQUE(id,contract_id),
 FOREIGN KEY(parent_id,contract_id) REFERENCES operational.commercial_items(id,contract_id),
 CHECK (parent_id IS DISTINCT FROM id),
 CHECK ((row_kind='GROUP' AND unit_price IS NULL AND reference_qty IS NULL) OR
        (row_kind='ITEM' AND unit IS NOT NULL AND btrim(unit) <> '' AND unit_price IS NOT NULL))
);
CREATE FUNCTION operational.validate_item_parent() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE parent_kind text;
BEGIN
 -- Serialize hierarchy edits within a contract to prevent concurrent cycles.
 PERFORM 1 FROM operational.contracts WHERE id=NEW.contract_id FOR UPDATE;
 IF TG_OP='UPDATE' AND (NEW.contract_id<>OLD.contract_id OR NEW.id<>OLD.id) THEN
  RAISE EXCEPTION 'Item identity and contract cannot change';
 END IF;
 IF NEW.parent_id IS NOT NULL THEN
  SELECT row_kind INTO parent_kind FROM operational.commercial_items WHERE id=NEW.parent_id AND contract_id=NEW.contract_id;
  IF parent_kind IS DISTINCT FROM 'GROUP' THEN RAISE EXCEPTION 'Parent must be a group in the same contract'; END IF;
  IF EXISTS (WITH RECURSIVE ancestors AS (
   SELECT id,parent_id FROM operational.commercial_items WHERE id=NEW.parent_id
   UNION SELECT i.id,i.parent_id FROM operational.commercial_items i JOIN ancestors a ON i.id=a.parent_id
  ) SELECT 1 FROM ancestors WHERE id=NEW.id) THEN RAISE EXCEPTION 'Hierarchy cycle'; END IF;
 END IF;
 IF NEW.row_kind='ITEM' AND EXISTS (SELECT 1 FROM operational.commercial_items WHERE parent_id=NEW.id) THEN
  RAISE EXCEPTION 'A group with children cannot become an item';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validate_item_parent BEFORE INSERT OR UPDATE ON operational.commercial_items FOR EACH ROW EXECUTE FUNCTION operational.validate_item_parent();
CREATE TABLE operational.work_orders (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), contract_id uuid NOT NULL REFERENCES operational.contracts(id),
 number text NOT NULL, title text NOT NULL, status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN ('DRAFT','APPROVED','CLOSED','CANCELLED')),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(contract_id,number), UNIQUE(id,contract_id)
);
CREATE TABLE operational.wo_packages (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), wo_id uuid NOT NULL REFERENCES operational.work_orders(id),
 code text NOT NULL, name text NOT NULL, UNIQUE(wo_id,code), UNIQUE(id,wo_id)
);
CREATE TABLE operational.wo_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), wo_id uuid NOT NULL, contract_id uuid NOT NULL,
 package_id uuid NOT NULL, commercial_item_id uuid NOT NULL,
 code_snapshot text NOT NULL, description_snapshot text NOT NULL, unit_snapshot text NOT NULL,
 rate_kind_snapshot text NOT NULL, unit_price_snapshot numeric NOT NULL CHECK(unit_price_snapshot >= 0),
 qty numeric NOT NULL CHECK(qty > 0), amount numeric GENERATED ALWAYS AS(qty*unit_price_snapshot) STORED,
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(wo_id,contract_id) REFERENCES operational.work_orders(id,contract_id),
 FOREIGN KEY(commercial_item_id,contract_id) REFERENCES operational.commercial_items(id,contract_id),
 FOREIGN KEY(package_id,wo_id) REFERENCES operational.wo_packages(id,wo_id)
);
CREATE FUNCTION operational.snapshot_wo_item() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE item operational.commercial_items; wo operational.work_orders;
BEGIN
 IF TG_OP<>'INSERT' THEN
  SELECT * INTO wo FROM operational.work_orders WHERE id=OLD.wo_id FOR UPDATE;
  IF wo.status<>'DRAFT' THEN RAISE EXCEPTION 'Only draft WO items can be changed'; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 SELECT * INTO wo FROM operational.work_orders WHERE id=NEW.wo_id FOR UPDATE;
 IF wo.status IS DISTINCT FROM 'DRAFT' THEN RAISE EXCEPTION 'WO must be a draft'; END IF;
 IF TG_OP='UPDATE' THEN
  IF ROW(NEW.wo_id,NEW.contract_id,NEW.commercial_item_id,NEW.code_snapshot,NEW.description_snapshot,NEW.unit_snapshot,NEW.rate_kind_snapshot,NEW.unit_price_snapshot)
   IS DISTINCT FROM ROW(OLD.wo_id,OLD.contract_id,OLD.commercial_item_id,OLD.code_snapshot,OLD.description_snapshot,OLD.unit_snapshot,OLD.rate_kind_snapshot,OLD.unit_price_snapshot)
   THEN RAISE EXCEPTION 'Snapshot is immutable; remove and re-add the draft item to change its source'; END IF;
 ELSE
  SELECT * INTO item FROM operational.commercial_items WHERE id=NEW.commercial_item_id AND contract_id=wo.contract_id;
  IF item.row_kind IS DISTINCT FROM 'ITEM' THEN RAISE EXCEPTION 'Choose a priced item from the WO contract'; END IF;
  NEW.contract_id:=wo.contract_id; NEW.code_snapshot:=item.code; NEW.description_snapshot:=item.description;
  NEW.unit_snapshot:=item.unit; NEW.rate_kind_snapshot:=item.rate_kind; NEW.unit_price_snapshot:=item.unit_price;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER snapshot_wo_item BEFORE INSERT OR UPDATE OR DELETE ON operational.wo_items FOR EACH ROW EXECUTE FUNCTION operational.snapshot_wo_item();
CREATE TABLE operational.resource_allocations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), wo_item_id uuid NOT NULL REFERENCES operational.wo_items(id),
 material_id bigint REFERENCES public.material("ID"), consumable_id bigint REFERENCES public.consumables("ID"),
 tool_id bigint REFERENCES public.tools("ID"), equipment_id bigint REFERENCES public."heavyEquipment"("ID"),
 employee_id bigint REFERENCES public."karyawanTbl"("Id"),
 planned_qty numeric NOT NULL CHECK(planned_qty>0), unit text NOT NULL,
 request_id bigint REFERENCES public.request("ID"), notes text,
 CHECK(num_nonnulls(material_id,consumable_id,tool_id,equipment_id,employee_id)=1)
);
CREATE INDEX ON operational.contracts(project_id);
CREATE INDEX ON operational.commercial_items(parent_id);
CREATE INDEX ON operational.wo_packages(wo_id);
CREATE INDEX ON operational.wo_items(wo_id);
CREATE INDEX ON operational.wo_items(commercial_item_id);
CREATE INDEX ON operational.resource_allocations(wo_item_id);
-- Backend foundation only. Auth/RPC integration is a separate migration.
ALTER TABLE operational.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.commercial_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.work_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.wo_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.wo_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE operational.resource_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA operational FROM PUBLIC,anon,authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA operational FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA operational TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA operational TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA operational TO service_role;
COMMIT;
