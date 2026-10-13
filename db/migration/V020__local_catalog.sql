-- V020: katalog lokal untuk merchant tanpa ERP (SaaS): kelola produk, kategori, pajak, stok awal,
-- opsi produk (mis. level pedas), preset diskon dan profil struk.
--
-- Prinsip:
--  * Semua tulis lewat fungsi SECURITY DEFINER yang memeriksa permission dan memfilter organisasi
--    secara eksplisit (fungsi definer melewati RLS). User aplikasi tetap hanya SELECT.
--  * Data dari Openbravo (source = 'OPENBRAVO') tidak bisa diubah dari aplikasi.
--  * Harga lokal ditulis sebagai versi baru di product_price_cache; transaksi tetap mengambil harga
--    dari pos.product_price() (tidak pernah dari client).

-- ---------------------------------------------------------------- sumber data LOCAL
ALTER TABLE pos.products DROP CONSTRAINT products_source_ck;
ALTER TABLE pos.products ADD CONSTRAINT products_source_ck CHECK (source IN ('OPENBRAVO', 'SEED', 'LOCAL'));
ALTER TABLE pos.product_price_cache DROP CONSTRAINT price_cache_source_ck;
ALTER TABLE pos.product_price_cache ADD CONSTRAINT price_cache_source_ck CHECK (source IN ('OPENBRAVO', 'SEED', 'LOCAL'));
ALTER TABLE pos.product_stock_cache DROP CONSTRAINT stock_cache_source_ck;
ALTER TABLE pos.product_stock_cache ADD CONSTRAINT stock_cache_source_ck CHECK (source IN ('OPENBRAVO', 'SEED', 'LOCAL'));
ALTER TABLE pos.tax_rates ADD COLUMN source text NOT NULL DEFAULT 'OPENBRAVO',
    ADD CONSTRAINT tax_rates_source_ck CHECK (source IN ('OPENBRAVO', 'SEED', 'LOCAL'));
ALTER TABLE pos.product_categories ADD COLUMN source text NOT NULL DEFAULT 'OPENBRAVO',
    ADD CONSTRAINT product_categories_source_ck CHECK (source IN ('OPENBRAVO', 'SEED', 'LOCAL'));
UPDATE pos.tax_rates SET source = 'SEED' WHERE openbravo_tax_id IS NULL;
UPDATE pos.product_categories SET source = 'SEED' WHERE openbravo_category_id IS NULL;

