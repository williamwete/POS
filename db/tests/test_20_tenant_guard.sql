-- Penjaga isolasi antar-tenant (struktural + lintas merchant)
BEGIN;
-- 1) Semua tabel schema pos wajib RLS aktif.
SELECT pos_test.ok((SELECT count(*) = 0 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pos' AND c.relkind = 'r' AND NOT c.relrowsecurity),
    'semua tabel pos memakai RLS');

-- 2) Tabel tanpa policy hanya boleh yang sengaja tertutup, dan tidak boleh dibaca role aplikasi.
SELECT pos_test.ok((SELECT count(*) = 0 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pos' AND c.relkind = 'r'
      AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)
      AND c.relname NOT IN ('plans','organization_payout_terms','organization_subscriptions','terminal_receipt_sequences','terminal_return_sequences')),
    'tabel tanpa policy hanya daftar tertutup yang dikenal');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pos' AND c.relkind = 'r'
      AND c.relname IN ('plans','organization_payout_terms','organization_subscriptions')
      AND (has_table_privilege('pos_app_user', c.oid, 'SELECT') OR has_table_privilege('pos_api', c.oid, 'SELECT'))),
    'tabel tertutup tidak dapat dibaca role aplikasi');

-- 3) Dua merchant berisi data; tiap pemilik hanya melihat org sendiri di semua tabel ber-organization_id.
CREATE TEMP TABLE m (a uuid, b uuid);
GRANT ALL ON m TO PUBLIC;
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
INSERT INTO m (a) SELECT pos.platform_provision_merchant('GUARDA', 'Guard A', 'FNB', 'STARTER', 'GA1', 'GA Pusat', 'Ani', 'ani@ga.test', pos_test.make_auth_user('ani@ga.test'));
INSERT INTO m (b) SELECT pos.platform_provision_merchant('GUARDB', 'Guard B', 'RETAIL', 'STARTER', 'GB1', 'GB Pusat', 'Bima', 'bima@gb.test', pos_test.make_auth_user('bima@gb.test'));
SELECT pos.platform_apply_preset(a) FROM m WHERE a IS NOT NULL;
SELECT pos.platform_apply_preset(b) FROM m WHERE b IS NOT NULL;
RESET ROLE;


SELECT pos_test.login('guarda.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) > 0 FROM pos.product_categories), 'pemilik A melihat data sendiri');
SELECT pos_test.ok(pos_test.foreign_rows((SELECT a FROM m WHERE a IS NOT NULL)) = 0, 'pemilik A tidak melihat baris org lain di tabel mana pun');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.products), 'merchant baru mulai dengan katalog produk kosong (tidak ada produk merchant lain)');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.users WHERE username NOT LIKE 'guarda.%'), 'merchant baru hanya melihat user miliknya');
RESET ROLE;

SELECT pos_test.login('guardb.owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.foreign_rows((SELECT b FROM m WHERE b IS NOT NULL)) = 0, 'pemilik B tidak melihat baris org lain di tabel mana pun');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.foreign_rows('00000000-0000-4000-8000-000000000001') = 0, 'pemilik demo tidak melihat org lain');
RESET ROLE;
ROLLBACK;
