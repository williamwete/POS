-- Onboarding merchant (SaaS) & isolasi antar-tenant
\set DEMO_JKT '''00000000-0000-4000-8000-000000000101'''

BEGIN;
-- ---- hanya operator platform
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT * FROM pos.platform_list_merchants()$$, 'USER_NOT_AUTHORIZED', 'admin merchant tidak bisa melihat daftar merchant');
SELECT pos_test.throws($$SELECT pos.platform_provision_merchant('EVIL','Evil','FNB','TRIAL','E1','E1','x','x@x.test', pos_test.make_auth_user('x@x.test'))$$,
    'USER_NOT_AUTHORIZED', 'admin merchant tidak bisa membuat merchant');
SELECT pos_test.throws($$SELECT count(*) FROM pos.plans$$, 'permission denied', 'tabel paket tertutup bagi merchant');
RESET ROLE;
SELECT pos_test.login('superadmin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.platform_set_active('00000000-0000-4000-8000-000000000001', false)$$, 'USER_NOT_AUTHORIZED', 'superadmin merchant tidak bisa menonaktifkan org');
SELECT pos_test.throws($$
    INSERT INTO pos.role_permissions (role_id, permission_code)
    SELECT id, 'report.view' FROM pos.roles WHERE code = 'CASHIER'$$, 'row-level security', 'merchant tidak bisa mengubah role sistem');
RESET ROLE;

-- ---- provisioning
CREATE TEMP TABLE m (a uuid, b uuid);
GRANT ALL ON m TO PUBLIC;
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 4 FROM pos.platform_plans()), 'platform melihat 4 paket');
INSERT INTO m (a) SELECT pos.platform_provision_merchant('ACME', 'Acme Kopi', 'FNB', 'STARTER', 'ACME01', 'Acme Pusat', 'Budi Acme', 'budi@acme.test', pos_test.make_auth_user('budi@acme.test'));
INSERT INTO m (b) SELECT pos.platform_provision_merchant('BETA', 'Beta Mart', 'RETAIL', 'TRIAL', 'BETA01', 'Beta Pusat', 'Citra Beta', 'citra@beta.test', pos_test.make_auth_user('citra@beta.test'));
SELECT pos_test.throws($$SELECT pos.platform_provision_merchant('ACME', 'Dup', 'FNB', 'TRIAL', 'D1', 'D1', 'x', 'dup@x.test', pos_test.make_auth_user('dup@x.test'))$$,
    'organizations_code_uk', 'kode merchant unik');
SELECT pos_test.throws($$SELECT pos.platform_provision_merchant('PLATFORM', 'x', 'FNB', 'TRIAL', 'D1', 'D1', 'x', 'dup2@x.test', pos_test.make_auth_user('dup2@x.test'))$$,
    'CATALOG_INVALID', 'kode PLATFORM dicadangkan');
SELECT pos_test.throws($$SELECT pos.platform_provision_merchant('GAMMA', 'x', 'FNB', 'NOPE', 'G1', 'G1', 'x', 'dup3@x.test', pos_test.make_auth_user('dup3@x.test'))$$,
    'CATALOG_INVALID', 'paket harus dikenal');
SELECT pos_test.ok((SELECT count(*) = 2 FROM pos.platform_list_merchants() WHERE code IN ('ACME', 'BETA')), 'daftar merchant memuat merchant baru');
SELECT pos_test.ok((SELECT outlets = 1 AND terminals = 1 AND users = 1 AND plan_code = 'STARTER' FROM pos.platform_list_merchants() WHERE code = 'ACME'), 'ACME: 1 outlet, 1 terminal, 1 pemilik, paket STARTER');
SELECT pos_test.ok((SELECT sub_status = 'TRIAL' AND trial_ends_at IS NOT NULL FROM pos.platform_list_merchants() WHERE code = 'BETA'), 'BETA trial 14 hari');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.products), 'operator platform tidak melihat data merchant');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.outlets), 'operator platform tidak melihat outlet');
RESET ROLE;

