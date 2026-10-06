-- Phase 4: penjualan (§15, §17, §18, §20, §26, §27, §31, §33, §77)
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set BDG '''00000000-0000-4000-8000-000000000102'''
\set T1 '''00000000-0000-4000-8000-000000000401'''
\set TB '''00000000-0000-4000-8000-000000000403'''
\set SUP '''00000000-0000-4000-8000-000000000704'''
\set MGR '''00000000-0000-4000-8000-000000000703'''

-- Harga, pajak & total dihitung database; nilai client diabaikan
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.new_sale() IS NULL, 'tanpa cashier session tidak ada penjualan');
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
CREATE TEMP TABLE t (sale uuid, item uuid) ON COMMIT DROP;
INSERT INTO t (sale) SELECT pos_test.new_sale();
SELECT pos_test.ok((SELECT status = 'DRAFT' AND prices_include_tax AND business_date = pos.business_date(now(), :JKT)
                    FROM pos.sales), 'sale DRAFT, business date & mode pajak dari server');
UPDATE t SET item = pos_test.add_item(sale, 'SKU-0001', 2);
SELECT pos_test.ok((SELECT list_price = 5000 AND unit_price = 5000 AND gross_amount = 10000 AND tax_amount = 991
                           AND sku = 'SKU-0001' AND product_name = 'Air Mineral 600 ml'
                    FROM pos.sale_items), 'harga dari price list, PPN 11% termasuk harga (991), snapshot produk');
SELECT pos_test.ok((SELECT subtotal = 10000 AND grand_total = 10000 AND tax_total = 991 AND line_count = 1
                    FROM pos.sales), 'total header dihitung dari baris');
UPDATE pos.sales SET grand_total = 1, subtotal = 1;
SELECT pos_test.ok((SELECT grand_total FROM pos.sales) = 10000, 'total header tidak bisa diubah langsung');
SELECT pos_test.throws($$SELECT pos_test.add_item((SELECT sale FROM t), 'SKU-0002', 1.5)$$,
    'QUANTITY_INVALID', 'produk PCS tidak boleh jumlah desimal');
SELECT pos_test.ok(pos_test.add_item((SELECT sale FROM t), 'SKU-0008', 1.25) IS NOT NULL, 'produk KG boleh desimal');
SELECT pos_test.ok((SELECT gross_amount = 35000 AND tax_amount = 0 FROM pos.sale_items WHERE sku = 'SKU-0008'),
    'telur 1,25 kg × 28.000 = 35.000 bebas PPN');
-- ubah harga butuh approval (kasir tidak punya sale.price_override)
SELECT pos_test.throws($$UPDATE pos.sale_items SET unit_price = 4000, price_override_reason = 'Kemasan penyok'
    WHERE sku = 'SKU-0001'$$, 'APPROVAL_REQUIRED', 'ubah harga tanpa approval ditolak');
SELECT pos_test.throws($$INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, sale_item_id, action, price,
    requested_by, approved_by, expires_at) SELECT pos.current_org_id(), '00000000-0000-4000-8000-000000000101', sale, item, 'PRICE_OVERRIDE', 4000,
    pos.current_app_user_id(), pos.current_app_user_id(), now() FROM t$$, 'approvals_distinct_ck|APPROVER_INVALID',
    'tidak bisa menyetujui diri sendiri');
INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, sale_item_id, action, price, requested_by, approved_by, expires_at)
SELECT pos.current_org_id(), :JKT, sale, item, 'PRICE_OVERRIDE', 4000, pos.current_app_user_id(), :SUP, now() FROM t;
UPDATE pos.approvals SET used_at = now();
UPDATE pos.sale_items SET unit_price = 4000, price_override_reason = 'Kemasan penyok',
       price_override_approval_id = (SELECT id FROM pos.approvals), price_override_approved_by = :SUP
WHERE sku = 'SKU-0001';
SELECT pos_test.ok((SELECT unit_price = 4000 AND gross_amount = 8000 AND price_override_by IS NOT NULL
                    FROM pos.sale_items WHERE sku = 'SKU-0001'), 'ubah harga dengan approval supervisor');
