# Milestone Phase 1 — Foundation

Tanggal: 2026-10-02 · Format mengikuti §108.

## 1. What was implemented
- **Struktur project**: monorepo `backend/` (Spring Boot 3.5, Java 21), `frontend/` (Vue 3 + Vite),
  `db/` (migration, seed, test SQL), CI GitHub Actions, Docker.
- **Auth**: validasi JWT Supabase (JWKS ES256/RS256 atau HS256 legacy, issuer, audience,
  `role=authenticated`); provider login lokal khusus profile `local`/`test`.
- **User, Role, Permission**: 7 role sistem dengan rank, 32 permission granular, scope outlet
  (org-wide atau per outlet), manajemen user lengkap (buat → akun Supabase Auth, ubah, nonaktif →
  login diblokir, reset password, role & akses outlet).
- **Outlet, Warehouse, Terminal, Device, Employee**: CRUD dengan soft delete dan optimistic lock.
- **RLS** yang benar-benar berlaku untuk request API (`SET LOCAL ROLE` + klaim JWT per transaksi).
- **Audit log** append-only di transaksi yang sama dengan perubahan data.
- **Idempotency** atomik untuk semua POST pembuat data.
- **Konfigurasi** §73 (definisi + override organisasi/outlet) dan fungsi **business date**.
- **Infrastruktur**: envelope response §62, kode error §99, access log terstruktur dengan
  requestId, rate limiting, health/liveness/readiness.
- **UI**: login, pilih outlet & terminal, beranda kasir, admin outlet, terminal & device,
  karyawan, user & akses, role & permission, audit log.

## 2. Files created/changed
- `db/migration/V001–V007`, `db/local/V000`, `db/seed/R__demo_seed.sql`, `db/tests/*`,
  `db/bootstrap/bootstrap_super_admin.sql`
- `backend/src/main/java/com/pirantisolution/pos/**` (common, db, security, audit, idempotency,
  auth, outlet, terminal, employee, user, role, settings), `backend/src/test/**`,
  `backend/scripts/check_sql.py`
- `frontend/src/**` (services, stores, router, layouts, modules, components, utils)
- `docs/*`, `README.md`, `docker-compose.yml`, `.env.example`, `.github/workflows/ci.yml`

## 3. Database migrations
Lihat [DATABASE.md](DATABASE.md#migration). Tabel: organizations, outlets, warehouses, devices,
terminals, employees, users, roles, permissions, role_permissions, user_roles, user_outlets,
audit_logs, idempotency_keys, setting_definitions, settings.

## 4. API endpoints
Lihat [API.md](API.md) (32 endpoint + 2 probe health).

## 5. Business rules
- Satu device browser hanya untuk satu terminal aktif; printer/laci kas harus satu outlet dan
  bertipe benar (FK komposit di DB + validasi service).
- Kode terminal unik global (prefix nomor struk).
- Device yang terpasang di terminal aktif tidak bisa dinonaktifkan.
- Karyawan dengan akun login aktif tidak bisa dinonaktifkan sebelum akunnya dinonaktifkan.
- Role outlet-scoped wajib disertai akses outlet tersebut; akses outlet tidak bisa dicabut
  selama masih ada role di outlet itu.
- Master data tidak bisa dihapus fisik (trigger), hanya dinonaktifkan.
- Business date = waktu lokal outlet − cutoff (default 04:00).

## 6. Security rules
- Tiga lapis: JWT → `AccessService` → RLS, dengan logika permission di satu tempat (fungsi SQL).
- Fail-closed: koneksi backend tanpa konteks user tidak punya privilege tabel.
- Anti-eskalasi berbasis rank; tidak bisa mengubah akses diri sendiri; SUPER_ADMIN tidak bisa
  diberikan lewat aplikasi.
- Audit tidak bisa diubah/dihapus siapa pun; aktor tidak bisa dipalsukan.
- Service role key & kredensial Openbravo hanya server-side; token di sessionStorage; password
  tidak pernah di-log, di-audit, atau ikut hash idempotency.
- Schema `pos` tidak terekspos ke PostgREST; `anon`/`authenticated` dicabut aksesnya.

## 7. Test cases
| Suite | Jumlah | Status di workspace ini |
|---|---|---|
| SQL RLS & otorisasi (`db/tests`) | 136 asersi / 6 file | ✅ lulus di PostgreSQL 16 |
| PREPARE-check SQL backend | 70 statement (+2 dinamis dicek manual) | ✅ lulus |
| Frontend unit (Vitest) | 15 test | ✅ lulus; type-check & build ✅ |
| Backend integrasi (JUnit) | 31 test / 6 kelas | CI run #1: compile ✅, 27/30 lulus → diperbaiki (lihat catatan CI) |
| Review visual UI | 13 layar desktop & mobile | ✅ diperiksa dengan mock API |

## 8. Known limitations
1. Workspace pengembangan tidak dapat mengakses Maven Central, sehingga backend hanya
   dikompilasi & dites di CI GitHub Actions (atau `./gradlew test` di mesin developer).
2. Rate limiting in-memory per instance (**TEMPORARY IMPLEMENTATION**, ASSUMPTIONS B11).
3. Login memakai email, belum username (B13).
4. Header terminal di audit masih klaim client sampai Phase 3 (B14).
5. Mapping Openbravo (`openbravo_mappings`) dibuat di Phase 9; data payment method & produk demo
   menyusul di phase yang memiliki tabelnya (B12).
6. Pengubahan konfigurasi §73 lewat UI belum ada (baca saja); diubah via SQL oleh admin DB.
7. Pembersihan `idempotency_keys` kedaluwarsa dijadwalkan Phase 10.
8. Spring Boot 3.5 dipakai sesuai spec (3.x); periksa status dukungan open-source versi ini
   sebelum go-live dan rencanakan upgrade bila diperlukan.

## 9. How to run
Lihat [README.md](../README.md#menjalankan-secara-lokal) dan [DEPLOYMENT.md](DEPLOYMENT.md).

## 10. How to rollback
- Aplikasi: deploy ulang image versi sebelumnya.
- Database: forward-fix dengan migration baru. Pada lingkungan tanpa data produksi, rollback penuh
  Phase 1 dijelaskan di [DATABASE.md](DATABASE.md#rollback).

## Catatan CI run #1 (2026-10-02)
Backend berhasil dikompilasi; 27/30 test lulus. Tiga kegagalan:
- `RlsBackstopIT` (2 test): **keamanan berfungsi benar** (database menolak dengan
  "permission denied" / "row-level security"), tetapi test memeriksa pesan exception luar,
  bukan root cause. Diperbaiki di test.
- `UserManagementIT.createLoginDeactivate` (403): **bug nyata**. Policy SELECT `users` dan
  `outlets` memakai fungsi STABLE yang membaca ulang tabel yang sama, sehingga baris baru pada
  `INSERT ... RETURNING` ditolak RLS. Akibatnya admin tidak bisa membuat user maupun outlet.
  Diperbaiki di migration V008, dengan test regresi SQL (`test_06_insert_returning.sql`, terbukti
  gagal tanpa V008) dan test API `SecurityIT.adminCanCreateOutletAndSeeIt`.

