-- Katalog lokal (SaaS): produk, kategori, pajak, stok awal, opsi produk, preset diskon, profil struk
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set BDG '''00000000-0000-4000-8000-000000000102'''
\set T1 '''00000000-0000-4000-8000-000000000401'''

BEGIN;
-- ---- izin
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.save_category(NULL, 'MIE', 'Mie', true)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa membuat kategori');
SELECT pos_test.throws($$SELECT pos.save_product(NULL, 'X1', 'X', NULL, 'PCS', false, NULL, true, true, NULL, NULL, 1000)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa membuat produk');
SELECT pos_test.throws($$SELECT pos.save_receipt_profile(NULL, 'Toko', NULL, NULL, NULL, NULL, NULL, true, true, 80)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa mengubah struk');
RESET ROLE;

SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.save_product(NULL, 'X1', 'X', NULL, 'PCS', false, NULL, true, true, NULL, NULL, 1000)$$, 'USER_NOT_AUTHORIZED', 'supervisor tidak bisa membuat produk');
SELECT pos_test.throws($$SELECT pos.save_receipt_profile(NULL, 'Toko', NULL, NULL, NULL, NULL, NULL, true, true, 80)$$, 'USER_NOT_AUTHORIZED', 'supervisor tidak bisa mengubah struk');
SELECT pos_test.throws($$SELECT pos.save_discount_preset(NULL, NULL, 'Promo semua outlet', 'PERCENTAGE', 5, true)$$, 'USER_NOT_AUTHORIZED', 'supervisor outlet tidak bisa membuat diskon seluruh organisasi');
SELECT pos_test.throws($$SELECT pos.save_discount_preset(NULL, '00000000-0000-4000-8000-000000000102', 'Promo Bandung', 'PERCENTAGE', 5, true)$$, 'USER_NOT_AUTHORIZED', 'supervisor JKT tidak bisa membuat diskon outlet BDG');
CREATE TEMP TABLE c (preset uuid, cat uuid, tax uuid, prod uuid, prod2 uuid, grp uuid, grp2 uuid, o1 uuid, o2 uuid, o3 uuid);
GRANT ALL ON c TO PUBLIC;
INSERT INTO c (preset) SELECT pos.save_discount_preset(NULL, :JKT, 'Diskon member 10%', 'PERCENTAGE', 10, true);
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.discount_presets WHERE outlet_id = :JKT), 'supervisor membuat diskon untuk outletnya');
SELECT pos_test.throws($$SELECT pos.save_discount_preset(NULL, '00000000-0000-4000-8000-000000000101', 'Diskon member 10%', 'PERCENTAGE', 5, true)$$, 'discount_presets_name_uk', 'nama diskon unik per cakupan');
SELECT pos_test.throws($$SELECT pos.save_discount_preset(NULL, '00000000-0000-4000-8000-000000000101', 'Terlalu besar', 'PERCENTAGE', 150, true)$$, 'CATALOG_INVALID', 'persen maksimal 100');
RESET ROLE;

SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.discount_presets), 'kasir outlet lain tidak melihat diskon outlet JKT');
RESET ROLE;

