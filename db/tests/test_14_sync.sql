-- Phase 9: antrean sinkronisasi Openbravo, pemetaan, status dokumen (§38–§43, §63)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set T1 '''00000000-0000-4000-8000-000000000401'''

BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
GRANT SELECT ON t TO PUBLIC;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.sync_jobs), 'kasir tidak melihat antrean sync');
SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 20000);
SELECT pos_test.ok((SELECT sync_status = 'PENDING' AND openbravo_document_no IS NULL FROM pos.sales), 'lunas: sync PENDING');
SELECT pos_test.throws($$UPDATE pos.sales SET openbravo_document_no = 'PALSU-1'$$, 'SALE_IMMUTABLE_FIELD',
    'kasir tidak bisa mengisi nomor dokumen Openbravo');
SELECT pos_test.throws($$INSERT INTO pos.sync_jobs (organization_id, job_type, direction) VALUES
    (pos.current_org_id(), 'MASTER_PRODUCT', 'IN')$$, 'row-level security', 'kasir tidak bisa memicu sinkron');
RESET ROLE;

-- §63: job sync dibuat dalam transaksi yang sama dengan pelunasan
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
SELECT pos_test.ok((SELECT count(*) = 1 AND bool_and(job_type = 'SALE' AND status = 'PENDING' AND direction = 'OUT'
                           AND entity_id = (SELECT sale FROM t) AND entity_ref LIKE 'POS-JKT-01-%' AND attempts = 0)
                    FROM pos.sync_jobs), 'job SALE dibuat saat lunas (satu transaksi)');
SELECT pos_test.ok((SELECT pos.sync_retry_delay(1) = interval '30 seconds' AND pos.sync_retry_delay(2) = interval '1 minute'
                           AND pos.sync_retry_delay(3) = interval '5 minutes' AND pos.sync_retry_delay(4) = interval '15 minutes'),
    'jeda retry 30 dtk, 1 mnt, 5 mnt, 15 mnt (§43)');
-- worker sistem menandai terkirim: hanya kolom sync yang berubah
UPDATE pos.sales SET status = 'POSTED', sync_status = 'SYNCED', synced_at = now(), last_sync_at = now(),
                     openbravo_document_id = 'OB-ORDER-1', openbravo_document_no = 'SO-0001', grand_total = 1, note = 'x'
WHERE id = (SELECT sale FROM t);
SELECT pos_test.ok((SELECT status = 'POSTED' AND sync_status = 'SYNCED' AND openbravo_document_no = 'SO-0001'
                           AND grand_total = 20000 AND note IS NULL FROM pos.sales),
    'sistem menandai POSTED + nomor dokumen; nilai transaksi tidak bisa diubah lewat jalur sync');
UPDATE pos.sync_jobs SET status = 'SUCCESS', openbravo_document_no = 'SO-0001', sync_finished_at = now();
INSERT INTO pos.sync_logs (job_id, attempt, status, message) SELECT id, 1, 'SUCCESS', 'ok' FROM pos.sync_jobs;
SELECT pos_test.throws($$UPDATE pos.sync_logs SET message = 'ubah'$$, 'APPEND_ONLY|permission denied', 'log sync append-only');
RESET ROLE;

-- admin: sinkron master & retry
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.sync_jobs), 'admin (sync.view) melihat antrean');
INSERT INTO pos.sync_jobs (organization_id, job_type, direction, status, attempts)
VALUES (pos.current_org_id(), 'MASTER_PRODUCT', 'IN', 'SUCCESS', 9);
SELECT pos_test.ok((SELECT status = 'PENDING' AND attempts = 0 AND requested_by IS NOT NULL
                    FROM pos.sync_jobs WHERE job_type = 'MASTER_PRODUCT'), 'permintaan sinkron master: status dari server');
SELECT pos_test.throws($$INSERT INTO pos.sync_jobs (organization_id, job_type, direction) VALUES
    (pos.current_org_id(), 'MASTER_PRODUCT', 'IN')$$, 'sync_jobs_master_active_uk', 'satu sinkron master aktif per jenis');
SELECT pos_test.throws($$INSERT INTO pos.sync_jobs (organization_id, job_type, direction, entity_id) VALUES
    (pos.current_org_id(), 'SALE', 'OUT', (SELECT sale FROM t))$$, 'SYNC_JOB_INVALID', 'dokumen tidak bisa diantrekan manual');
SELECT pos_test.throws($$UPDATE pos.sync_jobs SET status = 'RETRYING' WHERE job_type = 'SALE'$$, 'SYNC_JOB_NOT_RETRYABLE',
    'job sukses tidak bisa diulang');
