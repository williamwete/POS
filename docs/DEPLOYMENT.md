# Deployment

## Staging / production (Supabase)
1. Buat project Supabase. Catat: project URL, anon key, service role key, JWKS URL
   (`https://<project>.supabase.co/auth/v1/.well-known/jwks.json`), issuer
   (`https://<project>.supabase.co/auth/v1`).
2. Pastikan schema `pos` **tidak** ada di *API → Exposed schemas*.
3. Jalankan backend sekali dengan kredensial migration (`MIGRATION_DATABASE_*`, user `postgres`)
   agar Flyway menerapkan V001–V007. Seed demo tidak ikut (profile `prod`).
4. Set password `pos_api` (lihat docs/DATABASE.md), simpan di secret manager sebagai
   `DATABASE_PASSWORD`.
5. Buat SUPER_ADMIN pertama (SUPER_ADMIN tidak bisa diberikan lewat aplikasi):
   - buat user di Supabase Auth (dashboard);
   - jalankan `db/bootstrap/bootstrap_super_admin.sql` sebagai owner database (contoh perintah
     ada di kepala file). Skrip ini juga menulis audit log `USER_CREATED` beraktor SYSTEM.
6. Backend: image `backend/Dockerfile` (context root repo), profile `prod` (log terstruktur ECS).
   Isi env sesuai `.env.example`. Probe: `/actuator/health/liveness`, `/actuator/health/readiness`.
7. Frontend: image `frontend/Dockerfile` dengan build-arg `VITE_AUTH_MODE=supabase`,
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`. Nginx meneruskan `/api/` ke service `backend`.
8. Deployment POS terisolasi (container sendiri); tidak mengubah Node/npm global server yang ada.

## Secret
Tidak ada secret di repo. `.env*` di-ignore kecuali `.env.example`. Service role key Supabase dan
kredensial Openbravo hanya di environment backend.

## Rollback aplikasi
Image dideploy dengan tag versi; rollback = deploy tag sebelumnya. Migration bersifat
forward-only (lihat docs/DATABASE.md). Phase 1 tidak mengubah data finansial.
