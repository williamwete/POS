-- Dasbor penjualan (V030)
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
CREATE TEMP TABLE c AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM c), 'SKU-0001', 1);
UPDATE pos.sales SET status = 'VOID', void_reason = 'Pelanggan batal beli' WHERE id = (SELECT id FROM c);
SELECT pos_test.throws($$SELECT pos.dashboard(current_date - 1, current_date + 1, NULL)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa membuka dasbor');
RESET ROLE;

SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE d AS SELECT pos.dashboard(current_date - 1, current_date + 1, :JKT) AS j;
GRANT SELECT ON d TO PUBLIC;
SELECT pos_test.ok((SELECT (j #>> '{summary,salesCount}')::int = 2 FROM d), 'dasbor: 2 penjualan lunas');
SELECT pos_test.ok((SELECT (j #>> '{summary,netSales}')::numeric = 250000 FROM d), 'dasbor: omzet 250.000');
SELECT pos_test.ok((SELECT (j #>> '{summary,voidCount}')::int = 1 FROM d), 'dasbor: 1 transaksi void');
SELECT pos_test.ok((SELECT (j #>> '{summary,avgBasket}')::numeric = 125000 FROM d), 'dasbor: rata-rata keranjang');
SELECT pos_test.ok((SELECT jsonb_array_length(j -> 'daily') = 3 FROM d), 'dasbor: deret harian terisi untuk seluruh rentang');
SELECT pos_test.ok((SELECT jsonb_array_length(j -> 'hourly') = 24 FROM d), 'dasbor: 24 jam');
SELECT pos_test.ok((SELECT (j #>> '{payments,0,method}') = 'CASH' AND jsonb_array_length(j -> 'payments') = 2 FROM d), 'dasbor: rincian metode bayar');
SELECT pos_test.ok((SELECT (j #>> '{topProducts,0,sku}') = 'SKU-0012' AND (j #>> '{topProducts,0,quantity}')::numeric = 5 FROM d), 'dasbor: produk terlaris');
SELECT pos_test.ok((SELECT (j #>> '{attention,openSessions}')::int >= 1 FROM d), 'dasbor: kasir yang masih terbuka terlihat');
SELECT pos_test.throws($$SELECT pos.dashboard(current_date, current_date - 5, '00000000-0000-4000-8000-000000000101')$$, 'CATALOG_INVALID', 'rentang terbalik ditolak');
SELECT pos_test.throws($$SELECT pos.dashboard(current_date - 400, current_date, '00000000-0000-4000-8000-000000000101')$$, 'CATALOG_INVALID', 'rentang lebih dari 366 hari ditolak');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT (pos.dashboard(current_date - 1, current_date + 1, NULL) #>> '{summary,salesCount}')::int >= 2), 'owner melihat seluruh outlet');
RESET ROLE;

SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.dashboard(current_date - 1, current_date + 1, NULL)$$, 'USER_NOT_AUTHORIZED', 'operator platform tidak membuka dasbor merchant');
RESET ROLE;
ROLLBACK;
