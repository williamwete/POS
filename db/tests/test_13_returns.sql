-- Phase 8: retur & refund (§28, §29, §86)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set T1 '''00000000-0000-4000-8000-000000000401'''
\set SUP '''00000000-0000-4000-8000-000000000704'''
\set KASIR '''00000000-0000-4000-8000-000000000705'''

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,10}}') AS id;   -- modal 1.000.000
-- A: 10 × air mineral (5.000) tunai = 50.000 (§86: penjualan 10 item)
CREATE TEMP TABLE a AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM a), 'SKU-0001', 10);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM a);
SELECT pos_test.pay((SELECT id FROM a), 'CASH', 1, 50000);
-- B: 2 × tisu = 100.000: debit 60.000 + tunai 40.000
CREATE TEMP TABLE b AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM b), 'SKU-0012', 2);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM b);
SELECT pos_test.pay((SELECT id FROM b), 'DEBIT_CARD', 60000, NULL, 'APPR-1');
SELECT pos_test.pay((SELECT id FROM b), 'CASH', 1, 40000);
GRANT SELECT ON s, a, b TO PUBLIC;

-- pencarian struk
CREATE TEMP TABLE lk AS SELECT pos.return_lookup((SELECT receipt_no FROM pos.sales WHERE id = (SELECT id FROM a))) AS j;
SELECT pos_test.ok((SELECT (j #>> '{items,0,remainingQuantity}')::numeric = 10 AND (j ->> 'returnable')::boolean FROM lk),
    'lookup: sisa 10 item bisa diretur');

-- §86: retur 2 dari 10
CREATE TEMP TABLE r1 AS SELECT pos_test.new_return((SELECT id FROM a), 'R1') AS id;
GRANT SELECT ON r1 TO PUBLIC;
SELECT pos_test.return_line((SELECT id FROM r1), (SELECT id FROM a), 'SKU-0001', 2);
SELECT pos_test.ok((SELECT status = 'PENDING_APPROVAL' AND total_amount = 10000 AND item_count = 2
                           AND return_no LIKE 'RET-POS-JKT-01-%-000001' AND created_by = :KASIR
                    FROM pos.returns WHERE id = (SELECT id FROM r1)), 'retur dibuat: RET-…, 2 item, Rp 10.000, menunggu approval');
SELECT pos_test.throws($$UPDATE pos.returns SET total_amount = 1$$, 'RETURN_IMMUTABLE_FIELD', 'total retur dihitung database');
SELECT pos_test.throws($$
    WITH r AS (SELECT pos_test.new_return((SELECT id FROM a), 'R2') AS id)
    SELECT pos_test.return_line((SELECT id FROM r), (SELECT id FROM a), 'SKU-0001', 9)$$,
    'RETURN_QUANTITY_EXCEEDED', 'tidak bisa melebihi sisa (retur menunggu approval ikut dihitung)');
SELECT pos_test.throws($$UPDATE pos.returns SET status = 'COMPLETED' WHERE id = (SELECT id FROM r1)$$,
    'REFUND_APPROVAL_REQUIRED', 'refund tanpa approval ditolak (§29 restricted)');
SELECT pos_test.throws($$INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, price, requested_by, approved_by, expires_at)
    SELECT pos.current_org_id(), '00000000-0000-4000-8000-000000000101', (SELECT id FROM a), 'REFUND', 10000,
           pos.current_app_user_id(), '00000000-0000-4000-8000-000000000706', now()$$,
    'APPROVER_NOT_AUTHORIZED', 'approver tanpa sale.refund ditolak');

-- approval supervisor di terminal
INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, price, requested_by, approved_by, expires_at)
SELECT pos.current_org_id(), :JKT, (SELECT id FROM a), 'REFUND', 10000, pos.current_app_user_id(), :SUP, now();
UPDATE pos.approvals SET used_at = now() WHERE action = 'REFUND';
UPDATE pos.returns SET status = 'COMPLETED', approval_id = (SELECT id FROM pos.approvals WHERE action = 'REFUND')
WHERE id = (SELECT id FROM r1);
SELECT pos_test.ok((SELECT status = 'COMPLETED' AND approved_by = :SUP AND sync_status = 'PENDING'
                    FROM pos.returns WHERE id = (SELECT id FROM r1)), 'retur selesai, disetujui supervisor, siap sync');
