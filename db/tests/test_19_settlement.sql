-- Saldo merchant, biaya, rekening bank, dan pencairan
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set T1 '''00000000-0000-4000-8000-000000000401'''
\set SUP '''00000000-0000-4000-8000-000000000704'''

BEGIN;
-- ketentuan: tanpa masa tahan agar saldo langsung dapat dicairkan
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.platform_set_terms('00000000-0000-4000-8000-000000000001', 50, 0, 0, 1000)$$, 'payout_terms_ck', 'biaya maksimal 20%');
SELECT pos.platform_set_terms('00000000-0000-4000-8000-000000000001', 0.7, 0, 0, 1000);
RESET ROLE;

-- pembayaran QRIS lewat penyedia
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'QRIS', 20000, NULL);
UPDATE pos.payments SET provider = 'SIMULATOR', external_transaction_id = 'SIM-LEDGER-1', qr_payload = 'QR';
SELECT pos_test.throws($$SELECT * FROM pos.my_balance()$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa melihat saldo');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.merchant_ledger), 'kasir tidak melihat buku besar');
RESET ROLE;
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
UPDATE pos.payments SET status = 'PAID' WHERE status = 'PENDING';
SELECT pos_test.throws($$UPDATE pos.merchant_ledger SET amount = 1$$, 'APPEND_ONLY_VIOLATION|permission denied', 'buku besar tidak dapat diubah');
SELECT pos_test.throws($$DELETE FROM pos.merchant_ledger$$, 'APPEND_ONLY_VIOLATION|permission denied', 'buku besar tidak dapat dihapus');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 2 FROM pos.merchant_ledger), 'lunas: entri PAYMENT dan FEE');
SELECT pos_test.ok((SELECT amount = 20000 FROM pos.merchant_ledger WHERE entry_type = 'PAYMENT')
                   AND (SELECT amount = -140 FROM pos.merchant_ledger WHERE entry_type = 'FEE'), 'biaya 0,7% = Rp 140');
SELECT pos_test.ok((SELECT total = 19860 AND available = 19860 AND pending = 0 AND bank_status IS NULL FROM pos.my_balance()), 'saldo Rp 19.860, belum ada rekening');

-- rekening & pencairan
SELECT pos_test.throws($$SELECT pos.request_payout(5000)$$, 'PAYOUT_INVALID', 'tanpa rekening tidak bisa mencairkan');
SELECT pos_test.throws($$SELECT pos.save_bank_account('BCA', 'abc', 'Hendra')$$, 'CATALOG_INVALID', 'nomor rekening harus angka');
SELECT pos.save_bank_account('bca', '1234 567-890', 'Hendra Wijaya');
SELECT pos_test.ok((SELECT bank_code = 'BCA' AND account_number = '1234567890' AND status = 'PENDING' FROM pos.merchant_bank_accounts), 'rekening dinormalkan & menunggu verifikasi');
SELECT pos_test.throws($$SELECT pos.request_payout(5000)$$, 'PAYOUT_INVALID', 'rekening belum diverifikasi');
RESET ROLE;

SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.save_bank_account('BCA', '1234567890', 'Pencuri')$$, 'USER_NOT_AUTHORIZED', 'admin tanpa izin keuangan tidak bisa mengubah rekening');
SELECT pos_test.throws($$SELECT pos.request_payout(5000)$$, 'USER_NOT_AUTHORIZED', 'admin tanpa izin keuangan tidak bisa mencairkan');
SELECT pos_test.throws($$SELECT * FROM pos.platform_payouts()$$, 'USER_NOT_AUTHORIZED', 'admin tidak melihat antrean platform');
RESET ROLE;

SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.platform_bank_accounts(true)), 'operator melihat rekening yang menunggu verifikasi');
SELECT pos.platform_verify_bank_account('00000000-0000-4000-8000-000000000001', true);
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.request_payout(500)$$, 'PAYOUT_INVALID', 'di bawah minimum pencairan');
SELECT pos_test.throws($$SELECT pos.request_payout(25000)$$, 'PAYOUT_INVALID', 'melebihi saldo');
CREATE TEMP TABLE po (id uuid);
GRANT ALL ON po TO PUBLIC;
INSERT INTO po SELECT pos.request_payout(15000);
SELECT pos_test.ok((SELECT total = 4860 AND available = 4860 FROM pos.my_balance()), 'saldo langsung berkurang saat diajukan');
SELECT pos_test.throws($$SELECT pos.request_payout(5000)$$, 'PAYOUT_INVALID', 'tidak bisa mencairkan dua kali dari saldo yang sama');
SELECT pos_test.throws($$SELECT pos.save_bank_account('MANDIRI', '9999999999', 'Hendra Wijaya')$$, 'PAYOUT_INVALID', 'rekening tidak bisa diganti saat ada pencairan berjalan');
SELECT pos_test.ok((SELECT count(*) = 1 AND bool_and(status = 'REQUESTED' AND account_number = '1234567890') FROM pos.payouts), 'pencairan tercatat dengan snapshot rekening');
RESET ROLE;

