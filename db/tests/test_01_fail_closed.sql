-- Fail-closed: tanpa SET ROLE / tanpa klaim / user nonaktif => tidak ada akses.

-- 1. pos_api (NOINHERIT) tanpa SET ROLE tidak punya privilege tabel.
BEGIN;
SELECT pos_test.throws('SELECT * FROM pos.outlets', 'permission denied',
    'pos_api tanpa SET ROLE tidak bisa membaca pos.outlets');
ROLLBACK;

BEGIN;
SELECT pos_test.throws('SELECT * FROM pos.audit_logs', 'permission denied',
    'pos_api tanpa SET ROLE tidak bisa membaca audit_logs');
ROLLBACK;

-- 2. pos_app_user tanpa klaim JWT: semua RLS mengembalikan 0 baris.
BEGIN;
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos.current_app_user_id() IS NULL, 'tanpa klaim: current_app_user_id NULL');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.outlets') = 0, 'tanpa klaim: 0 outlet');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.users') = 0, 'tanpa klaim: 0 user');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.roles') = 0, 'tanpa klaim: katalog role tertutup');
SELECT pos_test.ok(NOT pos.has_permission('sale.create', '00000000-0000-4000-8000-000000000101'),
    'tanpa klaim: has_permission false');
ROLLBACK;

-- 3. Klaim dengan role selain authenticated (mis. token anon) ditolak.
BEGIN;
SELECT set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-000000000601","role":"anon"}', true);
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos.current_app_user_id() IS NULL, 'klaim role=anon tidak dikenali');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.outlets') = 0, 'klaim role=anon: 0 outlet');
ROLLBACK;

-- 4. Klaim rusak tidak menimbulkan error/bypass.
BEGIN;
SELECT set_config('request.jwt.claims', 'not-json', true);
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos.current_app_user_id() IS NULL, 'klaim rusak => NULL');
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"bukan-uuid"}', true);
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos.current_app_user_id() IS NULL, 'sub bukan uuid => NULL');
ROLLBACK;

-- 5. User nonaktif kehilangan seluruh akses.
BEGIN;
SET LOCAL ROLE pos_system;
UPDATE pos.users SET active = false WHERE username = 'cashier.jkt';
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos.current_app_user_id() IS NULL, 'user nonaktif: tidak dikenali');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.outlets') = 0, 'user nonaktif: 0 outlet');
ROLLBACK;

-- 6. Organisasi nonaktif mematikan akses seluruh user-nya.
BEGIN;
SET LOCAL ROLE pos_system;
UPDATE pos.organizations SET active = false WHERE code = 'DEMO';
SELECT pos_test.login('superadmin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos.current_app_user_id() IS NULL, 'organisasi nonaktif: superadmin tidak dikenali');
ROLLBACK;
