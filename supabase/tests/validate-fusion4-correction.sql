BEGIN;
LOCK TABLE operational.resource_allocations IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM operational.resource_allocations WHERE employee_id IS NOT NULL) THEN
 RAISE EXCEPTION 'Existing SMMS employee references must be mapped explicitly before migration';
 END IF;
END $$;
ALTER TABLE operational.resource_allocations DROP CONSTRAINT resource_allocations_employee_id_fkey;
ALTER TABLE operational.resource_allocations RENAME COLUMN employee_id TO fusion4_employee_id;
ALTER TABLE operational.resource_allocations ALTER COLUMN fusion4_employee_id TYPE text USING fusion4_employee_id::text;
ALTER TABLE operational.resource_allocations ADD COLUMN fusion4_project_ref text;
ALTER TABLE operational.resource_allocations ADD CONSTRAINT fusion4_employee_source CHECK (
 (fusion4_employee_id IS NULL AND fusion4_project_ref IS NULL) OR
 (fusion4_employee_id IS NOT NULL AND btrim(fusion4_employee_id) <> '' AND fusion4_project_ref IS NOT NULL AND btrim(fusion4_project_ref) <> '' AND fusion4_project_ref <> 'nhmpwjriextmbotmvvbu')
);
COMMENT ON COLUMN operational.resource_allocations.fusion4_employee_id IS 'External employee ID from the separate SmartGate Fusion4 project; validate through server-side integration, never SMMS karyawanTbl.';
COMMENT ON COLUMN operational.resource_allocations.fusion4_project_ref IS 'Verified SmartGate Fusion4 source project. Must be set server-side, not trusted from browser input.';
ROLLBACK;

