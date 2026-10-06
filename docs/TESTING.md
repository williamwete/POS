# Testing

| Lapisan | Perintah | Isi |
|---|---|---|
| SQL (RLS & otorisasi) | `./db/tests/run.sh` | 408 asersi: fail-closed, outlet scope (§88), proteksi tulis, anti-eskalasi, audit append-only, idempotency per user, setting & business date, attendance, cashier session (modal awal, kunci terminal, clock out diblokir), penjualan (harga & total dari database, diskon/approval, stok, nomor struk), pembayaran (kembalian, split, gateway, pembalikan, approval), manajemen kas & tutup kasir (kas masuk/keluar, ambang & approval, penyesuaian, §82 expected 5.400.000, selisih & approval, transaksi terbuka/pending, supervisor menutup laci lain, clock out setelah tutup), laporan closing (X report tidak mengubah session & hanya `cashier.view`, cash-up dibuat saat tutup, angka Z per bagian, nomor Z berurutan, cash-up append-only), retur & refund (§86 retur 2 dari 10 dengan transaksi asli utuh, sisa jumlah, approval terminal & akun, alokasi ke pembayaran asli, refund tunai dari laci, tolak, blokir tutup kasir, Z report) |
| SQL statis backend | `python3 backend/scripts/check_sql.py "<conninfo>"` | `PREPARE` setiap SQL di kode Java terhadap DB yang sudah dimigrasi (typo kolom, sintaks) |
| Backend integrasi | `cd backend && ./gradlew test` | Spring Boot penuh + PostgreSQL: login, `/me`, scope, §87 security test, idempotency (termasuk paralel), RLS backstop dari Java, lifecycle user, optimistic lock, attendance, cashier session (§76), penjualan (§77: dua item → checkout → struk; matriks diskon; ubah harga; tahan/lanjut/void; stok & duplikat) + unit test `CartCalculatorTest`; pembayaran (§78: tunai & kembalian, split, QRIS lewat callback bertanda tangan, simulator, pembatalan/pembalikan, transfer dengan approval, konfigurasi metode); manajemen kas (kas keluar & approval, tutup kasir tanpa/dengan selisih, transaksi terbuka, penyesuaian & tutup oleh supervisor, clock out); laporan (§84 X report session tetap OPEN, §85 Z report/cash-up, detail transaksi, cetak ulang); retur (§86, sisa jumlah, approval terminal & akun supervisor, tolak, struk outlet lain, Z report refund) |
| Frontend | `npm run type-check && npm test` | API client, permission store, validasi, format uang & selisih |

## Database test backend
Test integrasi memakai database `pos_it` (dibuat kosong; Flyway mengisi schema + seed):
```bash
createdb pos_it
POS_TEST_DB_URL=jdbc:postgresql://localhost:5432/pos_it \
POS_TEST_DB_OWNER=postgres POS_TEST_DB_OWNER_PASSWORD=... ./gradlew test
```
`db/tests/run.sh` menolak berjalan pada database bernama `*prod*` / `*staging*` karena
melakukan `DROP DATABASE`.

## CI
`.github/workflows/ci.yml` menjalankan ketiga job (database, backend, frontend) pada setiap push
dan pull request.