-- ---- admin: kategori, pajak, produk
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
UPDATE c SET cat = pos.save_category(NULL, 'MIE', 'Mie & Nasi', true);
UPDATE c SET tax = pos.save_tax_rate(NULL, 'PB1', 'PB1 10%', 10, true);
UPDATE c SET prod = pos.save_product(NULL, 'MIE-AYAM', 'Mie Ayam', (SELECT cat FROM c), 'PORSI', false, (SELECT tax FROM c), false, true, NULL, '8991234500011', 25000);
SELECT pos_test.ok((SELECT p.source = 'LOCAL' AND NOT p.track_stock AND p.tax_rate_id = (SELECT tax FROM c) FROM pos.products p WHERE p.id = (SELECT prod FROM c)), 'produk lokal tersimpan (tanpa stok, PB1)');
SELECT pos_test.ok((SELECT (pr.price_id IS NOT NULL AND pr.price = 25000 AND pr.source = 'LOCAL') FROM pos.product_price((SELECT prod FROM c), :JKT) pr), 'harga lokal berlaku di semua outlet');
SELECT pos_test.ok((SELECT barcode_type = 'EAN13' AND is_primary FROM pos.product_barcodes WHERE product_id = (SELECT prod FROM c)), 'barcode EAN13 tersimpan sebagai utama');
SELECT pos_test.throws($$SELECT pos.save_product(NULL, 'MIE-AYAM', 'Dobel', NULL, 'PCS', false, NULL, true, true, NULL, NULL, 1000)$$, 'products_org_sku_uk', 'SKU harus unik');
SELECT pos_test.throws($$SELECT pos.save_product(NULL, 'BC-DUP', 'Dobel barcode', NULL, 'PCS', false, NULL, true, true, NULL, '8991234500011', 1000)$$, 'product_barcodes_org_barcode_uk', 'barcode harus unik');
SELECT pos_test.throws($$SELECT pos.save_product(NULL, 'NO-PRICE', 'Tanpa harga', NULL, 'PCS', false, NULL, true, true, NULL, NULL, NULL)$$, 'CATALOG_INVALID', 'produk baru wajib berharga');
SELECT pos_test.throws($$SELECT pos.save_product(NULL, 'BAD CAT', 'x', gen_random_uuid(), 'PCS', false, NULL, true, true, NULL, NULL, 1)$$, 'CATALOG_INVALID', 'kategori harus ada di organisasi');
SELECT pos_test.throws($$SELECT pos.save_product(NULL, 'NEG', 'x', NULL, 'PCS', false, NULL, true, true, NULL, NULL, -1)$$, 'CATALOG_INVALID', 'harga tidak boleh negatif');
-- ubah harga = versi baru, versi lama ditutup
SELECT pos.save_product((SELECT prod FROM c), 'MIE-AYAM', 'Mie Ayam Spesial', (SELECT cat FROM c), 'PORSI', false, (SELECT tax FROM c), false, true, NULL, NULL, 27000);
SELECT pos_test.ok((SELECT pr.price = 27000 AND pr.version = 2 FROM pos.product_price((SELECT prod FROM c), :JKT, clock_timestamp()) pr), 'harga baru versi 2');
SELECT pos_test.ok((SELECT count(*) = 2 AND count(*) FILTER (WHERE valid_to IS NULL) = 1 FROM pos.product_price_cache WHERE product_id = (SELECT prod FROM c)), 'riwayat harga tersimpan, satu yang berlaku');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.product_barcodes WHERE product_id = (SELECT prod FROM c) AND active), 'barcode tidak berubah saat dikosongkan NULL');
SELECT pos.save_product((SELECT prod FROM c), 'MIE-AYAM', 'Mie Ayam Spesial', (SELECT cat FROM c), 'PORSI', false, (SELECT tax FROM c), false, true, NULL, '', NULL);
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.product_barcodes WHERE product_id = (SELECT prod FROM c) AND active), 'barcode kosong menghapus barcode utama');

-- produk Openbravo tidak bisa diubah dari aplikasi
RESET ROLE;
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
UPDATE pos.products SET source = 'OPENBRAVO' WHERE sku = 'SKU-0002';
RESET ROLE;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.save_product((SELECT id FROM pos.products WHERE sku = 'SKU-0002'), 'SKU-0002', 'Ubah', NULL, 'PCS', false, NULL, true, true, NULL, NULL, 100)$$, 'CATALOG_READ_ONLY', 'produk Openbravo read-only');
SELECT pos_test.throws($$SELECT pos.set_local_stock((SELECT id FROM pos.products WHERE sku = 'SKU-0002'), '00000000-0000-4000-8000-000000000101', 5)$$, 'CATALOG_READ_ONLY', 'stok produk Openbravo read-only');

