-- V026: jenis usaha FASHION (pakaian, sepatu, aksesoris, merchandise).
ALTER TABLE pos.organizations DROP CONSTRAINT organizations_business_type_ck;
ALTER TABLE pos.organizations ADD CONSTRAINT organizations_business_type_ck
    CHECK (business_type IN ('FNB', 'RETAIL', 'FASHION', 'SERVICE', 'GENERAL'));

CREATE OR REPLACE FUNCTION pos.platform_provision_merchant(
    p_code text, p_name text, p_business_type text, p_plan text,
    p_outlet_code text, p_outlet_name text, p_owner_name text, p_owner_email text,
    p_auth_user_id uuid, p_timezone text DEFAULT 'Asia/Jakarta')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid; v_outlet uuid; v_wh uuid; v_emp uuid; v_user uuid; v_actor uuid;
    v_code text := upper(btrim(coalesce(p_code, '')));
    v_username text;
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    v_actor := pos.current_app_user_id();
    IF v_code !~ '^[A-Z0-9_-]{2,24}$' OR v_code = 'PLATFORM' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kode merchant 2-24 karakter A-Z, 0-9, - atau _' USING ERRCODE = 'P0001';
    END IF;
    IF coalesce(btrim(p_name), '') = '' OR coalesce(btrim(p_outlet_name), '') = '' OR coalesce(btrim(p_owner_name), '') = '' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nama merchant, outlet, dan pemilik wajib diisi' USING ERRCODE = 'P0001';
    END IF;
    IF p_business_type NOT IN ('FNB', 'RETAIL', 'FASHION', 'SERVICE', 'GENERAL') THEN
        RAISE EXCEPTION 'CATALOG_INVALID: jenis usaha tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pos.plans WHERE code = p_plan AND active) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: paket tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    IF p_outlet_code !~ '^[A-Z0-9_-]{2,32}$' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kode outlet 2-32 karakter A-Z, 0-9, - atau _' USING ERRCODE = 'P0001';
    END IF;
    v_username := lower(v_code) || '.owner';
    IF v_username !~ '^[a-z0-9._-]{3,64}$' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kode merchant tidak valid untuk username' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO pos.organizations (code, name, timezone, business_type)
    VALUES (v_code, btrim(p_name), coalesce(p_timezone, 'Asia/Jakarta'), p_business_type)
    RETURNING id INTO v_org;

    INSERT INTO pos.organization_subscriptions (organization_id, plan_code, status, trial_ends_at)
    VALUES (v_org, p_plan, CASE WHEN p_plan = 'TRIAL' THEN 'TRIAL' ELSE 'ACTIVE' END,
            CASE WHEN p_plan = 'TRIAL' THEN now() + interval '14 days' END);

    INSERT INTO pos.outlets (organization_id, code, name) VALUES (v_org, upper(btrim(p_outlet_code)), btrim(p_outlet_name))
    RETURNING id INTO v_outlet;
    INSERT INTO pos.warehouses (organization_id, outlet_id, code, name)
    VALUES (v_org, v_outlet, 'WH-' || upper(btrim(p_outlet_code)), 'Gudang ' || btrim(p_outlet_name))
    RETURNING id INTO v_wh;
    UPDATE pos.outlets SET default_warehouse_id = v_wh WHERE id = v_outlet;

    INSERT INTO pos.terminals (outlet_id, code, name) VALUES (v_outlet, v_code || '-K1', 'Kasir 1');

    INSERT INTO pos.employees (organization_id, employee_code, full_name, email, position, home_outlet_id)
    VALUES (v_org, 'OWNER', btrim(p_owner_name), lower(btrim(p_owner_email)), 'Pemilik', v_outlet)
    RETURNING id INTO v_emp;
    INSERT INTO pos.users (auth_user_id, organization_id, employee_id, username, email, display_name, created_by)
    VALUES (p_auth_user_id, v_org, v_emp, v_username, lower(btrim(p_owner_email)), btrim(p_owner_name), v_actor)
    RETURNING id INTO v_user;
    INSERT INTO pos.user_roles (user_id, role_id, outlet_id, granted_by)
    SELECT v_user, r.id, NULL, v_actor FROM pos.roles r WHERE r.code IN ('OWNER', 'ADMIN', 'STORE_MANAGER');

    -- data awal: pajak & profil struk
    INSERT INTO pos.tax_rates (organization_id, code, name, rate, active, source) VALUES
        (v_org, 'PPN11', 'PPN 11%', 11, true, 'LOCAL'),
        (v_org, 'PB1', 'PB1 10%', 10, p_business_type = 'FNB', 'LOCAL');
    INSERT INTO pos.receipt_profiles (organization_id, outlet_id, business_name, footer_text)
    VALUES (v_org, NULL, btrim(p_name), 'Terima kasih atas kunjungan Anda');

    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (v_org, v_actor, 'MERCHANT_PROVISIONED', 'ORGANIZATION', v_org::text,
            jsonb_build_object('code', v_code, 'plan', p_plan, 'businessType', p_business_type, 'owner', v_username));
    RETURN v_org;
END
$$;

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
        ('FASHION', 'PAKAIAN', 'Pakaian'), ('FASHION', 'SEPATU', 'Sepatu'), ('FASHION', 'AKSESORIS', 'Aksesoris'),
        ('FASHION', 'KAOSKAKI', 'Kaos Kaki'), ('FASHION', 'MERCH', 'Merchandise'),
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
        ('FASHION', 'Diskon member 10%', 'PERCENTAGE', 10), ('FASHION', 'Potongan Rp 20.000', 'AMOUNT', 20000),
        ('SERVICE', 'Diskon pelanggan 10%', 'PERCENTAGE', 10),
        ('GENERAL', 'Diskon 10%', 'PERCENTAGE', 10)
    ) AS d(biz, name, type, value)
    WHERE d.biz = v_type
    ON CONFLICT DO NOTHING;
END
$$;
