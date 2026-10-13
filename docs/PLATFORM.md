# Platform SaaS: onboarding merchant

Satu sistem dijual ke banyak bisnis (merchant). Setiap merchant = satu `organization`; isolasi data memakai RLS
(`pos.current_org_id()`), bukan database terpisah.

## Operator platform
- Organisasi `PLATFORM` (dibuat migrasi V021) berisi akun operator dengan role `PLATFORM_ADMIN`
  (rank 100, permission `platform.manage` + `role.manage`). Role ini hanya bisa diberikan ke org `PLATFORM`.
- Lokal/demo: `platform@demo.local` / `Demo#12345` (seed). Production: buat akun di Supabase Auth lalu
  jalankan `db/bootstrap/bootstrap_super_admin.sql` dengan `org_code=PLATFORM`, kemudian beri role
  `PLATFORM_ADMIN` lewat SQL.
- Setelah login operator langsung masuk ke halaman **Merchant** (`/platform`).

## Membuat merchant
`POST /api/platform/merchants` -> akun login pemilik dibuat di penyedia auth (dibatalkan otomatis bila transaksi
gagal), lalu `pos.platform_provision_merchant` membuat dalam satu transaksi: organisasi, langganan, outlet,
gudang, terminal `<KODE>-K1`, karyawan `OWNER`, user `<kode>.owner` dengan role OWNER + ADMIN + STORE_MANAGER,
pajak (PPN 11%, PB1 10% untuk F&B), profil struk, dan (lewat trigger organisasi) metode pembayaran & pecahan kas.

## Paket & batas
Tabel `plans` (`NULL` = tanpa batas): TRIAL (1 outlet, 1 kasir, 3 user, 100 produk, 14 hari), STARTER, BUSINESS,
ENTERPRISE. Trigger menolak penambahan melebihi batas dengan `PLAN_LIMIT_EXCEEDED` (HTTP 403, pesan jelas).
Produk yang disinkronkan dari Openbravo tidak dihitung. Organisasi tanpa langganan = tanpa batas.
Belum ada: penagihan, penegakan masa trial, daftar mandiri.

## Penangguhan
`platform_set_active(false)` menonaktifkan organisasi; `current_app_user_id()` mensyaratkan organisasi aktif sehingga
seluruh akses merchant tertutup seketika (fail-closed). Login pengguna juga diblokir di penyedia auth.

## Isolasi antar-tenant (celah yang ditutup)
- Role sistem bersifat global; **permission-nya hanya dapat diubah operator platform** (RLS + pesan jelas di API).
  Sebelumnya admin satu merchant dapat mengubah role untuk semua merchant.
- Tabel `plans` dan `organization_subscriptions` tertutup bagi pengguna merchant.
- Role kustom masih global (belum per-organisasi): tidak ada UI untuk membuatnya; perlu `organization_id`
  pada `roles` sebelum fitur itu dibuka.
- Pengujian: `db/tests/test_17_platform_tenancy.sql` (47 pernyataan) dan `PlatformIT`.