RESET ROLE;
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
UPDATE pos.sync_jobs SET status = 'MANUAL_REVIEW', attempts = 5, last_error = 'Openbravo menolak' WHERE job_type = 'MASTER_PRODUCT';
RESET ROLE;
SELECT pos_test.login('admin');
SET LOCAL ROLE pos_app_user;
UPDATE pos.sync_jobs SET status = 'RETRYING' WHERE job_type = 'MASTER_PRODUCT';
SELECT pos_test.ok((SELECT status = 'RETRYING' AND attempts = 0 AND next_attempt_at <= now() AND last_error = 'Openbravo menolak'
                    FROM pos.sync_jobs WHERE job_type = 'MASTER_PRODUCT'), 'retry manual: jatah percobaan baru');

-- §39 pemetaan ID Openbravo
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.openbravo_mappings SET openbravo_id = 'OB-ORG-JKT'
    WHERE entity_type = 'OUTLET' AND pos_id = '00000000-0000-4000-8000-000000000101'$$) = 1, 'admin mengubah pemetaan');
SELECT pos_test.ok((SELECT version = 1 AND updated_by IS NOT NULL FROM pos.openbravo_mappings WHERE openbravo_id = 'OB-ORG-JKT'),
    'perubahan pemetaan tercatat versi & pengubah');
SELECT pos_test.throws($$UPDATE pos.openbravo_mappings SET pos_id = '00000000-0000-4000-8000-000000000102'
    WHERE openbravo_id = 'OB-ORG-JKT'$$, 'MAPPING_IMMUTABLE_FIELD|openbravo_mappings_uk', 'entitas pemetaan tidak bisa dipindah');
SELECT pos_test.throws($$INSERT INTO pos.openbravo_mappings (organization_id, entity_type, pos_id, openbravo_id)
    VALUES (pos.current_org_id(), 'WAREHOUSE', '00000000-0000-4000-8000-000000000101', 'X')$$, 'MAPPING_TARGET_INVALID',
    'pemetaan ke entitas yang salah ditolak');
SELECT pos_test.throws($$INSERT INTO pos.openbravo_mappings (organization_id, entity_type, pos_id, openbravo_id)
    VALUES (pos.current_org_id(), 'OUTLET', '00000000-0000-4000-8000-000000000102', 'ada spasi')$$, 'openbravo_mappings_id_ck',
    'format ID Openbravo divalidasi');
RESET ROLE;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.openbravo_mappings), 'kasir tidak melihat pemetaan');
SELECT pos_test.throws($$INSERT INTO pos.openbravo_mappings (organization_id, entity_type, pos_id, openbravo_id)
    VALUES (pos.current_org_id(), 'TERMINAL', '00000000-0000-4000-8000-000000000401', 'OB-T1')$$, 'row-level security',
    'kasir tidak bisa mengubah pemetaan');
ROLLBACK;

-- retur selesai & cash-up masuk antrean; sync retur hanya oleh sistem
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
GRANT SELECT ON t TO PUBLIC;
SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 20000);
CREATE TEMP TABLE r AS SELECT pos_test.new_return((SELECT sale FROM t), 'SYNC-R1') AS id;
GRANT SELECT ON r TO PUBLIC;
SELECT pos_test.return_line((SELECT id FROM r), (SELECT sale FROM t), 'SKU-0001', 1);
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
UPDATE pos.returns SET status = 'COMPLETED' WHERE id = (SELECT id FROM r);
SELECT pos_test.throws($$UPDATE pos.returns SET openbravo_document_no = 'X' WHERE id = (SELECT id FROM r)$$,
    'RETURN_CLOSED|RETURN_IMMUTABLE_FIELD', 'pengguna tidak bisa mengisi dokumen Openbravo retur');
RESET ROLE;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.close_session((SELECT id FROM pos.cashier_sessions WHERE status = 'OPEN'), '{{100000,1},{10000,1},{5000,1}}');
RESET ROLE;
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
SELECT pos_test.ok((SELECT string_agg(job_type, ',' ORDER BY job_type) FROM pos.sync_jobs) = 'CASHUP,RETURN,SALE',
    'job SALE, RETURN, dan CASHUP dibuat otomatis');
UPDATE pos.returns SET sync_status = 'SYNCED', openbravo_document_no = 'RM-0001', total_amount = 0 WHERE id = (SELECT id FROM r);
SELECT pos_test.ok((SELECT sync_status = 'SYNCED' AND openbravo_document_no = 'RM-0001' AND total_amount = 5000
                    FROM pos.returns), 'sistem menandai retur terkirim; nilai retur tetap');
ROLLBACK;

-- payload dokumen & master data masuk (dijalankan worker sebagai pos_system)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE t AS SELECT pos_test.checked_out_sale(:T1, :JKT) AS sale;
GRANT SELECT ON t TO PUBLIC;
SELECT pos_test.pay((SELECT sale FROM t), 'CASH', 1, 50000);
SELECT pos_test.throws($$SELECT pos.sync_payload((SELECT id FROM pos.sync_jobs LIMIT 1))$$, 'permission denied',
    'payload hanya untuk sistem');