-- Produk tanpa stok (makanan/minuman dibuat saat dipesan, jasa) tidak dicek stoknya saat checkout.
ALTER TABLE pos.products ADD COLUMN track_stock boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION pos.require_perm(p_permission text, p_outlet uuid DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF NOT pos.has_permission(p_permission, p_outlet) THEN
        RAISE EXCEPTION 'USER_NOT_AUTHORIZED: % required', p_permission USING ERRCODE = 'P0001';
    END IF;
END
$$;
REVOKE ALL ON FUNCTION pos.require_perm(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.require_perm(text, uuid) TO pos_app_user;

-- ---------------------------------------------------------------- opsi produk
CREATE TABLE pos.product_option_groups (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    name             text        NOT NULL,
    min_select       integer     NOT NULL DEFAULT 0,
    max_select       integer     NOT NULL DEFAULT 1,
    sort_order       integer     NOT NULL DEFAULT 0,
    active           boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT option_groups_name_ck CHECK (pg_catalog.length(btrim(name)) BETWEEN 1 AND 60),
    CONSTRAINT option_groups_select_ck CHECK (min_select >= 0 AND max_select >= 1 AND max_select <= 20 AND min_select <= max_select),
    CONSTRAINT option_groups_org_name_uk UNIQUE (organization_id, name),
    CONSTRAINT option_groups_id_org_uk UNIQUE (id, organization_id)
);
CREATE TABLE pos.product_options (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid          NOT NULL,
    group_id         uuid          NOT NULL,
    name             text          NOT NULL,
    price_delta      numeric(18,2) NOT NULL DEFAULT 0,
    sort_order       integer       NOT NULL DEFAULT 0,
    active           boolean       NOT NULL DEFAULT true,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT product_options_group_fk FOREIGN KEY (group_id, organization_id)
        REFERENCES pos.product_option_groups (id, organization_id),
    CONSTRAINT product_options_name_ck CHECK (pg_catalog.length(btrim(name)) BETWEEN 1 AND 60),
    CONSTRAINT product_options_delta_ck CHECK (price_delta >= 0 AND price_delta <= 100000000),
    CONSTRAINT product_options_group_name_uk UNIQUE (group_id, name)
);
CREATE TABLE pos.product_option_links (
    product_id  uuid    NOT NULL REFERENCES pos.products (id),
    group_id    uuid    NOT NULL REFERENCES pos.product_option_groups (id),
    sort_order  integer NOT NULL DEFAULT 0,
    PRIMARY KEY (product_id, group_id)
);
-- Pilihan opsi disimpan di baris penjualan: id (untuk validasi) dan snapshot (nama & harga saat itu).
ALTER TABLE pos.sale_items ADD COLUMN option_ids uuid[] NOT NULL DEFAULT '{}',
    ADD COLUMN options jsonb NOT NULL DEFAULT '[]'::jsonb;

-- ---------------------------------------------------------------- preset diskon & profil struk
CREATE TABLE pos.discount_presets (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id        uuid,
    name             text          NOT NULL,
    discount_type    text          NOT NULL,
    discount_value   numeric(18,2) NOT NULL,
    active           boolean       NOT NULL DEFAULT true,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT discount_presets_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT discount_presets_name_ck CHECK (pg_catalog.length(btrim(name)) BETWEEN 3 AND 60),
    CONSTRAINT discount_presets_type_ck CHECK (discount_type IN ('PERCENTAGE', 'AMOUNT')),
    CONSTRAINT discount_presets_value_ck CHECK (discount_value > 0 AND (discount_type <> 'PERCENTAGE' OR discount_value <= 100))
);
CREATE UNIQUE INDEX discount_presets_name_uk ON pos.discount_presets
    (organization_id, coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name));

CREATE TABLE pos.receipt_profiles (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    outlet_id        uuid,
    business_name    text,
    address          text,
    phone            text,
    header_text      text,
    footer_text      text,
    tax_id           text,
    show_tax_detail  boolean     NOT NULL DEFAULT true,
    show_cashier     boolean     NOT NULL DEFAULT true,
    paper_width_mm   integer     NOT NULL DEFAULT 80,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT receipt_profiles_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT receipt_profiles_paper_ck CHECK (paper_width_mm IN (58, 80)),
    CONSTRAINT receipt_profiles_len_ck CHECK (
        coalesce(length(business_name), 0) <= 80 AND coalesce(length(address), 0) <= 200
        AND coalesce(length(phone), 0) <= 30 AND coalesce(length(header_text), 0) <= 200
        AND coalesce(length(footer_text), 0) <= 200 AND coalesce(length(tax_id), 0) <= 40)
);
CREATE UNIQUE INDEX receipt_profiles_scope_uk ON pos.receipt_profiles
    (organization_id, coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid));

GRANT SELECT ON pos.product_option_groups, pos.product_options, pos.product_option_links,
    pos.discount_presets, pos.receipt_profiles TO pos_app_user;
ALTER TABLE pos.product_option_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.product_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.product_option_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.discount_presets ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.receipt_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY option_groups_select ON pos.product_option_groups FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
CREATE POLICY product_options_select ON pos.product_options FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
CREATE POLICY option_links_select ON pos.product_option_links FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.products p WHERE p.id = product_id AND p.organization_id = pos.current_org_id()));
CREATE POLICY discount_presets_select ON pos.discount_presets FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id() AND (outlet_id IS NULL OR pos.can_access_outlet(outlet_id)));
CREATE POLICY receipt_profiles_select ON pos.receipt_profiles FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id() AND (outlet_id IS NULL OR pos.can_access_outlet(outlet_id)));

-- ---------------------------------------------------------------- guard baris penjualan & cek stok
-- (versi V012 + opsi produk; produk tanpa stok dilewati)
CREATE OR REPLACE FUNCTION pos.tg_sale_item_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale    pos.sales%ROWTYPE;
    v_product pos.products%ROWTYPE;
    v_price   record;
    v_rate    numeric;
    v_appr    pos.approvals%ROWTYPE;
    v_need    boolean;
    v_delta   numeric := 0;
    v_g       record;
    v_n       integer;
