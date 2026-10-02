-- Proteksi tulis: role tanpa permission tidak bisa mengubah master, termasuk auditor.
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set BDG '''00000000-0000-4000-8000-000000000102'''
\set ORG '''00000000-0000-4000-8000-000000000001'''

-- Cashier
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws(
    $$INSERT INTO pos.outlets (organization_id, code, name) VALUES ('00000000-0000-4000-8000-000000000001', 'HACK1', 'x')$$,
    'row-level security', 'cashier tidak bisa membuat outlet');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.terminals SET name = 'x' WHERE code = 'POS-JKT-01'$$) = 0,
    'cashier tidak bisa mengubah terminal di outletnya');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.outlets SET name = 'x'$$) = 0,
    'cashier tidak bisa mengubah outlet');
SELECT pos_test.throws(
    $$INSERT INTO pos.terminals (outlet_id, code, name) VALUES ('00000000-0000-4000-8000-000000000101', 'POS-HACK', 'x')$$,
    'row-level security', 'cashier tidak bisa membuat terminal');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.users SET display_name = 'x'$$) = 0,
    'cashier tidak bisa mengubah user (termasuk dirinya)');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.employees SET full_name = 'x'$$) = 0,
    'cashier tidak bisa mengubah data karyawan (termasuk dirinya)');
SELECT pos_test.throws($$DELETE FROM pos.outlets$$, 'permission denied', 'DELETE outlet tidak di-grant');
SELECT pos_test.throws($$DELETE FROM pos.users$$, 'permission denied', 'DELETE user tidak di-grant');
SELECT pos_test.throws($$DELETE FROM pos.terminals$$, 'permission denied', 'DELETE terminal tidak di-grant');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.organizations SET name = 'x'$$) = 0,
    'cashier tidak bisa mengubah organisasi');
SELECT pos_test.throws(
    $$INSERT INTO pos.settings (organization_id, key, value) VALUES ('00000000-0000-4000-8000-000000000001', 'max_cashier_discount', '100')$$,
    'row-level security', 'cashier tidak bisa menaikkan batas diskonnya sendiri');
ROLLBACK;

-- Auditor: read-only total
BEGIN;
SELECT pos_test.login('auditor');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.outlets SET name = 'x'$$) = 0, 'auditor tidak bisa update outlet');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.terminals SET name = 'x'$$) = 0, 'auditor tidak bisa update terminal');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.employees SET full_name = 'x'$$) = 0, 'auditor tidak bisa update employee');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.users SET display_name = 'x'$$) = 0, 'auditor tidak bisa update user');
SELECT pos_test.throws(
    $$INSERT INTO pos.employees (organization_id, employee_code, full_name) VALUES ('00000000-0000-4000-8000-000000000001', 'EMP999', 'x')$$,
    'row-level security', 'auditor tidak bisa membuat employee');
SELECT pos_test.throws(
    $$INSERT INTO pos.user_roles (user_id, role_id) SELECT u.id, r.id FROM pos.users u, pos.roles r WHERE u.username='cashier.bdg' AND r.code='SUPERVISOR'$$,
    'row-level security', 'auditor tidak bisa memberi role');
ROLLBACK;

-- Supervisor: tidak punya terminal.manage / employee.manage
BEGIN;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws(
    $$INSERT INTO pos.terminals (outlet_id, code, name) VALUES ('00000000-0000-4000-8000-000000000101', 'POS-JKT-09', 'x')$$,
    'row-level security', 'supervisor tidak bisa membuat terminal');
SELECT pos_test.throws(
    $$INSERT INTO pos.employees (organization_id, employee_code, full_name, home_outlet_id) VALUES ('00000000-0000-4000-8000-000000000001', 'EMP998', 'x', '00000000-0000-4000-8000-000000000101')$$,
    'row-level security', 'supervisor tidak bisa membuat employee');
ROLLBACK;

