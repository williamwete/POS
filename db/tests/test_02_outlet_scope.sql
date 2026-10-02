-- Outlet scope (§60, §88): cashier/supervisor per outlet, manager multi-outlet, auditor read-only.
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set BDG '''00000000-0000-4000-8000-000000000102'''

-- Cashier Outlet A -> cannot SELECT Outlet B
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.outlets') = 1, 'cashier.jkt melihat tepat 1 outlet');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.outlets WHERE code = 'JKT01'$$) = 1, 'cashier.jkt melihat JKT01');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.outlets WHERE code = 'BDG01'$$) = 0, 'cashier.jkt TIDAK melihat BDG01');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.terminals WHERE code = 'POS-BDG-01'$$) = 0, 'cashier.jkt TIDAK melihat terminal BDG');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.terminals') = 2, 'cashier.jkt melihat 2 terminal JKT');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.devices d JOIN pos.outlets o ON o.id = d.outlet_id WHERE o.code='BDG01'$$) = 0,
    'cashier.jkt TIDAK melihat device BDG');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.warehouses WHERE code = 'WH-BDG01'$$) = 0, 'cashier.jkt TIDAK melihat warehouse BDG');
SELECT pos_test.ok(pos.has_permission('sale.create', :JKT), 'cashier.jkt sale.create di JKT01');
SELECT pos_test.ok(NOT pos.has_permission('sale.create', :BDG), 'cashier.jkt TIDAK sale.create di BDG01');
SELECT pos_test.ok(NOT pos.has_permission('sale.void', :JKT), 'cashier.jkt TIDAK sale.void');
SELECT pos_test.ok(NOT pos.has_permission('sale.refund', :JKT), 'cashier.jkt TIDAK sale.refund');
SELECT pos_test.ok(NOT pos.has_permission('cash.approve_difference', :JKT), 'cashier.jkt TIDAK approve selisih kas');
SELECT pos_test.ok(NOT pos.has_permission('sale.create', NULL), 'role outlet-scoped tidak berlaku level organisasi');
-- Kasir hanya melihat dirinya sendiri di tabel users/employees
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.users') = 1, 'cashier.jkt hanya melihat user dirinya');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.employees') = 1, 'cashier.jkt hanya melihat employee dirinya');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.audit_logs') = 0, 'cashier.jkt tidak bisa membaca audit log');
ROLLBACK;

BEGIN;
SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.outlets WHERE code = 'JKT01'$$) = 0, 'cashier.bdg TIDAK melihat JKT01');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.terminals') = 1, 'cashier.bdg melihat 1 terminal');
ROLLBACK;

-- Supervisor Outlet A -> can SELECT Outlet A
BEGIN;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.outlets WHERE code = 'JKT01'$$) = 1, 'supervisor.jkt melihat JKT01');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.outlets WHERE code = 'BDG01'$$) = 0, 'supervisor.jkt TIDAK melihat BDG01');
SELECT pos_test.ok(pos.has_permission('sale.void', :JKT), 'supervisor.jkt sale.void di JKT01');
SELECT pos_test.ok(pos.has_permission('cash.approve_difference', :JKT), 'supervisor.jkt approve selisih di JKT01');
SELECT pos_test.ok(NOT pos.has_permission('sale.void', :BDG), 'supervisor.jkt TIDAK sale.void di BDG01');
-- employee.view di JKT: melihat karyawan berhome JKT, bukan BDG
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.employees WHERE employee_code = 'EMP005'$$) = 1, 'supervisor.jkt melihat kasir JKT');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.employees WHERE employee_code = 'EMP006'$$) = 0, 'supervisor.jkt TIDAK melihat kasir BDG');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.employees WHERE employee_code = 'EMP001'$$) = 0, 'supervisor.jkt TIDAK melihat staf kantor pusat');
ROLLBACK;

-- Manager -> can SELECT assigned outlets
BEGIN;
SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.outlets') = 2, 'manager melihat 2 outlet yang ditugaskan');
SELECT pos_test.ok(pos.has_permission('cash.cash_adjustment', :BDG), 'manager cash_adjustment di BDG01');
SELECT pos_test.ok(NOT pos.has_permission('user.manage', NULL), 'manager tidak punya user.manage');
ROLLBACK;

-- Manager kehilangan akses outlet ketika user_outlets dicabut (role outlet-scoped butuh akses)
BEGIN;
SET LOCAL ROLE pos_system;
DELETE FROM pos.user_outlets
WHERE user_id = (SELECT id FROM pos.users WHERE username = 'manager') AND outlet_id = :BDG;
SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.outlets') = 1, 'manager tanpa user_outlets BDG hanya melihat 1 outlet');
SELECT pos_test.ok(NOT pos.has_permission('sale.void', :BDG), 'role outlet-scoped tanpa akses outlet tidak berlaku');
ROLLBACK;

-- Auditor -> SELECT only, org-wide
BEGIN;
SELECT pos_test.login('auditor');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.outlets') = 2, 'auditor melihat semua outlet');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.terminals') = 3, 'auditor melihat semua terminal');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.users') = 7, 'auditor melihat semua user');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.employees') = 7, 'auditor melihat semua karyawan');
SELECT pos_test.ok(NOT EXISTS (
    SELECT 1 FROM pos.effective_permissions(NULL) p
    WHERE p NOT LIKE '%.view'
), 'auditor hanya memiliki permission *.view');
ROLLBACK;

-- effective_permissions per outlet
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) FROM pos.effective_permissions(:JKT)) = 10, 'cashier.jkt: 10 permission di JKT01');
SELECT pos_test.ok((SELECT count(*) FROM pos.effective_permissions(:BDG)) = 0, 'cashier.jkt: 0 permission di BDG01');
ROLLBACK;