BEGIN
    v_sale := pos.assert_sale_editable(NEW.sale_id);

    IF TG_OP = 'INSERT' THEN
        SELECT * INTO v_product FROM pos.products p WHERE p.id = NEW.product_id;
        IF v_product.id IS NULL OR v_product.organization_id <> v_sale.organization_id OR NOT v_product.active THEN
            RAISE EXCEPTION 'PRODUCT_NOT_AVAILABLE: product % cannot be sold', NEW.product_id USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_price FROM pos.product_price(NEW.product_id, v_sale.outlet_id, now());
        IF v_price.price_id IS NULL THEN
            RAISE EXCEPTION 'PRICE_NOT_FOUND: no valid price for %', v_product.sku USING ERRCODE = 'P0001';
        END IF;
        SELECT t.rate INTO v_rate FROM pos.tax_rates t WHERE t.id = v_product.tax_rate_id AND t.active;
        NEW.line_no := coalesce((SELECT max(si.line_no) FROM pos.sale_items si WHERE si.sale_id = NEW.sale_id), 0) + 1;
        NEW.sku := v_product.sku;
        NEW.product_name := v_product.name;
        NEW.uom := v_product.uom;
        NEW.tax_rate_id := v_product.tax_rate_id;
        NEW.tax_rate := coalesce(v_rate, 0);
        -- Opsi produk (mis. level pedas, topping): dipilih dari daftar opsi produk ini, harga tambahan
        -- diambil dari database dan disimpan sebagai snapshot di baris.
        v_delta := 0;
        FOR v_g IN
            SELECT g.id, g.name, g.min_select, g.max_select
            FROM pos.product_option_links l JOIN pos.product_option_groups g ON g.id = l.group_id
            WHERE l.product_id = NEW.product_id AND g.active
        LOOP
            SELECT count(*) INTO v_n FROM pos.product_options o
            WHERE o.group_id = v_g.id AND o.active AND o.id = ANY (NEW.option_ids);
            IF v_n < v_g.min_select OR v_n > v_g.max_select THEN
                RAISE EXCEPTION 'OPTION_SELECTION_INVALID: pilihan "%" harus % sampai % opsi', v_g.name, v_g.min_select, v_g.max_select
                    USING ERRCODE = 'P0001';
            END IF;
        END LOOP;
        SELECT coalesce(sum(o.price_delta), 0), count(*),
               coalesce(jsonb_agg(jsonb_build_object('group', g.name, 'name', o.name, 'delta', o.price_delta)
                                  ORDER BY g.sort_order, g.name, o.sort_order, o.name), '[]'::jsonb)
          INTO v_delta, v_n, NEW.options
        FROM pos.product_options o
        JOIN pos.product_option_groups g ON g.id = o.group_id AND g.active
        JOIN pos.product_option_links l ON l.group_id = g.id AND l.product_id = NEW.product_id
        WHERE o.active AND o.id = ANY (NEW.option_ids);
        IF v_n <> coalesce(cardinality(NEW.option_ids), 0) THEN
            RAISE EXCEPTION 'OPTION_SELECTION_INVALID: opsi tidak berlaku untuk produk ini' USING ERRCODE = 'P0001';
        END IF;
        NEW.list_price := v_price.price + v_delta;
        NEW.unit_price := v_price.price + v_delta;   -- ubah harga hanya lewat override yang disetujui
        NEW.price_id := v_price.price_id;
        NEW.price_version := v_price.version;
        NEW.price_source := v_price.source;
        NEW.price_override_reason := NULL; NEW.price_override_by := NULL;
        NEW.price_override_approved_by := NULL; NEW.price_override_approval_id := NULL;
        NEW.item_discount_amount := 0;
        NEW.cart_discount_amount := 0;
        NEW.status := 'ACTIVE';
        NEW.void_reason := NULL; NEW.voided_by := NULL; NEW.voided_at := NULL;
        NEW.created_at := now();
        NEW.version := 0;
        IF NOT v_product.allow_decimal_qty AND NEW.quantity <> trunc(NEW.quantity) THEN
            RAISE EXCEPTION 'QUANTITY_INVALID: % is sold in whole units', v_product.sku USING ERRCODE = 'P0001';
        END IF;
    ELSE
        IF OLD.status = 'VOID' THEN
            RAISE EXCEPTION 'SALE_ITEM_VOID: line % is void', OLD.line_no USING ERRCODE = 'P0001';
        END IF;
        IF NEW.sale_id <> OLD.sale_id OR NEW.product_id <> OLD.product_id OR NEW.line_no <> OLD.line_no
           OR NEW.sku <> OLD.sku OR NEW.product_name <> OLD.product_name OR NEW.uom <> OLD.uom
           OR NEW.list_price <> OLD.list_price OR NEW.price_id IS DISTINCT FROM OLD.price_id
           OR NEW.price_version IS DISTINCT FROM OLD.price_version
           OR NEW.tax_rate <> OLD.tax_rate OR NEW.tax_rate_id IS DISTINCT FROM OLD.tax_rate_id
           OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at
           OR NEW.barcode IS DISTINCT FROM OLD.barcode
           OR NEW.option_ids IS DISTINCT FROM OLD.option_ids OR NEW.options IS DISTINCT FROM OLD.options THEN
            RAISE EXCEPTION 'SALE_ITEM_IMMUTABLE_FIELD' USING ERRCODE = 'P0001';
        END IF;
        SELECT p.allow_decimal_qty INTO v_product.allow_decimal_qty FROM pos.products p WHERE p.id = OLD.product_id;
        IF NOT v_product.allow_decimal_qty AND NEW.quantity <> trunc(NEW.quantity) THEN
            RAISE EXCEPTION 'QUANTITY_INVALID: % is sold in whole units', OLD.sku USING ERRCODE = 'P0001';
        END IF;

        -- Ubah harga (§18 "change price jika authorized", §20 "tidak boleh mengubah harga secara silent")
        IF NEW.unit_price <> OLD.unit_price
           OR NEW.price_override_approval_id IS DISTINCT FROM OLD.price_override_approval_id THEN
            IF NEW.unit_price = NEW.list_price THEN
                NEW.price_override_reason := NULL; NEW.price_override_by := NULL;
                NEW.price_override_approved_by := NULL; NEW.price_override_approval_id := NULL;
            ELSE
                IF pg_catalog.length(btrim(coalesce(NEW.price_override_reason, ''))) < 3 THEN
                    RAISE EXCEPTION 'PRICE_OVERRIDE_REASON_REQUIRED' USING ERRCODE = 'P0001';
                END IF;
                NEW.price_override_by := pos.current_app_user_id();
                v_need := coalesce((pos.get_setting('require_supervisor_for_price_override', v_sale.outlet_id))::boolean, true)
                          OR NOT pos.has_permission('sale.price_override', v_sale.outlet_id);
                IF v_need THEN
                    SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.price_override_approval_id;
                    IF v_appr.id IS NULL OR v_appr.action <> 'PRICE_OVERRIDE' OR v_appr.sale_id <> NEW.sale_id
                       OR v_appr.sale_item_id IS DISTINCT FROM NEW.id OR v_appr.price <> NEW.unit_price
                       OR v_appr.used_at IS NULL OR v_appr.approved_by IS DISTINCT FROM NEW.price_override_approved_by THEN
                        RAISE EXCEPTION 'APPROVAL_REQUIRED: price change needs supervisor approval' USING ERRCODE = 'P0001';
                    END IF;
                ELSE
                    NEW.price_override_approved_by := NULL;
                    NEW.price_override_approval_id := NULL;
                END IF;
            END IF;
        ELSIF NEW.price_override_reason IS DISTINCT FROM OLD.price_override_reason
           OR NEW.price_override_by IS DISTINCT FROM OLD.price_override_by
           OR NEW.price_override_approved_by IS DISTINCT FROM OLD.price_override_approved_by THEN
            RAISE EXCEPTION 'SALE_ITEM_IMMUTABLE_FIELD: override fields change only with the price' USING ERRCODE = 'P0001';
        END IF;

        IF NEW.status = 'VOID' THEN
            NEW.voided_at := now();
            NEW.voided_by := pos.current_app_user_id();
            NEW.item_discount_amount := 0;
            NEW.cart_discount_amount := 0;
        ELSIF NEW.void_reason IS NOT NULL OR NEW.voided_by IS NOT NULL THEN
            RAISE EXCEPTION 'SALE_ITEM_IMMUTABLE_FIELD: void fields only when voiding' USING ERRCODE = 'P0001';
        END IF;
        NEW.version := OLD.version + 1;
    END IF;

    -- Turunan dihitung database (§63 validate price).
    NEW.gross_amount := pos.money_round(NEW.quantity * NEW.unit_price);
    NEW.net_amount := NEW.gross_amount - NEW.item_discount_amount - NEW.cart_discount_amount;
    IF NEW.net_amount < 0 THEN
        RAISE EXCEPTION 'DISCOUNT_ALLOCATION_INVALID: discount larger than line amount' USING ERRCODE = 'P0001';
    END IF;
    NEW.tax_amount := CASE WHEN v_sale.prices_include_tax
                           THEN pos.money_round(NEW.net_amount * NEW.tax_rate / (100 + NEW.tax_rate))
                           ELSE pos.money_round(NEW.net_amount * NEW.tax_rate / 100) END;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

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
    FOR r IN
        SELECT si.product_id, p.sku, p.allow_negative_stock, p.track_stock, sum(si.quantity) AS qty
        FROM pos.sale_items si JOIN pos.products p ON p.id = si.product_id
        WHERE si.sale_id = p_sale AND si.status = 'ACTIVE'
        GROUP BY si.product_id, p.sku, p.allow_negative_stock, p.track_stock
        ORDER BY si.product_id
    LOOP
        -- serialisasi checkout produk yang sama di outlet yang sama (urutan tetap: tanpa deadlock)
        PERFORM pg_advisory_xact_lock(hashtextextended(r.product_id::text || ':' || p_outlet::text, 0));
        v_allow := coalesce(r.allow_negative_stock, v_outlet_allow, false);
        -- produk tanpa stok (makanan/minuman, jasa) tidak dicek stoknya
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

