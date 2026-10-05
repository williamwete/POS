-- Phase 5: pembayaran — tunai & kembalian, split, non-tunai, gateway, pembalikan (§22, §23, §24, §63, §64)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set T1 '''00000000-0000-4000-8000-000000000401'''

-- §24: tunai dengan kembalian; §23: lunas → PAID; A5: cash movement = jumlah diterapkan
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.ok((SELECT grand_total FROM pos.sales) = 20000, 'total Rp 20.000');
SELECT pos_test.ok((SELECT count(*) FROM pos.payment_methods) = 6, '6 metode pembayaran default');
SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 50000);
SELECT pos_test.ok((SELECT amount = 20000 AND amount_received = 50000 AND change_amount = 30000 AND status = 'PAID'
                    FROM pos.payments), 'tunai: diterapkan 20.000, diterima 50.000, kembali 30.000');
SELECT pos_test.ok((SELECT status = 'PAID' AND paid_amount = 20000 AND change_amount = 30000 AND paid_at IS NOT NULL
                           AND sync_status = 'PENDING' FROM pos.sales), 'sale PAID, siap sync');
SELECT pos_test.ok((SELECT amount FROM pos.cash_movements WHERE movement_type = 'CASH_SALE') = 20000,
    'cash movement CASH_SALE = jumlah diterapkan (bukan uang diterima)');
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM pos.cashier_sessions) = 120000,
    'expected cash = modal 100.000 + 20.000');
SELECT pos_test.throws($$SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 1000)$$, 'SALE_ALREADY_PAID',
    'tidak bisa bayar transaksi yang sudah lunas');
SELECT pos_test.throws($$UPDATE pos.payments SET status = 'CANCELLED', cancel_reason = 'Salah input kasir'$$,
    'PAYMENT_NOT_REVERSIBLE', 'pembayaran transaksi lunas tidak bisa dibalik (refund Phase 8)');
SELECT pos_test.throws($$UPDATE pos.payments SET amount = 1$$, 'PAYMENT_IMMUTABLE_FIELD', 'jumlah pembayaran tidak bisa diubah');
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'VOID', void_reason = 'Pelanggan batal'$$,
    'SALE_INVALID_TRANSITION|SALE_HAS_PAYMENTS', 'transaksi lunas tidak bisa di-void (retur Phase 8)');
SELECT pos_test.throws($$DELETE FROM pos.payments$$, 'permission denied', 'pembayaran tidak bisa dihapus');
ROLLBACK;

-- paid_amount yang dikirim client diabaikan (dihitung ulang dari payments)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
UPDATE pos.sales SET paid_amount = 20000;
SELECT pos_test.ok((SELECT paid_amount = 0 AND status = 'CHECKOUT' FROM pos.sales), 'paid_amount palsu diabaikan');
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'PAID'$$, 'SALE_NOT_FULLY_PAID', 'PAID tanpa pembayaran ditolak');
ROLLBACK;

-- §23 split: tunai + debit; non-tunai tidak boleh lebih dari sisa; referensi wajib
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 10000);
SELECT pos_test.ok((SELECT status = 'CHECKOUT' AND paid_amount = 10000 FROM pos.sales), 'bayar sebagian: belum lunas');
SELECT pos_test.throws($$SELECT pos_test.pay((SELECT sale FROM t), 'DEBIT_CARD', 10000, NULL)$$,
    'PAYMENT_REFERENCE_REQUIRED', 'kartu debit wajib nomor referensi EDC');
SELECT pos_test.throws($$SELECT pos_test.pay((SELECT sale FROM t), 'DEBIT_CARD', 15000, NULL, 'APPR-001')$$,
    'PAYMENT_EXCEEDS_REMAINING', 'non-tunai tidak boleh melebihi sisa tagihan');
SELECT pos_test.pay((SELECT sale FROM t), 'DEBIT_CARD', 10000, NULL, 'APPR-001');
SELECT pos_test.ok((SELECT status = 'PAID' AND paid_amount = 20000 FROM pos.sales), 'tunai 10.000 + debit 10.000 = lunas');
SELECT pos_test.ok((SELECT count(*) FROM pos.cash_movements WHERE movement_type = 'CASH_SALE') = 1,
    'hanya bagian tunai yang menjadi cash movement');
ROLLBACK;