SELECT pos_test.throws($$UPDATE pos.approvals SET used_at = now()$$, 'APPROVAL_USED', 'approval sekali pakai');
-- checkout -> nomor struk
UPDATE pos.sales SET status = 'CHECKOUT';
SELECT pos_test.ok((SELECT receipt_no ~ ('^POS-JKT-01-' || to_char(business_date, 'YYYYMMDD') || '-000001$')
                    FROM pos.sales), 'nomor struk terminal-tanggal-urut');
SELECT pos_test.ok((SELECT count(*) FROM pos.receipts) = 1, 'baris struk dibuat');
SELECT pos_test.ok(pos.available_to_sell((SELECT id FROM pos.products WHERE sku = 'SKU-0001'), :JKT) = 498,
    'stok tersedia = snapshot − penjualan lokal');
SELECT pos_test.throws($$SELECT pos_test.add_item((SELECT sale FROM t), 'SKU-0002', 1)$$, 'SALE_NOT_EDITABLE',
    'keranjang terkunci setelah checkout');
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'PAID'$$, 'SALE_NOT_FULLY_PAID', 'PAID tanpa pembayaran ditolak (§23)');
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'VOID', void_reason = 'Pelanggan batal'$$,
    'APPROVAL_REQUIRED', 'void setelah checkout butuh approval');
SELECT pos_test.throws($$DELETE FROM pos.sales$$, 'permission denied', 'penjualan tidak bisa dihapus');
-- transaksi kedua: urutan struk bertambah
INSERT INTO t (sale) SELECT pos_test.new_sale();
SELECT pos_test.add_item((SELECT sale FROM t WHERE item IS NULL), 'SKU-0002', 1);
UPDATE pos.sales SET status = 'CHECKOUT' WHERE status = 'DRAFT';
SELECT pos_test.ok((SELECT count(*) FROM pos.sales WHERE receipt_no LIKE '%-000002') = 1, 'nomor struk berurutan');
ROLLBACK;

-- Diskon & matriks approval (§20): kasir 5%, supervisor 15%, manager 30%
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
CREATE TEMP TABLE t (sale uuid, item uuid) ON COMMIT DROP;
INSERT INTO t (sale) SELECT pos_test.new_sale();
UPDATE t SET item = pos_test.add_item(sale, 'SKU-0007', 1);   -- beras 78.000 bebas PPN
INSERT INTO pos.sale_discounts (sale_id, sale_item_id, discount_type, discount_value, reason, created_by)
SELECT sale, item, 'PERCENTAGE', 5, 'Promo member', pos.current_app_user_id() FROM t;
UPDATE pos.sale_discounts SET amount = 3900;
UPDATE pos.sale_items SET item_discount_amount = 3900;
SELECT pos_test.ok((SELECT net_amount = 74100 FROM pos.sale_items) AND (SELECT grand_total = 74100 AND discount_total = 3900 FROM pos.sales),
    'diskon 5% baris');
SAVEPOINT a;
UPDATE pos.sale_discounts SET amount = 3000;
UPDATE pos.sale_items SET item_discount_amount = 3000;
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'CHECKOUT'$$, 'DISCOUNT_ALLOCATION_INVALID',
    'nilai diskon yang tidak sesuai definisi ditolak saat checkout');
ROLLBACK TO a;
UPDATE pos.sale_discounts SET status = 'REMOVED';
INSERT INTO pos.sale_discounts (sale_id, sale_item_id, discount_type, discount_value, reason, created_by)
SELECT sale, item, 'PERCENTAGE', 10, 'Barang display', pos.current_app_user_id() FROM t;
UPDATE pos.sale_discounts SET amount = 7800 WHERE status = 'ACTIVE';
UPDATE pos.sale_items SET item_discount_amount = 7800;
SAVEPOINT b;
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'CHECKOUT'$$, 'APPROVAL_REQUIRED', 'diskon 10% butuh approval');
ROLLBACK TO b;
-- diskon transaksi 20% butuh manager
SELECT pos_test.throws($$INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, max_percent, requested_by,
    approved_by, expires_at) SELECT pos.current_org_id(), '00000000-0000-4000-8000-000000000101', sale, 'DISCOUNT', 20, pos.current_app_user_id(),
    '00000000-0000-4000-8000-000000000704', now() FROM t$$, 'APPROVER_NOT_AUTHORIZED', 'supervisor tidak boleh menyetujui 20%');
