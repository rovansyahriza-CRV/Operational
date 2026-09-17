# Operational Project

Separate application folder connected to shared SMMS Supabase project `nhmpwjriextmbotmvvbu`, schema `operational`.

## Run locally
Run `node server.cjs`, then open http://127.0.0.1:4173. Only application assets are served; database configuration and Git files are not exposed.

## Implemented
- Excel import preview: worksheet selection, column mapping, first data row, text number locale, duplicate-code and missing-field validation.
- SmallPipeline profile: arbitrary-depth groups, priced main/sub-items, Working/Standby rates, subtotal exclusion. Parent groups can be corrected before saving. Other contract layouts require mapping and hierarchy review; automatic inference is not a universal semantic parser.
- Local draft JSON export. Draft data stays in memory until saved/downloaded; source XLSX is not modified or uploaded.
- Backend master import creates a new contract/revision atomically. Existing master revisions are not overwritten.
- WO packages and quantities; server snapshots master price/scope, ignores browser-supplied prices. Saved WOs can be read and approved; saved-draft editing is not yet implemented.
- Server-side PIC checks for data access, Author plus PIC for approval. Session tokens are random, stored hashed in the database, held only in browser memory, expire after 8 hours and are invalidated by password changes or account deactivation.
- Login uses existing verify_login. PIC follows Fusion4 precedence: nonempty `paswordTbl.PIC`, otherwise `paswordTbl.pic`. Author comes from `paswordTbl.Author`.

## Current login hold
Operational login is intentionally disabled by `operational.auth_gate.login_enabled=false`.
Inspection found table-level SELECT permission for anon plus policy `anon_select_paswordTbl` with `USING(true)`. This exposes credential columns to anonymous reads. No password values were read during inspection.
Before enabling login, review/restrict anonymous access to credential fields and audit password-reset/change RPC authorization. Operational does not modify those existing SMMS permissions automatically. The gate also blocks previously issued Operational sessions. Local preview remains usable.

## Permissions to assign AFTER shared-login hardening
Add tokens to existing comma-separated values; do not overwrite unrelated permissions.

| PIC (page/data access) | Author (approval only) |
| --- | --- |
| Operational Master Komersial | No approval flow for master in this version |
| Operational WO | Operational Approval WO |
| Operational Progress (reserved) | Operational Approval Progress (reserved) |
| Operational Resources (reserved) | Operational Approval Resources (reserved) |

Exact case-insensitive token matching. Blank, `all`, `*`, or unrelated legacy roles do not automatically authorize Operational. PIC permissions currently apply across Operational projects; project-level scopes are not implemented. No existing user permissions were changed.

## Sources and precision
Material, consumables, tools, heavyEquipment and karyawanTbl references all live in shared SMMS. No separate Fusion4 connection is needed. SMMS project-ID mapping still needs confirmation. PostgreSQL numeric preserves submitted precision; browser preview uses JS numbers matching Excel's numeric values. Currency is IDR in this release, display uses two decimals; contractual rounding policy is not finalized.

## Tests
- `node tests/import.test.cjs "<path-to-SmallPipeline.xlsx>"`: verified 262 priced items, original rate precision, hierarchy, rates and validation.
- Browser tests use bundled Playwright path on the development machine: Excel preview/WO calculations and mocked API login/save/approval/logout.
- `supabase/tests/pic-author-api.sql`: transactional test with dummy account and business records; must be wrapped in BEGIN/ROLLBACK, and the auth gate temporarily enabled within that same rollback transaction. Never run standalone against production.
- API integration preflight passed before deployment. Live REST rejects invalid/blocked sessions. Real-user UI login is not tested while gate is disabled.

## Pending
Shared-login hardening; actual user PIC/Author assignment; saved WO editing/revisions; progress acceptance; resource requests/actuals and attendance allocation UI; project-scoped permissions; import history UI and draft JSON re-import.

## Database migrations
Applied SQL is tracked in `docs/deployment-20260916.md`. Shared SMMS migration history is not baselined here. Do not run db reset/config push/unrestricted db push. Explicitly applied migrations are not registered in supabase_migrations; reconcile before adopting db push.
