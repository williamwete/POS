-- Phase 3: cashier session, opening cash count, session lock (§13, §14, §55, §74, §76)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set BDG '''00000000-0000-4000-8000-000000000102'''
\set T1 '''00000000-0000-4000-8000-000000000401'''
\set T2 '''00000000-0000-4000-8000-000000000402'''
\set TB '''00000000-0000-4000-8000-000000000403'''

-- §76: buka kasir dengan hitungan denominasi
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) FROM pos.cash_denominations) = 11, 'denominasi IDR default tersedia');
SELECT pos_test.throws($$SELECT pos_test.open_session('00000000-0000-4000-8000-000000000401', NULL)$$,
    'ATTENDANCE_REQUIRED', 'tidak bisa buka kasir sebelum clock in');
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,2},{50000,3},{20000,5},{10000,5},{5000,5}}');
SELECT pos_test.ok((SELECT opening_cash FROM pos.cashier_sessions) = 525000, 'opening cash = 525.000 dijumlah dari denominasi');
SELECT pos_test.ok((SELECT status FROM pos.cashier_sessions) = 'OPEN', 'session OPEN');
SELECT pos_test.ok((SELECT total_amount = 525000 AND expected_amount = 525000 AND difference = 0
                    FROM pos.cash_counts WHERE count_type = 'OPENING'), 'hitungan OPENING tercatat');
SELECT pos_test.ok((SELECT count(*) FROM pos.cash_count_items) = 5, 'rincian denominasi tersimpan');
SELECT pos_test.ok((SELECT business_date FROM pos.cashier_sessions) = pos.business_date(now(), :JKT),
    'business date dari server');
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM pos.cashier_sessions) = 525000,
    'expected cash = opening cash');
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pos_test.ok(true, 'pemeriksaan konsistensi modal awal lolos saat commit');
-- buka kedua: ditolak
SELECT pos_test.throws($$SELECT pos_test.open_session('00000000-0000-4000-8000-000000000402', '{{1000,1}}')$$,
    'cashier_sessions_active_employee_uk', 'karyawan tidak bisa punya dua session aktif');
ROLLBACK;

-- §74: terminal yang sudah punya session aktif tidak bisa dibuka kasir lain
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{50000,1}}');
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.throws($$SELECT pos_test.open_session('00000000-0000-4000-8000-000000000401', '{{50000,1}}')$$,
    'cashier_sessions_active_terminal_uk', 'terminal yang sudah OPEN tidak bisa dibuka lagi');
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.cashier_sessions$$) = 1,
    'supervisor (cashier.view) melihat session kasir di outletnya');
ROLLBACK;

-- Modal awal harus konsisten dengan hitungan (diperiksa saat commit)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
INSERT INTO pos.cashier_sessions (organization_id, outlet_id, terminal_id, employee_id, attendance_id, opened_by,
                                  opening_cash, status)
SELECT pos.current_org_id(), :JKT, :T1, pos.current_employee_id(), a.id, pos.current_app_user_id(), 999999, 'OPEN'
FROM pos.attendance a;
SELECT pos_test.ok((SELECT opening_cash FROM pos.cashier_sessions) = 0, 'opening cash dari client diabaikan');
SELECT pos_test.throws($$SET CONSTRAINTS ALL IMMEDIATE$$, 'OPENING_CASH_MISMATCH',
    'session tanpa hitungan OPENING ditolak saat commit');
ROLLBACK;

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
UPDATE pos.cashier_sessions SET opening_cash = 200000;
SELECT pos_test.throws($$SET CONSTRAINTS ALL IMMEDIATE$$, 'OPENING_CASH_MISMATCH',
    'opening cash yang tidak sama dengan hitungan ditolak');
ROLLBACK;

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
SELECT pos_test.throws($$
    INSERT INTO pos.cash_count_items (cash_count_id, denomination_id, value, kind, quantity)
    SELECT c.id, d.id, 1, 'NOTE', -1 FROM pos.cash_counts c, pos.cash_denominations d
    WHERE d.value = 50000 AND d.kind = 'NOTE'$$, 'cash_count_items_qty_ck', 'jumlah lembar negatif ditolak');