SELECT pos_test.throws($$INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, max_percent, requested_by,
    approved_by, expires_at) SELECT pos.current_org_id(), '00000000-0000-4000-8000-000000000101', sale, 'DISCOUNT', 40, pos.current_app_user_id(),
    '00000000-0000-4000-8000-000000000703', now() FROM t$$, 'DISCOUNT_LIMIT_EXCEEDED', 'di atas batas manager ditolak');
INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, max_percent, requested_by, approved_by, expires_at)
SELECT pos.current_org_id(), :JKT, sale, 'DISCOUNT', 10, pos.current_app_user_id(), :SUP, now() FROM t;
SELECT pos_test.ok((SELECT approver_rank = 50 AND expires_at > now() FROM pos.approvals), 'approval supervisor tercatat');
UPDATE pos.approvals SET used_at = now();
UPDATE pos.sale_discounts SET status = 'REMOVED' WHERE status = 'ACTIVE';
INSERT INTO pos.sale_discounts (sale_id, sale_item_id, discount_type, discount_value, reason, created_by, approval_id)
SELECT sale, item, 'PERCENTAGE', 10, 'Barang display', pos.current_app_user_id(), (SELECT id FROM pos.approvals) FROM t;
UPDATE pos.sale_discounts SET amount = 7800 WHERE status = 'ACTIVE';
UPDATE pos.sale_items SET item_discount_amount = 7800;
SELECT pos_test.ok((SELECT approved_by = :SUP FROM pos.sale_discounts WHERE status = 'ACTIVE'), 'approver tersimpan di diskon');
UPDATE pos.sales SET status = 'CHECKOUT';
SELECT pos_test.ok((SELECT grand_total = 70200 AND status = 'CHECKOUT' FROM pos.sales), 'checkout dengan diskon 10% disetujui');
ROLLBACK;

-- Hold / resume / batal / void (§26, §27)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
CREATE TEMP TABLE t (n int, sale uuid) ON COMMIT DROP;
INSERT INTO t SELECT 1, pos_test.new_sale();
SELECT pos_test.throws($$SELECT pos_test.new_sale()$$, 'sales_one_draft_per_session_uk', 'satu keranjang aktif per session');
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'HELD'$$, 'SALE_EMPTY', 'keranjang kosong tidak bisa ditahan');
SELECT pos_test.add_item((SELECT sale FROM t WHERE n = 1), 'SKU-0003', 1);
UPDATE pos.sales SET status = 'HELD';
INSERT INTO t SELECT 2, pos_test.new_sale();
SELECT pos_test.ok((SELECT count(*) FROM pos.sales) = 2, 'transaksi lain setelah hold');
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'DRAFT' WHERE status = 'HELD'$$,
    'sales_one_draft_per_session_uk', 'resume ditolak bila masih ada keranjang aktif');
UPDATE pos.sales SET status = 'CANCELLED' WHERE id = (SELECT sale FROM t WHERE n = 2);
UPDATE pos.sales SET status = 'DRAFT' WHERE status = 'HELD';
SELECT pos_test.ok((SELECT held_at IS NOT NULL FROM pos.sales WHERE status = 'DRAFT'), 'resume transaksi yang ditahan');
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'CANCELLED' WHERE status = 'DRAFT'$$, 'SALE_NOT_EMPTY',
    'keranjang berisi harus di-void dengan alasan');
