-- Penjualan offline: pencatatan, peninjauan selisih, hak akses (V031)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set T1 '''00000000-0000-4000-8000-000000000401'''
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,10}}') AS id;
GRANT SELECT ON s TO PUBLIC;
CREATE TEMP TABLE a AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM a), 'SKU-0012', 1);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM a);
SELECT pos_test.pay((SELECT id FROM a), 'CASH', 1, 200000);
CREATE TEMP TABLE b AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM b), 'SKU-0012', 2);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM b);
SELECT pos_test.pay((SELECT id FROM b), 'CASH', 1, 200000);
GRANT SELECT ON a, b TO PUBLIC;

CREATE TEMP TABLE r1 AS SELECT pos.record_offline_sale((SELECT id FROM a), now() - interval '2 hours',
    (SELECT grand_total FROM pos.sales WHERE id = (SELECT id FROM a)), NULL) AS id;
CREATE TEMP TABLE r2 AS SELECT pos.record_offline_sale((SELECT id FROM b), now() - interval '1 hour', 1, 'Harga server berbeda dari harga offline') AS id;
GRANT SELECT ON r1, r2 TO PUBLIC;
SELECT pos_test.ok((SELECT status = 'CLEAN' FROM pos.offline_sales WHERE id = (SELECT id FROM r1)) IS NOT TRUE, 'kasir tidak membaca tabel peninjauan');
SELECT pos_test.ok(pos.record_offline_sale((SELECT id FROM a), now() - interval '2 hours', 1, NULL) = (SELECT id FROM r1), 'pencatatan ulang idempoten');
SELECT pos_test.throws($$SELECT pos.record_offline_sale('00000000-0000-4000-8000-0000000fffff', now(), 1, NULL)$$, 'CATALOG_INVALID', 'transaksi tidak dikenal ditolak');
SELECT pos_test.throws($$SELECT pos.record_offline_sale((SELECT id FROM a), now() + interval '1 day', 1, NULL)$$, 'CATALOG_INVALID', 'waktu di masa depan ditolak');
SELECT pos_test.throws($$SELECT pos.offline_reviews('00000000-0000-4000-8000-000000000101', 'OPEN')$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa melihat daftar peninjauan');
-- stok: transaksi offline tidak boleh ditolak karena stok, transaksi biasa tetap ditolak
CREATE TEMP TABLE d AS SELECT pos_test.new_sale() AS id;
GRANT SELECT ON d TO PUBLIC;
SELECT pos_test.add_item((SELECT id FROM d), 'SKU-0012', 90000);
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM d)$$, 'STOCK_UNAVAILABLE', 'transaksi biasa tetap ditolak bila stok kurang');
SELECT pos.offline_stock_waiver(:JKT);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM d);
SELECT pos_test.ok((SELECT status = 'CHECKOUT' FROM pos.sales WHERE id = (SELECT id FROM d)), 'transaksi offline tidak ditolak karena stok');
RESET ROLE;

SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT jsonb_array_length(pos.offline_reviews(:JKT, 'OPEN'))) = 1, 'manajer melihat 1 selisih terbuka');
SELECT pos_test.ok((SELECT jsonb_array_length(pos.offline_reviews(:JKT, 'CLEAN'))) = 1, 'transaksi tanpa selisih tercatat bersih');
SELECT pos_test.throws($$SELECT pos.resolve_offline_review((SELECT id FROM r2), 'ok')$$, 'CATALOG_INVALID', 'catatan terlalu pendek ditolak');
SELECT pos.resolve_offline_review((SELECT id FROM r2), 'Sudah dicek dengan kasir, harga promo');
SELECT pos_test.ok((SELECT jsonb_array_length(pos.offline_reviews(:JKT, 'OPEN'))) = 0, 'setelah ditinjau tidak ada yang terbuka');
SELECT pos_test.throws($$SELECT pos.resolve_offline_review((SELECT id FROM r2), 'Dicek ulang lagi')$$, 'CATALOG_INVALID', 'peninjauan tidak bisa diselesaikan dua kali');
RESET ROLE;
ROLLBACK;
