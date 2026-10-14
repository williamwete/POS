-- V035: laporan penjualan terperinci (Fase 11): per produk, kategori, kasir, hari, atau metode bayar.
-- Satu fungsi, satu bentuk baris, supaya halaman dan ekspor CSV memakai angka yang sama dengan dasbor (penjualan lunas).
CREATE OR REPLACE FUNCTION pos.sales_report(p_from date, p_to date, p_outlet uuid, p_group text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_rows jsonb;
BEGIN
    PERFORM pos.require_perm('report.view', p_outlet);
    IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 366 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: rentang tanggal tidak valid (maks 366 hari)' USING ERRCODE = 'P0001';
    END IF;
    IF p_group IS NULL OR p_group NOT IN ('PRODUCT', 'CATEGORY', 'CASHIER', 'DAY', 'PAYMENT') THEN
        RAISE EXCEPTION 'CATALOG_INVALID: pengelompokan tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    IF p_outlet IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pos.outlets o WHERE o.id = p_outlet AND o.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: outlet' USING ERRCODE = 'P0001';
    END IF;
    IF p_group = 'PRODUCT' THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'label', t.label, 'transactions', t.transactions,
                   'quantity', t.quantity, 'gross', t.gross, 'discount', t.discount, 'net', t.net) ORDER BY t.net DESC, t.key), '[]')
          INTO v_rows FROM (
            SELECT i.sku AS key, max(i.product_name) AS label,
                   count(DISTINCT s.id) AS transactions, sum(i.quantity) AS quantity, sum(i.gross_amount) AS gross,
                   sum(i.item_discount_amount + i.cart_discount_amount) AS discount, sum(i.net_amount) AS net
            FROM pos.sale_items i
            JOIN pos.sales s ON s.id = i.sale_id
            LEFT JOIN pos.products pr ON pr.id = i.product_id
            LEFT JOIN pos.product_categories c ON c.id = pr.category_id
            WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to
              AND s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED') AND i.status = 'ACTIVE'
              AND (p_outlet IS NULL OR s.outlet_id = p_outlet)
            GROUP BY i.sku
) t;
    ELSIF p_group = 'CATEGORY' THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'label', t.label, 'transactions', t.transactions,
                   'quantity', t.quantity, 'gross', t.gross, 'discount', t.discount, 'net', t.net) ORDER BY t.net DESC, t.key), '[]')
          INTO v_rows FROM (
            SELECT coalesce(c.name, 'Tanpa kategori') AS key, coalesce(c.name, 'Tanpa kategori') AS label,
                   count(DISTINCT s.id) AS transactions, sum(i.quantity) AS quantity, sum(i.gross_amount) AS gross,
                   sum(i.item_discount_amount + i.cart_discount_amount) AS discount, sum(i.net_amount) AS net
            FROM pos.sale_items i
            JOIN pos.sales s ON s.id = i.sale_id
            LEFT JOIN pos.products pr ON pr.id = i.product_id
            LEFT JOIN pos.product_categories c ON c.id = pr.category_id
            WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to
              AND s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED') AND i.status = 'ACTIVE'
              AND (p_outlet IS NULL OR s.outlet_id = p_outlet)
            GROUP BY coalesce(c.name, 'Tanpa kategori')
) t;
    ELSIF p_group = 'CASHIER' THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'label', t.label, 'transactions', t.transactions,
                   'quantity', t.quantity, 'gross', t.gross, 'discount', t.discount, 'net', t.net) ORDER BY t.net DESC, t.key), '[]')
          INTO v_rows FROM (
            SELECT e.employee_code AS key, max(e.full_name) AS label,
                   count(*) AS transactions, sum(s.item_count) AS quantity, sum(s.subtotal) AS gross,
                   sum(s.discount_total) AS discount, sum(s.grand_total) AS net
            FROM pos.sales s JOIN pos.employees e ON e.id = s.employee_id
            WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to
              AND s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')
              AND (p_outlet IS NULL OR s.outlet_id = p_outlet)
            GROUP BY e.employee_code
) t;
    ELSIF p_group = 'DAY' THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'label', t.label, 'transactions', t.transactions,
                   'quantity', t.quantity, 'gross', t.gross, 'discount', t.discount, 'net', t.net) ORDER BY t.key), '[]')
          INTO v_rows FROM (
            SELECT s.business_date::text AS key, s.business_date::text AS label,
                   count(*) AS transactions, sum(s.item_count) AS quantity, sum(s.subtotal) AS gross,
                   sum(s.discount_total) AS discount, sum(s.grand_total) AS net
            FROM pos.sales s JOIN pos.employees e ON e.id = s.employee_id
            WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to
              AND s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')
              AND (p_outlet IS NULL OR s.outlet_id = p_outlet)
            GROUP BY s.business_date
) t;
    ELSE
        SELECT coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'label', t.label, 'transactions', t.transactions,
                   'quantity', t.quantity, 'gross', t.gross, 'discount', t.discount, 'net', t.net) ORDER BY t.net DESC, t.key), '[]')
          INTO v_rows FROM (
            SELECT p.method_code AS key, p.method_code AS label,
                   count(DISTINCT s.id) AS transactions, NULL::numeric AS quantity, NULL::numeric AS gross,
                   NULL::numeric AS discount, sum(p.amount) AS net
            FROM pos.payments p JOIN pos.sales s ON s.id = p.sale_id
            WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to
              AND s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED') AND p.status IN ('PAID', 'REFUNDED')
              AND (p_outlet IS NULL OR s.outlet_id = p_outlet)
            GROUP BY p.method_code
) t;
    END IF;
    RETURN jsonb_build_object('from', p_from, 'to', p_to, 'group', p_group, 'rows', v_rows);
END
$$;
REVOKE ALL ON FUNCTION pos.sales_report(date, date, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.sales_report(date, date, uuid, text) TO pos_app_user;
