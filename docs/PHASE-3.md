# Milestone Phase 3 — Cashier Session

Tanggal: 2026-10-02 · Format §108.

## 1. What was implemented
- **Buka kasir** (§14): kasir yang sudah clock in memilih terminal lalu menghitung uang laci per pecahan;
  modal awal = jumlah hitungan, dihitung server dari master denominasi (§13, §76).
- **Cash count** tengah shift (blind count) dengan rincian pecahan; expected cash & selisih hanya untuk supervisor.
- **Session** aktif per terminal & per karyawan; tawaran **melanjutkan session** saat login ulang (§6).
- **Session lock**: kunci terminal manual, otomatis saat idle (`terminal_idle_lock_minutes`), saat istirahat,
  dan saat supervisor force clock out. Buka kunci wajib **memasukkan password lagi** (ditegakkan database).
- Batal buka kasir (salah terminal / salah hitung) selama belum ada aktivitas kas.
- **Clock out ditolak selama kasir masih terbuka** (§55, §75) — menyelesaikan B15 dari Phase 2.
- Halaman supervisor **Sesi kasir**: session per business date, modal awal, kas seharusnya, hitungan & selisih.
- Audit: `OPEN_CASHIER`, `CASH_COUNT`, `CASHIER_LOCK`, `CASHIER_UNLOCK`, `CANCEL_CASHIER` (§47).

## 2. Files created/changed
- `db/migration/V010__cashier_sessions.sql`, `db/tests/test_08_cashier_session.sql`, `db/tests/_helpers.sql`
- `backend/.../cashier/*` (DTO, repository, service, controller); `AttendanceService` (blok clock out, audit kunci);
  `RlsTransactionManager` (klaim `auth_time`), `LocalTokenService` (klaim `amr`), `ErrorCode`, `GlobalExceptionHandler`
- `backend/src/test/.../CashierSessionIT.java`, `db/AuthTimeTest.java`; helper kasir/terminal baru di `IntegrationTestBase`
- `frontend/src/modules/cashier/*`, `stores/cashier.ts`, `utils/money.ts`, `composables/useIdleLock.ts`,
  layout (status kasir, layar kunci), beranda, pilih terminal (lanjutkan session), kartu & layar istirahat
- Docs: API, DATABASE, ASSUMPTIONS (B14, B15 diperbarui; B18–B24), TESTING, README

## 3. Database migrations
V010: `cash_denominations` (default IDR otomatis per organisasi), `cashier_sessions`, `cash_counts`,
`cash_count_items`, `cash_movements` (tipe & tanda sesuai §25, dipakai penuh mulai Phase 4–6),
fungsi `session_expected_cash` (§49), `finalize_cash_count`, `jwt_auth_time`, trigger penjaga,
constraint trigger konsistensi modal awal, RLS; setting `terminal_idle_lock_minutes`.

## 4. API endpoints
Lihat [API.md](API.md) bagian cashier session (9 endpoint).

## 5. Business rules
- Buka kasir hanya bila kehadiran **WORKING di outlet terminal**, terminal aktif, dan belum ada session
  aktif di terminal itu (§74) maupun milik karyawan itu (B19). Dijamin unique index, aman untuk request paralel.
- Modal awal **tidak pernah dikirim client**: server menjumlahkan item hitungan; saat COMMIT database
  memastikan `opening_cash` = total hitungan OPENING = movement `OPENING_CASH`. Modal awal tidak bisa diubah.
- Hitungan kas & movement append-only; item hanya bisa ditambah dalam transaksi pembuat hitungan;
  nilai pecahan disalin dari master (client hanya mengirim jumlah lembar).
- Expected cash = jumlah movement kas (non-tunai tidak pernah menjadi movement kas).
- Session terkunci: tidak bisa hitung kas (dan transaksi mulai Phase 4). Buka kunci hanya oleh pemilik,
  sedang WORKING, dan dengan token hasil login setelah waktu kunci.
- Clock out normal ditolak selama session OPEN/ON_BREAK/CLOSING; force clock out supervisor tetap bisa
  dan mengunci session.

## 6. Security rules
- Buka kasir hanya untuk diri sendiri dengan `cashier.open` di outlet terminal (RLS + service).
- Kasir hanya melihat session sendiri; `cashier.view` melihat session outlet beserta expected cash & selisih.
- Supervisor tidak bisa membuka kunci terminal kasir lain (RLS + trigger).
- Phase 3 hanya mengizinkan movement `OPENING_CASH`; cash in/out baru dibuka Phase 6.
- Semua POST idempotent; tidak ada DELETE.

## 7. Test cases
| Suite | Jumlah |
|---|---|
| SQL cashier session (`test_08`) | 42 asersi (total SQL 209) |
| Backend `CashierSessionIT` | 8 test: modal awal dari denominasi + buka kedua ditolak + clock out diblokir + audit, terminal dipakai kasir lain, validasi hitungan & izin, kunci/buka kunci dengan login ulang, istirahat mengunci + batal + clock out, blind count, force clock out mengunci, idempotent |
| Backend `AuthTimeTest` | 2 test klaim `amr` |
| Frontend | 3 test baru (format rupiah, total hitungan, baris request); total 22 |

## 8. Known limitations
- Tutup kasir, X/Z report, cash up: Phase 7. Session yang terkunci karena force clock out menunggu Phase 7
  (atau kasir clock in lagi lalu membuka kunci).
- Handover kasir (`cashier_handover_enabled`) belum diimplementasikan.
- Master denominasi belum bisa dikelola dari UI (B22).
- Kunci idle bergantung pada browser yang terbuka (B24).
- Backend integration test baru berjalan di CI (Maven Central diblokir di lingkungan pengembangan ini).

## 9. How to run
`docker compose up --build`. Login `cashier.jkt@demo.local` / `Demo#12345` → pilih POS-JKT-01 →
**Clock in** → **Buka kasir**, isi jumlah lembar → **Buka kasir**. Coba **Kunci terminal** lalu buka dengan
password, dan **Clock out** (akan ditolak selama kasir terbuka). Supervisor `supervisor.jkt@demo.local` →
menu **Sesi kasir**.

## 10. How to rollback
Aplikasi: deploy image sebelumnya. Database (tanpa data produksi): `DROP TABLE pos.cash_movements,
pos.cash_count_items, pos.cash_counts, pos.cashier_sessions, pos.cash_denominations CASCADE;`, kembalikan
`pos.tg_attendance_guard` dari V009, hapus trigger `attendance_lock_session` & `organizations_default_denominations`,
constraint `terminals_id_outlet_uk` & `attendance_id_employee_uk`, setting `terminal_idle_lock_minutes`,
lalu hapus baris V010 di `flyway_schema_history`. Di production gunakan forward-fix.
