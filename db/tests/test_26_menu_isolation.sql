-- Akses menu hanya berlaku di merchant sendiri
BEGIN;
CREATE TEMP TABLE m (a uuid, b uuid);
GRANT ALL ON m TO PUBLIC;
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
INSERT INTO m (a) SELECT pos.platform_provision_merchant('MENUA', 'Menu A', 'FNB', 'STARTER', 'MA1', 'MA Pusat', 'Ani', 'ani@ma.test', pos_test.make_auth_user('ani@ma.test'));
INSERT INTO m (b) SELECT pos.platform_provision_merchant('MENUB', 'Menu B', 'RETAIL', 'STARTER', 'MB1', 'MB Pusat', 'Bima', 'bima@mb.test', pos_test.make_auth_user('bima@mb.test'));
RESET ROLE;

SELECT pos_test.login('menua.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos.set_menu_enabled('manage-receipt', 'CASHIER', true);
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.menu_settings WHERE menu_code = 'manage-receipt' AND role_code = 'CASHIER' AND enabled), 'owner A menyimpan pengaturan di merchant sendiri');
SELECT pos_test.ok((SELECT count(DISTINCT organization_id) = 1 FROM pos.menu_settings), 'owner A hanya melihat pengaturan satu merchant');
RESET ROLE;

SELECT pos_test.login('menub.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.menu_settings), 'owner B tidak melihat pengaturan merchant A');
SELECT pos.set_menu_enabled('manage-receipt', 'CASHIER', false);
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.menu_settings), 'owner B mengembalikan ke bawaan tanpa menyentuh A');
RESET ROLE;

SELECT pos_test.login('menua.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT enabled FROM pos.menu_settings WHERE menu_code = 'manage-receipt' AND role_code = 'CASHIER'), 'perubahan owner B tidak menimpa pengaturan A');
SELECT pos_test.throws($$SELECT pos.set_menu_enabled('manage-receipt', 'SUPER_ADMIN', true)$$, 'MENU_ROLE_NOT_CONFIGURABLE', 'role platform tidak dapat diatur dari merchant');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) FROM pos.menu_settings WHERE menu_code = 'manage-receipt' AND role_code = 'CASHIER') = 0, 'merchant DEMO tidak ikut terpengaruh');
RESET ROLE;
ROLLBACK;