RESET ROLE;
SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
CREATE TEMP TABLE p AS SELECT pos.sync_payload(id) AS j FROM pos.sync_jobs WHERE job_type = 'SALE';
SELECT pos_test.ok((SELECT j ->> 'outletId' = 'DEMO-ORG-JKT01' AND j ->> 'warehouseId' = 'DEMO-WH-JKT01'
                           AND j ->> 'terminalId' = 'DEMO-POS-JKT-01' AND (j ->> 'grandTotal')::numeric = 20000
                           AND j #>> '{lines,0,productId}' = 'DEMO-SKU-0001' AND j #>> '{lines,0,taxId}' = 'DEMO-TAX-PPN11'
                           AND j #>> '{payments,0,paymentMethodId}' = 'DEMO-PM-CASH'
                           AND (j #>> '{payments,0,amountReceived}')::numeric = 50000 FROM p),
    'payload penjualan memakai ID Openbravo dari pemetaan (bukan hard-code)');
SELECT pos_test.throws($$SELECT pos.openbravo_id('00000000-0000-4000-8000-000000000001', 'TERMINAL',
    gen_random_uuid(), 'POS-JKT-99')$$, 'MAPPING_MISSING: TERMINAL POS-JKT-99', 'pemetaan kosong = error jelas');
SELECT pos_test.ok((SELECT processed = 2 AND success = 1 AND failed = 1 AND errors LIKE 'SKU-9999%' FROM pos.sync_upsert_products(
    '00000000-0000-4000-8000-000000000001',
    '[{"id":"DEMO-SKU-0001","sku":"SKU-0001","name":"Air Mineral 600 ml (baru)","uom":"PCS","taxId":"DEMO-TAX-PPN11","barcodes":["8990000000017"]},
      {"id":"DEMO-SKU-0001","sku":"SKU-9999","name":"Duplikat ID"}]')),
    'master produk: baris gagal tidak membatalkan yang lain');
SELECT pos_test.ok((SELECT name = 'Air Mineral 600 ml (baru)' AND synced_at IS NOT NULL FROM pos.products WHERE sku = 'SKU-0001'),
    'produk diperbarui dari Openbravo');
SELECT pos_test.ok((SELECT success = 1 FROM pos.sync_upsert_prices('00000000-0000-4000-8000-000000000001',
    '[{"productId":"DEMO-SKU-0001","price":5500}]')), 'harga dari Openbravo diterima');
SELECT pos_test.ok((SELECT count(*) FROM pos.product_price_cache c JOIN pos.products p ON p.id = c.product_id
                    WHERE p.sku = 'SKU-0001' AND c.outlet_id IS NULL) = 2
    AND (SELECT c.price FROM pos.product_price_cache c JOIN pos.products p ON p.id = c.product_id
         WHERE p.sku = 'SKU-0001' AND c.outlet_id IS NULL ORDER BY c.version DESC LIMIT 1) = 5500,
    'harga berubah = versi harga baru (riwayat tetap)');
SELECT pos_test.ok((SELECT success = 0 FROM pos.sync_upsert_prices('00000000-0000-4000-8000-000000000001',
    '[{"productId":"TIDAK-ADA","price":1}]')), 'harga produk yang belum tersinkron ditolak');
SELECT pos_test.ok((SELECT success = 1 FROM pos.sync_upsert_stock('00000000-0000-4000-8000-000000000001',
    '[{"productId":"DEMO-SKU-0001","warehouseId":"DEMO-WH-JKT01","quantity":42,"available":40}]')), 'stok diterima');
SELECT pos_test.ok((SELECT c.available_quantity = 40 AND c.source = 'OPENBRAVO' FROM pos.product_stock_cache c
         JOIN pos.products p ON p.id = c.product_id JOIN pos.warehouses w ON w.id = c.warehouse_id
         WHERE p.sku = 'SKU-0001' AND w.code = 'WH-JKT01'), 'stok = snapshot Openbravo');
SELECT pos.sync_upsert_customers('00000000-0000-4000-8000-000000000001',
    '[{"id":"BP-1","code":"C001","name":"PT Pelanggan Setia"}]');
SELECT pos.sync_upsert_customers('00000000-0000-4000-8000-000000000001',
    '[{"id":"BP-1","code":"C001","name":"PT Pelanggan Setia Abadi"}]');
SELECT pos_test.ok((SELECT count(*) = 1 AND min(name) = 'PT Pelanggan Setia Abadi' FROM pos.customers),
    'customer tidak duplikat pada sinkron berulang');
ROLLBACK;
