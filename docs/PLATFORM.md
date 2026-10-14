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

## Preset jenis usaha
`platform_apply_preset` (dipanggil otomatis saat membuat merchant; aman diulang) mengisi data awal menurut jenis usaha:
- **F&B:** kategori Makanan/Minuman/Snack/Paket Hemat; opsi Level pedas, Suhu, Gula, Topping; diskon member 10% & Promo Rp 5.000.
- **Retail:** 5 kategori umum, diskon member 5% & potongan Rp 5.000.
- **Jasa / Umum:** kategori dasar dan satu diskon.
Tanpa produk contoh (agar tidak memakan kuota paket). Semuanya dapat diubah pemilik.

## Branding per merchant
Halaman **Manage Receipt** memuat kartu *Merek & tampilan* (izin `receipt.manage` tingkat organisasi): nama tampilan,
warna utama, dan logo. Disimpan di `organization_branding`; `GET /api/branding` dibaca semua pengguna, `PUT` hanya pengelola.
- Warna: `#RRGGBB` dengan kontras ≥ 2,5 terhadap putih (tombol berteks putih harus terbaca); palet 50–950 dibuat otomatis
  di frontend (`utils/brand.ts`) dan menimpa variabel CSS Tailwind (`--brand-*`) dan PrimeVue (`--p-primary-*`).
- Logo: data URL PNG/JPEG/WebP ≤ ~70 KB (frontend mengecilkan ke 256 px). SVG ditolak karena dapat memuat skrip.
  Pada struk logo dicetak hitam-putih.
- Kosong = tampilan bawaan. Belum ada: subdomain/halaman login bermerek per merchant.

## Settlement & pencairan dana (V024)

Model: semua pembayaran gateway masuk ke rekening platform, lalu dicairkan ke rekening bank merchant.

- Hanya pembayaran dengan provider + external_transaction_id + konfirmasi GATEWAY masuk buku besar (`merchant_ledger`, append-only). Tunai dan QRIS statis manual tidak.
- Biaya default 0,7%, tahan 1 hari, minimal pencairan Rp 50.000 (diatur per merchant lewat `platform_set_terms`).
- Merchant (perm `finance.manage`, Owner/Super Admin): lihat saldo, simpan rekening bank (status PENDING sampai diverifikasi operator), ajukan pencairan.
- Operator platform: verifikasi rekening, proses pencairan (PAID/REJECTED/FAILED; penolakan mengembalikan saldo), rekonsiliasi saldo per merchant.
- Refund atas pembayaran gateway membuat entri REFUND; biaya tidak dikembalikan.

Catatan regulasi: menampung dan menyalurkan dana merchant di Indonesia umumnya masuk ranah perizinan sistem pembayaran Bank Indonesia (mis. PJP/payment facilitator). Tanyakan ke gateway saat registrasi apakah mendukung sub-merchant / split settlement. Bukan nasihat hukum.

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
- Pengujian: `db/tests/test_17_platform_tenancy.sql` (51 pernyataan) dan `PlatformIT`.

## Clock in opsional (V027)
Pengaturan merchant `attendance_required` (menu **Pengaturan**, perm `configuration.manage`; Owner dan Admin). Bawaan: wajib. Bila dimatikan, membuka kasir otomatis membuat kehadiran (`device_id = 'AUTO'`) dan menutup kasir menutupnya, sehingga aturan sesi kasir/penjualan/pembayaran tidak berubah. Perubahan tercatat di audit log.

## Masa percobaan berakhir (V028)
Merchant berpaket TRIAL yang `trial_ends_at`-nya lewat tidak bisa membuat penjualan baru atau membuka kasir (`TRIAL_EXPIRED`, HTTP 403); data tetap bisa dilihat. Banner muncul 7 hari sebelum berakhir. Operator memperpanjang lewat **Ganti paket** (memilih TRIAL lagi = 14 hari baru) atau memindahkan ke paket berbayar.

## Dashboard (V030)
Menu **Dashboard** (perm `report.view`; Owner, Admin, Store Manager, Auditor): omzet bersih (dikurangi retur), jumlah transaksi, rata-rata keranjang, void, tren harian, jam ramai, metode bayar, produk & kategori terlaris, ringkasan closing kasir (selisih), stok menipis, dan peringatan (kasir masih terbuka, gagal sinkron). Dihitung di database (`pos.dashboard`) dari penjualan lunas per business date; rentang maks 366 hari. Merchant satu outlet melihat seluruh datanya; peran per-outlet hanya outlet-nya.

Menu **Laporan penjualan** (perm `report.view`): rincian penjualan lunas per produk, kategori, kasir, hari, atau metode bayar untuk rentang tanggal (hari ini, 7/30 hari, bulan ini), dengan total dan unduhan CSV (sel yang diawali `=`, `+`, `-`, `@` dinetralkan agar tidak dibaca Excel sebagai rumus). Dihitung di database (`pos.sales_report`, V035) dengan definisi yang sama dengan Dashboard, jadi angkanya identik; void tidak dihitung dan retur tetap di Dashboard. API: `GET /api/reports/sales?from&to&group&outletId`.

