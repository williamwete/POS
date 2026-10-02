-- Identity & anti privilege escalation (ASSUMPTIONS A7).
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set BDG '''00000000-0000-4000-8000-000000000102'''

-- Admin bisa memberi role di bawah rank-nya
BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$
    INSERT INTO pos.user_roles (user_id, role_id, outlet_id)
    SELECT u.id, r.id, '00000000-0000-4000-8000-000000000102'::uuid FROM pos.users u, pos.roles r
    WHERE u.username = 'cashier.bdg' AND r.code = 'SUPERVISOR'$$) = 1,
    'admin bisa memberi SUPERVISOR@BDG01 ke cashier.bdg');
SELECT pos_test.ok(pos_test.affected($$
    INSERT INTO pos.user_outlets (user_id, outlet_id)
    SELECT u.id, '00000000-0000-4000-8000-000000000101'::uuid FROM pos.users u WHERE u.username = 'cashier.bdg'$$) = 1,
    'admin bisa memberi akses outlet JKT01 ke cashier.bdg');
SELECT pos_test.ok(pos_test.affected($$
    INSERT INTO pos.user_roles (user_id, role_id)
    SELECT u.id, r.id FROM pos.users u, pos.roles r WHERE u.username = 'cashier.jkt' AND r.code = 'AUDITOR'$$) = 1,
    'admin bisa memberi AUDITOR org-wide');
ROLLBACK;

-- Admin TIDAK bisa memberi SUPER_ADMIN atau ADMIN (rank >= miliknya)
BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.user_roles (user_id, role_id)
    SELECT u.id, r.id FROM pos.users u, pos.roles r WHERE u.username = 'cashier.jkt' AND r.code = 'SUPER_ADMIN'$$,
    'row-level security', 'admin tidak bisa memberi SUPER_ADMIN');
ROLLBACK;

BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.user_roles (user_id, role_id)
    SELECT u.id, r.id FROM pos.users u, pos.roles r WHERE u.username = 'cashier.jkt' AND r.code = 'ADMIN'$$,
    'row-level security', 'admin tidak bisa memberi ADMIN');
ROLLBACK;

-- Tidak bisa mengubah role diri sendiri
BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.user_roles (user_id, role_id)
    SELECT u.id, r.id FROM pos.users u, pos.roles r WHERE u.username = 'admin' AND r.code = 'STORE_MANAGER'$$,
    'row-level security', 'admin tidak bisa memberi role ke dirinya sendiri');
SELECT pos_test.ok(pos_test.affected($$DELETE FROM pos.user_roles WHERE user_id = pos.current_app_user_id()$$) = 0,
    'admin tidak bisa mencabut role dirinya sendiri');
ROLLBACK;

BEGIN;
SELECT pos_test.login('superadmin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.users SET active = false WHERE username = 'superadmin'$$) = 0,
    'superadmin tidak bisa menonaktifkan dirinya sendiri');
ROLLBACK;

-- Admin tidak bisa mengelola user yang rank-nya >= miliknya
BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.users SET active = false WHERE username = 'superadmin'$$) = 0,
    'admin tidak bisa menonaktifkan superadmin');
SELECT pos_test.ok(pos_test.affected($$DELETE FROM pos.user_roles
    WHERE user_id = (SELECT id FROM pos.users WHERE username = 'superadmin')$$) = 0,
    'admin tidak bisa mencabut role superadmin');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.users SET display_name = 'Dewi L.' WHERE username = 'cashier.jkt'$$) = 1,
    'admin bisa mengubah user kasir');
ROLLBACK;

-- Store manager tidak punya user.manage: tidak bisa memberi role apa pun
BEGIN;
SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.user_roles (user_id, role_id, outlet_id)
    VALUES ('00000000-0000-4000-8000-000000000705',
            (SELECT id FROM pos.roles WHERE code = 'SUPERVISOR'),
            '00000000-0000-4000-8000-000000000101')$$,
    'row-level security', 'manager tidak bisa mempromosikan kasir');
SELECT pos_test.throws($$
    INSERT INTO pos.user_outlets (user_id, outlet_id)
    VALUES ('00000000-0000-4000-8000-000000000705', '00000000-0000-4000-8000-000000000102')$$,
    'row-level security', 'manager tidak bisa memberi akses outlet');
-- user.view outlet-scoped: melihat staf yang punya akses ke JKT01/BDG01, bukan staf pusat
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.users') = 4, 'manager melihat 4 user di outlet-nya');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.users WHERE username = 'superadmin'$$) = 0,
    'manager tidak melihat akun pusat');
