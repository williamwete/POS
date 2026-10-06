-- Phase 6: manajemen kas + tutup kasir (§25, §48–§51, §82)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set T1 '''00000000-0000-4000-8000-000000000401'''
\set T2 '''00000000-0000-4000-8000-000000000402'''
\set T3 '''00000000-0000-4000-8000-000000000403'''
\set SUP '''00000000-0000-4000-8000-000000000704'''
\set MGR '''00000000-0000-4000-8000-000000000703'''
\set KASIR '''00000000-0000-4000-8000-000000000705'''
\set KASIR_BDG '''00000000-0000-4000-8000-000000000706'''

-- §25: kas masuk / keluar / petty cash oleh pemegang laci, wajib alasan, laci tidak bisa negatif
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,1}}') AS id;
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_IN', 50000, NULL)$$,
    'CASH_MOVEMENT_REASON_REQUIRED', 'kas masuk tanpa alasan ditolak');
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_IN', 50000, 'ok')$$,
    'CASH_MOVEMENT_REASON_REQUIRED', 'alasan terlalu pendek ditolak');
SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_IN', 50000, 'Tambahan uang kembalian');
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_IN', -5000, 'Tanda salah')$$,
    'cash_movements_amount_sign_ck|cash_movements', 'kas masuk harus positif');
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -200000, 'Bayar kurir')$$,
    'CASH_INSUFFICIENT', 'kas keluar melebihi isi laci ditolak');
SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -50000, 'Bayar kurir galon');
SELECT pos_test.cash_move((SELECT id FROM s), 'PETTY_CASH', -20000, 'Beli plastik kresek');
SELECT pos_test.ok((SELECT approved_by IS NULL AND approval_id IS NULL FROM pos.cash_movements WHERE movement_type = 'CASH_OUT'),
    'kas keluar di bawah ambang tanpa approval');
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM s) = 80000,
    'expected cash = 100.000 + 50.000 − 50.000 − 20.000');
SELECT pos_test.ok((SELECT outlet_id = :JKT AND business_date = (SELECT business_date FROM pos.cashier_sessions)
                    FROM pos.cash_movements WHERE movement_type = 'PETTY_CASH'), 'outlet & tanggal bisnis dari session');
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_ADJUSTMENT', 5000, 'Koreksi hitungan')$$,
    'row-level security|SELF_MODIFICATION_NOT_ALLOWED', 'kasir tidak bisa penyesuaian kas');
SELECT pos_test.throws($$UPDATE pos.cash_movements SET amount = -1 WHERE movement_type = 'CASH_OUT'$$,
    'permission denied', 'movement tidak bisa diubah');
UPDATE pos.cashier_sessions SET status = 'ON_BREAK', lock_reason = 'MANUAL';
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_IN', 10000, 'Tambahan modal')$$,
    'CASHIER_SESSION_LOCKED', 'kas masuk ditolak saat terminal terkunci');
ROLLBACK;

-- §25: kas keluar di atas ambang (100.000 demo) wajib approval supervisor
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,5}}') AS id;
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -150000, 'Setor ke brankas')$$,
    'APPROVAL_REQUIRED', 'kas keluar 150.000 tanpa approval ditolak');
SELECT pos_test.throws($$SELECT pos_test.cash_approval((SELECT id FROM s), 'CASH_OUT', 150000, '00000000-0000-4000-8000-000000000705')$$,
    'APPROVER_INVALID|approvals_distinct_ck', 'kasir tidak bisa menyetujui diri sendiri');
SELECT pos_test.throws($$SELECT pos_test.cash_approval((SELECT id FROM s), 'CASH_OUT', 150000, '00000000-0000-4000-8000-000000000706')$$,
    'APPROVER_NOT_AUTHORIZED', 'approver tanpa izin di outlet ditolak');
SELECT pos_test.throws($$SELECT pos_test.cash_approval((SELECT id FROM s), 'CASH_OUT', 0, '00000000-0000-4000-8000-000000000704')$$,
    'approvals_target_ck', 'approval kas wajib nominal');
CREATE TEMP TABLE a1 AS SELECT pos_test.cash_approval((SELECT id FROM s), 'CASH_OUT', 150000, :SUP, false) AS id;
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -150000, 'Setor ke brankas', (SELECT id FROM a1))$$,
    'APPROVAL_REQUIRED', 'approval belum dipakai (consume) ditolak');
UPDATE pos.approvals SET used_at = now() WHERE id = (SELECT id FROM a1);
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -200000, 'Setor ke brankas', (SELECT id FROM a1))$$,
    'APPROVAL_REQUIRED', 'approval untuk nominal lain ditolak');
SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -150000, 'Setor ke brankas', (SELECT id FROM a1));
SELECT pos_test.ok((SELECT approved_by = :SUP AND approval_id = (SELECT id FROM a1) FROM pos.cash_movements
                    WHERE movement_type = 'CASH_OUT'), 'kas keluar tercatat dengan approver');
