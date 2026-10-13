-- Masa percobaan berakhir (V028)
BEGIN;
CREATE TEMP TABLE m (a uuid);
GRANT ALL ON m TO PUBLIC;
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
INSERT INTO m SELECT pos.platform_provision_merchant('TRIALX', 'Trial X', 'FNB', 'TRIAL', 'TX1', 'TX Pusat', 'Tia', 'tia@tx.test', pos_test.make_auth_user('tia@tx.test'));
RESET ROLE;

SELECT pos_test.login('trialx.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT NOT expired AND status = 'TRIAL' AND trial_ends_at > now() FROM pos.my_subscription()), 'trial berjalan: belum kedaluwarsa');
SELECT pos_test.throws($$INSERT INTO pos.cashier_sessions (organization_id) SELECT a FROM m$$, 'TERMINAL_INACTIVE', 'saat trial berjalan, penjaga trial tidak menolak');
RESET ROLE;

SELECT pos_test.expire_trial((SELECT a FROM m));
SELECT pos_test.login('trialx.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT expired FROM pos.my_subscription()), 'trial berakhir terdeteksi');
SELECT pos_test.throws($$INSERT INTO pos.cashier_sessions (organization_id) SELECT a FROM m$$, 'TRIAL_EXPIRED', 'membuka kasir ditolak setelah trial berakhir');
SELECT pos_test.throws($$INSERT INTO pos.sales (organization_id) SELECT a FROM m$$, 'TRIAL_EXPIRED', 'penjualan baru ditolak setelah trial berakhir');
SELECT pos_test.ok((SELECT count(*) > 0 FROM pos.outlets), 'data tetap bisa dilihat');
RESET ROLE;

SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos.platform_set_plan((SELECT a FROM m), 'TRIAL');
RESET ROLE;
SELECT pos_test.login('trialx.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT NOT expired FROM pos.my_subscription()), 'operator memperpanjang trial 14 hari');
RESET ROLE;

SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos.platform_set_plan((SELECT a FROM m), 'STARTER');
RESET ROLE;
SELECT pos_test.expire_trial((SELECT a FROM m));
SELECT pos_test.login('trialx.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT NOT expired AND status = 'ACTIVE' FROM pos.my_subscription()), 'paket berbayar tidak terkena batas trial');
RESET ROLE;
ROLLBACK;