-- id milik DEMO (diambil sebagai admin DEMO) untuk uji lintas-tenant
CREATE TEMP TABLE foreign_ids (cat uuid, tax uuid);
GRANT ALL ON foreign_ids TO PUBLIC;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
INSERT INTO foreign_ids SELECT (SELECT id FROM pos.product_categories LIMIT 1), (SELECT id FROM pos.tax_rates LIMIT 1);
RESET ROLE;

-- ---- isolasi: pemilik ACME
SELECT pos_test.login('acme.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.organizations), 'pemilik hanya melihat organisasinya');
SELECT pos_test.ok((SELECT count(*) = 2 FROM pos.tax_rates), 'pajak awal dibuat');
SELECT pos_test.ok((SELECT count(*) >= 1 FROM pos.payment_methods), 'metode pembayaran awal dibuat');
SELECT pos_test.ok((SELECT count(*) >= 1 FROM pos.cash_denominations), 'pecahan kas awal dibuat');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.receipt_profiles WHERE business_name = 'Acme Kopi'), 'profil struk awal dibuat');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.terminals WHERE code = 'ACME-K1'), 'terminal ACME-K1');

SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.outlets), 'pemilik hanya melihat outletnya');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.products), 'tidak melihat produk merchant lain');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.users), 'tidak melihat user merchant lain');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.sales), 'tidak melihat penjualan merchant lain');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.terminals WHERE code NOT LIKE 'ACME-%'), 'tidak melihat terminal merchant lain');
SELECT pos_test.throws($$SELECT * FROM pos.platform_list_merchants()$$, 'USER_NOT_AUTHORIZED', 'pemilik tidak bisa memakai fungsi platform');
SELECT pos_test.throws($$SELECT count(*) FROM pos.organization_subscriptions$$, 'permission denied', 'langganan tidak terlihat oleh merchant');
SELECT pos_test.ok(pos.has_permission('user.manage', NULL) AND pos.has_permission('report.view', NULL), 'pemilik punya hak admin atas tokonya');

-- produk lokal milik ACME; id lintas-tenant ditolak
SELECT pos.save_category(NULL, 'KOPI', 'Kopi', true);
SELECT pos.save_product(NULL, 'ACME-LATTE', 'Latte', (SELECT id FROM pos.product_categories WHERE code = 'KOPI'), 'PCS', false, NULL, false, true, NULL, NULL, 28000);
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.products), 'pemilik membuat produk sendiri');
RESET ROLE;
SELECT pos_test.login('acme.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws(format($$SELECT pos.save_product(NULL, 'X', 'X', %L, 'PCS', false, NULL, true, true, NULL, NULL, 1000)$$, (SELECT cat FROM foreign_ids)),
    'CATALOG_', 'kategori merchant lain ditolak');
SELECT pos_test.throws(format($$SELECT pos.save_product(NULL, 'Y', 'Y', NULL, 'PCS', false, %L, true, true, NULL, NULL, 1000)$$, (SELECT tax FROM foreign_ids)),
    'CATALOG_', 'pajak merchant lain ditolak');
SELECT pos_test.throws($$SELECT pos.save_discount_preset(NULL, '00000000-0000-4000-8000-000000000101', 'Curang', 'PERCENTAGE', 5, true)$$,
    'CATALOG_NOT_FOUND|USER_NOT_AUTHORIZED', 'outlet merchant lain ditolak (diskon)');
SELECT pos_test.throws($$SELECT pos.set_local_stock((SELECT id FROM pos.products LIMIT 1), '00000000-0000-4000-8000-000000000101', 5)$$,
    'CATALOG_NOT_FOUND|USER_NOT_AUTHORIZED', 'outlet merchant lain ditolak (stok)');
