-- Phase 7: X report, cash-up / Z report (§52, §53, §84, §85)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set T1 '''00000000-0000-4000-8000-000000000401'''

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
CREATE TEMP TABLE s AS SELECT pos_test.open_session(:T1, '{{100000,10}}') AS id;   -- modal 1.000.000
GRANT SELECT ON s TO PUBLIC;
-- A: 3 × tisu (50.000) tunai
CREATE TEMP TABLE a AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM a), 'SKU-0012', 3);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM a);
SELECT pos_test.pay((SELECT id FROM a), 'CASH', 1, 200000);
-- B: 2 × tisu debit
CREATE TEMP TABLE b AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM b), 'SKU-0012', 2);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE id = (SELECT id FROM b);
SELECT pos_test.pay((SELECT id FROM b), 'DEBIT_CARD', 100000, NULL, 'APPR-777');
-- C: dibatalkan pelanggan (void sebelum checkout)
CREATE TEMP TABLE c AS SELECT pos_test.new_sale() AS id;
SELECT pos_test.add_item((SELECT id FROM c), 'SKU-0001', 1);
UPDATE pos.sales SET status = 'VOID', void_reason = 'Pelanggan batal beli' WHERE id = (SELECT id FROM c);
SELECT pos_test.cash_move((SELECT id FROM s), 'CASH_OUT', -50000, 'Bayar kurir');

-- §53/§84: X report tidak untuk kasir (berisi expected cash), tidak mengubah session
SELECT pos_test.throws($$SELECT pos.x_report((SELECT id FROM s))$$, 'REPORT_NOT_AUTHORIZED', 'kasir tidak bisa X report');
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE x AS SELECT pos.x_report((SELECT id FROM s)) AS r;
SELECT pos_test.ok((SELECT r ->> 'reportType' = 'X' FROM x), 'X report dibuat');
SELECT pos_test.ok((SELECT (r #>> '{cash,expectedCash}')::numeric = 1100000 FROM x),
    'X: expected 1.000.000 + 150.000 − 50.000');
SELECT pos_test.ok((SELECT (r #>> '{sales,transactionCount}')::int = 2 AND (r #>> '{sales,voidCount}')::int = 1
                           AND (r #>> '{sales,netSales}')::numeric = 250000 FROM x), 'X: 2 transaksi, 1 void, net 250.000');
SELECT pos_test.ok((SELECT r #> '{cash,actualCash}' = 'null'::jsonb FROM x), 'X: belum ada uang dihitung');
SELECT pos_test.ok((SELECT status = 'OPEN' FROM pos.cashier_sessions), 'X: session tetap OPEN');
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.cashups), 'X: tidak membuat cash-up');
SELECT pos_test.throws($$SELECT pos.x_report('00000000-0000-4000-8000-000000009999')$$, 'CASHIER_SESSION_NOT_FOUND',
    'X report session tidak dikenal');
RESET ROLE;

-- §85: tutup kasir → cash-up dibuat dalam transaksi yang sama
SELECT pos_test.reauth('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.close_session((SELECT id FROM s), '{{100000,11}}');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.cashups), 'Z: cash-up dibuat');
SELECT pos_test.ok((SELECT z_number = 1 AND transaction_count = 2 AND net_sales = 250000 AND expected_cash = 1100000
                           AND actual_cash = 1100000 AND difference = 0 FROM pos.cashups), 'Z: angka ringkasan');
SELECT pos_test.ok((SELECT (report #>> '{cash,openingCash}')::numeric = 1000000
                           AND (report #>> '{cash,cashSales}')::numeric = 150000
                           AND (report #>> '{cash,cashOut}')::numeric = 50000
                           AND (report #>> '{cash,actualCash}')::numeric = 1100000 FROM pos.cashups), 'Z: bagian kas');
SELECT pos_test.ok((SELECT (SELECT (p ->> 'amount')::numeric FROM jsonb_array_elements(report -> 'payments') p
                            WHERE p ->> 'methodCode' = 'CASH') = 150000
                           AND (SELECT (p ->> 'amount')::numeric FROM jsonb_array_elements(report -> 'payments') p
                                WHERE p ->> 'methodCode' = 'DEBIT_CARD') = 100000
                    FROM pos.cashups), 'Z: pembayaran per metode');
SELECT pos_test.ok((SELECT report #>> '{header,cashierName}' = 'Dewi Lestari' AND report #>> '{header,terminalCode}' = 'POS-JKT-01'
                           AND report #>> '{approval,closedByName}' = 'cashier.jkt' AND report ->> 'reportType' = 'Z'
                    FROM pos.cashups), 'Z: header & approval');
SELECT pos_test.throws($$UPDATE pos.cashups SET net_sales = 0$$, 'permission denied', 'cash-up tidak bisa diubah');
SELECT pos_test.throws($$DELETE FROM pos.cashups$$, 'permission denied', 'cash-up tidak bisa dihapus');
SELECT pos_test.throws($$INSERT INTO pos.cashups SELECT * FROM pos.cashups$$, 'permission denied',
    'cash-up tidak bisa dibuat manual');

-- shift berikutnya di terminal yang sama → Z nomor 2
CREATE TEMP TABLE s2 AS SELECT pos_test.open_session(:T1, '{{100000,1}}') AS id;
SELECT pos_test.close_session((SELECT id FROM s2), '{{100000,1}}');
SELECT pos_test.ok((SELECT z_number FROM pos.cashups WHERE cashier_session_id = (SELECT id FROM s2)) = 2,
    'Z berurutan per terminal');
RESET ROLE;

SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 2 FROM pos.cashups), 'supervisor melihat cash-up outlet');
SELECT pos_test.throws($$SELECT pos.x_report((SELECT id FROM s))$$, 'CASHIER_SESSION_CLOSED',
    'X report untuk session tertutup ditolak (pakai Z)');
RESET ROLE;
SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.cashups), 'kasir outlet lain tidak melihat cash-up');
ROLLBACK;
