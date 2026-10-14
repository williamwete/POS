-- Penjualan offline sudah terjadi di toko (barang sudah keluar, uang sudah diterima): server tidak boleh
-- menolaknya karena stok tidak cukup. Pengecekan stok dilewati untuk transaksi itu saja (satu transaksi
-- database) dan kekurangannya dicatat sebagai peninjauan (pos.offline_sales).
CREATE OR REPLACE FUNCTION pos.offline_stock_waiver(p_outlet uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('sale.create', p_outlet);
    PERFORM set_config('pos.offline_waive_stock', 'on', true);
END
$$;
REVOKE ALL ON FUNCTION pos.offline_stock_waiver(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.offline_stock_waiver(uuid) TO pos_app_user;

CREATE OR REPLACE FUNCTION pos.sale_stock_check(p_sale uuid, p_outlet uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    r          record;
    v_allow    boolean;
    v_avail    numeric;
    v_outlet_allow boolean := (pos.get_setting('allow_negative_stock', p_outlet))::boolean;
BEGIN
    -- transaksi offline: stok dicatat minus & ditinjau, bukan ditolak (lihat pos.offline_stock_waiver)
    IF coalesce(current_setting('pos.offline_waive_stock', true), '') = 'on' THEN
        RETURN;
    END IF;
    FOR r IN
        SELECT si.product_id, p.sku, p.allow_negative_stock, p.track_stock, sum(si.quantity) AS qty
        FROM pos.sale_items si JOIN pos.products p ON p.id = si.product_id
        WHERE si.sale_id = p_sale AND si.status = 'ACTIVE'
        GROUP BY si.product_id, p.sku, p.allow_negative_stock, p.track_stock
        ORDER BY si.product_id
    LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended(r.product_id::text || ':' || p_outlet::text, 0));
        v_allow := coalesce(r.allow_negative_stock, v_outlet_allow, false);
        IF v_allow OR NOT r.track_stock THEN
            CONTINUE;
        END IF;
        v_avail := pos.available_to_sell(r.product_id, p_outlet);
        IF v_avail IS NULL OR v_avail < r.qty THEN
            RAISE EXCEPTION 'STOCK_UNAVAILABLE: % (tersedia %, diminta %)', r.sku, coalesce(v_avail::text, 'tidak diketahui'), r.qty
                USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
END
$$;