SELECT pos_test.throws($$UPDATE pos.approvals SET used_at = now() WHERE id = (SELECT id FROM a1)$$,
    'APPROVAL_USED', 'approval hanya sekali pakai');
SELECT pos_test.ok((SELECT action = 'CASH_OUT' AND sale_id IS NULL AND outlet_id = :JKT FROM pos.approvals),
    'approval kas terikat session, bukan transaksi');
ROLLBACK;

-- Penyesuaian kas: restricted (store manager), tidak untuk laci sendiri
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,1}}') AS id;
GRANT SELECT ON s TO PUBLIC;
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_ADJUSTMENT', 5000, 'Koreksi hitungan')$$,
    'row-level security', 'supervisor tanpa cash.cash_adjustment ditolak');
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_IN', 5000, 'Tambah modal')$$,
    'row-level security|CASHIER_SESSION_NOT_OWNER', 'kas masuk ke laci orang lain ditolak');
RESET ROLE;
SELECT pos_test.login('manager');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_ADJUSTMENT', 5000, 'kor')$$,
    'CASH_MOVEMENT_REASON_REQUIRED', 'penyesuaian wajib alasan');
SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_ADJUSTMENT', 5000, 'Koreksi salah catat modal');
SELECT pos_test.ok((SELECT approved_by = :MGR AND created_by = :MGR FROM pos.cash_movements
                    WHERE movement_type = 'CASH_ADJUSTMENT'), 'penyesuaian tercatat atas nama manager');
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM s) = 105000, 'penyesuaian masuk expected cash');
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s2 AS SELECT pos_test.open_session(:T2, '{{100000,1}}') AS id;
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s2), 'CASH_ADJUSTMENT', 5000, 'Koreksi laci sendiri')$$,
    'SELF_MODIFICATION_NOT_ALLOWED', 'penyesuaian laci sendiri ditolak');
ROLLBACK;

-- §82: modal 1.000.000 + penjualan tunai 4.500.000 − kas keluar 100.000 = expected 5.400.000, selisih 0
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE att AS SELECT pos_test.clock_in(:JKT) AS id;
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,10}}') AS id;
CREATE TEMP TABLE sale AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM sale), 'SKU-0012', 90);
UPDATE pos.sales SET status = 'CHECKOUT';
SELECT pos_test.pay((SELECT id FROM sale), 'CASH', 1, 4500000);
SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -100000, 'Bayar ongkos kirim');
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM s) = 5400000, 'expected cash 5.400.000');
SELECT pos_test.throws($$UPDATE pos.attendance SET status = 'COMPLETED', clock_out_by = pos.current_app_user_id()$$,
    'CASHIER_SESSION_OPEN', 'belum tutup kasir: clock out ditolak');
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET expected_cash = 5400000$$,
    'CASHIER_SESSION_IMMUTABLE_FIELD', 'angka penutupan tidak bisa diisi client');
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'CLOSED', closed_by = pos.current_app_user_id()$$,
    'CLOSING_COUNT_REQUIRED', 'tutup tanpa hitung fisik ditolak');
SELECT pos_test.close_session((SELECT id FROM s), '{{100000,54}}');
SELECT pos_test.ok((SELECT status = 'CLOSED' AND closing_cash = 5400000 AND expected_cash = 5400000 AND difference = 0
                           AND closed_by = :KASIR AND closed_at IS NOT NULL AND difference_reason IS NULL
                    FROM pos.cashier_sessions), 'tutup kasir: kas akhir 5.400.000, selisih 0');
SELECT pos_test.ok((SELECT amount FROM pos.cash_movements WHERE movement_type = 'CLOSING_CASH') = -5400000,
    'uang laci dicatat keluar (CLOSING_CASH)');
SELECT pos_test.ok((SELECT expected_amount = 5400000 AND difference = 0 FROM pos.cash_counts WHERE count_type = 'CLOSING'),
    'hitungan CLOSING tersimpan dengan expected & selisih');
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_IN', 10000, 'Tambah modal')$$,
    'CASHIER_SESSION_CLOSED', 'tidak ada kas masuk setelah tutup');
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'OPEN'$$,
    'CASHIER_SESSION_CLOSED', 'session tertutup tidak bisa dibuka lagi');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.attendance SET status = 'COMPLETED', clock_out_by = pos.current_app_user_id()
                   WHERE status = 'WORKING'$$) = 1, 'setelah tutup kasir: clock out berhasil');
ROLLBACK;

-- §48: transaksi terbuka / pembayaran pending memblokir tutup kasir; terminal terkunci harus dibuka dulu
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE sale AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS id;
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM pos.cashier_sessions), '{{100000,1}}')$$,
    'OPEN_ORDER_EXISTS', 'transaksi CHECKOUT memblokir tutup kasir');
