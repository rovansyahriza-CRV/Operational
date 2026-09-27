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

Applied 20260927010000_wo_weather_main.sql (2026-09-27) after rollback dry-run: new operational.wo_weather (one row per WO/date/shift; RLS on, no anon/authenticated table access) and public.op_weather(list/save) RPC. Backfilled 2 rows from sms_item_weather (no conflicting per-WO values). sms_item_weather kept as archive, no longer written by the app. Applied via direct SQL like previous entries; not registered in schema_migrations.

Applied 20260927020000_checkout_follow_regular_attendance.sql (2026-09-27) after rollback dry-run: absen pulang (absensiTbl.JamPulang) now only closes WO manpower/equipment sessions checked in on the same local date (Asia/Makassar), at max(JamPulang, check_in_at) so the CHECK constraint can no longer fail Fusion4 attendance saves. Sessions left open past their date are closed at that date's JamPulang, else 21:30 (operational.close_stale_checkins, run from the trigger and at the start of every op_manpower call). Data correction: 1 manpower session (19 Sep 15:24 -> was 24 Sep 17:31, now 19 Sep 21:30) and 2 equipment sessions (21 Sep 09:07 -> were 24 Sep 17:31, now 21 Sep 21:30). Applied via direct SQL; not registered in schema_migrations.

Applied 20260927030000_dashboard_progress.sql (2026-09-27) after rollback dry-run: read-only operational.dashboard_wo_items(wo) helper and public.op_dashboard(projects/project/wo_detail) RPC (session + 'operational wo' PIC). WO progress = value-weighted average of SMS item progress (latest SMS revision per sequence only); plan is linear between work_orders.start_date and end_date. Dry-run on WO-001 gave 22.06%, matching the cumulative S-curve end. No tables or data changed. Applied via direct SQL; not registered in schema_migrations.

Applied 20260927040000_project_wo_tree.sql (2026-09-27): op_dashboard gains read-only action 'wo_tree' (all WOs grouped by project with value/progress) for the Project List page; it accepts PIC 'operational wo' OR 'operational master komersial'. All other op_dashboard actions still require 'operational wo'. No tables or data changed. Applied via direct SQL; not registered in schema_migrations.

Applied 20260927050000_internal_projects_wo.sql (2026-09-27) after rollback dry-run: projects.project_type (CLIENT/INTERNAL) + projects.divisi, work_orders.departemen, contracts.contract_type now also allows INTERNAL. Seeded non-project codes: projects 901 Direksi, 902 Business Development, 903 Human Resources, 904 Supply Chains, 905 Operation Overhead (one administrative INT-9xx contract each) and 10 permanent department WOs (WO-901-BOD, WO-902-TND, WO-903-HRA, WO-904-PRC/LOG/WHS, WO-905-HSE/PCT/QAC/DPU), status APPROVED, departemen text matching karyawanTbl."Departemen" exactly. op_dashboard 'wo_tree' now returns {projects,wos}; 'projects' (progress dashboard) lists CLIENT projects only. Applied via direct SQL; not registered in schema_migrations.