-- operator memproses
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 1 AND bool_and(merchant_code = 'DEMO') FROM pos.platform_payouts('REQUESTED')), 'antrean operator');
SELECT pos_test.throws(format($$SELECT pos.platform_process_payout(%L, 'PAID', NULL, NULL)$$, (SELECT id FROM po)), 'PAYOUT_INVALID', 'PAID wajib nomor referensi');
SELECT pos_test.throws(format($$SELECT pos.platform_process_payout(%L, 'REJECTED', NULL, 'x')$$, (SELECT id FROM po)), 'PAYOUT_INVALID', 'ditolak wajib alasan');
SELECT pos.platform_process_payout((SELECT id FROM po), 'REJECTED', NULL, 'Rekening tidak sesuai nama usaha');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT total = 19860 FROM pos.my_balance()), 'pencairan ditolak: saldo kembali');
INSERT INTO po SELECT pos.request_payout(10000);
RESET ROLE;

SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos.platform_process_payout((SELECT id FROM po WHERE id IS NOT NULL OFFSET 1 LIMIT 1), 'PAID', 'TRF-20261013-001', NULL);
SELECT pos_test.throws(format($$SELECT pos.platform_process_payout(%L, 'REJECTED', NULL, 'terlambat ditolak')$$, (SELECT id FROM po OFFSET 1 LIMIT 1)),
    'PAYOUT_INVALID', 'pencairan yang sudah dibayar tidak bisa diubah');
SELECT pos_test.ok((SELECT total = 9860 AND pending_payout = 0 FROM pos.platform_balances() WHERE merchant_code = 'DEMO'), 'rekonsiliasi: kewajiban ke merchant Rp 9.860');
RESET ROLE;

-- ketentuan menahan dana
SELECT pos_test.login('platform');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 2 FROM pos.platform_payouts() WHERE status IN ('REJECTED', 'PAID')), 'riwayat pencairan lengkap');
RESET ROLE;
ROLLBACK;

-- Pembayaran tanpa penyedia (QRIS statis dikonfirmasi manual / tunai) tidak masuk buku besar
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 20000);
RESET ROLE;
SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.merchant_ledger), 'tunai tidak masuk buku besar');
RESET ROLE;
ROLLBACK;

-- Masa tahan bawaan 1 hari: dana lunas hari ini belum bisa dicairkan
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'QRIS', 20000, NULL);
UPDATE pos.payments SET provider = 'SIMULATOR', external_transaction_id = 'SIM-HOLD-1', qr_payload = 'QR';
RESET ROLE;
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
UPDATE pos.payments SET status = 'PAID' WHERE status = 'PENDING';
RESET ROLE;
SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT total = 19860 AND available = 0 AND pending = 19860 FROM pos.my_balance()), 'masa tahan: Rp 19.860 masih tertahan');
RESET ROLE;
ROLLBACK;

-- Refund atas pembayaran penyedia mengurangi saldo; biaya layanan tidak dikembalikan
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
SELECT pos_test.pay((SELECT sale FROM t), 'QRIS', 20000, NULL);
UPDATE pos.payments SET provider = 'SIMULATOR', external_transaction_id = 'SIM-REFUND-1', qr_payload = 'QR';
RESET ROLE;
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
UPDATE pos.payments SET status = 'PAID' WHERE status = 'PENDING';
RESET ROLE;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE r1 AS SELECT pos_test.new_return((SELECT sale FROM t), 'RF-LEDGER-1', 'ORIGINAL', 'REF-QRIS-1') AS id;
SELECT pos_test.return_line((SELECT id FROM r1), (SELECT sale FROM t), 'SKU-0001', 2);
INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, price, requested_by, approved_by, expires_at)
SELECT pos.current_org_id(), :JKT, (SELECT sale FROM t), 'REFUND', 10000, pos.current_app_user_id(), :SUP, now();
UPDATE pos.approvals SET used_at = now() WHERE action = 'REFUND';
UPDATE pos.returns SET status = 'COMPLETED', approval_id = (SELECT id FROM pos.approvals WHERE action = 'REFUND') WHERE id = (SELECT id FROM r1);
RESET ROLE;
SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT amount = -10000 FROM pos.merchant_ledger WHERE entry_type = 'REFUND'), 'refund: entri -Rp 10.000');
SELECT pos_test.ok((SELECT total = 9860 FROM pos.my_balance()), 'saldo: 20.000 - biaya 140 - refund 10.000 = 9.860');
RESET ROLE;
ROLLBACK;
