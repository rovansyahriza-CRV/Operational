# Deployment record — 2026-09-16

Target: nhmpwjriextmbotmvvbu (SMMS).
Applied: supabase/migrations/20260916030000_operational_foundation.sql using linked db query in one transaction.
Preflight: validate-foundation.sql passed and rolled back all test rows and DDL.
Postflight: seven operational tables exist, all with RLS enabled. Existing public tables were not altered.

This explicit SQL application is NOT registered in supabase_migrations.schema_migrations. Reconcile the shared migration history before using db push; do not blindly replay this migration. validate-foundation.sql is a pre-install test for an empty operational schema only. For regression tests on the deployed schema, run foundation.sql inside BEGIN/ROLLBACK.

Scope delivered: backend foundation. Auth integration, approval workflow, progress/actuals and frontend remain pending. No production commercial data loaded.

Correction applied: 20260916040000_fusion4_external_manpower.sql. Removed SMMS employee foreign key after confirming zero manpower allocations. Added external Fusion4 employee ID and mandatory paired source project reference, excluding SMMS project. Rollback preflight passed. Fusion4 endpoint is not connected yet; source project confirmation pending.

Final source correction: user confirmed employee and related SmartGate Fusion4 data reside in SMMS. Applied 20260916050000_restore_shared_employee_reference.sql after rollback preflight and verification of zero external references. employee_id is bigint and references public.karyawanTbl.Id again. External Fusion4 source columns removed. This supersedes the earlier external-project note. Existing employee data unchanged. Migration files remain chronological and are not registered in shared migration history.

Applied 20260916060000_pic_author_api.sql after rollback tests: private sessions/audit/rate limit, public op_login/op_logout/op_api, master import and WO save/read/approval. No user roles assigned. Browser tests passed with mock API; live invalid-session request rejected.

Applied 20260916070000_hold_login_and_pic_compatibility.sql: Operational login and session operations intentionally paused due to confirmed anon SELECT on SMMS credential table. No SMMS grants/policies changed. PIC now follows uppercase PIC when populated, falling back to lowercase pic as used across existing apps. Login remains disabled until shared-account hardening is completed.
