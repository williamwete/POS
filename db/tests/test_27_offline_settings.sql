-- Pengaturan offline per merchant (V033)
BEGIN;
SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos.set_offline_settings(true, 500000, 120);
SELECT pos_test.ok((SELECT (pos.get_setting('allow_offline_sale', NULL))::boolean), 'offline diizinkan');
SELECT pos_test.ok((SELECT (pos.get_setting('max_offline_sale_amount', NULL))::text::numeric = 500000), 'batas nilai tersimpan');
SELECT pos_test.ok((SELECT (pos.get_setting('max_offline_duration_minutes', NULL))::text::int = 120), 'batas durasi tersimpan');
SELECT pos.set_offline_settings(false, 0, 0);
SELECT pos_test.ok(NOT (SELECT (pos.get_setting('allow_offline_sale', NULL))::boolean), 'dapat dimatikan lagi (upsert)');
SELECT pos_test.throws($$SELECT pos.set_offline_settings(true, -1, 10)$$, 'CATALOG_INVALID', 'batas negatif ditolak');
SELECT pos_test.throws($$SELECT pos.set_offline_settings(true, 1000.5, 10)$$, 'CATALOG_INVALID', 'batas pecahan ditolak');
SELECT pos_test.throws($$SELECT pos.set_offline_settings(true, 1000, 99999)$$, 'CATALOG_INVALID', 'durasi terlalu besar ditolak');
SELECT pos_test.throws($$SELECT pos.set_offline_settings(NULL, 1000, 10)$$, 'CATALOG_INVALID', 'nilai kosong ditolak');
RESET ROLE;

SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.set_offline_settings(true, 1000, 10)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak boleh mengubah');
RESET ROLE;
ROLLBACK;
