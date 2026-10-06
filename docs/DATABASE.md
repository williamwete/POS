# Database

## Role
| Role | Login | Fungsi |
|---|---|---|
| owner migration (`postgres` di Supabase) | ya | menjalankan Flyway, memiliki semua objek |
| `pos_api` | ya (password diset operator) | koneksi runtime backend; `NOINHERIT`, tanpa privilege tabel |
| `pos_app_user` | tidak | konteks request user; semua tabel dilindungi RLS |
| `pos_system` | tidak | konteks job sistem; dipakai sangat terbatas dan selalu diaudit |

Setelah migration pertama di Supabase/production, set password `pos_api` (sekali, oleh operator):
```sql
ALTER ROLE pos_api WITH LOGIN PASSWORD '<password kuat dari secret manager>';
```
Password ini **tidak** ada di migration. Seed demo (`db/seed`) hanya untuk lokal/test.

## Supabase
- Semua tabel di schema `pos`. **Jangan** tambahkan `pos` ke *Exposed schemas* PostgREST.
  Migration V001 juga mencabut akses `anon` dan `authenticated` dari schema ini.
- `pos.users.auth_user_id` → `auth.users(id)` (dikelola Supabase Auth).
- Folder `db/local` (shim tabel `auth.users`) **tidak pernah** dijalankan di Supabase.

## Migration
| File | Isi |
|---|---|
| V001 | schema, role, trigger umum (touch/version, append-only) |
| V002 | organizations, outlets, warehouses, devices, terminals |
| V003 | employees, users, roles (dengan rank), permissions, user_roles, user_outlets |
| V004 | audit_logs (append-only), idempotency_keys, setting_definitions, settings |
| V005 | katalog permission & 7 role sistem |
| V006 | fungsi keamanan (single source of truth otorisasi), get_setting, business_date |
| V007 | grant & RLS policy |
| V008 | perbaikan policy SELECT outlets/users agar `INSERT ... RETURNING` oleh admin tidak ditolak (bug ditemukan CI) |
| V009 | attendance & attendance_breaks: waktu dari server, trigger transisi status, satu kehadiran terbuka per karyawan, RLS |
| V010 | cash_denominations, cashier_sessions, cash_counts, cash_count_items, cash_movements: satu session aktif per terminal & karyawan, modal awal = hitungan OPENING = movement OPENING_CASH (constraint trigger saat commit), session lock dengan syarat login ulang, clock out ditolak selama session aktif, RLS; setting `terminal_idle_lock_minutes` |
| V011 | Cache master dari Openbravo: `tax_rates`, `product_categories`, `products`, `product_barcodes`, `product_price_cache` (periode berlaku, harga outlet > organisasi), `product_stock_cache`; fungsi `product_price`; hanya `pos_system` yang menulis; setting `prices_include_tax` |
| V012 | `sales`, `sale_items`, `sale_discounts`, `approvals` (sekali pakai, 2 menit, approver ≠ peminta, izin & rank), `receipts`, `terminal_receipt_sequences`; trigger menghitung harga/pajak/total, validasi diskon & stok saat checkout (advisory lock per produk), nomor struk `<terminal>-<YYYYMMDD>-<urut>`; batal buka kasir ditolak bila sudah ada penjualan; RLS |
| V013 | `payment_methods` (default 6 metode per organisasi), `payments` (diterapkan/diterima/kembalian, PENDING/PAID/FAILED/CANCELLED/REFUNDED, data gateway), kolom `sales.paid_amount/change_amount/paid_at`; status sale diturunkan dari pembayaran (PAID hanya bila Σ sukses ≥ total), cash movement `CASH_SALE`/`CASH_SALE_REVERSAL` otomatis, approval `PAYMENT_CONFIRM`, izin `payment.approve`, setting `payment_pending_timeout_minutes`; RLS |
| V014 | `products.image_url` (path aplikasi `/…` atau `https://`, divalidasi constraint); seed demo memakai ilustrasi di `frontend/public/products` |
| V015 | Manajemen kas & tutup kasir: kas masuk/keluar/petty cash oleh pemegang laci (alasan wajib, saldo tidak boleh negatif, approval `CASH_OUT` di atas `cash_out_approval_threshold`), `CASH_ADJUSTMENT` oleh `cash.cash_adjustment` (bukan laci sendiri); transisi OPEN/ON_BREAK → CLOSED dengan hitungan CLOSING di transaksi yang sama, expected & selisih dihitung trigger, alasan selisih + approval `CASH_DIFFERENCE` di atas `cash_difference_approval_threshold`, blokir transaksi terbuka (`allow_close_with_open_orders`) & pembayaran pending, movement `CLOSING_CASH`; approval kas terikat `cashier_session_id`; supervisor dapat menutup laci kasir lain (policy `cashier_sessions_close_other`); fungsi `session_open_orders`, `session_pending_payments` |
| V016 | `cashups` (cash-up / Z report, append-only, nomor Z berurutan per terminal, snapshot laporan jsonb + angka ringkasan) dibuat trigger AFTER saat session menjadi CLOSED, dengan constraint trigger deferred yang menolak session CLOSED tanpa cash-up (§85); fungsi `compute_shift_report` (satu sumber angka X & Z) dan `x_report` (hanya `cashier.view`); backfill cash-up untuk session yang sudah ditutup di Phase 6 |
| V017 | `returns`, `return_items`, `refunds`, `terminal_return_sequences`: retur merujuk transaksi asli (tidak diubah), sisa jumlah per baris dijaga trigger dengan row lock transaksi asal, nilai refund dari nilai bersih baris (sisa terakhir = sisa nilai), approval `REFUND` (izin `sale.refund`, rank ≥ 50) atau persetujuan dari akun approver, refund dialokasikan ke pembayaran asli + cash movement `CASH_REFUND`, append-only; tutup kasir ditolak bila ada retur menunggu; `return_lookup`; Z report menghitung refund |

Aturan: tidak ada perubahan schema manual; tidak ada `DROP TABLE` di production; Flyway `clean`
dinonaktifkan. Data master dinonaktifkan (`active=false`), tidak dihapus (trigger menolak DELETE
pada organizations, outlets, terminals, employees, users).

## Rollback
Flyway Community tidak mendukung undo otomatis. Rollback dilakukan dengan migration korektif
baru (forward-fix). Untuk Phase 1 pada database kosong, rollback penuh =
`DROP SCHEMA pos CASCADE; DROP ROLE pos_api, pos_app_user, pos_system;` lalu hapus baris
Flyway di `flyway_schema_history`. **Hanya** untuk lingkungan tanpa data produksi.

## Backup (§93)
- Supabase: aktifkan Point-in-Time Recovery (paket Pro ke atas) + `pg_dump` harian schema `pos`
  ke storage terpisah (retensi ≥ 30 hari).
- Uji restore minimal bulanan ke database terpisah, lalu jalankan `db/tests/run.sh` terhadap
  hasil restore (variabel `POS_TEST_DB`). Backup yang belum pernah diuji restore tidak dianggap andal.

## Retensi
- `audit_logs`: tidak dihapus oleh aplikasi (append-only). Arsip ke cold storage diputuskan
  bersama auditor.
- `idempotency_keys`: kedaluwarsa 7 hari (`expires_at`); job pembersih dibuat di Phase 10.
- Transaksi finansial (mulai Phase 4): tidak pernah dihapus karena umur.
