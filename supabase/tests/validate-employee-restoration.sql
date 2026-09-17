BEGIN;
LOCK TABLE operational.resource_allocations IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM operational.resource_allocations WHERE fusion4_employee_id IS NOT NULL OR fusion4_project_ref IS NOT NULL) THEN
  RAISE EXCEPTION 'External employee references require explicit mapping before restoration';
 END IF;
END $$;
ALTER TABLE operational.resource_allocations DROP CONSTRAINT fusion4_employee_source;
ALTER TABLE operational.resource_allocations DROP COLUMN fusion4_project_ref;
ALTER TABLE operational.resource_allocations RENAME COLUMN fusion4_employee_id TO employee_id;
ALTER TABLE operational.resource_allocations ALTER COLUMN employee_id TYPE bigint USING employee_id::bigint;
ALTER TABLE operational.resource_allocations ADD CONSTRAINT resource_allocations_employee_id_fkey FOREIGN KEY(employee_id) REFERENCES public."karyawanTbl"("Id");
COMMENT ON COLUMN operational.resource_allocations.employee_id IS 'Employee reference in the shared SMMS database, confirmed by user; SmartGate Fusion4 employee data resides here.';
ROLLBACK;

