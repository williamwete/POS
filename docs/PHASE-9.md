# Milestone Phase 9 — Integrasi Openbravo

Tanggal: 2026-10-06 · Format §108.

## 1. What was implemented
- **Antrean sinkronisasi** (§41, §63): job dibuat database di transaksi yang sama saat transaksi **lunas**, retur
  **selesai**, dan **cash-up/Z** dibuat — penjualan + pembayaran, retur + refund, cash-up dikirim ke Openbravo.
- **Worker** otomatis (tiap 15 detik) dengan **retry bertahap** 30 dtk → 1 mnt → 5 mnt → 15 mnt lalu **manual review**
  (§43); urutan dijaga (retur setelah penjualan asal, cash-up setelah dokumen session-nya).
- Setelah terkirim: transaksi `POSTED`, nomor & ID dokumen Openbravo, `last_sync_at`; bila gagal transaksi tetap `PAID`
  dengan sync `FAILED` (§42) — tidak ada data lokal yang dihapus. Layar lunas menampilkan "transaksi tersimpan dan akan
  disinkronkan otomatis".
- **Master data** (§40): produk, barcode, kategori, harga (versi baru bila berubah), stok (snapshot Openbravo), customer —
  dengan `sync_started_at/finished_at`, `records_processed/success/failed`, `error_count`.
- **Pemetaan ID Openbravo** (§39) untuk organisasi, outlet, gudang, terminal, metode bayar, pajak — diatur admin, tanpa
  hard-code.
- **Dashboard Sinkronisasi** (§42): antrean per jenis dokumen, master data, daftar "Perlu perhatian" dengan penyebab,
  riwayat percobaan, dan **Coba lagi**.
- Konektor **HTTP** (Openbravo sungguhan, kredensial di server) dan **simulator** untuk lokal.

## 2. Files created/changed
- `db/migration/V018__openbravo_sync.sql`, `db/seed/R__demo_seed.sql` (pemetaan demo), `db/tests/test_14_sync.sql`
- `backend/.../integration/*` (OpenbravoClient + HTTP/Simulator/Disabled, OpenbravoConfig, SyncWorker, SyncService,
  SyncRepository, SyncController, SyncDtos), `config/PosProperties`, `application.yml`, `ErrorCode`,
  `GlobalExceptionHandler`; test `SyncIT`, `application-test.yml`
- `frontend/src/modules/admin/SyncPage.vue`, `OpenbravoMappingsPage.vue` (baru), `PaymentMethodsPage.vue`,
  `modules/pos/PaidPanel.vue`, `router`, `AppLayout` (menu), `types/api.ts`
- Docs: OPENBRAVO.md (baru), API, DATABASE, ASSUMPTIONS (B57–B62), TESTING, README, `.env.example`

## 3. Database migrations
V018: `openbravo_mappings`, `customers`, `sync_jobs`, `sync_logs`; kolom dokumen Openbravo di `sales` & `returns`;
guard penjualan & retur diperbarui (kolom sync hanya konteks sistem); trigger antrean; fungsi payload, ketergantungan,
dan upsert master; backfill antrean untuk dokumen yang sudah ada; RLS.

## 4. API endpoints
8 endpoint — [API.md](API.md) bagian "Sinkronisasi Openbravo" (§72: `GET /api/sync/status`, `POST /api/sync/run`,
`GET /api/sync/errors`, `POST /api/sync/{id}/retry`, plus daftar/detail job dan pemetaan).

## 5. Business rules
- Tidak ada transaksi lunas tanpa job sync (dibuat di transaksi yang sama); satu job per dokumen (idempotent).
- Panggilan Openbravo tidak pernah di dalam transaksi database; hasilnya dicatat di transaksi sistem terpisah.
- Pemetaan kosong / data ditolak = manual review (tidak di-retry membabi buta); gangguan jaringan = retry bertahap.
- Stok POS = snapshot Openbravo; harga baru = versi baru; customer unik per ID Openbravo.

## 6. Security rules
- Kredensial Openbravo hanya environment server; frontend tidak pernah menerimanya (§38). Simulator ditolak di produksi.
- Status sync & nomor dokumen hanya bisa diubah konteks sistem (pos_system); kasir/admin tidak bisa memalsukan "terkirim".
- Lihat antrean: `sync.view`; jalankan/coba lagi: `sync.manage` (level organisasi); pemetaan: `configuration.manage`.
- Payload & upsert master hanya dapat dijalankan role sistem; semua kejadian sync di audit log.

## 7. Test cases
| Suite | Jumlah |
|---|---|
| SQL sync (`test_14`) | 35 asersi (total SQL 443) |
| Backend `SyncIT` | 3 test: lunas → antre → manual review (pemetaan kosong) → isi pemetaan → coba lagi → terkirim (POSTED, nomor dokumen, log); gagal sementara → jadwal retry ±30 dtk, sale tetap PAID; sinkron master customer & stok + validasi + izin |
| Frontend | type-check & build; 28 test |

## 8. Known limitations
- Modul/web service impor dokumen di sisi Openbravo belum ada di repo ini; kontrak di OPENBRAVO.md (B57).
- Nama field JSON REST Openbravo perlu diverifikasi pada instance Anda (B57).
- Sinkron master belum terjadwal otomatis; customer belum dipilih di transaksi; promosi belum (B62).
- Mode offline (§35) di Phase 10.

## 9. How to run
`docker compose up --build` (profile local = simulator). Lakukan transaksi lunas → admin `admin@demo.local` → menu
**Sinkronisasi**: penjualan terkirim (nomor `SIM/SO/…`) dalam ±15 detik atau tekan **Proses antrean sekarang**; jalankan
**Sinkron stok/harga/produk/customer**. Menu **Pemetaan Openbravo** untuk ID. Produksi: isi `POS_OPENBRAVO_*` di `.env`.

## 10. How to rollback
Aplikasi: deploy image sebelumnya (antrean berhenti diproses; transaksi tetap berjalan). Database (tanpa data produksi):
drop trigger antrean & fungsi V018, tabel `sync_logs`, `sync_jobs`, `customers`, `openbravo_mappings`, kolom dokumen
Openbravo; kembalikan `tg_sale_guard` (V013) dan `tg_return_guard` (V017); hapus baris V018 di `flyway_schema_history`.
Di production gunakan forward-fix.
