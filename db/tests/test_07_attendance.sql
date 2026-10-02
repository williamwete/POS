-- Phase 2: attendance & break (§11, §12, §75)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set BDG '''00000000-0000-4000-8000-000000000102'''

-- Alur normal: clock in -> break -> end break -> clock out
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows($$
    INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by, device_id)
    VALUES (pos.current_org_id(), pos.current_employee_id(), '00000000-0000-4000-8000-000000000101',
            pos.current_app_user_id(), 'web-test') RETURNING id$$) = 1,
    'kasir clock in di outletnya');
SELECT pos_test.ok((SELECT business_date FROM pos.attendance WHERE status = 'WORKING')
                   = pos.business_date(now(), :JKT), 'business date dihitung server');
SELECT pos_test.throws($$
    INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by)
    VALUES (pos.current_org_id(), pos.current_employee_id(), '00000000-0000-4000-8000-000000000101', pos.current_app_user_id())$$,
    'attendance_open_per_employee_uk', 'tidak bisa clock in dua kali');
SELECT pos_test.ok(pos_test.affected($$
    INSERT INTO pos.attendance_breaks (attendance_id, reason)
    SELECT id, 'Makan siang' FROM pos.attendance WHERE status = 'WORKING'$$) = 1, 'mulai break');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.attendance SET status = 'ON_BREAK' WHERE status = 'WORKING'$$) = 1,
    'status ON_BREAK');
SELECT pos_test.throws($$
    INSERT INTO pos.attendance_breaks (attendance_id) SELECT id FROM pos.attendance WHERE status = 'ON_BREAK'$$,
    'ATTENDANCE_NOT_WORKING', 'tidak bisa break dua kali');
SELECT pos_test.throws($$
    UPDATE pos.attendance SET status = 'COMPLETED', clock_out_by = pos.current_app_user_id() WHERE status = 'ON_BREAK'$$,
    'ATTENDANCE_INVALID_TRANSITION', 'tidak bisa clock out langsung dari ON_BREAK');
SELECT pos_test.ok(pos_test.affected($$
    UPDATE pos.attendance_breaks SET break_end = now(), ended_by = pos.current_app_user_id() WHERE break_end IS NULL$$) = 1,
    'akhiri break');
SELECT pos_test.ok((SELECT duration_seconds FROM pos.attendance_breaks) IS NOT NULL, 'durasi break dihitung server');
SELECT pos_test.throws($$UPDATE pos.attendance_breaks SET reason = 'ubah'$$, 'BREAK_CLOSED', 'break selesai tidak bisa diubah');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.attendance SET status = 'WORKING' WHERE status = 'ON_BREAK'$$) = 1,
    'kembali WORKING');
SELECT pos_test.ok(pos_test.affected($$
    UPDATE pos.attendance SET status = 'COMPLETED', clock_out_by = pos.current_app_user_id() WHERE status = 'WORKING'$$) = 1,
    'clock out');
SELECT pos_test.ok((SELECT clock_out IS NOT NULL FROM pos.attendance), 'jam clock out terisi');
SELECT pos_test.throws($$UPDATE pos.attendance SET status = 'WORKING'$$, 'ATTENDANCE_CLOSED',
    'attendance selesai tidak bisa dibuka lagi');
SELECT pos_test.throws($$DELETE FROM pos.attendance$$, 'permission denied', 'attendance tidak bisa dihapus');
ROLLBACK;

-- Waktu tidak bisa dipalsukan client
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by, clock_in, business_date)
VALUES (pos.current_org_id(), pos.current_employee_id(), :JKT, pos.current_app_user_id(),
        '2020-01-01 08:00+07', '2020-01-01');
SELECT pos_test.ok((SELECT clock_in > '2025-01-01' AND business_date > '2025-01-01' FROM pos.attendance),
    'clock_in & business_date dari client diabaikan');
SELECT pos_test.throws($$UPDATE pos.attendance SET clock_in = clock_in - interval '2 hours'$$,
    'ATTENDANCE_IMMUTABLE_FIELD', 'jam masuk tidak bisa digeser');
ROLLBACK;

-- Scope & identitas
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by)
    VALUES (pos.current_org_id(), pos.current_employee_id(), '00000000-0000-4000-8000-000000000102', pos.current_app_user_id())$$,
    'row-level security', 'kasir JKT tidak bisa clock in di BDG');
