-- V030: dasbor penjualan & closing untuk owner/manager.
-- Dihitung dari penjualan lunas per business_date. SECURITY DEFINER: setiap query difilter organisasi pemanggil.
CREATE OR REPLACE FUNCTION pos.dashboard(p_from date, p_to date, p_outlet uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_tz text;
    v_result jsonb;
BEGIN
    PERFORM pos.require_perm('report.view', p_outlet);
    IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 366 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: rentang tanggal tidak valid (maks 366 hari)' USING ERRCODE = 'P0001';
    END IF;
    IF p_outlet IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pos.outlets o WHERE o.id = p_outlet AND o.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: outlet' USING ERRCODE = 'P0001';
    END IF;
    SELECT coalesce(timezone, 'Asia/Jakarta') INTO v_tz FROM pos.organizations WHERE id = v_org;

    WITH sold AS (
        SELECT s.* FROM pos.sales s
        WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to
          AND s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')
          AND (p_outlet IS NULL OR s.outlet_id = p_outlet)
    ),
    ret AS (
        SELECT r.total_amount FROM pos.returns r
        WHERE r.organization_id = v_org AND r.business_date BETWEEN p_from AND p_to AND r.status = 'COMPLETED'
          AND (p_outlet IS NULL OR r.outlet_id = p_outlet)
    ),
    voids AS (
        SELECT s.grand_total FROM pos.sales s
        WHERE s.organization_id = v_org AND s.business_date BETWEEN p_from AND p_to AND s.status = 'VOID'
          AND (p_outlet IS NULL OR s.outlet_id = p_outlet)
    ),
    sess AS (
        SELECT c.difference FROM pos.cashier_sessions c
        WHERE c.organization_id = v_org AND c.business_date BETWEEN p_from AND p_to AND c.status = 'CLOSED'
          AND (p_outlet IS NULL OR c.outlet_id = p_outlet)
    )
    SELECT jsonb_build_object(
        'from', p_from, 'to', p_to,
        'summary', jsonb_build_object(
            'salesCount', (SELECT count(*) FROM sold),
            'grossSales', (SELECT coalesce(sum(subtotal), 0) FROM sold),
            'discounts', (SELECT coalesce(sum(discount_total), 0) FROM sold),
            'tax', (SELECT coalesce(sum(tax_total), 0) FROM sold),
            'netSales', (SELECT coalesce(sum(grand_total), 0) FROM sold),
            'avgBasket', (SELECT coalesce(round(avg(grand_total)), 0) FROM sold),
            'itemsSold', (SELECT coalesce(sum(item_count), 0) FROM sold),
            'returnsTotal', (SELECT coalesce(sum(total_amount), 0) FROM ret),
            'returnsCount', (SELECT count(*) FROM ret),
            'voidCount', (SELECT count(*) FROM voids),
            'voidTotal', (SELECT coalesce(sum(grand_total), 0) FROM voids)),
        'daily', (SELECT coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'count', coalesce(x.cnt, 0), 'total', coalesce(x.total, 0)) ORDER BY d.day), '[]')
                  FROM generate_series(p_from, p_to, interval '1 day') AS d(day)
                  LEFT JOIN (SELECT business_date, count(*) AS cnt, sum(grand_total) AS total FROM sold GROUP BY business_date) x
                         ON x.business_date = d.day::date),
        'hourly', (SELECT coalesce(jsonb_agg(jsonb_build_object('hour', h.hour, 'count', coalesce(x.cnt, 0), 'total', coalesce(x.total, 0)) ORDER BY h.hour), '[]')
                   FROM generate_series(0, 23) AS h(hour)
                   LEFT JOIN (SELECT extract(hour FROM paid_at AT TIME ZONE v_tz)::int AS hr, count(*) AS cnt, sum(grand_total) AS total
                              FROM sold WHERE paid_at IS NOT NULL GROUP BY 1) x ON x.hr = h.hour),
        'payments', (SELECT coalesce(jsonb_agg(jsonb_build_object('method', t.method, 'kind', t.kind, 'count', t.cnt, 'amount', t.amount) ORDER BY t.amount DESC), '[]')
                     FROM (SELECT p.method_code AS method, p.method_kind AS kind, count(*) AS cnt, sum(p.amount) AS amount
                           FROM pos.payments p JOIN sold ON sold.id = p.sale_id
                           WHERE p.organization_id = v_org AND p.status IN ('PAID', 'REFUNDED')
                           GROUP BY p.method_code, p.method_kind) t),
        'topProducts', (SELECT coalesce(jsonb_agg(jsonb_build_object('sku', t.sku, 'name', t.name, 'quantity', t.qty, 'revenue', t.revenue) ORDER BY t.revenue DESC), '[]')
                        FROM (SELECT i.sku, i.product_name AS name, sum(i.quantity) AS qty, sum(i.net_amount) AS revenue
                              FROM pos.sale_items i JOIN sold ON sold.id = i.sale_id
                              WHERE i.status = 'ACTIVE' GROUP BY i.sku, i.product_name
                              ORDER BY sum(i.net_amount) DESC LIMIT 10) t),
        'categories', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'revenue', t.revenue) ORDER BY t.revenue DESC), '[]')
                       FROM (SELECT coalesce(c.name, 'Tanpa kategori') AS name, sum(i.net_amount) AS revenue
                             FROM pos.sale_items i JOIN sold ON sold.id = i.sale_id
                             LEFT JOIN pos.products pr ON pr.id = i.product_id
                             LEFT JOIN pos.product_categories c ON c.id = pr.category_id
                             WHERE i.status = 'ACTIVE' GROUP BY 1 ORDER BY 2 DESC LIMIT 8) t),
        'cash', jsonb_build_object(
            'closedSessions', (SELECT count(*) FROM sess),
            'sessionsWithDifference', (SELECT count(*) FROM sess WHERE difference <> 0),
            'shortTotal', (SELECT coalesce(sum(difference), 0) FROM sess WHERE difference < 0),
            'overTotal', (SELECT coalesce(sum(difference), 0) FROM sess WHERE difference > 0)),
        'lowStock', (SELECT coalesce(jsonb_agg(jsonb_build_object('sku', t.sku, 'name', t.name, 'available', t.available) ORDER BY t.available), '[]')
                     FROM (SELECT pr.sku, pr.name, sum(sc.available_quantity) AS available
                           FROM pos.products pr
                           JOIN pos.product_stock_cache sc ON sc.product_id = pr.id
                           JOIN pos.warehouses w ON w.id = sc.warehouse_id
                           WHERE pr.organization_id = v_org AND pr.active AND pr.track_stock
                             AND (p_outlet IS NULL OR w.outlet_id = p_outlet)
                           GROUP BY pr.sku, pr.name HAVING sum(sc.available_quantity) <= 5
                           ORDER BY 3 LIMIT 10) t),
        'attention', jsonb_build_object(
            'syncProblems', (SELECT count(*) FROM pos.sales s WHERE s.organization_id = v_org AND s.sync_status IN ('FAILED', 'MANUAL_REVIEW')
                              AND (p_outlet IS NULL OR s.outlet_id = p_outlet)),
            'openSessions', (SELECT count(*) FROM pos.cashier_sessions c WHERE c.organization_id = v_org AND c.status IN ('OPEN', 'ON_BREAK', 'CLOSING')
                              AND (p_outlet IS NULL OR c.outlet_id = p_outlet)))
    ) INTO v_result;
    RETURN v_result;
END
$$;
REVOKE ALL ON FUNCTION pos.dashboard(date, date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.dashboard(date, date, uuid) TO pos_app_user;

-- Menu Dashboard (sudah ada sejak V019) kini membuka halaman dasbor, bukan beranda.
UPDATE pos.menu_items SET route_name = 'dashboard' WHERE code = 'dashboard';
