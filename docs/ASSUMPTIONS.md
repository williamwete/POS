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

## B. Asumsi

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
| B14 | Pilihan outlet & terminal di frontend disimpan di sessionStorage dan dikirim sebagai header untuk jejak audit saja. Mulai Phase 3 terminal kerja seorang kasir ditentukan oleh cashier session-nya (server); transaksi Phase 4 memakai terminal session, bukan header. | Header terminal di audit log tetap klaim client. |
| B15 | Aturan §55 "tidak boleh clock out selama cashier session OPEN" ditegakkan di trigger `pos.tg_attendance_guard` (V010) untuk semua status aktif (OPEN, ON_BREAK, CLOSING). Force clock out supervisor tetap diizinkan dan otomatis mengunci session kasir (`FORCED_CLOCK_OUT`). | Session yang terkunci karena force clock out ditutup lewat closing (Phase 7) atau dibuka lagi oleh kasir setelah clock in ulang. |
| B16 | Kehadiran tidak bisa diedit atau dihapus. Kesalahan ditangani dengan force clock out (beralasan, tercatat audit). Fitur koreksi jam kehadiran dengan approval belum termasuk scope. | Butuh fitur koreksi bila HR memerlukan penyesuaian jam. |
| B17 | Clock out normal ditolak selama istirahat berjalan (kasir harus "Selesai istirahat" dulu); force clock out supervisor menutup istirahat otomatis. | |
| B18 | Status `ON_BREAK` pada cashier session dipakai sebagai **session lock** (terminal terkunci), dengan `lock_reason` MANUAL, IDLE, BREAK, atau FORCED_CLOCK_OUT. Mulai istirahat otomatis mengunci session yang terbuka. | Spec mendaftar status ON_BREAK tanpa membedakan istirahat dan kunci layar; alasan kunci disimpan terpisah. |
| B19 | Satu karyawan hanya boleh memegang satu session aktif (selain aturan satu session per terminal). Pindah terminal = tutup/batal session lama. | Mencegah satu orang bertanggung jawab atas dua laci kas. |
| B20 | Membuka kunci terminal wajib login ulang dengan password. Backend meneruskan waktu autentikasi terakhir (klaim `amr` Supabase, tanpa `token_refresh`) sebagai `auth_time`; database menolak unlock bila `auth_time` < waktu kunci (presisi detik). | Refresh token tidak cukup untuk membuka kunci. Jika metode login lain dipakai (SSO), metode tersebut harus muncul di `amr`. |
| B21 | Hitung kas tengah shift bersifat **blind count**: kasir tidak melihat expected cash maupun selisih; hanya pemegang `cashier.view` yang melihatnya. | Mencegah kasir "menyesuaikan" hitungan. Penyesuaian kas & approval selisih: Phase 6. |
| B22 | Modal awal boleh Rp 0 (dengan konfirmasi di UI). Hitungan memakai master `cash_denominations` (default IDR 100.000 s.d. 100 rupiah, dibuat otomatis untuk setiap organisasi); nilai item disalin dari master oleh trigger, client hanya mengirim jumlah lembar. | Pengelolaan master denominasi di UI belum tersedia (ubah lewat migration/SQL). |
| B23 | Batal buka kasir (`CANCELLED`) hanya oleh pemilik dan hanya selama belum ada movement kas selain OPENING_CASH (Phase 4 menambah syarat belum ada transaksi). Penutupan normal (CLOSING → CLOSED, X/Z report) adalah Phase 7. | |
| B24 | Kunci otomatis karena tidak ada aktivitas memakai setting outlet `terminal_idle_lock_minutes` (default 10, 0 = nonaktif). Pendeteksian idle dilakukan browser; penguncian tetap dicatat server. | Jika browser ditutup, session tetap OPEN sampai kasir kembali (login ulang menampilkan tawaran melanjutkan session). |
| B25 | Uang dibulatkan ke rupiah penuh (HALF_UP) per baris: harga × jumlah, diskon, dan pajak. Diskon transaksi dialokasikan ke baris dengan metode sisa terbesar sehingga jumlahnya tepat. | Rupiah tidak memakai sen dalam praktik ritel. |
| B26 | Harga jual dari `product_price_cache` (harga khusus outlet lebih dulu, lalu organisasi; periode berlaku; versi terbaru). Default harga sudah termasuk PPN (`prices_include_tax`), pajak dihitung mundur per baris. | Diubah per outlet bila price list Openbravo eksklusif pajak. |
| B27 | Checkout (Phase 4) = keranjang dikunci, diskon/approval/stok divalidasi, nomor struk dialokasikan; status `CHECKOUT` menunggu pembayaran Phase 5. Struk sebelum lunas dicetak dengan tanda **BELUM DIBAYAR — BUKAN BUKTI PEMBAYARAN**. `reopen` mengembalikan ke keranjang dengan nomor struk yang sama. | Nomor struk tidak pernah dipakai ulang; transaksi void tetap memegang nomornya (jejak audit). |
| B28 | Nomor struk online: urutan per terminal per business date dengan row lock (`terminal_receipt_sequences`). Alokasi blok untuk offline mengikuti A4 di Phase 10. | |
| B29 | Stok dicek saat checkout terhadap stok tersedia (A6). Produk tanpa snapshot stok dianggap **tidak tersedia** kecuali `allow_negative_stock` aktif (per produk, lalu per outlet). Checkout produk yang sama di outlet yang sama diserialkan (advisory lock). | Data stok baru terisi otomatis setelah sync Openbravo (Phase 9); demo memakai seed. |
| B30 | Matriks diskon (§20): sampai `max_cashier_discount` % tanpa approval; sampai `max_supervisor_discount` % dengan approval rank ≥ SUPERVISOR; sampai `max_manager_discount` % dengan rank ≥ STORE_MANAGER; di atasnya ditolak. Ubah harga dan void setelah checkout butuh approval rank ≥ SUPERVISOR dengan izin terkait. | Satu diskon aktif per baris dan satu diskon transaksi; mengganti = hapus lalu tambah. |
| B31 | Approval diberikan di terminal kasir: supervisor mengetik email + password; backend memverifikasi ke penyedia login (Supabase password grant, sesi yang terbentuk langsung dicabut), password tidak disimpan/di-log, endpoint dibatasi rate limit seperti login. Approval terikat ke transaksi/baris/nilai tertentu, sekali pakai, berlaku 2 menit. | Alternatif tanpa password (PIN supervisor, approval dari perangkat supervisor) dapat ditambahkan. |
| B32 | Void transaksi: DRAFT/HELD boleh oleh kasir dengan alasan; setelah checkout wajib approval (`require_supervisor_for_void`). Keranjang kosong dibatalkan (`CANCELLED`), bukan di-void. Tidak ada DELETE. | Void setelah lunas (PAID) & refund: Phase 5/8. |
| B33 | Metode pembayaran per organisasi dengan tiga mode konfirmasi: IMMEDIATE (tunai), MANUAL (kartu via EDC terpisah & transfer — kasir memasukkan nomor referensi; transfer default wajib approval supervisor), GATEWAY (QRIS dinamis/e-wallet — hanya penyedia yang menyatakan lunas). Belum ada pengaturan metode per outlet. | EDC terintegrasi (host-to-host) belum ada; kartu dicatat dengan kode approval EDC. |
| B34 | Penyedia QRIS/e-wallet produksi belum dipilih. Tersedia kontrak penyedia (`PaymentGateway`), callback generik bertanda tangan HMAC + timestamp, simulator untuk local/test, dan mode **QRIS statis**: metode gateway dapat diset "boleh konfirmasi manual" sehingga kasir mengonfirmasi dengan nomor referensi + approval supervisor (§64 "manual hanya bila dikonfigurasi & ada permission"). | Integrasi Midtrans/Xendit/dll. ditambahkan sebagai implementasi `PaymentGateway` setelah kredensial merchant tersedia. |
| B35 | Charge ke penyedia dibuat di dalam transaksi database pembuatan pembayaran (timeout 10 detik); bila gagal, pembayaran tidak tersimpan. Charge yang terlanjur dibuat penyedia tetapi transaksinya batal akan kedaluwarsa tanpa pernah ditampilkan ke pelanggan. Callback "lunas" untuk pembayaran yang sudah dibatalkan/kedaluwarsa dicatat audit `PAYMENT_LATE_PAID` untuk ditinjau (refund manual). | |
| B36 | Pembayaran gateway PENDING kedaluwarsa setelah `payment_pending_timeout_minutes` (default 15) dan dibatalkan otomatis oleh job sistem (tiap menit) serta saat dicek. | |
| B37 | Pembatalan pembayaran: PENDING bisa dibatalkan kasir; PAID (tunai/manual) hanya bisa dibalik selama transaksi **belum lunas** (mis. split dibatalkan), wajib alasan, tunai menghasilkan `CASH_SALE_REVERSAL`. Setelah lunas, koreksi melalui retur/refund (Phase 8). Void & ubah keranjang ditolak selama masih ada pembayaran aktif. | |
| B38 | Transaksi dengan total Rp 0 (mis. diskon 100% yang disetujui) langsung lunas saat checkout tanpa baris pembayaran. | |
| B39 | Saat lunas, `sync_status` transaksi menjadi `PENDING` (siap dikirim ke Openbravo di Phase 9). | |
| B40 | Foto produk adalah bagian cache master (diisi sync Openbravo / seed, read-only di POS). Hanya path aplikasi atau URL https yang diterima. Produk tanpa foto tampil dengan inisial nama. Demo memakai ilustrasi SVG buatan sendiri, bukan foto merek nyata. | Pengunggahan foto dari POS tidak disediakan; sumbernya Openbravo/CDN. |
| B41 | Layar kasir menampilkan katalog lengkap (per kategori, maks 200 produk per tampilan) dengan foto, harga, dan stok outlet; pemindaian barcode & pencarian tetap tersedia di kolom yang sama. Harga/stok di katalog hanya tampilan — server menghitung ulang saat barang masuk keranjang dan saat checkout. | Untuk katalog > 200 produk per kategori, gunakan pencarian; paging dapat ditambahkan. |

