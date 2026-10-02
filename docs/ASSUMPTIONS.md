# Keputusan Arsitektur & Asumsi

Dokumen ini mencatat keputusan yang sudah disetujui pemilik project (2026-10-02) dan
asumsi yang dibuat selama implementasi. Setiap perubahan keputusan harus dicatat di sini.

## A. Keputusan yang disetujui

### A1. Frontend tidak mengakses tabel database secara langsung
- Frontend hanya memakai **Supabase Auth** untuk login (mendapat JWT).
- Semua data dibaca/ditulis melalui **Spring Boot API**.
- Semua tabel POS berada di schema `pos`. Schema ini **tidak boleh** ditambahkan ke
  "Exposed schemas" PostgREST di Supabase. Role `anon` dan `authenticated` tidak
  mendapat privilege apa pun di schema `pos`.
- Spring Boot memvalidasi JWT Supabase (JWKS untuk signing key asimetris, atau HS256
  untuk legacy JWT secret).

### A2. RLS benar-benar berlaku untuk request API
- Backend login ke Postgres sebagai role `pos_api` (`NOINHERIT`, tanpa privilege tabel).
- Di awal setiap transaksi, backend menjalankan:
  - `SET LOCAL ROLE pos_app_user`
  - `set_config('request.jwt.claims', <claims JWT>, true)`
- Policy RLS membaca `request.jwt.claims` sehingga outlet scope dan permission
  ditegakkan **di database**, bukan hanya di service.
- Query di luar transaksi atau tanpa konteks gagal dengan `permission denied`
  (fail-closed).
- Job sistem (sync, scheduler) memakai `SET LOCAL ROLE pos_system` dan wajib dicatat
  di audit log sebagai aktor sistem.
- Logika permission (`pos.has_permission`, `pos.can_access_outlet`) hanya ada **satu
  implementasi**, yaitu fungsi SQL. Backend memanggil fungsi yang sama dengan yang
  dipakai RLS, sehingga keduanya tidak bisa berbeda pendapat.

### A3. Offline penuh hanya untuk pembayaran CASH
- Offline jenis 1 (Openbravo down, backend hidup): normal, ditangani sync queue.
- Offline jenis 2 (backend/internet mati): hanya CASH; harga dari cache berversi;
  diskon manual, void, refund, price override diblokir; semua transaksi offline
  divalidasi ulang saat sync, dan selisih masuk `MANUAL_REVIEW`.
- Implementasi: Phase 10.

### A4. Nomor struk dari blok yang dialokasikan server
- Backend mengalokasikan blok nomor per terminal. Unique constraint di DB tetap
  berlaku pada `(terminal_id, receipt_no)` dan `client_transaction_id`.
- Implementasi: Phase 4 / Phase 10.

### A5. Kas
- Movement `CASH_SALE` = nilai yang diterapkan ke transaksi (diterima − kembalian).
- Kelebihan bayar hanya untuk CASH; pembayaran non-tunai melebihi sisa tagihan ditolak.
- Implementasi: Phase 5–7.

### A6. Stok tampilan = snapshot Openbravo − penjualan lokal belum ter-sync
- Nilai turunan, tidak pernah ditulis ke `product_stock_cache`.

### A7. Separation of duties berlaku umum
- Approver tidak boleh sama dengan requester untuk diskon, void, refund, selisih kas.
- Pada Phase 1 diterapkan untuk manajemen akses (ditegakkan di RLS, bukan hanya service):
  - user tidak bisa mengubah baris user, role, atau outlet dirinya sendiri;
  - setiap role punya `rank` (SUPER_ADMIN 100, ADMIN 90, AUDITOR 80, STORE_MANAGER 70,
    SUPERVISOR 50, STOCK_OPERATOR 30, CASHIER 20). Memberi/mencabut role, mengubah
    permission role, atau mengelola user hanya boleh untuk rank **di bawah** rank
    tertinggi role org-wide milik pengelola. Akibatnya SUPER_ADMIN tidak pernah dapat
    diberikan lewat aplikasi, dan ADMIN tidak bisa mengubah akun ADMIN/SUPER_ADMIN lain.
  - Menambah permission ke role hanya boleh untuk permission yang dipegang sendiri.
  - Catatan desain: aturan awal "hanya boleh memberi role yang permission-nya subset
    milik sendiri" ditolak karena membuat ADMIN tidak bisa membuat akun kasir
    (ADMIN sengaja tidak punya permission transaksi).

