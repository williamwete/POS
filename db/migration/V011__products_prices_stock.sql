-- V011: master produk, harga & stok sebagai CACHE dari Openbravo (§3, §16, §17, §33)
--
-- Prinsip:
--  * Openbravo adalah system of record. Tabel di sini hanya cache yang ditulis job sync
--    (role pos_system, Phase 9) atau seed. User aplikasi hanya membaca.
--  * Harga & stok TIDAK pernah dikirim client; transaksi mengambil harga dari
--    pos.product_price() dan stok dari pos.available_to_sell() di database.
--  * Stok tampilan = snapshot Openbravo − penjualan lokal yang belum tercermin di snapshot
--    (ASSUMPTIONS A6). Snapshot tidak pernah dikurangi langsung.

CREATE TABLE pos.tax_rates (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid         NOT NULL REFERENCES pos.organizations (id),
    code               text         NOT NULL,
    name               text         NOT NULL,
    rate               numeric(6,3) NOT NULL,
    openbravo_tax_id   text,
    active             boolean      NOT NULL DEFAULT true,
    synced_at          timestamptz,
    created_at         timestamptz  NOT NULL DEFAULT now(),
    updated_at         timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT tax_rates_rate_ck CHECK (rate >= 0 AND rate <= 100),
    CONSTRAINT tax_rates_org_code_uk UNIQUE (organization_id, code)
);

CREATE TABLE pos.product_categories (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id         uuid        NOT NULL REFERENCES pos.organizations (id),
    code                    text        NOT NULL,
    name                    text        NOT NULL,
    parent_id               uuid REFERENCES pos.product_categories (id),
    openbravo_category_id   text,
    active                  boolean     NOT NULL DEFAULT true,
    synced_at               timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT product_categories_org_code_uk UNIQUE (organization_id, code)
);

CREATE TABLE pos.products (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id        uuid        NOT NULL REFERENCES pos.organizations (id),
    openbravo_product_id   text,
    sku                    text        NOT NULL,
    name                   text        NOT NULL,
    description            text,
    category_id            uuid REFERENCES pos.product_categories (id),
    uom                    text        NOT NULL DEFAULT 'PCS',
    allow_decimal_qty      boolean     NOT NULL DEFAULT false,
    tax_rate_id            uuid REFERENCES pos.tax_rates (id),
    -- NULL = ikuti setting outlet allow_negative_stock (§33: per outlet/produk)
    allow_negative_stock   boolean,
    active                 boolean     NOT NULL DEFAULT true,
    source                 text        NOT NULL DEFAULT 'OPENBRAVO',
    synced_at              timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    version                integer     NOT NULL DEFAULT 0,
    CONSTRAINT products_org_sku_uk UNIQUE (organization_id, sku),
    CONSTRAINT products_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT products_source_ck CHECK (source IN ('OPENBRAVO', 'SEED'))
);
CREATE UNIQUE INDEX products_org_openbravo_uk ON pos.products (organization_id, openbravo_product_id)
    WHERE openbravo_product_id IS NOT NULL;
CREATE INDEX products_name_idx ON pos.products (organization_id, lower(name) text_pattern_ops);
CREATE INDEX products_category_idx ON pos.products (category_id);

CREATE TABLE pos.product_barcodes (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL,
    product_id       uuid        NOT NULL,
    barcode          text        NOT NULL,
    barcode_type     text        NOT NULL DEFAULT 'EAN13',
    is_primary       boolean     NOT NULL DEFAULT false,
    active           boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT product_barcodes_product_fk FOREIGN KEY (product_id, organization_id)
        REFERENCES pos.products (id, organization_id),
    CONSTRAINT product_barcodes_type_ck CHECK (barcode_type IN ('EAN13', 'EAN8', 'UPC', 'CODE128', 'INTERNAL')),
    CONSTRAINT product_barcodes_value_ck CHECK (barcode ~ '^[A-Za-z0-9._-]{1,64}$')
);
-- Satu barcode menunjuk satu produk dalam organisasi.
CREATE UNIQUE INDEX product_barcodes_org_barcode_uk ON pos.product_barcodes (organization_id, barcode) WHERE active;
CREATE UNIQUE INDEX product_barcodes_primary_uk ON pos.product_barcodes (product_id) WHERE is_primary AND active;