SELECT pos_test.throws($$UPDATE pos.products SET name = 'hack' WHERE organization_id = '00000000-0000-4000-8000-000000000001'$$, 'permission denied', 'tulis langsung ke produk ditolak');
-- batas paket STARTER: 1 outlet
SELECT pos_test.throws($$INSERT INTO pos.outlets (organization_id, code, name) VALUES (pos.current_org_id(), 'ACME02', 'Cabang')$$,
    'PLAN_LIMIT_EXCEEDED', 'STARTER dibatasi 1 outlet');
RESET ROLE;

-- ---- isolasi sebaliknya: admin DEMO tidak melihat ACME
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.outlets WHERE code = 'ACME01'), 'admin DEMO tidak melihat outlet ACME');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.users WHERE username LIKE 'acme.%'), 'admin DEMO tidak melihat user ACME');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.products WHERE sku = 'ACME-LATTE'), 'admin DEMO tidak melihat produk ACME');
RESET ROLE;

-- ---- batas paket lain (BETA = TRIAL: 3 pengguna, 1 terminal, 100 produk)
SELECT pos_test.login('beta.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$INSERT INTO pos.terminals (outlet_id, code, name) SELECT id, 'BETA-K2', 'K2' FROM pos.outlets$$,
    'PLAN_LIMIT_EXCEEDED', 'TRIAL dibatasi 1 terminal');
SELECT count(pos.save_product(NULL, 'P' || g, 'Produk ' || g, NULL, 'PCS', false, NULL, false, true, NULL, NULL, 1000)) FROM generate_series(1, 100) g;
SELECT pos_test.throws($$SELECT pos.save_product(NULL, 'P101', 'Produk 101', NULL, 'PCS', false, NULL, false, true, NULL, NULL, 1000)$$,
    'PLAN_LIMIT_EXCEEDED', 'TRIAL dibatasi 100 produk lokal');
RESET ROLE;

-- ---- suspend
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos.platform_set_active((SELECT a FROM m WHERE a IS NOT NULL), false, 'tunggakan');
RESET ROLE;
SELECT pos_test.login('acme.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.outlets), 'merchant ditangguhkan tidak melihat apa pun');
SELECT pos_test.ok(NOT pos.has_permission('sale.create', NULL), 'merchant ditangguhkan kehilangan semua izin');
RESET ROLE;
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT NOT active AND sub_status = 'SUSPENDED' FROM pos.platform_list_merchants() WHERE code = 'ACME'), 'status ditangguhkan tercatat');
SELECT pos.platform_set_active((SELECT a FROM m WHERE a IS NOT NULL), true);
SELECT pos.platform_set_plan((SELECT a FROM m WHERE a IS NOT NULL), 'ENTERPRISE');
SELECT pos_test.ok((SELECT plan_code = 'ENTERPRISE' AND active FROM pos.platform_list_merchants() WHERE code = 'ACME'), 'aktif lagi & naik paket');
RESET ROLE;
SELECT pos_test.login('acme.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.outlets), 'merchant aktif kembali');
RESET ROLE;
SET LOCAL ROLE pos_system;
SELECT pos_test.ok((SELECT count(*) >= 3 FROM pos.audit_logs WHERE action IN ('MERCHANT_PROVISIONED', 'MERCHANT_SUSPENDED', 'MERCHANT_REACTIVATED', 'MERCHANT_PLAN_CHANGED')), 'audit platform tercatat');
RESET ROLE;

-- ---- role platform tidak bisa diberikan ke user merchant
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
SELECT pos_test.throws($$INSERT INTO pos.user_roles (user_id, role_id)
    SELECT u.id, r.id FROM pos.users u, pos.roles r WHERE u.username = 'admin' AND r.code = 'PLATFORM_ADMIN'$$,
    'USER_NOT_AUTHORIZED', 'role PLATFORM_ADMIN hanya untuk org PLATFORM');
RESET ROLE;
ROLLBACK;
