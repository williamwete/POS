-- V029: impor produk massal (CSV di frontend -> JSON). Semua-atau-tidak-sama-sekali; kategori baru dibuat otomatis.
CREATE OR REPLACE FUNCTION pos.import_products(p_rows jsonb, p_outlet uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    r record;
    v_sku text; v_name text; v_catname text; v_uom text; v_bc text;
    v_price numeric; v_stock numeric;
    v_cat uuid; v_code text; v_try integer;
    v_prod pos.products%ROWTYPE;
    v_id uuid;
    v_created integer := 0; v_updated integer := 0; v_cats integer := 0;
BEGIN
    PERFORM pos.require_perm('product.manage', NULL);
    IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: impor 1-500 baris per berkas' USING ERRCODE = 'P0001';
    END IF;
    IF p_outlet IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pos.outlets o WHERE o.id = p_outlet AND o.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: outlet tidak ditemukan' USING ERRCODE = 'P0001';
    END IF;

    FOR r IN SELECT e.value AS v, e.ordinality AS n FROM jsonb_array_elements(p_rows) WITH ORDINALITY e LOOP
        BEGIN
            v_sku := btrim(coalesce(r.v ->> 'sku', ''));
            v_name := btrim(coalesce(r.v ->> 'name', ''));
            v_catname := nullif(btrim(coalesce(r.v ->> 'category', '')), '');
            v_uom := nullif(btrim(coalesce(r.v ->> 'uom', '')), '');
            v_bc := nullif(btrim(coalesce(r.v ->> 'barcode', '')), '');
            v_price := nullif(btrim(coalesce(r.v ->> 'price', '')), '')::numeric;
            v_stock := nullif(btrim(coalesce(r.v ->> 'stock', '')), '')::numeric;

            v_cat := NULL;
            IF v_catname IS NOT NULL THEN
                SELECT c.id INTO v_cat FROM pos.product_categories c
                 WHERE c.organization_id = v_org AND (upper(c.code) = upper(v_catname) OR lower(c.name) = lower(v_catname))
                 ORDER BY c.active DESC LIMIT 1;
                IF v_cat IS NULL THEN
                    v_code := left(upper(regexp_replace(v_catname, '[^A-Za-z0-9]+', '', 'g')), 26);
                    IF v_code = '' THEN v_code := 'KAT'; END IF;
                    v_try := 1;
                    WHILE EXISTS (SELECT 1 FROM pos.product_categories c WHERE c.organization_id = v_org AND c.code = v_code || CASE WHEN v_try = 1 THEN '' ELSE v_try::text END) LOOP
                        v_try := v_try + 1;
                    END LOOP;
                    v_cat := pos.save_category(NULL, v_code || CASE WHEN v_try = 1 THEN '' ELSE v_try::text END, v_catname, true);
                    v_cats := v_cats + 1;
                END IF;
            END IF;

            SELECT * INTO v_prod FROM pos.products WHERE organization_id = v_org AND sku = v_sku;
            IF FOUND THEN
                v_id := pos.save_product(v_prod.id, v_sku, v_name, coalesce(v_cat, v_prod.category_id), coalesce(v_uom, v_prod.uom),
                                         v_prod.allow_decimal_qty, v_prod.tax_rate_id, v_prod.track_stock, v_prod.active,
                                         NULL, v_bc, v_price);
                v_updated := v_updated + 1;
            ELSE
                IF v_price IS NULL THEN
                    RAISE EXCEPTION 'CATALOG_INVALID: harga wajib diisi untuk produk baru';
                END IF;
                v_id := pos.save_product(NULL, v_sku, v_name, v_cat, coalesce(v_uom, 'PCS'), false, NULL, true, true, NULL, v_bc, v_price);
                v_created := v_created + 1;
            END IF;

            IF v_stock IS NOT NULL AND p_outlet IS NOT NULL THEN
                PERFORM pos.set_local_stock(v_id, p_outlet, v_stock);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'CATALOG_INVALID: baris %: %', r.n, regexp_replace(SQLERRM, '^[A-Z_]+: ', '') USING ERRCODE = 'P0001';
        END;
    END LOOP;

    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (v_org, pos.current_app_user_id(), 'PRODUCTS_IMPORTED', 'PRODUCT', 'import',
            jsonb_build_object('created', v_created, 'updated', v_updated, 'categoriesCreated', v_cats));
    RETURN jsonb_build_object('created', v_created, 'updated', v_updated, 'categoriesCreated', v_cats);
END
$$;
REVOKE ALL ON FUNCTION pos.import_products(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.import_products(jsonb, uuid) TO pos_app_user;