-- ---------------------------------------------------------------- kategori & pajak
CREATE OR REPLACE FUNCTION pos.save_category(p_id uuid, p_code text, p_name text, p_active boolean DEFAULT true)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_row pos.product_categories%ROWTYPE;
    v_id  uuid;
BEGIN
    PERFORM pos.require_perm('category.manage');
    IF p_code IS NULL OR p_code !~ '^[A-Za-z0-9._-]{1,30}$' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kode kategori 1-30 karakter (huruf, angka, . _ -)' USING ERRCODE = 'P0001';
    END IF;
    IF p_name IS NULL OR pg_catalog.length(btrim(p_name)) NOT BETWEEN 1 AND 60 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nama kategori 1-60 karakter' USING ERRCODE = 'P0001';
    END IF;
    IF p_id IS NULL THEN
        INSERT INTO pos.product_categories (organization_id, code, name, active, source)
        VALUES (v_org, p_code, btrim(p_name), coalesce(p_active, true), 'LOCAL')
        RETURNING id INTO v_id;
        RETURN v_id;
    END IF;
    SELECT * INTO v_row FROM pos.product_categories WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: kategori' USING ERRCODE = 'P0001';
    END IF;
    IF v_row.source = 'OPENBRAVO' THEN
        RAISE EXCEPTION 'CATALOG_READ_ONLY: kategori berasal dari Openbravo' USING ERRCODE = 'P0001';
    END IF;
    UPDATE pos.product_categories SET code = p_code, name = btrim(p_name), active = coalesce(p_active, true),
           updated_at = now()
     WHERE id = p_id;
    RETURN p_id;