SELECT pos_test.pay((SELECT id FROM sale), 'QRIS', 20000, NULL);
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM pos.cashier_sessions), '{{100000,1}}')$$,
    'OPEN_ORDER_EXISTS|PAYMENT_PENDING', 'pembayaran QRIS pending memblokir tutup kasir');
UPDATE pos.payments SET status = 'CANCELLED', cancel_reason = 'Pelanggan batal QRIS';
SELECT pos_test.ok((SELECT status FROM pos.sales) = 'CHECKOUT', 'QRIS dibatalkan: transaksi kembali CHECKOUT');
ROLLBACK;

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
UPDATE pos.cashier_sessions SET status = 'ON_BREAK', lock_reason = 'IDLE';
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM pos.cashier_sessions), '{{100000,1}}')$$,
    'CASHIER_SESSION_LOCKED', 'terminal terkunci: buka kunci dulu');
ROLLBACK;

-- §51: selisih wajib alasan; di atas ambang (20.000 demo) wajib approval orang lain
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,2}}') AS id;
SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_IN', 10000, 'Tambahan receh');
-- expected 210.000; fisik 200.000 → selisih −10.000
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM s), '{{100000,2}}')$$,
    'CASH_DIFFERENCE_REASON_REQUIRED', 'selisih tanpa alasan ditolak');
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM s), '{{100000,2}}', 'LAINNYA')$$,
    'CASH_DIFFERENCE_REASON_REQUIRED|cashier_sessions_difference_reason_ck', 'kode alasan tidak dikenal ditolak');
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM s), '{{100000,2}}', 'OTHER', 'x')$$,
    'CASH_DIFFERENCE_REASON_REQUIRED', 'alasan OTHER wajib keterangan');
SELECT pos_test.close_session((SELECT id FROM s), '{{100000,2}}', 'SHORTAGE');
SELECT pos_test.ok((SELECT difference = -10000 AND difference_reason = 'SHORTAGE' AND difference_approval_id IS NULL
                    FROM pos.cashier_sessions), 'selisih −10.000 (≤ ambang) cukup dengan alasan');
ROLLBACK;

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,3}}') AS id;
-- expected 300.000; fisik 250.000 → selisih −50.000
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM s), '{{100000,2},{50000,1}}', 'SHORTAGE')$$,
    'CASH_DIFFERENCE_REQUIRES_APPROVAL', 'selisih −50.000 tanpa approval ditolak');
CREATE TEMP TABLE a1 AS SELECT pos_test.cash_approval((SELECT id FROM s), 'CASH_DIFFERENCE', 40000, :SUP) AS id;
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM s), '{{100000,2},{50000,1}}', 'SHORTAGE', NULL, (SELECT id FROM a1))$$,
    'CASH_DIFFERENCE_REQUIRES_APPROVAL', 'approval untuk nominal selisih lain ditolak');
CREATE TEMP TABLE a2 AS SELECT pos_test.cash_approval((SELECT id FROM s), 'CASH_DIFFERENCE', 50000, :SUP) AS id;
SELECT pos_test.close_session((SELECT id FROM s), '{{100000,2},{50000,1}}', 'SHORTAGE', NULL, (SELECT id FROM a2));
SELECT pos_test.ok((SELECT difference = -50000 AND difference_approval_id = (SELECT id FROM a2)
                           AND difference_approved_by = :SUP FROM pos.cashier_sessions),
    'selisih −50.000 tertutup dengan approval supervisor');
SELECT pos_test.ok((SELECT amount FROM pos.cash_movements WHERE movement_type = 'CLOSING_CASH') = -250000,
    'CLOSING_CASH = uang fisik, bukan expected');
ROLLBACK;

-- Supervisor menutup laci kasir lain (mis. kasir pulang); kasir lain / outlet lain tidak bisa
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,1}}') AS id;
GRANT SELECT ON s TO PUBLIC;
RESET ROLE;
SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM s), '{{100000,1}}')$$,
    'row-level security|not visible', 'kasir outlet lain tidak bisa menutup laci');
RESET ROLE;
SELECT pos_test.reauth('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -10000, 'Ambil uang')$$,
    'row-level security|CASHIER_SESSION_NOT_OWNER', 'supervisor tidak bisa kas keluar dari laci kasir');
SELECT pos_test.close_session((SELECT id FROM s), '{{100000,1}}');
SELECT pos_test.ok((SELECT status = 'CLOSED' AND closed_by = :SUP AND difference = 0 FROM pos.cashier_sessions),
    'supervisor menutup laci kasir lain');
SELECT pos_test.ok((SELECT counted_by = :SUP FROM pos.cash_counts WHERE count_type = 'CLOSING'),
    'hitungan akhir atas nama supervisor');
ROLLBACK;
