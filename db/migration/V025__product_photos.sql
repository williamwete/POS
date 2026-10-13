-- Foto produk: data URL kecil (hasil kecilkan di browser) atau path/https; NULL pada save_product = foto tidak diubah, '' = hapus.
ALTER TABLE pos.products DROP CONSTRAINT products_image_url_ck;
ALTER TABLE pos.products ADD CONSTRAINT products_image_url_ck CHECK (
    image_url IS NULL
    OR (length(image_url) <= 500 AND (image_url ~ '^/[A-Za-z0-9/_.-]+$' OR image_url ~ '^https://[^\s"''<>]+$'))
    OR (length(image_url) <= 60000 AND image_url ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$'));

CREATE OR REPLACE FUNCTION pos.save_product(
    p_id uuid, p_sku text, p_name text, p_category uuid, p_uom text, p_decimal boolean, p_tax uuid,
    p_track_stock boolean, p_active boolean, p_image text, p_barcode text, p_price numeric)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org  uuid := pos.current_org_id();
    v_row  pos.products%ROWTYPE;
    v_id   uuid;
    v_cur  record;
    v_bc   text := nullif(btrim(coalesce(p_barcode, '')), '');
    v_type text;
BEGIN
    PERFORM pos.require_perm('product.manage');
    IF p_sku IS NULL OR p_sku !~ '^[A-Za-z0-9._-]{1,40}$' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: SKU 1-40 karakter (huruf, angka, . _ -)' USING ERRCODE = 'P0001';
    END IF;
    IF p_name IS NULL OR pg_catalog.length(btrim(p_name)) NOT BETWEEN 1 AND 120 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nama produk 1-120 karakter' USING ERRCODE = 'P0001';
    END IF;
    IF p_uom IS NULL OR pg_catalog.length(btrim(p_uom)) NOT BETWEEN 1 AND 12 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: satuan 1-12 karakter' USING ERRCODE = 'P0001';
    END IF;
    IF p_price IS NOT NULL AND (p_price < 0 OR p_price > 1000000000) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: harga di luar batas' USING ERRCODE = 'P0001';
    END IF;
    IF p_image IS NOT NULL AND btrim(p_image) <> '' AND NOT (
           (btrim(p_image) ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' AND pg_catalog.length(btrim(p_image)) <= 60000)
        OR (btrim(p_image) ~ '^(/[A-Za-z0-9/_.-]+|https://[^\s"''<>]+)$' AND pg_catalog.length(btrim(p_image)) <= 500)) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: foto harus PNG/JPEG/WebP (maks ± 45 KB setelah dikecilkan)' USING ERRCODE = 'P0001';
    END IF;
    IF p_category IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pos.product_categories c WHERE c.id = p_category AND c.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kategori tidak ditemukan' USING ERRCODE = 'P0001';
    END IF;
    IF p_tax IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pos.tax_rates t WHERE t.id = p_tax AND t.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: pajak tidak ditemukan' USING ERRCODE = 'P0001';
    END IF;

    IF p_id IS NULL THEN
        IF p_price IS NULL THEN
            RAISE EXCEPTION 'CATALOG_INVALID: harga wajib diisi untuk produk baru' USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO pos.products (organization_id, sku, name, category_id, uom, allow_decimal_qty, tax_rate_id,
                                  track_stock, active, image_url, source)
        VALUES (v_org, p_sku, btrim(p_name), p_category, btrim(p_uom), coalesce(p_decimal, false), p_tax,
                coalesce(p_track_stock, true), coalesce(p_active, true), nullif(btrim(p_image), ''), 'LOCAL')
        RETURNING id INTO v_id;
    ELSE
        SELECT * INTO v_row FROM pos.products WHERE id = p_id AND organization_id = v_org FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CATALOG_NOT_FOUND: produk' USING ERRCODE = 'P0001';
        END IF;
        IF v_row.source = 'OPENBRAVO' THEN
            RAISE EXCEPTION 'CATALOG_READ_ONLY: produk berasal dari Openbravo' USING ERRCODE = 'P0001';
        END IF;
        v_id := p_id;
        UPDATE pos.products SET sku = p_sku, name = btrim(p_name), category_id = p_category, uom = btrim(p_uom),
               allow_decimal_qty = coalesce(p_decimal, false), tax_rate_id = p_tax,
               track_stock = coalesce(p_track_stock, true), active = coalesce(p_active, true),
               image_url = CASE WHEN p_image IS NULL THEN image_url ELSE nullif(btrim(p_image), '') END, updated_at = now(), version = version + 1
         WHERE id = v_id;
    END IF;

    IF p_price IS NOT NULL THEN
        SELECT c.id, c.price, c.version INTO v_cur FROM pos.product_price_cache c
         WHERE c.product_id = v_id AND c.outlet_id IS NULL AND c.price_list_code = 'DEFAULT' AND c.valid_to IS NULL
         ORDER BY c.version DESC LIMIT 1;
        IF v_cur.id IS NULL THEN
            INSERT INTO pos.product_price_cache (organization_id, product_id, price, source, version, valid_from)
            VALUES (v_org, v_id, p_price, 'LOCAL',
                    coalesce((SELECT max(x.version) FROM pos.product_price_cache x
                              WHERE x.product_id = v_id AND x.outlet_id IS NULL AND x.price_list_code = 'DEFAULT'), 0) + 1,
                    now());
        ELSIF v_cur.price <> p_price THEN
            UPDATE pos.product_price_cache SET valid_to = clock_timestamp() WHERE id = v_cur.id;
            INSERT INTO pos.product_price_cache (organization_id, product_id, price, source, version, valid_from)
            VALUES (v_org, v_id, p_price, 'LOCAL', v_cur.version + 1, clock_timestamp());
        END IF;
    END IF;

    IF p_barcode IS NOT NULL THEN
        UPDATE pos.product_barcodes SET active = false, is_primary = false
         WHERE product_id = v_id AND active AND is_primary AND barcode IS DISTINCT FROM v_bc;
        IF v_bc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pos.product_barcodes b WHERE b.product_id = v_id AND b.active AND b.barcode = v_bc) THEN
            v_type := CASE WHEN v_bc ~ '^[0-9]{13}$' THEN 'EAN13' WHEN v_bc ~ '^[0-9]{8}$' THEN 'EAN8' ELSE 'INTERNAL' END;
            INSERT INTO pos.product_barcodes (organization_id, product_id, barcode, barcode_type, is_primary)
            VALUES (v_org, v_id, v_bc, v_type, true);
        END IF;
    END IF;
    RETURN v_id;
END
$$;