-- §64: QRIS menunggu konfirmasi penyedia; kasir tidak bisa menandai PAID
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'QRIS', 20000, NULL);
SELECT pos_test.ok((SELECT status = 'PENDING' AND expires_at > now() FROM pos.payments), 'QRIS: PENDING dengan batas waktu');
SELECT pos_test.ok((SELECT status FROM pos.sales) = 'PAYMENT_PENDING', 'sale PAYMENT_PENDING');
SELECT pos_test.throws($$UPDATE pos.payments SET status = 'PAID', reference_number = 'SUDAH-BAYAR'$$,
    'PAYMENT_CONFIRMATION_REQUIRED', 'tombol "sudah bayar" tidak membuat PAID');
SELECT pos_test.throws($$UPDATE pos.payments SET status = 'FAILED'$$, 'PAYMENT_INVALID_TRANSITION',
    'kasir tidak bisa menandai gagal');
SELECT pos_test.throws($$SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 20000)$$, 'SALE_ALREADY_PAID',
    'tidak bisa menambah pembayaran yang melebihi tagihan selama QRIS pending');
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'DRAFT'$$, 'SALE_INVALID_TRANSITION|SALE_HAS_PAYMENTS',
    'keranjang tidak bisa dibuka saat pembayaran berjalan');
-- terminal dikunci; callback penyedia tetap diterima
UPDATE pos.cashier_sessions SET status = 'ON_BREAK', lock_reason = 'MANUAL';
RESET ROLE;
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
UPDATE pos.payments SET status = 'PAID', external_transaction_id = external_transaction_id WHERE status = 'PENDING';
SELECT pos_test.ok((SELECT status = 'PAID' AND paid_at IS NOT NULL AND confirmed_by IS NULL FROM pos.payments),
    'callback sistem: PAID');
SELECT pos_test.ok((SELECT status FROM pos.sales) = 'PAID', 'sale lunas walau terminal terkunci');
SELECT pos_test.ok((SELECT count(*) FROM pos.cash_movements WHERE movement_type = 'CASH_SALE') = 0,
    'QRIS tidak masuk laci kas');
ROLLBACK;

-- PENDING dibatalkan (pelanggan batal QRIS) → kembali CHECKOUT; data gateway hanya diisi sekali
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'E_WALLET', 20000, NULL);
UPDATE pos.payments SET provider = 'SIMULATOR', external_transaction_id = 'SIM-1', qr_payload = 'QR';
SELECT pos_test.ok((SELECT external_transaction_id FROM pos.payments) = 'SIM-1', 'data gateway disimpan');
UPDATE pos.payments SET status = 'CANCELLED', cancel_reason = 'Pelanggan ganti metode';
SELECT pos_test.ok((SELECT status FROM pos.sales) = 'CHECKOUT', 'pembatalan pending → CHECKOUT');
SELECT pos_test.throws($$UPDATE pos.payments SET status = 'PAID'$$, 'PAYMENT_INVALID_TRANSITION', 'batal bersifat final');
ROLLBACK;

-- Pembalikan tunai sebelum lunas → CASH_SALE_REVERSAL; transaksi bisa di-void setelah pembayaran dibalik
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 5000);
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'VOID', void_reason = 'Pelanggan batal'$$, 'SALE_HAS_PAYMENTS',
    'void ditolak selama ada pembayaran');
SELECT pos_test.throws($$UPDATE pos.payments SET status = 'CANCELLED', cancel_reason = 'x'$$, 'PAYMENT_CANCEL_REASON_REQUIRED',
    'pembalikan wajib alasan');
UPDATE pos.payments SET status = 'CANCELLED', cancel_reason = 'Pelanggan batal belanja';
SELECT pos_test.ok((SELECT sum(amount) FROM pos.cash_movements WHERE reference_type = 'PAYMENT') = 0,
    'CASH_SALE + CASH_SALE_REVERSAL = 0');
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM pos.cashier_sessions) = 100000, 'expected cash kembali');
SELECT pos_test.ok((SELECT paid_amount FROM pos.sales) = 0, 'paid_amount kembali 0');
ROLLBACK;

-- Transfer bank: wajib approval supervisor (payment.approve)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.throws($$SELECT pos_test.pay((SELECT sale FROM t), 'BANK_TRANSFER', 20000, NULL, 'TRF-778899')$$,
    'APPROVAL_REQUIRED', 'transfer tanpa approval ditolak');
