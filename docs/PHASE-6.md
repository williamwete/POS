# Milestone Phase 6 — Manajemen kas + Tutup kasir

Tanggal: 2026-10-06 · Format §108. Tutup kasir dimajukan dari Phase 7 (B42); X/Z report tetap Phase 7.

## 1. What was implemented
- **Kas masuk / kas keluar / petty cash** (§25) oleh pemegang laci: nominal, alasan wajib, tidak boleh melebihi isi
  laci. Kas keluar di atas batas outlet meminta **persetujuan supervisor** langsung di terminal (sekali pakai,
  nominal persis).
- **Penyesuaian kas** (restricted) oleh store manager untuk laci kasir lain, dengan alasan, tercatat atas namanya.
- **Tutup kasir** (§48–§51): hitung uang per pecahan tanpa melihat catatan sistem → server menampilkan uang dihitung,
  kas seharusnya, dan selisih → alasan selisih (dan approval supervisor bila melewati batas) → laci ditutup →
  tombol **Clock out sekarang**.
- Tutup kasir ditolak bila masih ada transaksi terbuka/ditahan/checkout atau pembayaran menunggu konfirmasi;
  keranjang kosong sisa layar dibatalkan otomatis.
- Supervisor/manager dapat **menutup laci kasir lain** (mis. kasir pulang atau kehadirannya ditutup paksa) dari
  halaman **Sesi kasir**, yang kini juga menampilkan **mutasi kas** dan hasil penutupan.
- Tombol clock out saat kasir masih terbuka sekarang mengarahkan ke **Tutup kasir**.

## 2. Files created/changed
- `db/migration/V015__cash_management_close.sql`, `db/seed/R__demo_seed.sql` (ambang kas keluar demo),
  `db/tests/test_11_cash_management.sql`, `db/tests/_helpers.sql`, `test_08` (aturan Phase 3 diperbarui)
- `backend/.../cashier/CashierService.java`, `CashierRepository.java`, `CashierController.java`, `CashierDtos.java`,
  `CashApprovalService.java` (baru), `common/error/ErrorCode.java`, `GlobalExceptionHandler.java`,
  `common/web/RateLimitFilter.java`
- `backend/src/test/.../CashManagementIT.java`
- `frontend/src/modules/cashier/CloseCashierPage.vue`, `CashMovementDialog.vue`, `CashApprovalDialog.vue` (baru),
  `CashierCard.vue`, `OutletCashierPage.vue`, `cashierFormat.ts` (+ spec), `modules/attendance/AttendanceCard.vue`,
  `stores/cashier.ts`, `types/api.ts`, `router/index.ts`, `utils/errorMessages.ts`
- Docs: API, DATABASE, ASSUMPTIONS (B42–B47), TESTING, README

## 3. Database migrations
V015: setting `cash_out_approval_threshold` & `allow_close_with_open_orders`; approval kas (`CASH_OUT`,
`CASH_DIFFERENCE`) terikat `cashier_session_id`; kolom penutupan di `cashier_sessions` (`closing_count_id`, alasan,
keterangan, approval) dan `reason_code/approval_id/approved_by` di `cash_movements`; trigger session, hitungan,
movement, dan approval diperbarui; RLS insert movement/hitungan dan update session (termasuk supervisor menutup laci
lain); fungsi `session_open_orders`, `session_pending_payments`.

## 4. API endpoints
6 endpoint baru — lihat [API.md](API.md) bagian "Manajemen kas & tutup kasir": mutasi, kas masuk/keluar,
penyesuaian, pratinjau tutup, tutup, dan approval kas.

## 5. Business rules
- **Expected cash** = Σ movement laci (modal + penjualan tunai − pembalikan + kas masuk − kas keluar − petty cash ±
  penyesuaian). Contoh §82: 1.000.000 + 4.500.000 − 100.000 = 5.400.000; hitungan 5.400.000 → selisih 0 (diuji SQL).
- Expected cash, uang dihitung, dan selisih **dihitung database** di trigger penutupan; client tidak bisa mengisi
  angka penutupan. Uang dihitung = Σ (nilai pecahan master × jumlah lembar).
