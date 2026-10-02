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