## B. Asumsi Phase 1

| # | Asumsi | Alasan / konsekuensi |
|---|--------|----------------------|
| B1 | Satu deployment = satu organisasi utama, tetapi skema sudah memakai `organization_id` di semua tabel master. | Multi-tenant penuh (banyak organisasi di satu DB) belum diuji. |
| B2 | Scope role: `user_roles.outlet_id = NULL` berarti role berlaku di **semua outlet organisasi** (org-wide). Selain itu role berlaku hanya di outlet tersebut. | Mendukung manager multi-outlet dan supervisor per outlet. |
| B3 | Akses outlet = `user_outlets` ∪ (semua outlet organisasi jika user punya role org-wide). | Role outlet-scoped wajib disertai baris `user_outlets` (ditegakkan oleh service). |
| B4 | `pos.has_permission(p, NULL)` hanya menghitung role org-wide. Aksi level organisasi (kelola role, user, outlet) membutuhkan role org-wide. | Store manager belum bisa mengelola user outletnya sendiri; ditunda sampai ada kebutuhan nyata. |
| B5 | Permission tambahan di luar contoh spec: `user.view`, `employee.view`, `employee.manage`, `outlet.manage`, `terminal.manage`, `role.manage`, `audit.view`, `attendance.view`, `attendance.force_clock_out`, `cashier.view`, `sale.view`, `sync.view`, `sync.manage`. | Spec meminta permission granular. |
| B6 | Pembuatan akun login dilakukan backend melalui Supabase Admin API (service role key hanya di server). Untuk pengembangan lokal tersedia auth shim + endpoint token **khusus profile `local`**. | Endpoint dev tidak di-load di profile lain; aplikasi menolak start jika profile `local` aktif bersamaan dengan `prod`. |
| B7 | Kode terminal unik global (mis. `POS-JKT-01`) karena dipakai sebagai prefix nomor struk. | |
| B8 | Business date: timezone outlet (fallback organisasi, default `Asia/Jakarta`) + setting `business_day_cutoff` (default `04:00`). Transaksi pukul 01:30 masuk business date hari sebelumnya. | Dipakai mulai Phase 2. |
| B9 | Audit log append-only ditegakkan dengan trigger (UPDATE/DELETE/TRUNCATE ditolak untuk semua role, termasuk owner). | Koreksi audit tidak dimungkinkan, sesuai tujuan. |
| B10 | Uang disimpan sebagai `numeric(18,2)`, bukan float. | Berlaku mulai Phase 3. |
| B11 | Rate limiting Phase 1 bersifat in-memory per instance backend. | **TEMPORARY IMPLEMENTATION**: jika backend di-scale lebih dari satu instance, limit efektif dikalikan jumlah instance. Ganti dengan Redis/gateway sebelum scale-out. |
| B12 | Payment method dan product seed (§90) dibuat di phase yang memiliki tabelnya (Phase 4–5). | Phase 1 tidak membuat tabel di luar scope. |
| B13 | Login memakai **email** (bukan username). Spec menyebut "username/email"; mendukung username memerlukan endpoint publik pemetaan username→email yang membuka celah enumerasi akun. | Username tetap ada sebagai identitas tampilan & audit. Dapat ditambahkan nanti lewat Supabase custom claim / edge function. |
| B14 | Pilihan outlet & terminal di frontend disimpan di sessionStorage dan dikirim sebagai header untuk jejak audit saja. Validasi "terminal ini dipakai oleh kasir ini" ditegakkan server mulai Phase 3 (cashier session). | Sebelum Phase 3, header terminal di audit log adalah klaim client. |