ROLLBACK;

BEGIN;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.users') = 1, 'supervisor (tanpa user.view) hanya melihat dirinya');
ROLLBACK;

-- Role management: hanya SUPER_ADMIN punya role.manage; tetap tidak bisa mengubah rank sistem
BEGIN;
SELECT pos_test.login('superadmin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$
    INSERT INTO pos.role_permissions (role_id, permission_code)
    SELECT id, 'report.view' FROM pos.roles WHERE code = 'CASHIER'$$) = 1,
    'superadmin bisa menambah permission ke CASHIER');
SELECT pos_test.ok(pos_test.affected($$
    DELETE FROM pos.role_permissions WHERE role_id = (SELECT id FROM pos.roles WHERE code = 'SUPER_ADMIN')$$) = 0,
    'permission SUPER_ADMIN tidak bisa dihapus (rank tidak di bawah)');
SELECT pos_test.throws($$UPDATE pos.roles SET rank = 95 WHERE code = 'CASHIER'$$,
    'SYSTEM_ROLE_PROTECTED', 'rank role sistem tidak bisa diubah');
SELECT pos_test.throws($$INSERT INTO pos.roles (code, name, rank) VALUES ('GOD_MODE', 'x', 100)$$,
    'row-level security', 'tidak bisa membuat role dengan rank >= milik sendiri');
SELECT pos_test.ok(pos_test.affected($$INSERT INTO pos.roles (code, name, rank) VALUES ('SENIOR_CASHIER', 'Kasir Senior', 25)$$) = 1,
    'superadmin bisa membuat role custom di bawah rank-nya');
ROLLBACK;

BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.role_permissions (role_id, permission_code)
    SELECT id, 'sale.refund' FROM pos.roles WHERE code = 'CASHIER'$$,
    'row-level security', 'admin tanpa role.manage tidak bisa mengubah permission role');
ROLLBACK;

-- Audit log
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, actor_employee_id, action, entity_type)
    VALUES (pos.current_org_id(), pos.current_app_user_id(), pos.current_employee_id(), 'LOGIN', 'USER')$$) = 1,
    'user bisa menulis audit atas namanya sendiri');
SELECT pos_test.throws($$
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, actor_employee_id, action, entity_type)
    SELECT pos.current_org_id(), u.id, u.employee_id, 'LOGIN', 'USER' FROM pos.users u WHERE false
    UNION ALL
    SELECT pos.current_org_id(), '00000000-0000-4000-8000-000000000704', '00000000-0000-4000-8000-000000000504', 'APPROVAL', 'X'$$,
    'row-level security', 'kasir tidak bisa memalsukan audit atas nama supervisor');
SELECT pos_test.throws($$UPDATE pos.audit_logs SET reason = 'x'$$, 'permission denied',
    'kasir tidak bisa mengubah audit log');
SELECT pos_test.throws($$DELETE FROM pos.audit_logs$$, 'permission denied',
    'kasir tidak bisa menghapus audit log');
ROLLBACK;

-- Audit log append-only bahkan untuk owner/superuser (trigger)
BEGIN;
SET LOCAL ROLE pos_system;
INSERT INTO pos.audit_logs (actor_type, action, entity_type) VALUES ('SYSTEM', 'SYNC_SUCCESS', 'TEST');
SELECT pos_test.throws($$UPDATE pos.audit_logs SET reason = 'x'$$, 'permission denied|APPEND_ONLY',
    'pos_system tidak bisa mengubah audit log');
ROLLBACK;

BEGIN;
SELECT pos_test.login('auditor');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type)
    VALUES (pos.current_org_id(), pos.current_app_user_id(), 'LOGIN', 'USER')$$,
    'row-level security', 'actor_employee_id wajib cocok dengan user');
ROLLBACK;

-- Idempotency key: hanya milik sendiri
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
INSERT INTO pos.idempotency_keys (user_id, idempotency_key, method, path, request_hash)
VALUES (pos.current_app_user_id(), 'key-cashier-0001', 'POST', '/api/x', 'h');
SELECT pos_test.throws($$
    INSERT INTO pos.idempotency_keys (user_id, idempotency_key, method, path, request_hash)
    VALUES ('00000000-0000-4000-8000-000000000704', 'key-spoof-0001', 'POST', '/api/x', 'h')$$,
    'row-level security', 'tidak bisa membuat idempotency key atas nama user lain');
SELECT pos_test.login('supervisor.jkt');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.idempotency_keys') = 0,
    'user lain tidak melihat idempotency key milik kasir');
ROLLBACK;