-- ---- stok awal produk lokal
UPDATE c SET prod2 = pos.save_product(NULL, 'KOPI-250', 'Kopi Bubuk 250 g', (SELECT cat FROM c), 'PCS', false, NULL, true, true, NULL, NULL, 18000);
SELECT pos_test.ok(pos.available_to_sell((SELECT prod2 FROM c), :JKT) IS NULL, 'produk berstok baru: stok belum diketahui');
SELECT pos.set_local_stock((SELECT prod2 FROM c), :JKT, 12);
SELECT pos_test.ok(pos.available_to_sell((SELECT prod2 FROM c), :JKT) = 12, 'stok awal 12 tersedia');
SELECT pos.set_local_stock((SELECT prod2 FROM c), :JKT, 7);
SELECT pos_test.ok(pos.available_to_sell((SELECT prod2 FROM c), :JKT) = 7, 'penyesuaian stok menjadi 7');
SELECT pos_test.throws($$SELECT pos.set_local_stock((SELECT prod2 FROM c), '00000000-0000-4000-8000-000000000101', -1)$$, 'CATALOG_INVALID', 'stok tidak boleh negatif');

-- ---- opsi produk
UPDATE c SET grp = pos.save_option_group(NULL, 'Level pedas', 1, 1, 1, true);
UPDATE c SET grp2 = pos.save_option_group(NULL, 'Topping', 0, 2, 2, true);
UPDATE c SET o1 = pos.save_option(NULL, (SELECT grp FROM c), 'Tidak pedas', 0, 1, true);
UPDATE c SET o2 = pos.save_option(NULL, (SELECT grp FROM c), 'Pedas', 0, 2, true);
UPDATE c SET o3 = pos.save_option(NULL, (SELECT grp2 FROM c), 'Bakso', 5000, 1, true);
SELECT pos.save_option(NULL, (SELECT grp2 FROM c), 'Pangsit', 3000, 2, true);
SELECT pos_test.throws($$SELECT pos.save_option(NULL, (SELECT grp FROM c), 'Negatif', -1, 1, true)$$, 'CATALOG_INVALID', 'harga tambahan tidak negatif');
SELECT pos_test.throws($$SELECT pos.save_option_group(NULL, 'Rusak', 3, 2, 1, true)$$, 'CATALOG_INVALID', 'min tidak boleh melebihi max');
SELECT pos.set_product_options((SELECT prod FROM c), ARRAY[(SELECT grp FROM c), (SELECT grp2 FROM c)]);
SELECT pos_test.ok((SELECT count(*) = 2 FROM pos.product_option_links WHERE product_id = (SELECT prod FROM c)), 'dua grup opsi tertaut ke produk');
SELECT pos_test.throws($$SELECT pos.set_product_options((SELECT prod FROM c), ARRAY[gen_random_uuid()])$$, 'CATALOG_NOT_FOUND', 'grup opsi harus ada');

-- ---- profil struk
SELECT pos.save_receipt_profile(NULL, 'Warung Mie Sejahtera', 'Jl. Merdeka 1', '021-555', 'Selamat datang', 'Terima kasih', '01.234.567.8-901.000', true, true, 58);
SELECT pos.save_receipt_profile(:JKT, 'Warung Mie Cabang JKT', NULL, NULL, NULL, 'Sampai jumpa', NULL, false, true, 80);
SELECT pos_test.ok((SELECT count(*) = 2 FROM pos.receipt_profiles), 'profil struk organisasi dan outlet');
SELECT pos.save_receipt_profile(:JKT, 'Warung Mie Cabang JKT 2', NULL, NULL, NULL, 'Sampai jumpa', NULL, false, true, 80);
SELECT pos_test.ok((SELECT count(*) = 2 AND bool_or(business_name = 'Warung Mie Cabang JKT 2') FROM pos.receipt_profiles), 'simpan ulang memperbarui, bukan menambah');
SELECT pos_test.throws($$SELECT pos.save_receipt_profile(NULL, 'Toko', NULL, NULL, NULL, NULL, NULL, true, true, 70)$$, 'CATALOG_INVALID', 'lebar kertas 58 atau 80');
RESET ROLE;

-- ---- penjualan: opsi, harga tambahan, produk tanpa stok
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
CREATE TEMP TABLE s (sale uuid);
GRANT ALL ON s TO PUBLIC;
INSERT INTO s SELECT pos_test.new_sale();
SELECT pos_test.throws($$INSERT INTO pos.sale_items (sale_id, product_id, sku, product_name, uom, quantity, list_price, unit_price, created_by)
    SELECT (SELECT sale FROM s), prod, 'x', 'x', 'x', 1, 1, 1, pos.current_app_user_id() FROM c$$,
    'OPTION_SELECTION_INVALID', 'level pedas wajib dipilih');
