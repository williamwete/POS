-- Clock in opsional per merchant (V027)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos.attendance_required('00000000-0000-4000-8000-000000000101'), 'bawaan: clock in wajib');
SELECT pos_test.throws($$SELECT pos.auto_clock_in('00000000-0000-4000-8000-000000000101')$$, 'ATTENDANCE_REQUIRED', 'kehadiran otomatis ditolak saat clock in wajib');
SELECT pos_test.throws($$SELECT pos.set_attendance_required(false)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa mengubah pengaturan');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos.set_attendance_required(false);
SELECT pos_test.ok(NOT pos.attendance_required(NULL), 'owner mematikan wajib clock in');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.audit_logs WHERE action = 'SETTING_CHANGED' AND entity_id = 'attendance_required'), 'perubahan pengaturan tercatat di audit');
RESET ROLE;

SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.auto_clock_in('00000000-0000-4000-8000-000000000102')$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa clock in otomatis di outlet lain');
SELECT pos.auto_clock_in('00000000-0000-4000-8000-000000000101');
SELECT pos_test.ok((SELECT status = 'WORKING' AND device_id = 'AUTO' FROM pos.attendance WHERE employee_id = pos.current_employee_id() AND status = 'WORKING'), 'kehadiran otomatis berstatus WORKING');
SELECT pos.auto_clock_out(pos.current_employee_id());
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.attendance WHERE employee_id = pos.current_employee_id() AND status = 'WORKING'), 'kehadiran otomatis ditutup');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.attendance WHERE employee_id = pos.current_employee_id() AND status = 'COMPLETED' AND device_id = 'AUTO'), 'riwayat kehadiran otomatis tersimpan');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos.set_attendance_required(true);
SELECT pos_test.ok(pos.attendance_required(NULL), 'owner menyalakan kembali');
RESET ROLE;
ROLLBACK;
