# Arsitektur

```
Browser (Vue)  ──JWT──▶  Spring Boot API  ──pos_api──▶  PostgreSQL / Supabase (schema pos, RLS)
     │                        │
     └── login ──▶ Supabase Auth            └── (Phase 9) Integration service ──▶ Openbravo
```

## Prinsip
1. **Frontend tidak pernah menjadi sumber kebenaran.** Pengecekan permission di UI hanya
   menyembunyikan menu. Setiap request divalidasi ulang oleh service dan RLS.
2. **Tiga lapis otorisasi** untuk setiap request:
   1. Spring Security memvalidasi JWT Supabase (signature, issuer, audience, `role=authenticated`);
   2. service memanggil `AccessService` → fungsi SQL `pos.has_permission` / `pos.can_access_outlet`;
   3. RLS di PostgreSQL memakai fungsi SQL yang SAMA, sebagai backstop.
3. **Fail-closed.** Backend login sebagai `pos_api` yang tidak punya privilege tabel. Hanya di
   dalam transaksi dengan JWT valid, `RlsTransactionManager` menjalankan
   `SET LOCAL ROLE pos_app_user` + `set_config('request.jwt.claims', ...)`. Query tanpa konteks
   ditolak database (`permission denied`).
4. **Audit di transaksi yang sama.** `AuditService` wajib dipanggil di dalam transaksi bisnis
   (propagation MANDATORY); data dan jejak audit selalu commit/rollback bersama. Aktor diambil
   dari database, dan policy menolak aktor palsu. Tabel audit append-only via trigger.
5. **Idempotency atomik.** Key disimpan di transaksi yang sama dengan aksi bisnis; retry atau
   request paralel dengan key sama menghasilkan satu data (lihat `IdempotencyService`).
6. **Sistem eksternal dengan kompensasi.** Pembuatan akun login di Supabase dikompensasi
   (dihapus) otomatis jika transaksi database gagal di titik mana pun, termasuk saat commit.

## Model otorisasi
- **Role** (7 role sistem) + **permission** granular + **outlet scope**.
- `user_roles.outlet_id NULL` = role org-wide; selain itu hanya berlaku di outlet tersebut.
- Akses outlet = `user_outlets` ∪ semua outlet jika user punya role org-wide.
- **Rank anti-eskalasi:** user hanya bisa memberi/mencabut role, mengubah permission role, atau
  mengelola user dengan rank di bawah rank tertinggi role org-wide miliknya; tidak pernah
  dirinya sendiri. SUPER_ADMIN tidak dapat diberikan lewat aplikasi.

## Struktur kode
```
backend/src/main/java/com/pirantisolution/pos/
  common/   api (envelope), error (kode error, handler), web (requestId, rate limit)
  db/       RlsTransactionManager, DbContext, SystemTx
  security/ SecurityConfig (JWT), AccessService
  audit/ idempotency/ auth/ outlet/ terminal/ employee/ user/ role/ settings/
frontend/src/
  services/ (api client, auth provider)  stores/ (session)  router/  layouts/
  modules/  auth, home, admin            components/ composables/ utils/ types/
db/
  migration/ (V001–V007)  local/ (shim auth lokal)  seed/ (demo)  tests/ (test SQL)
```

## Business date
`pos.business_date(ts, outlet)` = waktu lokal outlet dikurangi `business_day_cutoff`
(default 04:00). Disediakan di Phase 1, dipakai mulai Phase 2.
