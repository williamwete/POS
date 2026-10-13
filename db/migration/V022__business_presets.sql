-- V022: preset jenis usaha — kategori, opsi produk, dan preset diskon awal.
-- Idempotent: memakai ON CONFLICT DO NOTHING, aman dipanggil ulang (mis. untuk merchant lama).
CREATE OR REPLACE FUNCTION pos.platform_apply_preset(p_org uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_type text;
    v_group uuid;
    g record;
    o text;
    i integer;
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    SELECT business_type INTO v_type FROM pos.organizations WHERE id = p_org AND code <> 'PLATFORM';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: merchant' USING ERRCODE = 'P0001';
    END IF;

    -- kategori
    INSERT INTO pos.product_categories (organization_id, code, name, source)
    SELECT p_org, c.code, c.name, 'LOCAL'
    FROM (VALUES
        ('FNB', 'MAKANAN', 'Makanan'), ('FNB', 'MINUMAN', 'Minuman'), ('FNB', 'SNACK', 'Snack'), ('FNB', 'PAKET', 'Paket Hemat'),
        ('RETAIL', 'MAKMIN', 'Makanan & Minuman'), ('RETAIL', 'RUMAH', 'Kebutuhan Rumah'),
        ('RETAIL', 'PERAWATAN', 'Perawatan Diri'), ('RETAIL', 'ELEKTRONIK', 'Elektronik'), ('RETAIL', 'LAINNYA', 'Lainnya'),
        ('SERVICE', 'LAYANAN', 'Layanan'), ('SERVICE', 'PRODUK', 'Produk'),
        ('GENERAL', 'UMUM', 'Umum')
    ) AS c(type, code, name)
    WHERE c.type = v_type
    ON CONFLICT (organization_id, code) DO NOTHING;

    -- opsi produk (hanya F&B)
    IF v_type = 'FNB' THEN
        FOR g IN SELECT * FROM (VALUES
            ('Level pedas', 1, 1, 1, ARRAY['Tidak pedas|0', 'Sedang|0', 'Pedas|0']),
            ('Suhu', 1, 1, 2, ARRAY['Dingin|0', 'Panas|0']),
            ('Gula', 1, 1, 3, ARRAY['Normal|0', 'Kurang manis|0', 'Tanpa gula|0']),
            ('Topping', 0, 3, 4, ARRAY['Telur|4000', 'Keju|3000', 'Boba|5000'])
        ) AS t(name, min_select, max_select, sort_order, opts)
        LOOP
            INSERT INTO pos.product_option_groups (organization_id, name, min_select, max_select, sort_order)
            VALUES (p_org, g.name, g.min_select, g.max_select, g.sort_order)
            ON CONFLICT (organization_id, name) DO NOTHING;
            SELECT id INTO v_group FROM pos.product_option_groups WHERE organization_id = p_org AND name = g.name;
            i := 0;
            FOREACH o IN ARRAY g.opts LOOP
                i := i + 1;
                INSERT INTO pos.product_options (organization_id, group_id, name, price_delta, sort_order)
                VALUES (p_org, v_group, split_part(o, '|', 1), split_part(o, '|', 2)::numeric, i)
                ON CONFLICT (group_id, name) DO NOTHING;
            END LOOP;
        END LOOP;
    END IF;

    -- preset diskon
    INSERT INTO pos.discount_presets (organization_id, outlet_id, name, discount_type, discount_value)
    SELECT p_org, NULL, d.name, d.type, d.value
    FROM (VALUES
        ('FNB', 'Diskon member 10%', 'PERCENTAGE', 10), ('FNB', 'Promo Rp 5.000', 'AMOUNT', 5000),
        ('RETAIL', 'Diskon member 5%', 'PERCENTAGE', 5), ('RETAIL', 'Potongan Rp 5.000', 'AMOUNT', 5000),
        ('SERVICE', 'Diskon pelanggan 10%', 'PERCENTAGE', 10),
        ('GENERAL', 'Diskon 10%', 'PERCENTAGE', 10)
    ) AS d(biz, name, type, value)
    WHERE d.biz = v_type
    ON CONFLICT DO NOTHING;
END
$$;
REVOKE ALL ON FUNCTION pos.platform_apply_preset(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.platform_apply_preset(uuid) TO pos_app_user;
