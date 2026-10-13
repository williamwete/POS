-- Impor produk massal (V029)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.import_products('[{"sku":"IMP1","name":"x","price":"1000"}]'::jsonb, NULL)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa impor produk');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT (r ->> 'created')::int = 2 AND (r ->> 'categoriesCreated')::int = 1 AND (r ->> 'updated')::int = 0
    FROM (SELECT pos.import_products('[
        {"sku":"IMP-1","name":"Kopi Susu","category":"Minuman Impor","price":"18000","barcode":"8995550000011","stock":"25","uom":"CUP"},
        {"sku":"IMP-2","name":"Teh Tarik","category":"minuman impor","price":"15000"}]'::jsonb, '00000000-0000-4000-8000-000000000101') AS r) x),
    'impor membuat 2 produk dan 1 kategori baru (nama kategori tidak peka huruf besar)');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.product_barcodes WHERE barcode = '8995550000011'), 'barcode tersimpan');
SELECT pos_test.ok((SELECT uom = 'CUP' FROM pos.products WHERE sku = 'IMP-1'), 'satuan tersimpan');
SELECT pos_test.ok((SELECT (r ->> 'updated')::int = 1 AND (r ->> 'created')::int = 0
    FROM (SELECT pos.import_products('[{"sku":"IMP-1","name":"Kopi Susu Gula Aren","price":"20000"}]'::jsonb, NULL) AS r) x),
    'SKU yang sudah ada diperbarui');
SELECT pos_test.ok((SELECT name = 'Kopi Susu Gula Aren' AND uom = 'CUP' FROM pos.products WHERE sku = 'IMP-1'), 'kolom kosong tidak menimpa data lama');
SELECT pos_test.throws($$SELECT pos.import_products('[{"sku":"IMP-3","name":"Baik","price":"1000"},{"sku":"IMP-4","name":"Salah","price":"-5"}]'::jsonb, NULL)$$, 'baris 2', 'galat menyebut nomor baris');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.products WHERE sku IN ('IMP-3', 'IMP-4')), 'impor gagal membatalkan seluruh berkas');
SELECT pos_test.throws($$SELECT pos.import_products('[{"sku":"IMP-5","name":"Tanpa harga"}]'::jsonb, NULL)$$, 'harga wajib', 'produk baru wajib harga');
SELECT pos_test.throws($$SELECT pos.import_products('[]'::jsonb, NULL)$$, 'CATALOG_INVALID', 'berkas kosong ditolak');
RESET ROLE;
ROLLBACK;
