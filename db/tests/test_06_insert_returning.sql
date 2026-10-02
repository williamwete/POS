-- Regresi V008: INSERT ... RETURNING oleh admin harus berhasil (bug CI 2026-10-02),
-- tanpa membuka akses bagi role lain.

-- Admin membuat outlet baru dan langsung bisa membacanya (RETURNING)
BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows($$
    INSERT INTO pos.outlets (organization_id, code, name)
    VALUES (pos.current_org_id(), 'SBY01', 'Outlet Surabaya') RETURNING id$$) = 1,
    'admin: INSERT outlet ... RETURNING berhasil');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.outlets WHERE code = 'SBY01'$$) = 1,
    'admin melihat outlet baru');
ROLLBACK;

-- Outlet baru tidak terlihat oleh kasir outlet lain
BEGIN;
SET LOCAL ROLE pos_system;
INSERT INTO pos.outlets (organization_id, code, name)
VALUES ('00000000-0000-4000-8000-000000000001', 'SBY02', 'Outlet Surabaya 2');
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.outlets WHERE code = 'SBY02'$$) = 0,
    'kasir JKT tidak melihat outlet baru');
SELECT pos_test.login('auditor');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.outlets WHERE code = 'SBY02'$$) = 1,
    'auditor (org-wide) melihat outlet baru');
ROLLBACK;

-- Admin membuat user baru dengan RETURNING, lalu memberi akses outlet & role
BEGIN;
SELECT set_config('pos_test.auth_id', pos_test.make_auth_user('baru@demo.local')::text, true);
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows($$
    INSERT INTO pos.users (auth_user_id, organization_id, username, email, display_name)
    VALUES (current_setting('pos_test.auth_id')::uuid, pos.current_org_id(), 'kasir.baru', 'baru@demo.local', 'Kasir Baru')
    RETURNING id$$) = 1,
    'admin: INSERT user ... RETURNING berhasil');
SELECT pos_test.ok(pos_test.affected($$
    INSERT INTO pos.user_outlets (user_id, outlet_id)
    SELECT id, '00000000-0000-4000-8000-000000000101' FROM pos.users WHERE username = 'kasir.baru'$$) = 1,
    'admin memberi akses outlet ke user baru');
SELECT pos_test.ok(pos_test.affected($$
    INSERT INTO pos.user_roles (user_id, role_id, outlet_id)
    SELECT u.id, r.id, '00000000-0000-4000-8000-000000000101' FROM pos.users u, pos.roles r
    WHERE u.username = 'kasir.baru' AND r.code = 'CASHIER'$$) = 1,
    'admin memberi role CASHIER@JKT01 ke user baru');
-- Store manager JKT melihat user baru (user.view outlet-scoped), kasir lain tidak
SELECT pos_test.login('manager');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.users WHERE username = 'kasir.baru'$$) = 1,
    'manager JKT melihat kasir baru di outletnya');
SELECT pos_test.login('cashier.bdg');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.users WHERE username = 'kasir.baru'$$) = 0,
    'kasir BDG tidak melihat user baru');
ROLLBACK;

-- Non-admin tetap tidak bisa membuat user / outlet
BEGIN;
SELECT set_config('pos_test.auth_id', pos_test.make_auth_user('hack@demo.local')::text, true);
SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.users (auth_user_id, organization_id, username, email, display_name)
    VALUES (current_setting('pos_test.auth_id')::uuid, pos.current_org_id(), 'hack.user', 'hack@demo.local', 'X')$$,
    'row-level security', 'manager tidak bisa membuat user');
ROLLBACK;
