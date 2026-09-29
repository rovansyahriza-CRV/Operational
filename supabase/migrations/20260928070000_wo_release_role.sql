-- Sebelumnya WO-Released cuma dibedain dari WO-Internal/Draft lewat penamaan manual ("(Released)")
-- dan heuristik gak langsung (wo_kind/departemen/prefix kontrak). Sekarang dikasih kolom eksplisit
-- release_role: 'WORKING' (default, WO kerja/Internal -- tempat progress & resource dicatat) atau
-- 'RELEASED' (WO tagihan -- tujuan klaim). Dashboard & dropdown Klaim Release pakai ini biar jelas.

ALTER TABLE operational.work_orders
  ADD COLUMN IF NOT EXISTS release_role text NOT NULL DEFAULT 'WORKING'
  CHECK (release_role IN ('WORKING','RELEASED'));

CREATE INDEX IF NOT EXISTS idx_work_orders_release_role ON operational.work_orders(release_role);