END
$$;

CREATE OR REPLACE FUNCTION pos.save_tax_rate(p_id uuid, p_code text, p_name text, p_rate numeric, p_active boolean DEFAULT true)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_row pos.tax_rates%ROWTYPE;
    v_id  uuid;
BEGIN
    PERFORM pos.require_perm('product.manage');
    IF p_code IS NULL OR p_code !~ '^[A-Za-z0-9._-]{1,30}$' OR p_name IS NULL
       OR pg_catalog.length(btrim(p_name)) NOT BETWEEN 1 AND 60 OR p_rate IS NULL OR p_rate < 0 OR p_rate > 100 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kode, nama, dan tarif pajak (0-100) wajib valid' USING ERRCODE = 'P0001';
    END IF;
    IF p_id IS NULL THEN
        INSERT INTO pos.tax_rates (organization_id, code, name, rate, active, source)
        VALUES (v_org, p_code, btrim(p_name), p_rate, coalesce(p_active, true), 'LOCAL')
        RETURNING id INTO v_id;
        RETURN v_id;
    END IF;
    SELECT * INTO v_row FROM pos.tax_rates WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: pajak' USING ERRCODE = 'P0001';
    END IF;
    IF v_row.source = 'OPENBRAVO' THEN
        RAISE EXCEPTION 'CATALOG_READ_ONLY: pajak berasal dari Openbravo' USING ERRCODE = 'P0001';
    END IF;
    UPDATE pos.tax_rates SET code = p_code, name = btrim(p_name), rate = p_rate, active = coalesce(p_active, true),
           updated_at = now()
     WHERE id = p_id;
    RETURN p_id;
