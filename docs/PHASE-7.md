# Milestone Phase 7 — Closing (X report, cash-up, Z report)

Tanggal: 2026-10-06 · Format §108. Tutup kasir & clock out sudah selesai di Phase 6 (B42); fase ini melengkapi laporannya.

## 1. What was implemented
- **X report** (§53): laporan tengah shift — penjualan, pembayaran per metode, dan kas (termasuk kas seharusnya);
  kasir tetap buka. Dibuat supervisor dari halaman **Sesi kasir**.
- **Cash-up / Z report** (§52, §85): dibuat otomatis oleh database saat laci ditutup, dengan nomor Z berurutan per
  terminal; berisi header (outlet, terminal, business date, kasir, session, jam buka/tutup), penjualan (jumlah transaksi,
  kotor, diskon, refund, bersih, pajak), pembayaran (tunai, debit, kredit, QRIS, e-wallet, transfer), kas (modal, penjualan
  tunai, kas masuk/keluar, petty cash, refund tunai, kas seharusnya, kas dihitung, selisih), dan approval (kasir,
  penutup, penyetuju selisih, waktu).
- Tombol **Z report** di layar selesai tutup kasir dan di detail session; cetak 80 mm dengan kolom tanda tangan.
- **Detail transaksi** per session (§54): no struk, waktu, status, total, metode bayar, alasan void.

## 2. Files created/changed
- `db/migration/V016__cashup_reports.sql`, `db/tests/test_12_reports.sql`
- `backend/.../report/ReportService.java`, `ReportRepository.java`, `ReportController.java` (baru),
  `ErrorCode`, `GlobalExceptionHandler`
- `backend/src/test/.../ReportsIT.java`
- `frontend/src/modules/cashier/ShiftReportPaper.vue`, `ShiftReportDialog.vue` (baru), `CloseCashierPage.vue`,
  `OutletCashierPage.vue`, `stores/cashier.ts`, `types/api.ts`
- Docs: API, DATABASE, ASSUMPTIONS (B48–B50), TESTING, README

## 3. Database migrations
V016: tabel `cashups` (append-only, unik per session, nomor Z unik per terminal), fungsi `compute_shift_report` dan
`x_report`, trigger cash-up saat CLOSED + constraint trigger deferred "CLOSED wajib punya cash-up", backfill cash-up
untuk session yang ditutup sebelum migration, RLS.

## 4. API endpoints
4 endpoint baru — lihat [API.md](API.md) bagian "Laporan closing".

## 5. Business rules
- Angka X dan Z berasal dari satu fungsi database; Z disimpan sebagai snapshot sehingga cetak ulang selalu identik.
- Cash-up dibuat dalam transaksi yang sama dengan tutup kasir; bila gagal, penutupan ikut batal (§85 "session CLOSED,
  cashup missing" tidak mungkin). Expected cash di cash-up diperiksa sama dengan angka penutupan.
- X report tidak mengubah session maupun membuat cash-up (§84); hanya untuk session yang masih aktif.
- Penjualan bersih = Σ grand total transaksi lunas; void dihitung terpisah; refund 0 sampai Phase 8.

## 6. Security rules
- X report hanya `cashier.view` (dicek service dan fungsi database) — kasir tidak melihat kas seharusnya selama shift.
- Z report: pemilik session atau `cashier.view` (RLS cash-up mengikuti visibilitas session); kasir/outlet lain tidak bisa.
- Detail transaksi: `cashier.view`, atau pemilik setelah ditutup.
- Cash-up tidak bisa dibuat, diubah, atau dihapus oleh role aplikasi; setiap X report dan cetak Z tercatat di audit.

## 7. Test cases
| Suite | Jumlah |
|---|---|
| SQL laporan (`test_12`) | 20 asersi (total SQL 376) |
| Backend `ReportsIT` | 1 skenario end-to-end: X oleh kasir ditolak, X supervisor & session tetap OPEN, Z belum ada, tutup → Z (nomor, penjualan, pembayaran, kas, approval), detail transaksi, cetak, X pada session tertutup ditolak, kasir lain ditolak, audit |
| Frontend | 27 test (type-check & build) |

## 8. Known limitations
- Serah terima kasir (handover, §32 opsional) belum diaktifkan.
- Laporan harian/outlet (gabungan Z) dan ekspor: Phase 11. Refund di laporan: Phase 8.
- Cetak memakai dialog print browser (printer thermal diatur di sistem operasi).

## 9. How to run
`docker compose up --build`. Supervisor `supervisor.jkt@demo.local` → **Sesi kasir** → pilih kasir aktif → **X report**.
Kasir → **Tutup kasir** → layar selesai → **Z report** → **Cetak**. Session yang sudah tutup → **Z report** dan daftar transaksi.

## 10. How to rollback
Aplikasi: deploy image sebelumnya (tombol laporan hilang; tutup kasir tetap berfungsi). Database (tanpa data produksi):
drop trigger `cashier_sessions_cashup` & `cashier_sessions_requires_cashup`, fungsi `tg_cashier_session_cashup`,
`tg_cashier_session_requires_cashup`, `x_report`, `compute_shift_report`, tabel `cashups`, lalu baris V016 di
`flyway_schema_history`. Di production gunakan forward-fix (cash-up adalah catatan keuangan).