Menu **Rekap harian** (perm `report.view`): ringkasan satu tanggal untuk penutupan hari: transaksi, penjualan kotor/diskon/pajak/bersih, retur, omzet setelah retur, void (tidak dihitung), metode pembayaran, daftar sesi kasir (modal, kas tutup, selisih) dan lima produk terlaris. Memakai `/api/dashboard` untuk satu hari dan daftar sesi kasir, jadi angkanya sama dengan Dashboard; tombol Cetak menghasilkan A4.

## Penjualan offline (Fase 10, tahap 1: sisi server)

Transaksi tunai yang dibuat saat internet mati dikirim lewat `POST /api/sales/offline` (satu panggilan
berisi seluruh keranjang, waktu transaksi, total versi kasir, dan uang diterima). Server membuat
transaksi memakai alur biasa (harga, pajak, stok, nomor struk, pembayaran tunai dihitung ulang oleh
database), jadi hasilnya sama seperti penjualan online. Kirim ulang dengan `clientTransactionId` yang
sama mengembalikan transaksi yang sama (`duplicate: true`).

Transaksi yang sudah terjadi di toko tidak ditolak karena kebijakan. Hal-hal berikut dicatat di
`pos.offline_sales` dengan status `OPEN` untuk ditinjau pemilik/manajer (`GET /api/offline-reviews`,
`POST /api/offline-reviews/{id}/resolve`, butuh `report.view`):

- total di server berbeda dari total kasir offline;
- `allow_offline_sale` mati untuk outlet itu;
- nilai melebihi `max_offline_sale_amount`;
- pengiriman lebih lambat dari `max_offline_duration_minutes`.

Stok tidak cukup di server tidak menolak transaksi offline (barang sudah keluar): stok dicatat minus dan
kekurangannya masuk peninjauan agar stok dicocokkan (`pos.offline_stock_waiver`, hanya berlaku dalam satu transaksi database).

### Tahap 2: kasir offline di browser

- Saat halaman kasir dimuat online, katalog lengkap disimpan di IndexedDB perangkat (hanya produk berharga
  dan tanpa grup opsi; produk dengan opsi belum bisa dijual offline).
- `OfflineBanner` memeriksa `/actuator/health` tiap 20 detik dan dari event browser online/offline. Server
  tak terjangkau = halaman kasir berganti ke `OfflinePos`: cari/pindai barcode, keranjang, hanya tunai,
  tanpa diskon/void/ubah harga.
- Transaksi masuk antrean lokal (`stores/offline.ts`) dan dikirim berurutan ke `POST /api/sales/offline`
  begitu server terjangkau. Jaringan putus, sesi habis, atau error 5xx: tetap antre. Ditolak server (mis.
  stok kurang): ditandai gagal beserta pesannya, menunggu Coba lagi atau Buang oleh manusia.
- Syarat: browser harus sudah memuat aplikasi sebelum internet mati (belum ada service worker; reload saat
  offline belum didukung) dan sesi login masih berlaku.

Menu Outlet, Sinkronisasi, dan Pemetaan Openbravo kini hanya untuk operator platform (`platform.manage`).

### Tahap 3: aplikasi bisa dibuka offline & peninjauan

- `frontend/public/sw.js` (service worker, hanya build produksi) menyimpan aset dan halaman utama agar aplikasi
  bisa dibuka lagi saat internet mati, selama perangkat pernah memuatnya online. `/api` dan `/actuator` tidak
  pernah di-cache. Setelah rilis baru, versi lama diganti saat perangkat online berikutnya.
- Pemeriksaan koneksi memakai `/actuator/health` (diteruskan nginx ke backend); jawaban HTML dari SPA tidak
  dihitung sebagai server terjangkau.
- Halaman **Transaksi offline** (`/offline-reviews`, butuh `report.view`, ada tautan dari Dashboard): daftar
  selisih yang perlu ditinjau, ditutup dengan catatan minimal 5 karakter.
- Batasan yang tersisa: produk dengan opsi belum bisa dijual offline, nomor struk resmi baru ada setelah terkirim.

Isolasi di perangkat bersama: antrean offline disimpan per akun (`ownerId`). Akun lain, termasuk dari merchant
lain, tidak melihat dan tidak mengirimnya; entri lama tanpa pemilik hanya terlihat bila outlet-nya dapat diakses
akun yang login. Server juga menolak transaksi offline yang `outletId`-nya berbeda dari outlet kasir yang mengirim.

Pengaturan offline ada di halaman **Pengaturan** (owner/admin, `configuration.manage`): izinkan penjualan
offline, batas nilai per transaksi, dan batas keterlambatan kirim (0 = tanpa batas). Berlaku untuk seluruh outlet
merchant; perubahan tercatat di audit log (`PUT /api/settings/offline`).

## Openbravo opt-in

Sinkron master data Openbravo (produk, harga, stok, pelanggan) hanya berjalan untuk merchant dengan setting
`openbravo_enabled = true`, yang hanya dapat diubah operator platform (`PUT /api/platform/merchants/{id}/openbravo`).
Merchant katalog lokal (bawaan) menerima penolakan "memakai katalog lokal" sehingga katalognya tidak bercampur dengan
produk simulator `SKU-…`. Merchant DEMO pada fixture tes diaktifkan.
