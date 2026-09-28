-- =====================================================================================
-- FITUR: Klaim Progress & Resource dari WO-Internal (Draft) ke WO-Released
-- Tanggal: 2026-09-28 -- DRAFT, belum di-apply, buat direview bareng dulu.
-- =====================================================================================
-- Konteks: WO-Internal (WO status DRAFT) dipakai sebagai wadah kerja harian sepanjang
-- periode -- Daily Progress (sms_item_progress) & resource (manpower checkin, material
-- usage, equipment checkin) semua nempel ke WO-Internal ini karena WO-Released (formal,
-- buat tagihan) belum tentu terbit/stabil sepanjang bulan berjalan.
--
-- Begitu periode tagihan tiba, progress yang udah numpuk di WO-Internal di-"klaim" manual
-- ke satu atau beberapa WO-Released -- boleh dikonversi ke item komersial yang beda dari
-- item asalnya di WO-Internal, dan gak harus diklaim sekaligus (sisa nunggu periode/klaim
-- berikutnya). Resource yang menyertai periode itu ikut diklaim juga (proporsional atau
-- pilih manual per record).
--
-- Desain: WO-Released TETAP work_orders biasa (bukan tabel/tipe baru) -- isi "resminya"
-- (qty per item komersial, jam manpower, dst) dihitung SUM dari tabel klaim di bawah, jadi
-- WO-Released gak butuh sms_items/wo_items pra-dibuat buat nerima klaim.
-- =====================================================================================

-- 1. Klaim PROGRESS: dari 1 SMS Item di WO-Internal -> 1 Commercial Item di WO-Released.
--    Boleh dipecah (1 SMS Item source bisa diklaim ke banyak WO-Released/Commercial Item
--    beda, di beberapa baris klaim terpisah, asal jumlahnya gak lebih dari yang tersedia).
CREATE TABLE IF NOT EXISTS operational.wo_release_claims (
  id uuid primary key default gen_random_uuid(),
  source_sms_item_id uuid not null references operational.sms_items(id),
  target_wo_id uuid not null references operational.work_orders(id),
  target_commercial_item_id uuid not null references operational.commercial_items(id),
  qty numeric not null check (qty > 0),
  claim_date date not null default current_date,
  notes text,
  claimed_by bigint not null,
  created_at timestamptz not null default now()
);
CREATE INDEX IF NOT EXISTS idx_wo_release_claims_source ON operational.wo_release_claims(source_sms_item_id);
CREATE INDEX IF NOT EXISTS idx_wo_release_claims_target ON operational.wo_release_claims(target_wo_id);

-- 2. Klaim RESOURCE (manpower/material/equipment): dari 1 record resource yang tercatat
--    di WO-Internal -> WO-Released tujuan. resource_id nunjuk ke salah satu dari 3 tabel
--    tergantung resource_type (polymorphic, sengaja gak di-FK-in karena beda tabel):
--      MANPOWER  -> operational.wo_manpower_checkin.id   (portion = jam)
--      MATERIAL  -> operational.material_usage_log.id    (portion = qty)
--      EQUIPMENT -> operational.equipment_checkin.id     (portion = jam)
--    release_claim_id nyambungin ke klaim progress yang jadi pemicu (1x aksi "Klaim" di UI
--    bisa langsung bawa progress + resource sekaligus) -- boleh NULL kalau nanti ada
--    kebutuhan klaim resource mandiri tanpa progress.
CREATE TABLE IF NOT EXISTS operational.wo_release_resource_claims (
  id uuid primary key default gen_random_uuid(),
  release_claim_id uuid references operational.wo_release_claims(id),
  target_wo_id uuid not null references operational.work_orders(id),
  resource_type text not null check (resource_type in ('MANPOWER','MATERIAL','EQUIPMENT')),
  resource_id uuid not null,
  portion numeric not null check (portion > 0),
  claim_date date not null default current_date,
  claimed_by bigint not null,
  created_at timestamptz not null default now()
);
CREATE INDEX IF NOT EXISTS idx_wo_release_resource_claims_resource ON operational.wo_release_resource_claims(resource_type, resource_id);
CREATE INDEX IF NOT EXISTS idx_wo_release_resource_claims_target ON operational.wo_release_resource_claims(target_wo_id);
CREATE INDEX IF NOT EXISTS idx_wo_release_resource_claims_release ON operational.wo_release_resource_claims(release_claim_id);

-- Belum ada RPC di migration ini -- nyusul setelah schema-nya di-oke-in.