SELECT pos_test.throws($$
    INSERT INTO pos.cash_movements (organization_id, outlet_id, cashier_session_id, business_date, movement_type, amount, created_by)
    SELECT organization_id, outlet_id, id, business_date, 'CASH_IN', 10000, pos.current_app_user_id()
    FROM pos.cashier_sessions$$, 'CASH_MOVEMENT_REASON_REQUIRED', 'kas masuk wajib alasan');
SELECT pos_test.throws($$UPDATE pos.cash_movements SET amount = 1$$, 'permission denied', 'movement tidak bisa diubah');
SELECT pos_test.throws($$DELETE FROM pos.cashier_sessions$$, 'permission denied', 'session tidak bisa dihapus');
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET terminal_id = '00000000-0000-4000-8000-000000000402'$$,
    'CASHIER_SESSION_IMMUTABLE_FIELD', 'terminal session tidak bisa dipindah');
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'CLOSED', closed_by = pos.current_app_user_id()$$,
    'CLOSING_COUNT_REQUIRED|cashier_sessions', 'tutup kasir wajib hitung kas akhir');
ROLLBACK;

-- Nilai denominasi diambil dari master, bukan dari client
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
SELECT pos_test.ok((SELECT value FROM pos.cash_count_items) = 100000, 'nilai item = nilai denominasi master');
ROLLBACK;

-- Scope: kasir JKT tidak bisa buka terminal BDG; terminal harus di outlet attendance
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.throws($$
    INSERT INTO pos.cashier_sessions (organization_id, outlet_id, terminal_id, employee_id, attendance_id, opened_by)
    SELECT pos.current_org_id(), '00000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000403',
           pos.current_employee_id(), a.id, pos.current_app_user_id() FROM pos.attendance a$$,
    'ATTENDANCE_REQUIRED', 'kasir JKT tidak bisa buka terminal BDG (attendance di JKT)');
SELECT pos_test.throws($$
    INSERT INTO pos.cashier_sessions (organization_id, outlet_id, terminal_id, employee_id, attendance_id, opened_by)
    SELECT pos.current_org_id(), '00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000403',
           pos.current_employee_id(), a.id, pos.current_app_user_id() FROM pos.attendance a$$,
    'cashier_sessions_terminal_fk', 'terminal harus milik outlet session');
ROLLBACK;

-- Terminal nonaktif
BEGIN;
SET LOCAL ROLE pos_system;
UPDATE pos.terminals SET active = false WHERE id = :T2;
RESET ROLE;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.throws($$SELECT pos_test.open_session('00000000-0000-4000-8000-000000000402', '{{1000,1}}')$$,
    'TERMINAL_INACTIVE', 'terminal nonaktif tidak bisa dibuka');
ROLLBACK;

-- Auditor & admin: tidak bisa buka kasir
BEGIN;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$
    INSERT INTO pos.cashier_sessions (organization_id, outlet_id, terminal_id, employee_id, attendance_id, opened_by)
    VALUES (pos.current_org_id(), '00000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000401',
            pos.current_employee_id(), gen_random_uuid(), pos.current_app_user_id())$$,
    'row-level security|ATTENDANCE_REQUIRED|foreign key', 'admin tidak punya cashier.open');
ROLLBACK;

-- Session lock: kunci manual, buka kunci wajib login ulang
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{50000,2}}');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.cashier_sessions SET status = 'ON_BREAK', lock_reason = 'MANUAL'$$) = 1,
    'kunci terminal');
SELECT pos_test.ok((SELECT locked_at IS NOT NULL FROM pos.cashier_sessions), 'waktu kunci dari server');
SELECT pos_test.throws($$
    INSERT INTO pos.cash_counts (cashier_session_id, count_type, counted_by)
    SELECT id, 'MID', pos.current_app_user_id() FROM pos.cashier_sessions$$,
    'CASHIER_SESSION_LOCKED', 'tidak bisa hitung kas saat terkunci');
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'OPEN', lock_reason = NULL, locked_at = NULL$$,
    'REAUTH_REQUIRED', 'buka kunci tanpa login ulang ditolak');
