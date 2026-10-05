# POS Outlet — terintegrasi Openbravo ERP

Sistem POS berbasis web untuk operasional toko multi-outlet. Openbravo adalah system of record
ERP; Supabase/PostgreSQL menyimpan data operasional POS; Spring Boot adalah lapisan bisnis,
otorisasi, dan integrasi.

| Komponen | Teknologi | Folder |
|---|---|---|
| Frontend | Vue 3, Vite, TypeScript, PrimeVue 4, Tailwind 3, Pinia, Zod | `frontend/` |
| Backend | Spring Boot 3.5, Java 21, Spring JDBC, Spring Security (JWT Supabase), Flyway | `backend/` |
| Database | PostgreSQL 16 / Supabase, RLS | `db/` |

**Status:** Phase 1 (Foundation), 2 (Attendance), 3 (Cashier session), 4 (Sales) dan 5 (Payment) selesai. Lihat [PHASE-1](docs/PHASE-1.md), [PHASE-2](docs/PHASE-2.md), [PHASE-3](docs/PHASE-3.md), [PHASE-4](docs/PHASE-4.md), [PHASE-5](docs/PHASE-5.md).

## Menjalankan secara lokal

### Opsi A: Docker Compose (semua komponen)
```bash
docker compose up --build
# Frontend: http://localhost:8081   Backend: http://localhost:8080
```

### Opsi B: tanpa Docker
```bash
# 1. PostgreSQL 16 lokal, buat database
createdb pos

# 2. Backend (migration + seed demo dijalankan otomatis oleh Flyway)
cd backend
MIGRATION_DATABASE_PASSWORD=<password postgres> \
DATABASE_PASSWORD=pos_api_local_only \
SPRING_PROFILES_ACTIVE=local ./gradlew bootRun

# 3. Frontend (proxy /api -> localhost:8080)
cd frontend
cp .env.example .env.local   # VITE_AUTH_MODE=local
npm install && npm run dev   # http://localhost:5173
```

Akun demo (password `Demo#12345`): `cashier.jkt@demo.local`, `supervisor.jkt@demo.local`,
`manager@demo.local`, `admin@demo.local`, `superadmin@demo.local`, `auditor@demo.local`,
`cashier.bdg@demo.local`.

## Test
```bash
PGHOST=localhost PGUSER=postgres PGPASSWORD=... ./db/tests/run.sh      # RLS & aturan otorisasi (SQL)
python3 backend/scripts/check_sql.py "dbname=pos_rls_test host=localhost user=postgres password=..."
cd backend && ./gradlew test                                              # integrasi (butuh DB pos_it)
cd frontend && npm run type-check && npm test && npm run build
```
Detail: [docs/TESTING.md](docs/TESTING.md).

## Dokumentasi
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): arsitektur & alur keamanan
- [docs/ASSUMPTIONS.md](docs/ASSUMPTIONS.md): keputusan arsitektur yang disetujui & asumsi
- [docs/DATABASE.md](docs/DATABASE.md): role database, RLS, migration, backup
- [docs/API.md](docs/API.md): daftar endpoint
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md): deploy ke Supabase + server