SELECT pos_test.ok((SELECT count(*) = 1 AND sum(refund_amount) = 10000 AND bool_and(refund_method = 'CASH')
                           AND bool_and(original_payment_id = (SELECT id FROM pos.payments WHERE sale_id = (SELECT id FROM a)))
                           AND bool_and(approved_by = :SUP)
                    FROM pos.refunds WHERE return_id = (SELECT id FROM r1)), 'refund tunai 10.000 merujuk pembayaran asli');
SELECT pos_test.ok((SELECT amount FROM pos.cash_movements WHERE movement_type = 'CASH_REFUND') = -10000,
    'uang refund keluar dari laci (CASH_REFUND)');
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM s) = 1080000, 'expected cash 1.000.000 + 50.000 + 40.000 − 10.000');
-- §86: transaksi asli utuh
SELECT pos_test.ok((SELECT status = 'PAID' AND grand_total = 50000 FROM pos.sales WHERE id = (SELECT id FROM a))
                   AND (SELECT quantity = 10 AND net_amount = 50000 FROM pos.sale_items WHERE sale_id = (SELECT id FROM a))
                   AND (SELECT amount = 50000 AND status = 'PAID' FROM pos.payments WHERE sale_id = (SELECT id FROM a)),
    'transaksi, baris, dan pembayaran asli tidak berubah');
SELECT pos_test.throws($$UPDATE pos.returns SET status = 'REJECTED', reject_reason = 'Salah input' WHERE id = (SELECT id FROM r1)$$,
    'RETURN_CLOSED', 'retur selesai tidak bisa diubah');
SELECT pos_test.throws($$SELECT pos_test.return_line((SELECT id FROM r1), (SELECT id FROM a), 'SKU-0001', 1)$$,
    'RETURN_IMMUTABLE_FIELD|return_items_line_uk', 'baris retur selesai tidak bisa ditambah');
SELECT pos_test.throws($$DELETE FROM pos.returns$$, 'permission denied', 'retur tidak bisa dihapus');
SELECT pos_test.throws($$UPDATE pos.refunds SET refund_amount = 1$$, 'permission denied', 'refund tidak bisa diubah');
SELECT pos_test.throws($$INSERT INTO pos.refunds SELECT * FROM pos.refunds$$, 'permission denied', 'refund tidak bisa dibuat manual');

-- sisa 8 lewat approval akun supervisor (POST /returns/{id}/approve)
CREATE TEMP TABLE r3 AS SELECT pos_test.new_return((SELECT id FROM a), 'R3') AS id;
GRANT SELECT ON r3 TO PUBLIC;
SELECT pos_test.return_line((SELECT id FROM r3), (SELECT id FROM a), 'SKU-0001', 8);
SELECT pos_test.ok((SELECT total_amount FROM pos.returns WHERE id = (SELECT id FROM r3)) = 40000,
    'sisa terakhir = sisa nilai baris (40.000)');
-- retur menunggu approval memblokir tutup kasir
SELECT pos_test.throws($$SELECT pos_test.close_session((SELECT id FROM s), '{{100000,10}}')$$, 'RETURN_PENDING',
    'tutup kasir ditolak selama ada retur menunggu approval');
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.returns SET status = 'COMPLETED' WHERE id = (SELECT id FROM r3)$$) = 1,
    'supervisor menyetujui dari akunnya');
SELECT pos_test.ok((SELECT approved_by = :SUP FROM pos.returns WHERE id = (SELECT id FROM r3)), 'approver tercatat');
RESET ROLE;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM s) = 1040000, 'refund kedua keluar dari laci kasir');
SELECT pos_test.throws($$
    WITH r AS (SELECT pos_test.new_return((SELECT id FROM a), 'R4') AS id)
    SELECT pos_test.return_line((SELECT id FROM r), (SELECT id FROM a), 'SKU-0001', 1)$$,
    'RETURN_QUANTITY_EXCEEDED', 'semua sudah diretur: tidak bisa retur lagi');