RESET ROLE;
SELECT pos_test.reauth('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.cashier_sessions SET status = 'OPEN', lock_reason = NULL, locked_at = NULL$$) = 1,
    'buka kunci setelah login ulang');
ROLLBACK;

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{50000,2}}');
UPDATE pos.cashier_sessions SET status = 'ON_BREAK', lock_reason = 'IDLE';
RESET ROLE;
SELECT pos_test.reauth('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'OPEN', lock_reason = NULL, locked_at = NULL$$,
    'CASHIER_SESSION_NOT_OWNER|row-level security', 'supervisor tidak bisa membuka kunci session kasir');
ROLLBACK;

-- §55: clock out ditolak selama session aktif; break mengunci session
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{50000,2}}');
SELECT pos_test.throws($$
    UPDATE pos.attendance SET status = 'COMPLETED', clock_out_by = pos.current_app_user_id() WHERE status = 'WORKING'$$,
    'CASHIER_SESSION_OPEN', 'clock out ditolak selama cashier session OPEN');
INSERT INTO pos.attendance_breaks (attendance_id) SELECT id FROM pos.attendance WHERE status = 'WORKING';
UPDATE pos.attendance SET status = 'ON_BREAK' WHERE status = 'WORKING';
SELECT pos_test.ok((SELECT status = 'ON_BREAK' AND lock_reason = 'BREAK' FROM pos.cashier_sessions),
    'mulai istirahat mengunci session');
RESET ROLE;
SELECT pos_test.reauth('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'OPEN', lock_reason = NULL, locked_at = NULL$$,
    'ATTENDANCE_REQUIRED', 'tidak bisa buka kunci selama masih istirahat');
UPDATE pos.attendance_breaks SET break_end = now(), ended_by = pos.current_app_user_id() WHERE break_end IS NULL;
UPDATE pos.attendance SET status = 'WORKING' WHERE status = 'ON_BREAK';
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.cashier_sessions SET status = 'OPEN', lock_reason = NULL, locked_at = NULL$$) = 1,
    'selesai istirahat + login ulang membuka kunci');
-- batal buka kasir (belum ada aktivitas) lalu clock out boleh
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'CANCELLED', closed_by = pos.current_app_user_id(), cancel_reason = 'x'$$,
    'cashier_sessions_cancel_reason_ck', 'batal wajib alasan');
SELECT pos_test.ok(pos_test.affected($$
    UPDATE pos.cashier_sessions SET status = 'CANCELLED', closed_by = pos.current_app_user_id(),
           cancel_reason = 'Salah hitung modal'$$) = 1, 'batal buka kasir');
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'OPEN'$$, 'CASHIER_SESSION_CLOSED',
    'session batal tidak bisa dibuka lagi');
SELECT pos_test.ok(pos_test.affected($$
    UPDATE pos.attendance SET status = 'COMPLETED', clock_out_by = pos.current_app_user_id() WHERE status = 'WORKING'$$) = 1,
    'clock out setelah session ditutup');
ROLLBACK;

-- Force clock out supervisor: diizinkan, session kasir dikunci
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{50000,2}}');
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$
    UPDATE pos.attendance SET status = 'FORCED_CLOSED', clock_out_by = pos.current_app_user_id(),
           forced_reason = 'Kasir pulang mendadak'
    WHERE employee_id = '00000000-0000-4000-8000-000000000505'$$) = 1, 'force clock out tetap bisa');
SELECT pos_test.ok((SELECT status = 'ON_BREAK' AND lock_reason = 'FORCED_CLOCK_OUT' FROM pos.cashier_sessions),
    'session kasir dikunci setelah force clock out');
ROLLBACK;
