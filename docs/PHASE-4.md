# Milestone Phase 4 — Sales

Tanggal: 2026-10-05 · Format §108.

## 1. What was implemented
- **Produk**: cache produk, kategori, barcode (satu produk bisa banyak barcode), harga per outlet/organisasi
  dengan periode berlaku, tarif pajak, dan stok — semuanya cache dari Openbravo (§3, §16, §17, §33).
  Data demo: 12 produk termasuk produk timbangan (kg) dan produk bebas PPN.
- **Layar kasir (POS)**: pindai barcode / cari nama-SKU, keranjang, ubah jumlah, void baris dengan alasan,
  diskon per baris & per transaksi, ubah harga, tahan & lanjutkan transaksi, checkout, struk 80 mm (§15, §18, §26).
  Pintasan: F2 kolom pindai, F4 tahan, F9 checkout.
- **Approval supervisor di terminal** untuk diskon di atas batas kasir, ubah harga, dan void setelah checkout (§20, §27).
- **Checkout**: validasi ulang diskon, approval, dan stok di database, lalu alokasi nomor struk
  `<kode terminal>-<YYYYMMDD>-<urut>` (§31). Pembayaran menyusul Phase 5.
- Audit: pembuatan transaksi, item, void item, diskon, ubah harga, approval, tahan/lanjut, checkout, void, cetak struk (§47).
- Batal buka kasir kini ditolak bila session sudah memiliki penjualan (melengkapi B23).

## 2. Files created/changed
- `db/migration/V011__products_prices_stock.sql`, `V012__sales.sql`, `db/seed/R__demo_seed.sql` (produk demo),
  `db/tests/test_09_sales.sql`, `db/tests/_helpers.sql`
- `backend/.../product/*`, `backend/.../sale/*` (CartCalculator, SaleService, SaleRepository, SaleController,
  ApprovalService, DTO), `auth/provider/*` (verifikasi password approver), `RateLimitFilter`, `ErrorCode`,
  `GlobalExceptionHandler`
- `backend/src/test/.../SalesIT.java`, `sale/CartCalculatorTest.java`
- `frontend/src/modules/pos/*` (PosPage, dialog diskon/harga/alasan/approval/transaksi ditahan/struk),
  `stores/sale.ts`, router, layout, tipe API
- Docs: API, DATABASE, ASSUMPTIONS (B25–B32), TESTING, README

## 3. Database migrations
- V011: tabel cache master + `pos.product_price()` (satu-satunya sumber harga transaksi); hanya `pos_system` menulis.
- V012: tabel penjualan, approval, struk & urutan nomor struk; trigger penjaga; `available_to_sell`,
  `sale_stock_check`, `sale_discount_check`, `allocate_receipt_no`, `record_receipt_print`; RLS.

## 4. API endpoints
Lihat [API.md](API.md) bagian produk & penjualan (2 endpoint produk, 20 endpoint penjualan, 1 endpoint approval).

## 5. Business rules
- **Harga & total tidak pernah dari client.** Database mengambil harga berlaku, menghitung gross, diskon,
  pajak (default harga termasuk PPN), dan total per baris & transaksi; nilai turunan dihitung ulang setiap perubahan.
- Transaksi hanya bisa dibuat/diubah oleh pemegang cashier session yang OPEN (tidak terkunci) dan sedang WORKING.
  Satu keranjang aktif per session; yang lain harus ditahan.
- `clientTransactionId` unik per organisasi (anti transaksi ganda); semua aksi idempotent.
- Jumlah desimal hanya untuk produk yang diizinkan (timbangan).
- Diskon: persen atau nominal, wajib alasan; matriks batas kasir/supervisor/manager (B30). Approval sekali pakai,
  terikat ke transaksi/baris/nilai, berlaku 2 menit, approver ≠ peminta.
- Ubah harga wajib alasan dan approval (setting `require_supervisor_for_price_override`).
- Checkout memeriksa stok tersedia = snapshot Openbravo − penjualan lokal yang belum tersinkron (A6, B29);
  checkout paralel produk yang sama diserialkan.
- Status bisnis (`DRAFT`, `HELD`, `CHECKOUT`, `VOID`, `CANCELLED`, …) terpisah dari status sync (§100).
- Tidak ada DELETE; koreksi = void baris / void transaksi dengan alasan (B32).

## 6. Security rules
- Master produk/harga/stok read-only bagi user; ditulis hanya oleh job sistem.
- RLS: kasir hanya melihat & mengubah transaksi di session miliknya; `sale.view` melihat transaksi outlet.
- Approval diverifikasi database (izin + rank approver di outlet tersebut); password approver tidak disimpan/di-log,
  sesi login yang terbentuk saat verifikasi langsung dicabut, endpoint dibatasi rate limit.

## 7. Test cases
| Suite | Jumlah |
|---|---|
| SQL penjualan (`test_09`) | 44 asersi (total SQL 253) |
| Backend `SalesIT` | 6 test: §77 dua item → checkout → struk; barcode & penggabungan baris; matriks approval diskon; ubah harga; tahan/lanjut/batal/void; stok, session & duplikat |
| Backend `CartCalculatorTest` | 6 test pembulatan & alokasi diskon |
| Frontend | total 24 test |

## 8. Known limitations
- Pembayaran (tunai, debit, kredit, QRIS, e-wallet, split) dan status `PAID`: Phase 5. Struk sebelum lunas bertanda
  "BELUM DIBAYAR".
- Promosi otomatis (`source = PROMOTION`) belum diimplementasikan; hanya diskon manual.
- Data produk/harga/stok baru dari seed; sync Openbravo di Phase 9.
- Pencetakan struk memakai dialog cetak browser (80 mm); integrasi printer ESC/POS belum ada.
- Backend integration test berjalan di CI (Maven Central tidak terjangkau dari lingkungan pengembangan ini).

## 9. How to run
`docker compose up --build`. Login `cashier.jkt@demo.local` / `Demo#12345` → pilih POS-JKT-01 → Clock in →
Buka kasir → menu **Transaksi**. Pindai mis. `8990000000017` atau cari "teh". Diskon di atas 5 % meminta
approval: isi `supervisor.jkt@demo.local` / `Demo#12345` di dialog approval.

## 10. How to rollback
Aplikasi: deploy image sebelumnya. Database (tanpa data produksi): drop tabel V012 lalu V011
(`receipts`, `terminal_receipt_sequences`, `approvals`, `sale_discounts`, `sale_items`, `sales`, lalu tabel cache),
hapus trigger `cashier_sessions_sales_check`, setting `prices_include_tax`, dan baris V011–V012 di
`flyway_schema_history`. Di production gunakan forward-fix.