- Selisih ≠ 0 wajib alasan (`OTHER` wajib keterangan ≥ 5 karakter); |selisih| > `cash_difference_approval_threshold`
  wajib approval `CASH_DIFFERENCE` dari orang lain dengan nominal persis.
- Kas keluar/petty cash > `cash_out_approval_threshold` wajib approval `CASH_OUT`; laci tidak bisa negatif.
- Setelah CLOSED: tidak ada movement, hitungan, atau transaksi baru; session tidak bisa dibuka lagi; clock out diizinkan.
- Uang laci dicatat keluar sebagai `CLOSING_CASH` (tidak memengaruhi expected).

## 6. Security rules
- Kas masuk/keluar hanya pemegang laci dengan izin `cash.cash_in`/`cash.cash_out`, session OPEN (terminal tidak terkunci).
- Penyesuaian hanya `cash.cash_adjustment` (default STORE_MANAGER) dan tidak untuk laci sendiri; supervisor tidak bisa.
- Menutup laci orang lain hanya `cashier.close` + `cash.approve_difference` di outlet tsb.; kasir lain/outlet lain ditolak.
- Approval: password diverifikasi tanpa transaksi DB terbuka, tidak disimpan/di-log; endpoint dibatasi rate limit seperti
  login; approver ≠ peminta, izin `cash.approve_difference`, rank ≥ SUPERVISOR; sekali pakai, 2 menit.
- Semua aksi tercatat di audit: `CASH_IN`, `CASH_OUT`, `PETTY_CASH`, `CASH_ADJUSTMENT`, `APPROVAL`, `CLOSE_PREVIEW`,
  `CLOSE_CASHIER` (dengan rincian pecahan, selisih, approver).
- Setiap aturan ditegakkan trigger + RLS sehingga berlaku juga bila service dilewati.

## 7. Test cases
| Suite | Jumlah |
|---|---|
| SQL manajemen kas (`test_11`) | 51 asersi (total SQL 356) |
| Backend `CashManagementIT` | 5 test: §82 tutup tanpa selisih + clock out + blind count + audit; kas keluar & approval (salah password, nominal lain, sekali pakai, saldo kurang); selisih → alasan → approval; transaksi terbuka memblokir & keranjang kosong dibatalkan; penyesuaian manager & supervisor menutup laci lain |
| Frontend | 1 test baru (format selisih); total 27 |

## 8. Known limitations
- X/Z report, serah terima kasir (status `CLOSING`/HANDOVER), dan laporan selisih per kasir: Phase 7/11.
- Penyetoran ke brankas/bank belum menjadi dokumen tersendiri (B47).
- Pratinjau tutup kasir memperlihatkan selisih kepada kasir setelah ia menghitung; pratinjau berulang terlihat di audit (B43).
- Backend integration test berjalan di CI.

## 9. How to run
`docker compose up --build`. Kasir `cashier.jkt@demo.local`: Clock in → Buka kasir → transaksi tunai →
**Kas masuk/keluar** (kas keluar > Rp 100.000 meminta email + password `supervisor.jkt@demo.local`) → **Tutup kasir**
→ hitung uang → periksa selisih (selisih > Rp 20.000 meminta persetujuan) → **Tutup kasir** → **Clock out sekarang**.
Supervisor: **Sesi kasir** → pilih kasir → mutasi kas / **Tutup laci ini**. Manager `manager@demo.local`: **Penyesuaian kas**.

## 10. How to rollback
Aplikasi: deploy image sebelumnya (tombol kas & tutup kasir hilang; session yang sudah CLOSED tetap tersimpan).
Database (tanpa data produksi): kembalikan fungsi `tg_cashier_session_guard`, `tg_cash_count_guard`,
`tg_cash_movement_guard` dari V010 dan `tg_approval_guard` dari V013, policy `cash_movements_insert`,
`cash_counts_insert`, `cashier_sessions_update_own`, `approvals_select/insert`; drop policy
`cashier_sessions_close_other`, fungsi `session_open_orders/session_pending_payments`, kolom & constraint baru, dan
setting baru; hapus baris V015 di `flyway_schema_history`. Di production gunakan forward-fix.