END
$$;

-- ---------------------------------------------------------------- produk
-- p_price NULL = harga tidak diubah; p_barcode NULL = tidak diubah, '' = hapus barcode utama.
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
               image_url = nullif(btrim(p_image), ''), updated_at = now(), version = version + 1
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

-- Stok awal / penyesuaian untuk produk lokal yang dilacak stoknya: stok tersedia menjadi p_qty.
CREATE OR REPLACE FUNCTION pos.set_local_stock(p_product uuid, p_outlet uuid, p_qty numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org       uuid := pos.current_org_id();
    v_prod      pos.products%ROWTYPE;
    v_wh        uuid;
    v_reserved  numeric;
    v_other     numeric;
BEGIN
    PERFORM pos.require_perm('product.manage', p_outlet);
    IF p_qty IS NULL OR p_qty < 0 OR p_qty > 100000000 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: jumlah stok tidak valid' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_prod FROM pos.products WHERE id = p_product AND organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: produk' USING ERRCODE = 'P0001';
    END IF;
    IF v_prod.source = 'OPENBRAVO' THEN
        RAISE EXCEPTION 'CATALOG_READ_ONLY: stok produk Openbravo dikelola di Openbravo' USING ERRCODE = 'P0001';
    END IF;
    SELECT coalesce(o.default_warehouse_id,
                    (SELECT w.id FROM pos.warehouses w WHERE w.outlet_id = o.id AND w.active ORDER BY w.code LIMIT 1))
      INTO v_wh FROM pos.outlets o WHERE o.id = p_outlet AND o.organization_id = v_org;
    IF v_wh IS NULL THEN
        RAISE EXCEPTION 'CATALOG_INVALID: outlet belum punya warehouse' USING ERRCODE = 'P0001';
    END IF;
    -- penjualan yang belum tercermin di snapshot tetap mengurangi stok tersedia (lihat available_to_sell)
    SELECT coalesce(sum(si.quantity), 0) INTO v_reserved
      FROM pos.sale_items si JOIN pos.sales s ON s.id = si.sale_id
     WHERE si.product_id = p_product AND si.status = 'ACTIVE' AND s.outlet_id = p_outlet
       AND s.status IN ('CHECKOUT', 'PAYMENT_PENDING', 'PAID', 'POSTING') AND s.sync_status <> 'SYNCED';
    SELECT coalesce(sum(sc.available_quantity), 0) INTO v_other
      FROM pos.product_stock_cache sc JOIN pos.warehouses w ON w.id = sc.warehouse_id
     WHERE sc.product_id = p_product AND w.outlet_id = p_outlet AND sc.warehouse_id <> v_wh;
    INSERT INTO pos.product_stock_cache (organization_id, product_id, warehouse_id, quantity, available_quantity, source, synced_at)
    VALUES (v_org, p_product, v_wh, p_qty + v_reserved - v_other, p_qty + v_reserved - v_other, 'LOCAL', now())
    ON CONFLICT (product_id, warehouse_id) DO UPDATE
        SET quantity = EXCLUDED.quantity, available_quantity = EXCLUDED.available_quantity,
            source = 'LOCAL', synced_at = EXCLUDED.synced_at;
END
$$;

-- ---------------------------------------------------------------- opsi produk
CREATE OR REPLACE FUNCTION pos.save_option_group(p_id uuid, p_name text, p_min integer, p_max integer, p_sort integer, p_active boolean DEFAULT true)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_id  uuid;
BEGIN
    PERFORM pos.require_perm('product.manage');
    IF p_name IS NULL OR pg_catalog.length(btrim(p_name)) NOT BETWEEN 1 AND 60
       OR coalesce(p_min, 0) < 0 OR coalesce(p_max, 1) < 1 OR coalesce(p_max, 1) > 20 OR coalesce(p_min, 0) > coalesce(p_max, 1) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nama 1-60 karakter, min 0+, max 1-20, min tidak lebih dari max' USING ERRCODE = 'P0001';
    END IF;
    IF p_id IS NULL THEN
        INSERT INTO pos.product_option_groups (organization_id, name, min_select, max_select, sort_order, active)
        VALUES (v_org, btrim(p_name), coalesce(p_min, 0), coalesce(p_max, 1), coalesce(p_sort, 0), coalesce(p_active, true))
        RETURNING id INTO v_id;
        RETURN v_id;
    END IF;
    UPDATE pos.product_option_groups SET name = btrim(p_name), min_select = coalesce(p_min, 0), max_select = coalesce(p_max, 1),
           sort_order = coalesce(p_sort, 0), active = coalesce(p_active, true), updated_at = now()
     WHERE id = p_id AND organization_id = v_org RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: grup opsi' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION pos.save_option(p_id uuid, p_group uuid, p_name text, p_delta numeric, p_sort integer, p_active boolean DEFAULT true)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_id  uuid;
BEGIN
    PERFORM pos.require_perm('product.manage');
    IF p_name IS NULL OR pg_catalog.length(btrim(p_name)) NOT BETWEEN 1 AND 60 OR p_delta IS NULL OR p_delta < 0 OR p_delta > 100000000 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nama 1-60 karakter dan harga tambahan 0 atau lebih' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pos.product_option_groups g WHERE g.id = p_group AND g.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: grup opsi' USING ERRCODE = 'P0001';
    END IF;
    IF p_id IS NULL THEN
        INSERT INTO pos.product_options (organization_id, group_id, name, price_delta, sort_order, active)
        VALUES (v_org, p_group, btrim(p_name), p_delta, coalesce(p_sort, 0), coalesce(p_active, true))
        RETURNING id INTO v_id;
        RETURN v_id;
    END IF;
    UPDATE pos.product_options SET name = btrim(p_name), price_delta = p_delta, sort_order = coalesce(p_sort, 0),
           active = coalesce(p_active, true), updated_at = now()
     WHERE id = p_id AND organization_id = v_org AND group_id = p_group RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: opsi' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_id;
END
$$;

-- Mengganti daftar grup opsi milik produk (urutan array = urutan tampil).
CREATE OR REPLACE FUNCTION pos.set_product_options(p_product uuid, p_groups uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
BEGIN
    PERFORM pos.require_perm('product.manage');
    IF NOT EXISTS (SELECT 1 FROM pos.products p WHERE p.id = p_product AND p.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: produk' USING ERRCODE = 'P0001';
    END IF;
    p_groups := coalesce(p_groups, '{}');
    IF (SELECT count(*) FROM pos.product_option_groups g WHERE g.organization_id = v_org AND g.id = ANY (p_groups))
       <> (SELECT count(DISTINCT x) FROM unnest(p_groups) x) THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: grup opsi' USING ERRCODE = 'P0001';
    END IF;
    DELETE FROM pos.product_option_links WHERE product_id = p_product;
    INSERT INTO pos.product_option_links (product_id, group_id, sort_order)
    SELECT p_product, g, min(ord)::integer FROM unnest(p_groups) WITH ORDINALITY AS t(g, ord) GROUP BY g;
END
$$;

-- ---------------------------------------------------------------- preset diskon
CREATE OR REPLACE FUNCTION pos.save_discount_preset(p_id uuid, p_outlet uuid, p_name text, p_type text, p_value numeric, p_active boolean DEFAULT true)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_row pos.discount_presets%ROWTYPE;
    v_id  uuid;
BEGIN
    IF p_id IS NOT NULL THEN
        SELECT * INTO v_row FROM pos.discount_presets WHERE id = p_id AND organization_id = v_org FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CATALOG_NOT_FOUND: diskon' USING ERRCODE = 'P0001';
        END IF;
        p_outlet := v_row.outlet_id;   -- cakupan tidak bisa dipindah
    END IF;
    PERFORM pos.require_perm('discount.manage', p_outlet);
    IF p_name IS NULL OR pg_catalog.length(btrim(p_name)) NOT BETWEEN 3 AND 60 OR p_type NOT IN ('PERCENTAGE', 'AMOUNT')
       OR p_value IS NULL OR p_value <= 0 OR (p_type = 'PERCENTAGE' AND p_value > 100) OR p_value > 1000000000 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nama 3-60 karakter, jenis, dan nilai diskon wajib valid' USING ERRCODE = 'P0001';
    END IF;
    IF p_id IS NULL THEN
        INSERT INTO pos.discount_presets (organization_id, outlet_id, name, discount_type, discount_value, active)
        VALUES (v_org, p_outlet, btrim(p_name), p_type, p_value, coalesce(p_active, true))
        RETURNING id INTO v_id;
        RETURN v_id;
    END IF;
    UPDATE pos.discount_presets SET name = btrim(p_name), discount_type = p_type, discount_value = p_value,
           active = coalesce(p_active, true), updated_at = now()
     WHERE id = p_id;
    RETURN p_id;
END
$$;

-- ---------------------------------------------------------------- profil struk
CREATE OR REPLACE FUNCTION pos.save_receipt_profile(
    p_outlet uuid, p_business_name text, p_address text, p_phone text, p_header text, p_footer text,
    p_tax_id text, p_show_tax boolean, p_show_cashier boolean, p_paper integer)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_id  uuid;
BEGIN
    PERFORM pos.require_perm('receipt.manage', p_outlet);
    IF p_outlet IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pos.outlets o WHERE o.id = p_outlet AND o.organization_id = v_org) THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: outlet' USING ERRCODE = 'P0001';
    END IF;
    IF coalesce(p_paper, 80) NOT IN (58, 80) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: lebar kertas 58 atau 80 mm' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.receipt_profiles AS r (organization_id, outlet_id, business_name, address, phone, header_text, footer_text,
                                           tax_id, show_tax_detail, show_cashier, paper_width_mm)
    VALUES (v_org, p_outlet, nullif(btrim(p_business_name), ''), nullif(btrim(p_address), ''), nullif(btrim(p_phone), ''),
            nullif(btrim(p_header), ''), nullif(btrim(p_footer), ''), nullif(btrim(p_tax_id), ''),
            coalesce(p_show_tax, true), coalesce(p_show_cashier, true), coalesce(p_paper, 80))
    ON CONFLICT (organization_id, coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid)) DO UPDATE
        SET business_name = EXCLUDED.business_name, address = EXCLUDED.address, phone = EXCLUDED.phone,
            header_text = EXCLUDED.header_text, footer_text = EXCLUDED.footer_text, tax_id = EXCLUDED.tax_id,
            show_tax_detail = EXCLUDED.show_tax_detail, show_cashier = EXCLUDED.show_cashier,
            paper_width_mm = EXCLUDED.paper_width_mm, updated_at = now()
    RETURNING r.id INTO v_id;
    RETURN v_id;