-- Store manager: kelola karyawan HANYA di outletnya
BEGIN;
SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected(
    $$INSERT INTO pos.employees (organization_id, employee_code, full_name, home_outlet_id) VALUES ('00000000-0000-4000-8000-000000000001', 'EMP100', 'Karyawan Baru', '00000000-0000-4000-8000-000000000101')$$) = 1,
    'manager bisa membuat employee di JKT01');
SELECT pos_test.throws(
    $$INSERT INTO pos.employees (organization_id, employee_code, full_name) VALUES ('00000000-0000-4000-8000-000000000001', 'EMP101', 'Staf Pusat')$$,
    'row-level security', 'manager tidak bisa membuat employee level organisasi');
SELECT pos_test.throws(
    $$INSERT INTO pos.terminals (outlet_id, code, name) VALUES ('00000000-0000-4000-8000-000000000101', 'POS-JKT-08', 'x')$$,
    'row-level security', 'manager tidak punya terminal.manage');
ROLLBACK;

BEGIN;
SET LOCAL ROLE pos_system;
DELETE FROM pos.user_outlets
WHERE user_id = (SELECT id FROM pos.users WHERE username = 'manager') AND outlet_id = :BDG;
SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws(
    $$INSERT INTO pos.employees (organization_id, employee_code, full_name, home_outlet_id) VALUES ('00000000-0000-4000-8000-000000000001', 'EMP102', 'x', '00000000-0000-4000-8000-000000000102')$$,
    'row-level security', 'manager tanpa akses BDG tidak bisa membuat employee di BDG');
ROLLBACK;

-- Admin: kelola outlet/terminal/device di semua outlet
BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected(
    $$INSERT INTO pos.terminals (outlet_id, code, name) VALUES ('00000000-0000-4000-8000-000000000102', 'POS-BDG-02', 'Kasir 2')$$) = 1,
    'admin bisa membuat terminal di BDG01');
SELECT set_config('pos_test.v_before', (SELECT version::text FROM pos.outlets WHERE code = 'JKT01'), true);
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.outlets SET phone = '021-0000' WHERE code = 'JKT01'$$) = 1,
    'admin bisa mengubah outlet');
SELECT pos_test.ok((SELECT version FROM pos.outlets WHERE code = 'JKT01')
                   = current_setting('pos_test.v_before')::int + 1, 'update menaikkan version (optimistic lock)');
SELECT pos_test.throws(
    $$INSERT INTO pos.terminals (outlet_id, code, name) VALUES ('00000000-0000-4000-8000-000000000101', 'POS-JKT-01', 'dup')$$,
    'terminals_code_uk', 'kode terminal unik');
-- device harus satu outlet & bertipe benar
SELECT pos_test.throws(
    $$UPDATE pos.terminals SET printer_id = '00000000-0000-4000-8000-000000000304' WHERE code = 'POS-JKT-01'$$,
    'terminals_printer_fk', 'printer outlet lain ditolak');
SELECT pos_test.throws(
    $$UPDATE pos.terminals SET printer_id = '00000000-0000-4000-8000-000000000302' WHERE code = 'POS-JKT-01'$$,
    'terminals_printer_fk', 'cash drawer tidak bisa dipasang sebagai printer');
SELECT pos_test.throws($$DELETE FROM pos.terminals WHERE code = 'POS-JKT-02'$$, 'permission denied',
    'admin pun tidak bisa hard delete terminal');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.terminals SET active = false WHERE code = 'POS-JKT-02'$$) = 1,
    'terminal dinonaktifkan (soft delete)');
ROLLBACK;

-- Hard delete master ditolak bahkan untuk pos_system (trigger)
BEGIN;
SET LOCAL ROLE pos_system;
SELECT pos_test.throws($$DELETE FROM pos.users WHERE username = 'cashier.bdg'$$, 'permission denied|APPEND_ONLY',
    'pos_system tidak bisa hard delete user');
ROLLBACK;
