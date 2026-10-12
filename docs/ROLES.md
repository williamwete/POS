# Peran, menu, dan verifikasi kehadiran (Phase 10a)

## Empat peran utama

| Peran | Tugas | Tidak boleh |
|---|---|---|
| **Kasir** (`CASHIER`) | Transaksi, clock in/out, saldo awal, melihat history shift sendiri, closing laci sendiri | Mengubah produk/diskon/struk/kasir lain, void & refund tanpa approval |
| **Supervisor** (`SUPERVISOR`) | Semua tugas kasir + approval (void, refund, selisih kas, harga), kelola diskon, atur PIN & lihat foto kasir outlet, closing laci kasir lain | Kategori produk, tampilan struk, akses menu |
| **Owner** (`OWNER`, rank 75) | Mengawasi semua outlet (dashboard, history, closing, laporan), approval tingkat atas, kelola kategori/diskon/struk/produk, atur akses menu | Transaksi penjualan & memegang laci kas |
| **Admin** (`ADMIN`) | Sistem: outlet, terminal, user & role, metode pembayaran, sinkronisasi Openbravo, audit, atur akses menu, PIN, produk/kategori/diskon/struk | Transaksi penjualan, kas, approval transaksi |

Role lama (`SUPER_ADMIN`, `STORE_MANAGER`, `AUDITOR`, `STOCK_OPERATOR`) tetap ada agar akun/tes lama berfungsi, tetapi tidak muncul di layar Akses menu. Hanya empat peran di atas yang diatur dari UI.

## Menu default

| Menu | Kasir | Supervisor | Owner | Admin |
|---|:-:|:-:|:-:|:-:|
| Menu (penjualan) | ✓ | ✓ | – | – |
| Clock in/Clock out | ✓ | ✓ | – | – |
| Beginning cash balance | ✓ | ✓ | – | – |
| Product List | ✓ (lihat) | ✓ | ✓ | ✓ |
| History | ✓ (shift sendiri) | ✓ | ✓ | – |
| Manage Categories | – | – | ✓ | ✓ |
| Manage Discount | – | ✓ | ✓ | ✓ |
| Manage Cashier | – | ✓ | ✓ | ✓ |
| Manage Receipt | – | – | ✓ | ✓ |
| Closing | ✓ | ✓ | ✓ (lihat) | – |
| Dashboard | – | ✓ | ✓ | ✓ |

Retur tidak ada di menu (sesuai permintaan). Halaman Retur dan API-nya tetap ada tetapi tidak ditautkan.

## Aktif/nonaktif menu
* Owner dan Admin (`menu.configure`) membuka **Admin → Akses menu**: matriks menu × peran dengan saklar, penanda "default"/"diubah", tombol reset per sel dan "Kembalikan semua ke default".
* Hanya penyimpangan dari default yang disimpan (`menu_settings`); default ada di `menu_defaults`.
* Menu hanya lapisan tampilan: menu tampil bila **ada satu peran user yang menyalakannya DAN user punya permission yang dibutuhkan**. Menyalakan menu tidak memberi akses API tambahan.
* Anti-eskalasi: tidak bisa mengatur peran dengan rank lebih tinggi dari rank sendiri (Owner tidak bisa mengatur Admin).

## Verifikasi kehadiran (PIN + foto)
* Clock in **dan** clock out meminta foto (kamera perangkat, diperkecil ke 480 px JPEG) dan PIN pribadi 6 digit.
* PIN disimpan sebagai hash bcrypt di tabel yang tidak dapat dibaca user aplikasi. Salah 5 kali = terkunci 5 menit; supervisor/admin memasang PIN baru untuk membuka. Percobaan dicatat di transaksi terpisah agar tidak ikut rollback.
* Foto tersimpan di database, hanya bisa dilihat pemiliknya dan role `attendance.view_photo` pada outlet itu (`GET /api/attendance/{id}/photo/{CLOCK_IN|CLOCK_OUT}`).
* Setting `attendance_verification_required` (default `true`, per outlet) dapat dimatikan; properti `pos.attendance.enforce-verification=false` mematikannya total (dipakai profile test).
* Atur/reset PIN: **Manage Cashier → ikon kunci** (`employee.reset_pin`). Seed demo: PIN `123456` untuk semua karyawan demo.

## Rekomendasi PPN
Pengaturan outlet `prices_include_tax` sudah ada; yang perlu diputuskan adalah **nilai bawaannya**.

* **Bawaan: harga sudah termasuk pajak** (struk menampilkan "termasuk PPN Rp x"). Cocok untuk retail/minimarket dan untuk pelanggan: harga di rak = harga yang dibayar, tidak ada kejutan di kasir.
* **Per outlet F&B/tenant restoran: pajak di atas harga** (`prices_include_tax=false`), seperti Figma (Subtotal + PPN 11% = Total). Untuk restoran, pajak daerah biasanya PB1 (umumnya 10%), bukan PPN; label dan tarif perlu mengikuti jenis usaha.
* Tarif per produk (`taxRate`) tetap dari Openbravo, sehingga barang bebas PPN tetap benar di kedua mode.
* Hanya Pengusaha Kena Pajak (PKP) yang boleh memungut PPN. Tarif berlaku (11% efektif untuk kebanyakan barang) sebaiknya dikonfirmasi ke konsultan pajak sebelum go-live.