CREATE TEMP TABLE a (id uuid);
WITH ins AS (
    INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, price, requested_by, approved_by, expires_at)
    SELECT s.organization_id, s.outlet_id, s.id, 'PAYMENT_CONFIRM', 20000, pos.current_app_user_id(),
           '00000000-0000-4000-8000-000000000704', now()
    FROM pos.sales s RETURNING id)
INSERT INTO a SELECT id FROM ins;
UPDATE pos.approvals SET used_at = now();
SELECT pos_test.pay((SELECT sale FROM t), 'BANK_TRANSFER', 20000, NULL, 'TRF-778899', (SELECT id FROM a));
SELECT pos_test.ok((SELECT status = 'PAID' AND approved_by = '00000000-0000-4000-8000-000000000704' FROM pos.payments),
    'transfer disetujui supervisor → PAID');
SELECT pos_test.ok((SELECT status FROM pos.sales) = 'PAID', 'sale lunas');
ROLLBACK;

-- Kasir lain / role tanpa izin tidak bisa menerima pembayaran transaksi orang lain
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
GRANT SELECT ON t TO PUBLIC;
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 20000)$$,
    'CASHIER_SESSION_NOT_OWNER|row-level security', 'supervisor tidak bisa mencatat pembayaran transaksi kasir');
ROLLBACK;

-- Konfigurasi metode: hanya configuration.manage org-wide
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.payment_methods SET active = false, updated_by = pos.current_app_user_id()$$) = 0,
    'kasir tidak bisa mengubah metode pembayaran');
RESET ROLE;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.payment_methods SET manual_confirm_allowed = true,
    updated_by = pos.current_app_user_id() WHERE code = 'QRIS'$$) = 1, 'admin mengaktifkan konfirmasi manual QRIS (QRIS statis)');
SELECT pos_test.throws($$UPDATE pos.payment_methods SET manual_confirm_allowed = true, updated_by = pos.current_app_user_id()
    WHERE code = 'CASH'$$, 'payment_methods_manual_confirm_ck', 'konfirmasi manual hanya untuk metode gateway');
SELECT pos_test.throws($$UPDATE pos.payment_methods SET kind = 'CASH', updated_by = pos.current_app_user_id() WHERE code = 'QRIS'$$,
    'PAYMENT_METHOD_IMMUTABLE_FIELD', 'jenis metode tidak bisa diubah');
-- QRIS statis: pending lalu dikonfirmasi manual dengan approval supervisor + referensi
RESET ROLE;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'QRIS', 20000, NULL);
SELECT pos_test.throws($$UPDATE pos.payments SET status = 'PAID', reference_number = 'RRN-123456'$$, 'APPROVAL_REQUIRED',
    'konfirmasi manual tetap wajib approval');
CREATE TEMP TABLE a (id uuid);
WITH ins AS (
    INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, price, requested_by, approved_by, expires_at)
    SELECT s.organization_id, s.outlet_id, s.id, 'PAYMENT_CONFIRM', 20000, pos.current_app_user_id(),
           '00000000-0000-4000-8000-000000000704', now()
    FROM pos.sales s RETURNING id)
INSERT INTO a SELECT id FROM ins;
UPDATE pos.approvals SET used_at = now();
SELECT pos_test.throws($$UPDATE pos.payments SET status = 'PAID', approval_id = (SELECT id FROM a)$$,
    'PAYMENT_REFERENCE_REQUIRED', 'konfirmasi manual wajib nomor referensi');
UPDATE pos.payments SET status = 'PAID', approval_id = (SELECT id FROM a), reference_number = 'RRN-123456';
SELECT pos_test.ok((SELECT status = 'PAID' AND confirmed_by IS NOT NULL AND approved_by IS NOT NULL FROM pos.payments),
    'QRIS statis dikonfirmasi manual');
SELECT pos_test.ok((SELECT status FROM pos.sales) = 'PAID', 'sale lunas');
ROLLBACK;

-- Approval konfirmasi pembayaran tidak bisa diberikan kasir lain (rank/izin)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.throws($$
    INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, price, requested_by, approved_by, expires_at)
    SELECT s.organization_id, s.outlet_id, s.id, 'PAYMENT_CONFIRM', 20000, pos.current_app_user_id(),
           '00000000-0000-4000-8000-000000000706', now() FROM pos.sales s$$,
    'APPROVER_NOT_AUTHORIZED', 'kasir BDG tidak bisa menyetujui pembayaran');
ROLLBACK;