END
$$;

REVOKE ALL ON FUNCTION pos.save_category(uuid, text, text, boolean), pos.save_tax_rate(uuid, text, text, numeric, boolean),
    pos.save_product(uuid, text, text, uuid, text, boolean, uuid, boolean, boolean, text, text, numeric),
    pos.set_local_stock(uuid, uuid, numeric), pos.save_option_group(uuid, text, integer, integer, integer, boolean),
    pos.save_option(uuid, uuid, text, numeric, integer, boolean), pos.set_product_options(uuid, uuid[]),
    pos.save_discount_preset(uuid, uuid, text, text, numeric, boolean),
    pos.save_receipt_profile(uuid, text, text, text, text, text, text, boolean, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.save_category(uuid, text, text, boolean), pos.save_tax_rate(uuid, text, text, numeric, boolean),
    pos.save_product(uuid, text, text, uuid, text, boolean, uuid, boolean, boolean, text, text, numeric),
    pos.set_local_stock(uuid, uuid, numeric), pos.save_option_group(uuid, text, integer, integer, integer, boolean),
    pos.save_option(uuid, uuid, text, numeric, integer, boolean), pos.set_product_options(uuid, uuid[]),
    pos.save_discount_preset(uuid, uuid, text, text, numeric, boolean),
    pos.save_receipt_profile(uuid, text, text, text, text, text, text, boolean, boolean, integer) TO pos_app_user;
