-- Branding per merchant
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.save_branding('Toko', '#3F6A9E', NULL)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa mengubah branding');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.save_branding('Toko', 'biru', NULL)$$, 'CATALOG_INVALID', 'format warna harus #RRGGBB');
SELECT pos_test.throws($$SELECT pos.save_branding('Toko', '#FFFF99', NULL)$$, 'CATALOG_INVALID', 'warna terlalu terang ditolak');
SELECT pos_test.throws($$SELECT pos.save_branding('Toko', '#3F6A9E', 'data:image/svg+xml;base64,PHN2Zz4=')$$, 'CATALOG_INVALID', 'logo SVG ditolak');
SELECT pos_test.throws($$SELECT pos.save_branding('Toko', '#3F6A9E', 'https://evil.example/x.png')$$, 'CATALOG_INVALID', 'logo harus data URL raster');
SELECT pos.save_branding('Warung Maju', '#0f7a6b', 'data:image/png;base64,iVBORw0KGgo=');
SELECT pos_test.ok((SELECT display_name = 'Warung Maju' AND primary_color = '#0F7A6B' AND logo IS NOT NULL FROM pos.organization_branding), 'owner menyimpan branding');
SELECT pos.save_branding(NULL, NULL, NULL);
SELECT pos_test.ok((SELECT display_name IS NULL AND primary_color IS NULL AND logo IS NULL FROM pos.organization_branding), 'branding dapat dikosongkan (kembali ke bawaan)');
SELECT pos.save_branding('Warung Maju', '#0F7A6B', NULL);
RESET ROLE;

SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.organization_branding), 'operator platform tidak melihat branding merchant');
RESET ROLE;
ROLLBACK;
