-- Laporan penjualan terperinci (V035)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set T1 '''00000000-0000-4000-8000-000000000401'''
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,10}}') AS id;
GRANT SELECT ON s TO PUBLIC;
CREATE TEMP TABLE a AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM a), 'SKU-0012', 3);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM a);
SELECT pos_test.pay((SELECT id FROM a), 'CASH', 1, 200000);
CREATE TEMP TABLE b AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM b), 'SKU-0012', 2);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM b);
SELECT pos_test.pay((SELECT id FROM b), 'DEBIT_CARD', 100000, NULL, 'APPR-777');
SELECT pos_test.throws($$SELECT pos.sales_report(current_date - 1, current_date + 1, NULL, 'PRODUCT')$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa membuka laporan');
RESET ROLE;

SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE p AS SELECT pos.sales_report(current_date - 1, current_date + 1, :JKT, 'PRODUCT') AS j;
CREATE TEMP TABLE k AS SELECT pos.sales_report(current_date - 1, current_date + 1, :JKT, 'CASHIER') AS j;
CREATE TEMP TABLE d AS SELECT pos.sales_report(current_date - 1, current_date + 1, :JKT, 'DAY') AS j;
CREATE TEMP TABLE y AS SELECT pos.sales_report(current_date - 1, current_date + 1, :JKT, 'PAYMENT') AS j;
CREATE TEMP TABLE c AS SELECT pos.sales_report(current_date - 1, current_date + 1, :JKT, 'CATEGORY') AS j;
GRANT SELECT ON p, k, d, y, c TO PUBLIC;
SELECT pos_test.ok((SELECT (j #>> '{rows,0,key}') = 'SKU-0012' AND (j #>> '{rows,0,quantity}')::numeric = 5 FROM p), 'laporan produk: SKU-0012 terjual 5');
SELECT pos_test.ok((SELECT (j #>> '{rows,0,transactions}')::int = 2 FROM p), 'laporan produk: 2 transaksi');
SELECT pos_test.ok((SELECT (j #>> '{rows,0,net}')::numeric = 250000 FROM p), 'laporan produk: nilai bersih 250.000');
SELECT pos_test.ok((SELECT jsonb_array_length(j -> 'rows') = 1 AND (j #>> '{rows,0,transactions}')::int = 2 FROM k), 'laporan kasir: satu kasir dengan 2 transaksi');
SELECT pos_test.ok((SELECT (j #>> '{rows,0,net}')::numeric = 250000 FROM k), 'laporan kasir: omzet kasir sama dengan produk');
SELECT pos_test.ok((SELECT jsonb_array_length(j -> 'rows') = 1 AND (j #>> '{rows,0,net}')::numeric = 250000 FROM d), 'laporan harian: satu hari 250.000');
SELECT pos_test.ok((SELECT jsonb_array_length(j -> 'rows') = 2 FROM y), 'laporan metode bayar: tunai dan debit');
SELECT pos_test.ok((SELECT (j #>> '{rows,0,net}')::numeric + (j #>> '{rows,1,net}')::numeric = 250000 FROM y), 'laporan metode bayar: jumlah sama dengan omzet');
SELECT pos_test.ok((SELECT jsonb_array_length(j -> 'rows') >= 1 FROM c), 'laporan kategori terisi');
SELECT pos_test.throws($$SELECT pos.sales_report(current_date, current_date - 2, '00000000-0000-4000-8000-000000000101', 'PRODUCT')$$, 'CATALOG_INVALID', 'rentang terbalik ditolak');
SELECT pos_test.throws($$SELECT pos.sales_report(current_date - 1, current_date, '00000000-0000-4000-8000-000000000101', 'HACK')$$, 'CATALOG_INVALID', 'pengelompokan asing ditolak');
RESET ROLE;

SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.sales_report(current_date - 1, current_date + 1, NULL, 'PRODUCT')$$, 'USER_NOT_AUTHORIZED', 'operator platform tidak membuka laporan merchant');
RESET ROLE;
ROLLBACK;