-- Harga dari price list Openbravo (§17). outlet_id NULL = berlaku untuk semua outlet organisasi.
CREATE TABLE pos.product_price_cache (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid          NOT NULL,
    product_id       uuid          NOT NULL,
    outlet_id        uuid,
    price_list_code  text          NOT NULL DEFAULT 'DEFAULT',
    price            numeric(18,2) NOT NULL,
    currency         char(3)       NOT NULL DEFAULT 'IDR',
    source           text          NOT NULL DEFAULT 'OPENBRAVO',
    version          integer       NOT NULL,
    valid_from       timestamptz   NOT NULL,
    valid_to         timestamptz,
    synced_at        timestamptz   NOT NULL DEFAULT now(),
    created_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT price_cache_product_fk FOREIGN KEY (product_id, organization_id)
        REFERENCES pos.products (id, organization_id),
    CONSTRAINT price_cache_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT price_cache_price_ck CHECK (price >= 0),
    CONSTRAINT price_cache_period_ck CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT price_cache_source_ck CHECK (source IN ('OPENBRAVO', 'SEED'))
);
CREATE UNIQUE INDEX price_cache_version_uk
    ON pos.product_price_cache (product_id, coalesce(outlet_id, '00000000-0000-0000-0000-000000000000'::uuid),
                                price_list_code, version);
CREATE INDEX price_cache_lookup_idx ON pos.product_price_cache (product_id, outlet_id, valid_from DESC);

-- Snapshot stok Openbravo per warehouse (§33).
CREATE TABLE pos.product_stock_cache (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id        uuid          NOT NULL,
    product_id             uuid          NOT NULL,
    warehouse_id           uuid          NOT NULL REFERENCES pos.warehouses (id),
    openbravo_product_id   text,
    quantity               numeric(18,3) NOT NULL,
    available_quantity     numeric(18,3) NOT NULL,
    source                 text          NOT NULL DEFAULT 'OPENBRAVO',
    synced_at              timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT stock_cache_product_fk FOREIGN KEY (product_id, organization_id)
        REFERENCES pos.products (id, organization_id),
    CONSTRAINT stock_cache_uk UNIQUE (product_id, warehouse_id),
    CONSTRAINT stock_cache_source_ck CHECK (source IN ('OPENBRAVO', 'SEED'))
);

-- Setting baru (§73): harga sudah termasuk pajak (umum di ritel Indonesia).
INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('prices_include_tax', 'BOOLEAN', 'true', 'Harga jual di price list sudah termasuk pajak (PPN)', 'OUTLET');

-- ---------------------------------------------------------------- harga berlaku
-- Harga yang berlaku untuk produk di outlet pada waktu tertentu: harga khusus outlet lebih dulu,
-- lalu harga organisasi; periode valid; versi terbaru. Satu-satunya sumber harga transaksi.
CREATE OR REPLACE FUNCTION pos.product_price(p_product uuid, p_outlet uuid, p_at timestamptz DEFAULT now())
RETURNS TABLE (price_id uuid, price numeric, version integer, source text, price_list_code text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT c.id, c.price, c.version, c.source, c.price_list_code
    FROM pos.product_price_cache c
    JOIN pos.products p ON p.id = c.product_id
    WHERE c.product_id = p_product
      AND p.organization_id = pos.current_org_id()
      AND (c.outlet_id = p_outlet OR c.outlet_id IS NULL)
      AND c.price_list_code = 'DEFAULT'
      AND c.valid_from <= p_at
      AND (c.valid_to IS NULL OR c.valid_to > p_at)
    ORDER BY (c.outlet_id IS NULL), c.valid_from DESC, c.version DESC
    LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION pos.product_price(uuid, uuid, timestamptz) TO pos_app_user, pos_system;

-- ---------------------------------------------------------------- privileges & RLS
GRANT SELECT ON pos.tax_rates, pos.product_categories, pos.products, pos.product_barcodes,
    pos.product_price_cache, pos.product_stock_cache TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.tax_rates, pos.product_categories, pos.products, pos.product_barcodes,
    pos.product_price_cache, pos.product_stock_cache TO pos_system;

ALTER TABLE pos.tax_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.product_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.product_barcodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.product_price_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.product_stock_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY tax_rates_system_all ON pos.tax_rates TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY product_categories_system_all ON pos.product_categories TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY products_system_all ON pos.products TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY product_barcodes_system_all ON pos.product_barcodes TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY price_cache_system_all ON pos.product_price_cache TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY stock_cache_system_all ON pos.product_stock_cache TO pos_system USING (true) WITH CHECK (true);

CREATE POLICY tax_rates_select ON pos.tax_rates FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
CREATE POLICY product_categories_select ON pos.product_categories FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
CREATE POLICY products_select ON pos.products FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
CREATE POLICY product_barcodes_select ON pos.product_barcodes FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
-- Harga khusus outlet hanya untuk outlet yang dapat diakses.
CREATE POLICY price_cache_select ON pos.product_price_cache FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id() AND (outlet_id IS NULL OR pos.can_access_outlet(outlet_id)));
CREATE POLICY stock_cache_select ON pos.product_stock_cache FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND EXISTS (SELECT 1 FROM pos.warehouses w WHERE w.id = warehouse_id
                       AND (w.outlet_id IS NULL OR pos.can_access_outlet(w.outlet_id))));
