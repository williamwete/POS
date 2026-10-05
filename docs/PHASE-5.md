# Milestone Phase 5 — Payment

Tanggal: 2026-10-05 · Format §108.

## 1. What was implemented
- **Metode pembayaran** yang dapat dikonfigurasi (§22): Tunai, Kartu Debit, Kartu Kredit, QRIS, E-Wallet,
  Transfer Bank — dibuat otomatis per organisasi; halaman admin **Metode pembayaran**.
- **Tunai** dengan uang diterima, jumlah diterapkan, dan **kembalian** tersimpan terpisah (§24); tombol nominal cepat.
- **Kartu & transfer**: dicatat dengan nomor referensi (kode approval EDC / no. transfer); transfer wajib approval supervisor.
- **QRIS & e-wallet**: pembayaran PENDING dengan kode QR, menunggu konfirmasi penyedia (callback bertanda tangan atau
  polling server) — tombol "sudah bayar" tidak membuat lunas (§64). Opsi **QRIS statis**: konfirmasi manual dengan
  nomor referensi + approval supervisor, hanya bila diaktifkan admin.
- **Split payment** (§23): beberapa pembayaran untuk satu transaksi; status sale `CHECKOUT` → `PAYMENT_PENDING` → `PAID`
  diturunkan database.
- **Status pembayaran**: PENDING, PAID, FAILED, CANCELLED (REFUNDED di Phase 8); kedaluwarsa otomatis.
- Pembatalan pembayaran sebelum lunas (pembalikan tunai tercatat di laci kas).
- Layar **Lunas** dengan kembalian besar; struk menampilkan pembayaran, kembalian, dan "LUNAS".
- Simulator penyedia pembayaran untuk pengembangan (local/test saja).

## 2. Files created/changed
- `db/migration/V013__payments.sql`, `db/tests/test_10_payments.sql`, `db/tests/_helpers.sql`, `test_09` (aturan PAID)
- `backend/.../payment/*` (service, repository, controller, DTO, dev controller), `payment/gateway/*`
  (kontrak penyedia, tanda tangan callback, simulator), `SaleService`/`SaleRepository`/`SaleDtos` (approval
  `PAYMENT_CONFIRM`, kolom pembayaran, struk), `ErrorCode`, `GlobalExceptionHandler`, `SecurityConfig`
  (callback publik), `PosProperties`, `application.yml`
- `backend/src/test/.../PaymentsIT.java`
- `frontend/src/modules/pos/PaymentPanel.vue`, `QrPaymentDialog.vue`, `PaidPanel.vue`, `paymentFormat.ts`,
  `modules/admin/PaymentMethodsPage.vue`, `stores/payment.ts`, struk, dialog approval, tipe API; dependensi `qrcode`
- Docs: API, DATABASE, ASSUMPTIONS (B33–B39), TESTING, README, `.env.example`

## 3. Database migrations
V013: `payment_methods`, `payments`, kolom pembayaran di `sales`, approval `PAYMENT_CONFIRM`, izin `payment.approve`
(SUPER_ADMIN, STORE_MANAGER, SUPERVISOR), movement `CASH_SALE_REVERSAL`, setting `payment_pending_timeout_minutes`,
guard sale & approval diperbarui, RLS.

## 4. API endpoints
Lihat [API.md](API.md) bagian pembayaran (10 endpoint, termasuk callback penyedia & simulator dev).

## 5. Business rules
- **PAID hanya bila Σ pembayaran sukses ≥ grand total dan tidak ada yang PENDING** — dihitung database; tidak ada
  jalur yang bisa membuat "sale PAID tanpa payment" atau "payment PAID tanpa sale" (§63: satu transaksi database).
- Tunai: diterapkan = min(uang diterima, sisa tagihan); kembalian = diterima − diterapkan; cash movement `CASH_SALE`
  = jumlah diterapkan (A5). Non-tunai tidak boleh melebihi sisa tagihan.
- Selama ada pembayaran PENDING, tidak bisa menambah pembayaran yang melebihi tagihan.
- `clientPaymentId` unik: request yang dikirim ulang menghasilkan pembayaran yang sama (§66, §79).
- Callback penyedia: tanda tangan HMAC + timestamp ±5 menit, jumlah harus sama persis, idempoten; diproses sebagai
  aktor SYSTEM dan dicatat di audit. Callback sah tetap diterima walau terminal kasir terkunci.
- Pembayaran tidak pernah dihapus; setelah lunas tidak bisa dibatalkan (refund Phase 8). Void/ubah keranjang ditolak
  selama ada pembayaran aktif.

## 6. Security rules
- Hanya kasir pemilik transaksi (session OPEN, sedang WORKING) yang menerima pembayaran; RLS + trigger.
- Konfirmasi manual & transfer memerlukan approver lain dengan `payment.approve` dan rank ≥ SUPERVISOR.
- Endpoint callback satu-satunya endpoint publik baru; tanpa tanda tangan valid tidak menyentuh database.
- Simulator & endpoint dev ditolak di luar profile local/test (aplikasi gagal start bila dikonfigurasi di prod).
- Konfigurasi metode hanya `configuration.manage` level organisasi; kode/jenis metode tidak bisa diubah.

## 7. Test cases
| Suite | Jumlah |
|---|---|
| SQL pembayaran (`test_10`) | 48 asersi (total SQL 301) |
| Backend `PaymentsIT` | 10 test: tunai & kembalian + struk + audit, §78 split tunai+QRIS, split tunai+debit & duplikat, callback QRIS (tanda tangan salah/kedaluwarsa/jumlah beda/idempoten), simulator e-wallet, batal & pembalikan, transfer dengan approval, aturan status & kepemilikan, konfigurasi metode |
| Frontend | 2 test baru (nominal cepat, ID pembayaran); total 26 |

## 8. Known limitations
- Penyedia QRIS/e-wallet produksi belum dihubungkan (B34) — gunakan mode QRIS statis atau tambahkan implementasi penyedia.
- EDC kartu tidak terintegrasi; kasir mengetik kode approval EDC.
- Metode pembayaran berlaku untuk seluruh organisasi (belum per outlet).
- Refund/void setelah lunas: Phase 8. Laporan per metode pembayaran: Phase 7/11.
- Backend integration test berjalan di CI.

## 9. How to run
`docker compose up --build` (profile local memakai simulator pembayaran). Kasir: Clock in → Buka kasir → Transaksi →
pindai barang → Checkout → pilih **QRIS** sebagian → **Simulasikan dibayar** → sisanya **Tunai** (pilih nominal
cepat) → layar Lunas menampilkan kembalian → **Cetak struk**. Admin `admin@demo.local` → **Metode pembayaran**.
Produksi: set `POS_PAYMENT_GATEWAY` dan `POS_PAYMENT_CALLBACK_SECRET` (lihat `.env.example`).

## 10. How to rollback
Aplikasi: deploy image sebelumnya (UI pembayaran hilang; transaksi kembali berhenti di CHECKOUT). Database (tanpa data
produksi): drop `payments`, `payment_methods`, kolom pembayaran `sales`, kembalikan fungsi `tg_sale_guard` &
`tg_approval_guard` dari V012 serta constraint `approvals_action_ck` & cash movement dari V010, hapus izin
`payment.approve` dan setting `payment_pending_timeout_minutes`, lalu baris V013 di `flyway_schema_history`.
Di production gunakan forward-fix.