-- B: refund ke metode asal — debit dikembalikan lewat EDC (referensi wajib), sisanya tunai
CREATE TEMP TABLE rb AS SELECT pos_test.new_return((SELECT id FROM b), 'RB', 'ORIGINAL') AS id;
GRANT SELECT ON rb TO PUBLIC;
SELECT pos_test.return_line((SELECT id FROM rb), (SELECT id FROM b), 'SKU-0012', 2);
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$UPDATE pos.returns SET status = 'COMPLETED' WHERE id = (SELECT id FROM rb)$$,
    'PAYMENT_REFERENCE_REQUIRED', 'refund non-tunai wajib nomor referensi');
UPDATE pos.returns SET status = 'COMPLETED', refund_reference = 'VOID-EDC-991' WHERE id = (SELECT id FROM rb);
SELECT pos_test.ok((SELECT string_agg(refund_method || ':' || refund_amount::bigint || ':' || coalesce(reference_number, '-'), ','
                                      ORDER BY refund_method DESC)
                    FROM pos.refunds WHERE return_id = (SELECT id FROM rb)) = 'DEBIT_CARD:60000:VOID-EDC-991,CASH:40000:-',
    'refund dialokasikan ke pembayaran asli: debit 60.000 + tunai 40.000');
RESET ROLE;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT pos.session_expected_cash(id) FROM s) = 1000000, 'hanya bagian tunai keluar dari laci');

-- tolak retur: sisa kembali tersedia
CREATE TEMP TABLE c AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM c), 'SKU-0001', 1);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM c);
SELECT pos_test.pay((SELECT id FROM c), 'CASH', 1, 5000);
CREATE TEMP TABLE rc AS SELECT pos_test.new_return((SELECT id FROM c), 'RC') AS id;
SELECT pos_test.return_line((SELECT id FROM rc), (SELECT id FROM c), 'SKU-0001', 1);
SELECT pos_test.throws($$UPDATE pos.returns SET status = 'REJECTED', reject_reason = 'x' WHERE id = (SELECT id FROM rc)$$,
    'returns_rejected_ck', 'penolakan wajib alasan');
UPDATE pos.returns SET status = 'REJECTED', reject_reason = 'Pelanggan batal retur' WHERE id = (SELECT id FROM rc);
SELECT pos_test.ok((SELECT (j #>> '{items,0,remainingQuantity}')::numeric = 1
                    FROM (SELECT pos.return_lookup((SELECT receipt_no FROM pos.sales WHERE id = (SELECT id FROM c))) AS j) x),
    'retur ditolak tidak mengurangi sisa');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.refunds WHERE return_id = (SELECT id FROM rc)), 'retur ditolak tanpa refund');

-- Z report: refund mengurangi penjualan bersih
SELECT pos_test.close_session((SELECT id FROM s), '{{100000,10},{5000,1}}');
SELECT pos_test.ok((SELECT (report #>> '{sales,refund}')::numeric = 150000 AND (report #>> '{sales,returnCount}')::int = 3
                           AND (report #>> '{sales,netSales}')::numeric = 5000
                           AND (report #>> '{cash,cashRefund}')::numeric = 90000 AND difference = 0
                    FROM pos.cashups), 'Z report: refund 150.000, bersih 5.000, refund tunai 90.000');
RESET ROLE;

-- kasir outlet lain tidak bisa mencari struk JKT
SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$SELECT pos.return_lookup((SELECT receipt_no FROM pos.sales WHERE id = (SELECT id FROM a)))$$,
    'SALE_NOT_FOUND', 'struk outlet lain tidak bisa diretur');
ROLLBACK;

-- tanpa approval wajib (setting false): kasir tanpa sale.refund tetap tidak bisa menyelesaikan sendiri
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE a AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS id;
SELECT pos_test.pay((SELECT id FROM a), 'CASH', 1, 20000);
CREATE TEMP TABLE r AS SELECT pos_test.new_return((SELECT id FROM a), 'X1') AS id;
SELECT pos_test.return_line((SELECT id FROM r), (SELECT id FROM a), 'SKU-0001', 1);
SELECT pos_test.throws($$UPDATE pos.returns SET status = 'COMPLETED'$$, 'REFUND_APPROVAL_REQUIRED',
    'kasir tidak bisa menyetujui refund sendiri');
UPDATE pos.cashier_sessions SET status = 'ON_BREAK', lock_reason = 'MANUAL';
SELECT pos_test.throws($$SELECT pos_test.new_return((SELECT id FROM a), 'X2')$$, 'CASHIER_SESSION_LOCKED',
    'retur ditolak saat terminal terkunci');
ROLLBACK;
