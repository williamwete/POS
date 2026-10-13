# Katalog lokal (merchant tanpa ERP)

POS dapat dipakai tanpa Openbravo: set `OPENBRAVO_MODE=DISABLED` dan kelola katalog langsung di aplikasi.
Dengan Openbravo aktif, data bersumber Openbravo tetap **read-only** di POS (ikon gembok).

## Siapa boleh apa

| Aksi | Permission | Default role |
|---|---|---|
| Produk, harga, stok awal, pajak, opsi produk | `product.manage` | Admin, Owner |
| Kategori | `category.manage` | Admin, Owner |
| Diskon siap pakai | `discount.manage` | Admin, Owner (seluruh outlet); Supervisor (outletnya) |
| Tampilan struk | `receipt.manage` | Admin, Owner |
| Lihat Product List | `stock.view` | semua role operasional |

Menu hanya lapisan tampilan (lihat `docs/ROLES.md`); izin sebenarnya diperiksa fungsi database (`pos.require_perm`).

## Produk
- `source`: `LOCAL` (dibuat di POS), `SEED` (data demo, boleh diubah), `OPENBRAVO` (read-only).
- **Harga**: mengubah harga membuat versi baru di `product_price_cache` dan menutup versi lama; riwayat tetap tersimpan.
  Transaksi tetap mengambil harga dari database (`pos.product_price`), tidak pernah dari client.
- **Lacak stok** (`track_stock`): matikan untuk makanan/minuman yang dibuat saat dipesan dan untuk jasa. Produk ini tidak
  dicek stoknya saat checkout. Untuk produk berstok, "Stok di outlet" mengatur stok tersedia sekarang
  (`pos.set_local_stock`); penjualan setelahnya mengurangi stok.
- Barcode: satu barcode utama per produk, unik per organisasi. Mengosongkan kolom barcode menghapus barcode utama.

## Opsi produk (mis. Level pedas, Topping)
- Grup opsi: `min_select`/`max_select` (1/1 = pilih satu wajib; 0/2 = opsional maksimal dua).
- Opsi punya harga tambahan (≥ 0). Satu grup bisa dipasang ke banyak produk.
- Saat dijual, pilihan disimpan di baris (`sale_items.option_ids` + `options` sebagai snapshot nama & harga).
  Harga baris = harga produk + total harga tambahan, **dihitung trigger database** dan tidak bisa diubah setelahnya.
- Produk yang sama dengan pilihan berbeda menjadi baris terpisah.
- Opsi tampil di struk. Sinkronisasi Openbravo mengirim harga baris (sudah termasuk opsi); opsi tidak dikirim sebagai item sendiri.

## Diskon siap pakai
Tombol di dialog diskon kasir mengisi jenis, nilai, dan alasan. Batas diskon kasir/manajer dan persetujuan supervisor
tetap berlaku (`max_cashier_discount`, `max_manager_discount`). Diskon bisa untuk semua outlet atau satu outlet.

## Struk
Profil per organisasi (bawaan) dengan penimpaan per outlet: nama usaha, alamat, telepon, NPWP, teks header/footer,
rincian pajak, nama kasir, lebar kertas 58/80 mm. Kolom kosong memakai data organisasi/outlet.

## Pajak
Tarif dikelola di Manage Categories → Pajak. PPN 11% hanya untuk usaha PKP; restoran umumnya PB1 (~10%, sesuai perda).
Harga termasuk pajak atau di luar pajak diatur per outlet lewat setting `prices_include_tax`.

## Batasan saat ini
- Belum ada impor produk massal (CSV) dan unggah foto produk (gunakan URL gambar/`image_url`).
- Harga khusus per outlet belum bisa diatur dari UI (tabel mendukungnya).
- Hapus produk tidak ada; nonaktifkan saja agar riwayat penjualan tetap utuh.

## Impor produk CSV (V029)
Menu Produk → **Impor CSV**. Kolom: `sku, nama, harga` wajib; `kategori, satuan, barcode, stok` opsional (judul Indonesia atau Inggris, pemisah koma/titik koma). SKU yang sudah ada diperbarui (kolom kosong tidak menimpa), SKU baru dibuat; kategori yang belum ada dibuat otomatis; stok diisi untuk outlet terpilih. Maksimal 500 baris; satu galat membatalkan seluruh berkas dan menyebut nomor barisnya. Produk dari Openbravo tidak bisa diubah. Batas jumlah produk paket tetap berlaku.