SELECT pos_test.throws($$INSERT INTO pos.sale_items (sale_id, product_id, sku, product_name, uom, quantity, list_price, unit_price, created_by, option_ids)
    SELECT (SELECT sale FROM s), prod, 'x', 'x', 'x', 1, 1, 1, pos.current_app_user_id(), ARRAY[o1, o2] FROM c$$,
    'OPTION_SELECTION_INVALID', 'level pedas hanya boleh satu');
SELECT pos_test.throws($$INSERT INTO pos.sale_items (sale_id, product_id, sku, product_name, uom, quantity, list_price, unit_price, created_by, option_ids)
    SELECT (SELECT sale FROM s), prod2, 'x', 'x', 'x', 1, 1, 1, pos.current_app_user_id(), ARRAY[o1] FROM c$$,
    'OPTION_SELECTION_INVALID', 'opsi milik produk lain ditolak');
INSERT INTO pos.sale_items (sale_id, product_id, sku, product_name, uom, quantity, list_price, unit_price, created_by, option_ids)
SELECT (SELECT sale FROM s), prod, 'x', 'x', 'x', 2, 1, 1, pos.current_app_user_id(), ARRAY[o2, o3] FROM c;
SELECT pos_test.ok((SELECT unit_price = 30000 AND list_price = 30000 AND gross_amount = 60000 AND jsonb_array_length(options) = 2
                    AND options -> 0 ->> 'name' = 'Pedas' AND options -> 1 ->> 'name' = 'Bakso'
                    FROM pos.sale_items), 'harga = 25.000 (harga berlaku saat transaksi dimulai) + topping 5.000; snapshot opsi tersimpan');
SELECT pos_test.ok((SELECT tax_rate = 10 AND tax_amount = 5455 FROM pos.sale_items), 'PB1 10% termasuk harga dihitung dari harga + opsi');
SELECT pos_test.throws($$UPDATE pos.sale_items SET option_ids = '{}'$$, 'SALE_ITEM_IMMUTABLE_FIELD', 'opsi tidak bisa diubah setelah dipilih');
-- produk tanpa stok lolos checkout walaupun stok tidak ada; produk berstok tetap dicek
UPDATE pos.sales SET status = 'CHECKOUT';
SELECT pos_test.ok((SELECT status = 'CHECKOUT' AND grand_total = 60000 FROM pos.sales), 'produk tanpa stok boleh checkout');
RESET ROLE;
ROLLBACK;

-- Foto produk (V025)
BEGIN;
SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE ph (id uuid);
GRANT ALL ON ph TO PUBLIC;
INSERT INTO ph SELECT pos.save_product(NULL, 'FOTO1', 'Produk Foto', NULL, 'PCS', false, NULL, true, true, 'data:image/png;base64,iVBORw0KGgo=', NULL, 5000);
SELECT pos_test.ok((SELECT image_url LIKE 'data:image/png%' FROM pos.products WHERE id = (SELECT id FROM ph)), 'foto produk tersimpan');
SELECT pos_test.throws($$SELECT pos.save_product((SELECT id FROM ph), 'FOTO1', 'Produk Foto', NULL, 'PCS', false, NULL, true, true, 'data:image/svg+xml;base64,PHN2Zz4=', NULL, NULL)$$, 'CATALOG_INVALID', 'foto SVG ditolak');
SELECT pos.save_product((SELECT id FROM ph), 'FOTO1', 'Produk Foto Baru', NULL, 'PCS', false, NULL, true, true, NULL, NULL, NULL);
SELECT pos_test.ok((SELECT image_url IS NOT NULL FROM pos.products WHERE id = (SELECT id FROM ph)), 'p_image NULL tidak menghapus foto');
SELECT pos.save_product((SELECT id FROM ph), 'FOTO1', 'Produk Foto Baru', NULL, 'PCS', false, NULL, true, true, '', NULL, NULL);
SELECT pos_test.ok((SELECT image_url IS NULL FROM pos.products WHERE id = (SELECT id FROM ph)), 'p_image kosong menghapus foto');
RESET ROLE;
ROLLBACK;