UPDATE pos.sale_items SET status = 'VOID', void_reason = 'Salah scan';
SELECT pos_test.ok((SELECT grand_total = 0 AND line_count = 0 FROM pos.sales WHERE status = 'DRAFT'), 'void baris mengurangi total');
SELECT pos_test.throws($$UPDATE pos.sale_items SET status = 'ACTIVE', void_reason = NULL$$, 'SALE_ITEM_VOID',
    'baris void tidak bisa dihidupkan lagi');
SELECT pos_test.add_item((SELECT sale FROM t WHERE n = 1), 'SKU-0003', 1);
UPDATE pos.sales SET status = 'VOID', void_reason = 'Pelanggan batal beli' WHERE status = 'DRAFT';
SELECT pos_test.ok((SELECT voided_by IS NOT NULL FROM pos.sales WHERE status = 'VOID'), 'void sebelum checkout dengan alasan');
SELECT pos_test.throws($$UPDATE pos.cashier_sessions SET status = 'CANCELLED', closed_by = pos.current_app_user_id(),
    cancel_reason = 'Salah terminal'$$, 'CASHIER_SESSION_HAS_ACTIVITY', 'session dengan transaksi tidak bisa dibatalkan');
ROLLBACK;

-- Terminal terkunci, stok, dan scope
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:JKT);
SELECT pos_test.open_session(:T1, '{{100000,1}}');
CREATE TEMP TABLE t (sale uuid) ON COMMIT DROP;
INSERT INTO t SELECT pos_test.new_sale();
UPDATE pos.cashier_sessions SET status = 'ON_BREAK', lock_reason = 'MANUAL';
SELECT pos_test.throws($$SELECT pos_test.add_item((SELECT sale FROM t), 'SKU-0001', 1)$$, 'CASHIER_SESSION_LOCKED',
    'tidak bisa menambah barang saat terminal terkunci');
RESET ROLE;
SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.sales$$) = 0, 'kasir lain tidak melihat transaksi');
RESET ROLE;
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos_test.rows($$SELECT 1 FROM pos.sales$$) = 1, 'supervisor (sale.view) melihat transaksi outlet');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.sales SET note = 'x'$$) = 0, 'supervisor tidak mengubah transaksi kasir');
ROLLBACK;

BEGIN;
SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.clock_in(:BDG);
SELECT pos_test.open_session(:TB, '{{100000,1}}');
CREATE TEMP TABLE t (sale uuid) ON COMMIT DROP;
INSERT INTO t SELECT pos_test.new_sale();
SELECT pos_test.add_item((SELECT sale FROM t), 'SKU-0001', 1);
SELECT pos_test.ok((SELECT unit_price FROM pos.sale_items) = 4500, 'harga khusus outlet Bandung');
SELECT pos_test.add_item((SELECT sale FROM t), 'SKU-0006', 1);
SELECT pos_test.throws($$UPDATE pos.sales SET status = 'CHECKOUT'$$, 'STOCK_UNAVAILABLE', 'stok habis menolak checkout');
ROLLBACK;

-- Foto produk: hanya path aplikasi atau https; user tidak bisa mengubah master produk
BEGIN;
SET LOCAL ROLE pos_system;
SELECT pos_test.throws($$UPDATE pos.products SET image_url = 'javascript:alert(1)' WHERE sku = 'SKU-0001'$$,
    'products_image_url_ck', 'image_url javascript: ditolak');
SELECT pos_test.throws($$UPDATE pos.products SET image_url = 'http://contoh.test/a.png' WHERE sku = 'SKU-0001'$$,
    'products_image_url_ck', 'image_url http (tanpa TLS) ditolak');
SELECT pos_test.ok(pos_test.affected($$UPDATE pos.products SET image_url = 'https://cdn.contoh.test/p/1.webp' WHERE sku = 'SKU-0001'$$) = 1,
    'image_url https diterima');
RESET ROLE;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.throws($$UPDATE pos.products SET image_url = '/x.png'$$, 'permission denied', 'kasir tidak bisa mengubah foto produk');
ROLLBACK;