ROLLBACK;

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by)
    VALUES (pos.current_org_id(), '00000000-0000-4000-8000-000000000504', '00000000-0000-4000-8000-000000000101', pos.current_app_user_id())$$,
    'row-level security', 'tidak bisa clock in atas nama karyawan lain');
ROLLBACK;

BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by)
    VALUES (pos.current_org_id(), pos.current_employee_id(), '00000000-0000-4000-8000-000000000101', pos.current_app_user_id())$$,
    'row-level security', 'admin tanpa attendance.clock_in tidak bisa clock in');
ROLLBACK;

-- Visibilitas & force clock out oleh supervisor
BEGIN;
SET LOCAL ROLE pos_system;
INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by)
VALUES ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000505', :JKT,
        '00000000-0000-4000-8000-000000000705');
INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by)
VALUES ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000506', :BDG,
        '00000000-0000-4000-8000-000000000706');
INSERT INTO pos.attendance_breaks (attendance_id)
SELECT id FROM pos.attendance WHERE employee_id = '00000000-0000-4000-8000-000000000505';
UPDATE pos.attendance SET status = 'ON_BREAK' WHERE employee_id = '00000000-0000-4000-8000-000000000505';

SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.attendance') = 1, 'kasir hanya melihat kehadirannya sendiri');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.attendance SET status = 'FORCED_CLOSED', clock_out_by = pos.current_app_user_id(),
    forced_reason = 'coba coba' WHERE employee_id = '00000000-0000-4000-8000-000000000505'$$) = 0,
    'kasir tidak bisa force clock out kasir lain');

SELECT pos_test.login('supervisor.jkt');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.attendance WHERE outlet_id = '00000000-0000-4000-8000-000000000101'$$) = 1,
    'supervisor JKT melihat kehadiran outletnya');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.attendance WHERE outlet_id = '00000000-0000-4000-8000-000000000102'$$) = 0,
    'supervisor JKT tidak melihat kehadiran BDG');
SELECT pos_test.ok(pos_test.rows('SELECT 1 FROM pos.attendance_breaks') = 1, 'supervisor melihat break kasir JKT');
SELECT pos_test.throws($$UPDATE pos.attendance SET status = 'FORCED_CLOSED', clock_out_by = pos.current_app_user_id(),
    forced_reason = 'Lupa clock out' WHERE employee_id = '00000000-0000-4000-8000-000000000505'$$,
    'BREAK_IN_PROGRESS', 'force clock out wajib menutup break dulu');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.attendance_breaks SET break_end = now(), ended_by = pos.current_app_user_id()
    WHERE break_end IS NULL$$) = 1, 'supervisor menutup break');
SELECT pos_test.throws($$UPDATE pos.attendance SET status = 'FORCED_CLOSED', clock_out_by = pos.current_app_user_id(),
    forced_reason = '' WHERE employee_id = '00000000-0000-4000-8000-000000000505'$$,
    'attendance_forced_reason_ck', 'force clock out wajib ada alasan');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.attendance SET status = 'FORCED_CLOSED', clock_out_by = pos.current_app_user_id(),
    forced_reason = 'Lupa clock out' WHERE employee_id = '00000000-0000-4000-8000-000000000505'$$) = 1,
    'supervisor force clock out dengan alasan');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.attendance SET status = 'FORCED_CLOSED', clock_out_by = pos.current_app_user_id(),
    forced_reason = 'Lupa clock out' WHERE employee_id = '00000000-0000-4000-8000-000000000506'$$) = 0,
    'supervisor JKT tidak bisa force clock out kasir BDG');
ROLLBACK;

-- Tidak bisa force clock out diri sendiri; tidak bisa clock out normal atas nama orang lain
BEGIN;
SET LOCAL ROLE pos_system;
INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by)
VALUES ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000504', :JKT,
        '00000000-0000-4000-8000-000000000704');
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$UPDATE pos.attendance SET status = 'FORCED_CLOSED', clock_out_by = pos.current_app_user_id(),
    forced_reason = 'Force diri sendiri'$$, 'row-level security', 'supervisor tidak bisa force clock out dirinya');
ROLLBACK;
