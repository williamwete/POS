-- V012: penjualan — keranjang, diskon, approval, checkout, nomor struk (§15, §18, §20, §26, §27, §30, §31, §63, §66)
--
-- Prinsip:
--  * Harga, pajak, subtotal, total, dan nomor struk dihitung DATABASE. Client hanya mengirim
--    produk, jumlah, dan definisi diskon; backend menghitung alokasi diskon, database
--    menghitung ulang semua turunan dan memvalidasinya saat checkout.
--  * Uang dibulatkan ke satuan rupiah (pos.money_round, ASSUMPTIONS B25).
--  * Penjualan hanya bisa dibuat/diubah oleh pemegang cashier session yang OPEN (tidak terkunci)
--    dan sedang WORKING. Tidak ada DELETE: koreksi = VOID / CANCELLED dengan alasan.
--  * Approval supervisor (diskon di atas batas, ubah harga, void setelah checkout) adalah baris
--    pos.approvals sekali pakai yang diverifikasi database: approver ≠ peminta, punya izin &
--    tingkat (rank) yang cukup di outlet tersebut.
--  * Status bisnis terpisah dari status sync (§100).

CREATE OR REPLACE FUNCTION pos.money_round(p numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT round(p, 0) $$;
GRANT EXECUTE ON FUNCTION pos.money_round(numeric) TO pos_app_user, pos_system;

-- ---------------------------------------------------------------- identitas approver
-- Izin user LAIN di outlet tertentu (dipakai memvalidasi approver; bukan untuk user saat ini).
CREATE OR REPLACE FUNCTION pos.user_has_permission_at(p_user uuid, p_permission text, p_outlet uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM pos.users u
        JOIN pos.organizations o ON o.id = u.organization_id AND o.active
        JOIN pos.outlets ot ON ot.id = p_outlet AND ot.organization_id = u.organization_id
        JOIN pos.user_roles ur ON ur.user_id = u.id
        JOIN pos.role_permissions rp ON rp.role_id = ur.role_id
        WHERE u.id = p_user AND u.active
          AND rp.permission_code = p_permission
          AND (ur.outlet_id IS NULL
               OR (ur.outlet_id = p_outlet
                   AND EXISTS (SELECT 1 FROM pos.user_outlets uo WHERE uo.user_id = u.id AND uo.outlet_id = p_outlet)))
    )
$$;

-- Rank tertinggi role user yang berlaku di outlet (org-wide atau outlet tersebut).
CREATE OR REPLACE FUNCTION pos.user_rank_at(p_user uuid, p_outlet uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT coalesce(max(r.rank), 0)::integer
    FROM pos.user_roles ur
    JOIN pos.roles r ON r.id = ur.role_id
    WHERE ur.user_id = p_user AND (ur.outlet_id IS NULL OR ur.outlet_id = p_outlet)
$$;

-- Pemetaan akun login (sudah diverifikasi password-nya oleh backend) ke user POS aktif di
-- organisasi pemanggil. Tidak membuka data user lain selain nama untuk catatan approval.
CREATE OR REPLACE FUNCTION pos.approver_lookup(p_auth_user uuid)
RETURNS TABLE (user_id uuid, username text, display_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT u.id, u.username, u.display_name
    FROM pos.users u
    WHERE u.auth_user_id = p_auth_user AND u.active AND u.organization_id = pos.current_org_id()
$$;
REVOKE ALL ON FUNCTION pos.user_has_permission_at(uuid, text, uuid), pos.user_rank_at(uuid, uuid),
    pos.approver_lookup(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.approver_lookup(uuid) TO pos_app_user;

-- ---------------------------------------------------------------- tabel
CREATE TABLE pos.sales (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id        uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id              uuid          NOT NULL,
    terminal_id            uuid          NOT NULL,
    cashier_session_id     uuid          NOT NULL REFERENCES pos.cashier_sessions (id),
    employee_id            uuid          NOT NULL,
    created_by             uuid          NOT NULL,
    business_date          date          NOT NULL,
    client_transaction_id  text          NOT NULL,
    receipt_no             text,
    status                 text          NOT NULL DEFAULT 'DRAFT',
    sync_status            text          NOT NULL DEFAULT 'NOT_READY',
    synced_at              timestamptz,
    prices_include_tax     boolean       NOT NULL DEFAULT true,
    line_count             integer       NOT NULL DEFAULT 0,
    item_count             numeric(18,3) NOT NULL DEFAULT 0,
    subtotal               numeric(18,2) NOT NULL DEFAULT 0,
    item_discount_total    numeric(18,2) NOT NULL DEFAULT 0,
    cart_discount_total    numeric(18,2) NOT NULL DEFAULT 0,
    discount_total         numeric(18,2) NOT NULL DEFAULT 0,
    tax_total              numeric(18,2) NOT NULL DEFAULT 0,
    grand_total            numeric(18,2) NOT NULL DEFAULT 0,
    note                   text,
    device_id              text,
    held_at                timestamptz,
    checked_out_at         timestamptz,
    cancelled_at           timestamptz,
    voided_at              timestamptz,
    void_reason            text,
    voided_by              uuid,
    void_approved_by       uuid,
    void_approval_id       uuid,
    created_at             timestamptz   NOT NULL DEFAULT now(),
    updated_at             timestamptz   NOT NULL DEFAULT now(),
    version                integer       NOT NULL DEFAULT 0,
    CONSTRAINT sales_status_ck CHECK (status IN ('DRAFT', 'HELD', 'CHECKOUT', 'PAYMENT_PENDING', 'PAID',
        'POSTING', 'POSTED', 'VOID', 'RETURNED', 'CANCELLED', 'SYNC_ERROR')),
    CONSTRAINT sales_sync_status_ck CHECK (sync_status IN ('NOT_READY', 'PENDING', 'SYNCED', 'FAILED', 'MANUAL_REVIEW')),
    CONSTRAINT sales_outlet_fk FOREIGN KEY (outlet_id, organization_id) REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT sales_terminal_fk FOREIGN KEY (terminal_id, outlet_id) REFERENCES pos.terminals (id, outlet_id),
    CONSTRAINT sales_employee_fk FOREIGN KEY (employee_id, organization_id) REFERENCES pos.employees (id, organization_id),
    CONSTRAINT sales_client_tx_uk UNIQUE (organization_id, client_transaction_id),
    CONSTRAINT sales_client_tx_ck CHECK (client_transaction_id ~ '^[A-Za-z0-9._:-]{8,80}$'),
    CONSTRAINT sales_receipt_uk UNIQUE (receipt_no),
    CONSTRAINT sales_amounts_ck CHECK (subtotal >= 0 AND item_discount_total >= 0 AND cart_discount_total >= 0
        AND discount_total = item_discount_total + cart_discount_total AND tax_total >= 0 AND grand_total >= 0),
    CONSTRAINT sales_void_ck CHECK (status <> 'VOID'
        OR (voided_at IS NOT NULL AND voided_by IS NOT NULL AND pg_catalog.length(btrim(void_reason)) >= 5)),
    CONSTRAINT sales_checkout_receipt_ck CHECK (status IN ('DRAFT', 'HELD', 'CANCELLED') OR status = 'VOID'
        OR receipt_no IS NOT NULL)
);
-- Satu keranjang aktif (DRAFT) per cashier session; transaksi lain harus ditahan dulu (§26).
CREATE UNIQUE INDEX sales_one_draft_per_session_uk ON pos.sales (cashier_session_id) WHERE status = 'DRAFT';
CREATE INDEX sales_business_date_idx ON pos.sales (business_date);
CREATE INDEX sales_outlet_idx ON pos.sales (outlet_id, business_date);
CREATE INDEX sales_terminal_idx ON pos.sales (terminal_id);
CREATE INDEX sales_session_idx ON pos.sales (cashier_session_id);
CREATE INDEX sales_status_idx ON pos.sales (status);

CREATE TABLE pos.sale_items (
    id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sale_id                       uuid          NOT NULL REFERENCES pos.sales (id),
    line_no                       integer       NOT NULL,
    product_id                    uuid          NOT NULL REFERENCES pos.products (id),
    sku                           text          NOT NULL,
    product_name                  text          NOT NULL,
    barcode                       text,
    uom                           text          NOT NULL,
    quantity                      numeric(18,3) NOT NULL,
    list_price                    numeric(18,2) NOT NULL,
    unit_price                    numeric(18,2) NOT NULL,
    price_id                      uuid,
    price_version                 integer,
    price_source                  text,
    price_override_reason         text,
    price_override_by             uuid,
    price_override_approved_by    uuid,
    price_override_approval_id    uuid,
    tax_rate_id                   uuid,
    tax_rate                      numeric(6,3)  NOT NULL DEFAULT 0,
    gross_amount                  numeric(18,2) NOT NULL DEFAULT 0,
    item_discount_amount          numeric(18,2) NOT NULL DEFAULT 0,
    cart_discount_amount          numeric(18,2) NOT NULL DEFAULT 0,
    net_amount                    numeric(18,2) NOT NULL DEFAULT 0,
    tax_amount                    numeric(18,2) NOT NULL DEFAULT 0,
    status                        text          NOT NULL DEFAULT 'ACTIVE',
    void_reason                   text,
    voided_by                     uuid,
    voided_at                     timestamptz,
    created_by                    uuid          NOT NULL,
    created_at                    timestamptz   NOT NULL DEFAULT now(),
    updated_at                    timestamptz   NOT NULL DEFAULT now(),
    version                       integer       NOT NULL DEFAULT 0,
    CONSTRAINT sale_items_line_uk UNIQUE (sale_id, line_no),
    CONSTRAINT sale_items_status_ck CHECK (status IN ('ACTIVE', 'VOID')),
    CONSTRAINT sale_items_qty_ck CHECK (quantity > 0 AND quantity <= 100000),
    CONSTRAINT sale_items_price_ck CHECK (unit_price >= 0 AND list_price >= 0),
    CONSTRAINT sale_items_amounts_ck CHECK (item_discount_amount >= 0 AND cart_discount_amount >= 0
        AND net_amount >= 0 AND tax_amount >= 0),
    CONSTRAINT sale_items_void_ck CHECK (status <> 'VOID'
        OR (voided_at IS NOT NULL AND voided_by IS NOT NULL AND pg_catalog.length(btrim(void_reason)) >= 3))
);
CREATE INDEX sale_items_sale_idx ON pos.sale_items (sale_id);
CREATE INDEX sale_items_product_idx ON pos.sale_items (product_id);

CREATE TABLE pos.sale_discounts (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sale_id          uuid          NOT NULL REFERENCES pos.sales (id),
    sale_item_id     uuid REFERENCES pos.sale_items (id),
    discount_type    text          NOT NULL,
    discount_value   numeric(18,2) NOT NULL,
    amount           numeric(18,2) NOT NULL DEFAULT 0,
    source           text          NOT NULL DEFAULT 'MANUAL',
    reason           text          NOT NULL,
    status           text          NOT NULL DEFAULT 'ACTIVE',
    created_by       uuid          NOT NULL,
    approved_by      uuid,
    approval_id      uuid,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    removed_by       uuid,
    removed_at       timestamptz,
    CONSTRAINT sale_discounts_type_ck CHECK (discount_type IN ('PERCENTAGE', 'AMOUNT')),
    CONSTRAINT sale_discounts_value_ck CHECK (discount_value > 0
        AND (discount_type <> 'PERCENTAGE' OR discount_value <= 100)),
    CONSTRAINT sale_discounts_amount_ck CHECK (amount >= 0),
    CONSTRAINT sale_discounts_source_ck CHECK (source IN ('MANUAL', 'PROMOTION')),
    CONSTRAINT sale_discounts_status_ck CHECK (status IN ('ACTIVE', 'REMOVED')),
    CONSTRAINT sale_discounts_reason_ck CHECK (pg_catalog.length(btrim(reason)) >= 3),
    CONSTRAINT sale_discounts_removed_ck CHECK (status <> 'REMOVED' OR (removed_by IS NOT NULL AND removed_at IS NOT NULL))
);
-- Satu diskon aktif per baris dan satu diskon transaksi aktif (mengganti = hapus lalu tambah).
CREATE UNIQUE INDEX sale_discounts_active_uk ON pos.sale_discounts
    (sale_id, coalesce(sale_item_id, '00000000-0000-0000-0000-000000000000'::uuid)) WHERE status = 'ACTIVE';
CREATE INDEX sale_discounts_sale_idx ON pos.sale_discounts (sale_id);

-- Approval supervisor sekali pakai (§20, §27; audit "APPROVAL" §47).
CREATE TABLE pos.approvals (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id        uuid          NOT NULL,
    sale_id          uuid          NOT NULL REFERENCES pos.sales (id),
    sale_item_id     uuid REFERENCES pos.sale_items (id),
    action           text          NOT NULL,
    max_percent      numeric(6,3),
    price            numeric(18,2),
    requested_by     uuid          NOT NULL,
    approved_by      uuid          NOT NULL,
    approver_rank    integer       NOT NULL DEFAULT 0,
    expires_at       timestamptz   NOT NULL,
    used_at          timestamptz,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT approvals_action_ck CHECK (action IN ('DISCOUNT', 'PRICE_OVERRIDE', 'VOID_SALE')),
    CONSTRAINT approvals_distinct_ck CHECK (requested_by <> approved_by),
    CONSTRAINT approvals_discount_ck CHECK (action <> 'DISCOUNT' OR (max_percent > 0 AND max_percent <= 100)),
    CONSTRAINT approvals_price_ck CHECK (action <> 'PRICE_OVERRIDE' OR (price >= 0 AND sale_item_id IS NOT NULL))
);
CREATE INDEX approvals_sale_idx ON pos.approvals (sale_id);

CREATE TABLE pos.receipts (
    sale_id          uuid PRIMARY KEY REFERENCES pos.sales (id),
    receipt_no       text        NOT NULL UNIQUE,
    issued_at        timestamptz NOT NULL DEFAULT now(),
    print_count      integer     NOT NULL DEFAULT 0,
    last_printed_at  timestamptz,
    last_printed_by  uuid
);

-- Nomor urut struk per terminal per business date (online). Blok untuk offline: Phase 10 (A4).
CREATE TABLE pos.terminal_receipt_sequences (
    terminal_id    uuid    NOT NULL REFERENCES pos.terminals (id),
    business_date  date    NOT NULL,
    last_no        integer NOT NULL,
    PRIMARY KEY (terminal_id, business_date)
);

-- ---------------------------------------------------------------- stok tersedia (A6)
-- Snapshot Openbravo di gudang outlet − penjualan lokal yang belum tercermin di snapshot.
-- NULL = tidak ada snapshot (stok tidak diketahui). VOLATILE agar membaca data terbaru setelah lock.
CREATE OR REPLACE FUNCTION pos.available_to_sell(p_product uuid, p_outlet uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_qty      numeric;
    v_synced   timestamptz;
    v_reserved numeric;
BEGIN
    SELECT sum(sc.available_quantity), max(sc.synced_at) INTO v_qty, v_synced
    FROM pos.product_stock_cache sc
    JOIN pos.warehouses w ON w.id = sc.warehouse_id
    WHERE sc.product_id = p_product AND w.outlet_id = p_outlet;
    IF v_qty IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT coalesce(sum(si.quantity), 0) INTO v_reserved
    FROM pos.sale_items si
    JOIN pos.sales s ON s.id = si.sale_id
    WHERE si.product_id = p_product AND si.status = 'ACTIVE'
      AND s.outlet_id = p_outlet
      AND s.status IN ('CHECKOUT', 'PAYMENT_PENDING', 'PAID', 'POSTING')
      AND (s.sync_status <> 'SYNCED' OR s.synced_at > v_synced);
    RETURN v_qty - v_reserved;
END
$$;
REVOKE ALL ON FUNCTION pos.available_to_sell(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.available_to_sell(uuid, uuid) TO pos_app_user, pos_system;

-- Validasi stok saat checkout (§15 VALIDATE STOCK, §33 ALLOW_NEGATIVE_STOCK).
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
        SELECT si.product_id, p.sku, p.allow_negative_stock, sum(si.quantity) AS qty
        FROM pos.sale_items si JOIN pos.products p ON p.id = si.product_id
        WHERE si.sale_id = p_sale AND si.status = 'ACTIVE'
        GROUP BY si.product_id, p.sku, p.allow_negative_stock
        ORDER BY si.product_id
    LOOP
        -- serialisasi checkout produk yang sama di outlet yang sama (urutan tetap: tanpa deadlock)
        PERFORM pg_advisory_xact_lock(hashtextextended(r.product_id::text || ':' || p_outlet::text, 0));
        v_allow := coalesce(r.allow_negative_stock, v_outlet_allow, false);
        IF v_allow THEN
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

-- Validasi diskon & approval saat checkout (§20). Batas dari setting outlet.
CREATE OR REPLACE FUNCTION pos.sale_discount_check(p_sale uuid, p_outlet uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    d             record;
    v_base        numeric;
    v_expected    numeric;
    v_cashier_max numeric := coalesce((pos.get_setting('max_cashier_discount', p_outlet))::numeric, 0);
    v_manager_max numeric := coalesce((pos.get_setting('max_manager_discount', p_outlet))::numeric, 0);
    v_appr        pos.approvals%ROWTYPE;
    v_alloc       numeric;
BEGIN
    -- alokasi per baris harus sama dengan diskon aktifnya
    IF EXISTS (
        SELECT 1 FROM pos.sale_items si
        WHERE si.sale_id = p_sale AND si.status = 'ACTIVE'
          AND si.item_discount_amount <> coalesce((SELECT sum(x.amount) FROM pos.sale_discounts x
                                                   WHERE x.sale_item_id = si.id AND x.status = 'ACTIVE'), 0)
    ) THEN
        RAISE EXCEPTION 'DISCOUNT_ALLOCATION_INVALID: item discount mismatch' USING ERRCODE = 'P0001';
    END IF;
    SELECT coalesce(sum(si.cart_discount_amount), 0) INTO v_alloc
    FROM pos.sale_items si WHERE si.sale_id = p_sale AND si.status = 'ACTIVE';
    IF v_alloc <> coalesce((SELECT sum(x.amount) FROM pos.sale_discounts x
                            WHERE x.sale_id = p_sale AND x.sale_item_id IS NULL AND x.status = 'ACTIVE'), 0) THEN
        RAISE EXCEPTION 'DISCOUNT_ALLOCATION_INVALID: cart discount allocation mismatch' USING ERRCODE = 'P0001';
    END IF;

    FOR d IN SELECT * FROM pos.sale_discounts x WHERE x.sale_id = p_sale AND x.status = 'ACTIVE' LOOP
        IF d.sale_item_id IS NOT NULL THEN
            SELECT si.gross_amount INTO v_base FROM pos.sale_items si
            WHERE si.id = d.sale_item_id AND si.status = 'ACTIVE';
            IF v_base IS NULL THEN
                RAISE EXCEPTION 'DISCOUNT_ALLOCATION_INVALID: discount on voided line' USING ERRCODE = 'P0001';
            END IF;
        ELSE
            SELECT coalesce(sum(si.gross_amount - si.item_discount_amount), 0) INTO v_base
            FROM pos.sale_items si WHERE si.sale_id = p_sale AND si.status = 'ACTIVE';
        END IF;
        v_expected := CASE WHEN d.discount_type = 'PERCENTAGE' THEN pos.money_round(v_base * d.discount_value / 100)
                           ELSE least(d.discount_value, v_base) END;
        IF d.amount <> v_expected THEN
            RAISE EXCEPTION 'DISCOUNT_ALLOCATION_INVALID: discount % amount % expected %', d.id, d.amount, v_expected
                USING ERRCODE = 'P0001';
        END IF;
        IF d.amount <= pos.money_round(v_base * v_cashier_max / 100) THEN
            CONTINUE;
        END IF;
        IF d.amount > pos.money_round(v_base * v_manager_max / 100) THEN
            RAISE EXCEPTION 'DISCOUNT_LIMIT_EXCEEDED: discount above maximum' USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = d.approval_id;
        IF v_appr.id IS NULL OR v_appr.action <> 'DISCOUNT' OR v_appr.sale_id <> p_sale OR v_appr.used_at IS NULL
           OR v_appr.approved_by IS DISTINCT FROM d.approved_by
           OR d.amount > pos.money_round(v_base * v_appr.max_percent / 100) THEN
            RAISE EXCEPTION 'APPROVAL_REQUIRED: discount % needs supervisor approval', d.id USING ERRCODE = 'P0001';
        END IF;
    END LOOP;
END
$$;

-- Alokasi nomor struk: <kode terminal>-<YYYYMMDD business date>-<urut 6 digit> (§31).
CREATE OR REPLACE FUNCTION pos.allocate_receipt_no(p_terminal uuid, p_business_date date)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_no   integer;
    v_code text;
BEGIN
    INSERT INTO pos.terminal_receipt_sequences AS s (terminal_id, business_date, last_no)
    VALUES (p_terminal, p_business_date, 1)
    ON CONFLICT (terminal_id, business_date) DO UPDATE SET last_no = s.last_no + 1
    RETURNING last_no INTO v_no;
    SELECT t.code INTO v_code FROM pos.terminals t WHERE t.id = p_terminal;
    RETURN v_code || '-' || to_char(p_business_date, 'YYYYMMDD') || '-' || lpad(v_no::text, 6, '0');
END
$$;
REVOKE ALL ON FUNCTION pos.allocate_receipt_no(uuid, date), pos.sale_stock_check(uuid, uuid),
    pos.sale_discount_check(uuid, uuid) FROM PUBLIC;

-- ---------------------------------------------------------------- guard: sales
CREATE OR REPLACE FUNCTION pos.tg_sale_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_session pos.cashier_sessions%ROWTYPE;
    v_totals  record;
    v_appr    pos.approvals%ROWTYPE;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'SALE_INVALID_TRANSITION: new sale must start DRAFT' USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_session FROM pos.cashier_sessions s WHERE s.id = NEW.cashier_session_id;
        IF v_session.id IS NULL OR v_session.status IN ('CLOSED', 'CANCELLED', 'CLOSING') THEN
            RAISE EXCEPTION 'CASHIER_SESSION_CLOSED: open the cashier first' USING ERRCODE = 'P0001';
        END IF;
        IF v_session.status = 'ON_BREAK' THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: unlock the terminal first' USING ERRCODE = 'P0001';
        END IF;
        IF v_session.employee_id <> NEW.employee_id THEN
            RAISE EXCEPTION 'CASHIER_SESSION_NOT_OWNER: sale must use your own cashier session' USING ERRCODE = 'P0001';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pos.attendance a WHERE a.employee_id = NEW.employee_id
                       AND a.status = 'WORKING' AND a.outlet_id = v_session.outlet_id) THEN
            RAISE EXCEPTION 'ATTENDANCE_REQUIRED: clock in / end break first' USING ERRCODE = 'P0001';
        END IF;
        NEW.organization_id := v_session.organization_id;
        NEW.outlet_id := v_session.outlet_id;
        NEW.terminal_id := v_session.terminal_id;
        NEW.business_date := pos.business_date(now(), v_session.outlet_id);
        NEW.prices_include_tax := coalesce((pos.get_setting('prices_include_tax', v_session.outlet_id))::boolean, true);
        NEW.receipt_no := NULL;
        NEW.sync_status := 'NOT_READY';
        NEW.synced_at := NULL;
        NEW.line_count := 0; NEW.item_count := 0; NEW.subtotal := 0; NEW.item_discount_total := 0;
        NEW.cart_discount_total := 0; NEW.discount_total := 0; NEW.tax_total := 0; NEW.grand_total := 0;
        NEW.held_at := NULL; NEW.checked_out_at := NULL; NEW.cancelled_at := NULL; NEW.voided_at := NULL;
        NEW.void_reason := NULL; NEW.voided_by := NULL; NEW.void_approved_by := NULL; NEW.void_approval_id := NULL;
        NEW.created_at := now();
        NEW.updated_at := now();
        NEW.version := 0;
        RETURN NEW;
    END IF;

    -- UPDATE
    IF OLD.status IN ('VOID', 'CANCELLED') THEN
        RAISE EXCEPTION 'SALE_CLOSED: sale % is %', OLD.id, OLD.status USING ERRCODE = 'P0001';
    END IF;
    IF NEW.organization_id <> OLD.organization_id OR NEW.outlet_id <> OLD.outlet_id
       OR NEW.terminal_id <> OLD.terminal_id OR NEW.cashier_session_id <> OLD.cashier_session_id
       OR NEW.employee_id <> OLD.employee_id OR NEW.created_by <> OLD.created_by
       OR NEW.business_date <> OLD.business_date OR NEW.client_transaction_id <> OLD.client_transaction_id
       OR NEW.prices_include_tax <> OLD.prices_include_tax OR NEW.created_at <> OLD.created_at
       OR NEW.receipt_no IS DISTINCT FROM OLD.receipt_no
       OR NEW.sync_status IS DISTINCT FROM OLD.sync_status OR NEW.synced_at IS DISTINCT FROM OLD.synced_at THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE_FIELD: identity, receipt and sync fields cannot change here' USING ERRCODE = 'P0001';
    END IF;

    -- Total SELALU dihitung dari baris aktif (keranjang hanya berubah saat DRAFT).
    IF OLD.status = 'DRAFT' THEN
        SELECT count(*)::integer AS line_count,
               coalesce(sum(si.quantity), 0) AS item_count,
               coalesce(sum(si.gross_amount), 0) AS subtotal,
               coalesce(sum(si.item_discount_amount), 0) AS item_disc,
               coalesce(sum(si.cart_discount_amount), 0) AS cart_disc,
               coalesce(sum(si.tax_amount), 0) AS tax,
               coalesce(sum(si.net_amount), 0) AS net
        INTO v_totals
        FROM pos.sale_items si WHERE si.sale_id = OLD.id AND si.status = 'ACTIVE';
        NEW.line_count := v_totals.line_count;
        NEW.item_count := v_totals.item_count;
        NEW.subtotal := v_totals.subtotal;
        NEW.item_discount_total := v_totals.item_disc;
        NEW.cart_discount_total := v_totals.cart_disc;
        NEW.discount_total := v_totals.item_disc + v_totals.cart_disc;
        NEW.tax_total := v_totals.tax;
        NEW.grand_total := v_totals.net + CASE WHEN OLD.prices_include_tax THEN 0 ELSE v_totals.tax END;
    ELSE
        NEW.line_count := OLD.line_count; NEW.item_count := OLD.item_count; NEW.subtotal := OLD.subtotal;
        NEW.item_discount_total := OLD.item_discount_total; NEW.cart_discount_total := OLD.cart_discount_total;
        NEW.discount_total := OLD.discount_total; NEW.tax_total := OLD.tax_total; NEW.grand_total := OLD.grand_total;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        SELECT * INTO v_session FROM pos.cashier_sessions s WHERE s.id = OLD.cashier_session_id;
        IF v_session.status <> 'OPEN' THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: cashier session is not open' USING ERRCODE = 'P0001';
        END IF;

        IF OLD.status = 'DRAFT' AND NEW.status = 'HELD' THEN
            IF NEW.line_count = 0 THEN
                RAISE EXCEPTION 'SALE_EMPTY: nothing to hold' USING ERRCODE = 'P0001';
            END IF;
            NEW.held_at := now();
        ELSIF OLD.status = 'HELD' AND NEW.status = 'DRAFT' THEN
            NEW.held_at := OLD.held_at;
        ELSIF OLD.status = 'DRAFT' AND NEW.status = 'CHECKOUT' THEN
            IF NEW.line_count = 0 THEN
                RAISE EXCEPTION 'SALE_EMPTY: add an item before checkout' USING ERRCODE = 'P0001';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pos.attendance a WHERE a.employee_id = OLD.employee_id
                           AND a.status = 'WORKING' AND a.outlet_id = OLD.outlet_id) THEN
                RAISE EXCEPTION 'ATTENDANCE_REQUIRED: clock in / end break first' USING ERRCODE = 'P0001';
            END IF;
            PERFORM pos.sale_discount_check(OLD.id, OLD.outlet_id);
            PERFORM pos.sale_stock_check(OLD.id, OLD.outlet_id);
            IF OLD.receipt_no IS NULL THEN
                NEW.receipt_no := pos.allocate_receipt_no(OLD.terminal_id, OLD.business_date);
            END IF;
            NEW.checked_out_at := now();
        ELSIF OLD.status = 'CHECKOUT' AND NEW.status = 'DRAFT' THEN
            -- kembali ke keranjang sebelum pembayaran; nomor struk tetap milik transaksi ini
            NEW.checked_out_at := NULL;
        ELSIF OLD.status IN ('DRAFT', 'HELD') AND NEW.status = 'CANCELLED' THEN
            IF NEW.line_count > 0 THEN
                RAISE EXCEPTION 'SALE_NOT_EMPTY: void the sale with a reason instead' USING ERRCODE = 'P0001';
            END IF;
            NEW.cancelled_at := now();
        ELSIF OLD.status IN ('DRAFT', 'HELD', 'CHECKOUT') AND NEW.status = 'VOID' THEN
            NEW.voided_at := now();
            NEW.voided_by := pos.current_app_user_id();
            IF OLD.status = 'CHECKOUT'
               AND coalesce((pos.get_setting('require_supervisor_for_void', OLD.outlet_id))::boolean, true) THEN
                SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.void_approval_id;
                IF v_appr.id IS NULL OR v_appr.action <> 'VOID_SALE' OR v_appr.sale_id <> OLD.id
                   OR v_appr.used_at IS NULL OR v_appr.approved_by IS DISTINCT FROM NEW.void_approved_by THEN
                    RAISE EXCEPTION 'APPROVAL_REQUIRED: voiding a checked-out sale needs supervisor approval'
                        USING ERRCODE = 'P0001';
                END IF;
            END IF;
        ELSE
            -- CHECKOUT -> PAID dll. diaktifkan Phase 5 (pembayaran).
            RAISE EXCEPTION 'SALE_INVALID_TRANSITION: % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
        END IF;
    ELSIF OLD.status <> 'DRAFT' AND (NEW.note IS DISTINCT FROM OLD.note) THEN
        RAISE EXCEPTION 'SALE_NOT_EDITABLE: only draft sales can be edited' USING ERRCODE = 'P0001';
    END IF;

    IF NEW.status <> 'VOID' AND (NEW.void_reason IS NOT NULL OR NEW.void_approved_by IS NOT NULL) THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE_FIELD: void fields only with VOID' USING ERRCODE = 'P0001';
    END IF;
    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;

CREATE TRIGGER sales_guard BEFORE INSERT OR UPDATE ON pos.sales
    FOR EACH ROW EXECUTE FUNCTION pos.tg_sale_guard();
CREATE TRIGGER sales_no_delete BEFORE DELETE ON pos.sales
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

CREATE OR REPLACE FUNCTION pos.tg_sale_receipt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF NEW.receipt_no IS NOT NULL AND OLD.receipt_no IS NULL THEN
        INSERT INTO pos.receipts (sale_id, receipt_no) VALUES (NEW.id, NEW.receipt_no);
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER sales_receipt AFTER UPDATE ON pos.sales
    FOR EACH ROW EXECUTE FUNCTION pos.tg_sale_receipt();

-- ---------------------------------------------------------------- guard: sale items
-- Keranjang hanya bisa diubah selama sale DRAFT dan session OPEN.
CREATE OR REPLACE FUNCTION pos.assert_sale_editable(p_sale uuid)
RETURNS pos.sales
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale pos.sales%ROWTYPE;
    v_session_status text;
BEGIN
    SELECT * INTO v_sale FROM pos.sales WHERE id = p_sale;
    IF v_sale.id IS NULL THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_sale.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'SALE_NOT_EDITABLE: sale is %', v_sale.status USING ERRCODE = 'P0001';
    END IF;
    SELECT s.status INTO v_session_status FROM pos.cashier_sessions s WHERE s.id = v_sale.cashier_session_id;
    IF v_session_status <> 'OPEN' THEN
        RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: cashier session is not open' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_sale;
END
$$;
REVOKE ALL ON FUNCTION pos.assert_sale_editable(uuid) FROM PUBLIC;

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
        NEW.list_price := v_price.price;
        NEW.unit_price := v_price.price;      -- ubah harga hanya lewat override yang disetujui
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
           OR NEW.barcode IS DISTINCT FROM OLD.barcode THEN
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

CREATE TRIGGER sale_items_guard BEFORE INSERT OR UPDATE ON pos.sale_items
    FOR EACH ROW EXECUTE FUNCTION pos.tg_sale_item_guard();
CREATE TRIGGER sale_items_no_delete BEFORE DELETE ON pos.sale_items
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Setiap perubahan baris menghitung ulang header (lewat guard sales).
CREATE OR REPLACE FUNCTION pos.tg_sale_item_touch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    UPDATE pos.sales SET updated_at = now() WHERE id = NEW.sale_id;
    RETURN NULL;
END
$$;
CREATE TRIGGER sale_items_touch AFTER INSERT OR UPDATE ON pos.sale_items
    FOR EACH ROW EXECUTE FUNCTION pos.tg_sale_item_touch();

-- ---------------------------------------------------------------- guard: diskon
CREATE OR REPLACE FUNCTION pos.tg_sale_discount_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale pos.sales%ROWTYPE;
    v_appr pos.approvals%ROWTYPE;
BEGIN
    v_sale := pos.assert_sale_editable(NEW.sale_id);
    IF TG_OP = 'INSERT' THEN
        IF NEW.sale_item_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM pos.sale_items si WHERE si.id = NEW.sale_item_id AND si.sale_id = NEW.sale_id
              AND si.status = 'ACTIVE') THEN
            RAISE EXCEPTION 'SALE_ITEM_VOID: discount target line is not active' USING ERRCODE = 'P0001';
        END IF;
        NEW.created_by := pos.current_app_user_id();
        NEW.created_at := now();
        NEW.status := 'ACTIVE';
        NEW.amount := 0;                     -- diisi alokasi dalam transaksi yang sama
        NEW.removed_by := NULL; NEW.removed_at := NULL;
        IF NEW.approval_id IS NOT NULL THEN
            SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.approval_id;
            IF v_appr.id IS NULL OR v_appr.action <> 'DISCOUNT' OR v_appr.sale_id <> NEW.sale_id
               OR v_appr.used_at IS NULL THEN
                RAISE EXCEPTION 'APPROVAL_REQUIRED: invalid discount approval' USING ERRCODE = 'P0001';
            END IF;
            NEW.approved_by := v_appr.approved_by;
        ELSE
            NEW.approved_by := NULL;
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.status = 'REMOVED' THEN
        RAISE EXCEPTION 'DISCOUNT_REMOVED: discount % already removed', OLD.id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.sale_id <> OLD.sale_id OR NEW.sale_item_id IS DISTINCT FROM OLD.sale_item_id
       OR NEW.discount_type <> OLD.discount_type OR NEW.discount_value <> OLD.discount_value
       OR NEW.reason <> OLD.reason OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at
       OR NEW.approved_by IS DISTINCT FROM OLD.approved_by OR NEW.approval_id IS DISTINCT FROM OLD.approval_id
       OR NEW.source <> OLD.source THEN
        RAISE EXCEPTION 'DISCOUNT_IMMUTABLE_FIELD: remove and add a new discount instead' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.status = 'REMOVED' THEN
        NEW.removed_by := pos.current_app_user_id();
        NEW.removed_at := now();
        NEW.amount := 0;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER sale_discounts_guard BEFORE INSERT OR UPDATE ON pos.sale_discounts
    FOR EACH ROW EXECUTE FUNCTION pos.tg_sale_discount_guard();
CREATE TRIGGER sale_discounts_no_delete BEFORE DELETE ON pos.sale_discounts
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- ---------------------------------------------------------------- guard: approval
CREATE OR REPLACE FUNCTION pos.tg_approval_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale     pos.sales%ROWTYPE;
    v_required integer := 0;
    v_perm     text;
    v_sup_max  numeric;
    v_mgr_max  numeric;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        -- hanya "pakai" (sekali) oleh peminta, sebelum kedaluwarsa
        IF OLD.used_at IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVAL_USED: approval % already used', OLD.id USING ERRCODE = 'P0001';
        END IF;
        IF OLD.expires_at < now() THEN
            RAISE EXCEPTION 'APPROVAL_EXPIRED: approval % expired', OLD.id USING ERRCODE = 'P0001';
        END IF;
        IF ROW(NEW.organization_id, NEW.outlet_id, NEW.sale_id, NEW.sale_item_id, NEW.action, NEW.max_percent, NEW.price,
               NEW.requested_by, NEW.approved_by, NEW.approver_rank, NEW.expires_at, NEW.created_at)
           IS DISTINCT FROM
           ROW(OLD.organization_id, OLD.outlet_id, OLD.sale_id, OLD.sale_item_id, OLD.action, OLD.max_percent, OLD.price,
               OLD.requested_by, OLD.approved_by, OLD.approver_rank, OLD.expires_at, OLD.created_at)
           OR NEW.used_at IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_IMMUTABLE_FIELD' USING ERRCODE = 'P0001';
        END IF;
        NEW.used_at := now();
        RETURN NEW;
    END IF;

    SELECT * INTO v_sale FROM pos.sales WHERE id = NEW.sale_id;
    IF v_sale.id IS NULL OR v_sale.status IN ('VOID', 'CANCELLED') THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    NEW.organization_id := v_sale.organization_id;
    NEW.outlet_id := v_sale.outlet_id;
    NEW.requested_by := pos.current_app_user_id();
    IF NEW.approved_by IS NULL OR NEW.approved_by = NEW.requested_by THEN
        RAISE EXCEPTION 'APPROVER_INVALID: approver must be another user (separation of duties)' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.sale_item_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pos.sale_items si WHERE si.id = NEW.sale_item_id AND si.sale_id = NEW.sale_id) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND: line does not belong to sale' USING ERRCODE = 'P0001';
    END IF;

    IF NEW.action = 'DISCOUNT' THEN
        v_perm := 'sale.discount';
        v_sup_max := coalesce((pos.get_setting('max_supervisor_discount', v_sale.outlet_id))::numeric, 0);
        v_mgr_max := coalesce((pos.get_setting('max_manager_discount', v_sale.outlet_id))::numeric, 0);
        IF NEW.max_percent > v_mgr_max THEN
            RAISE EXCEPTION 'DISCOUNT_LIMIT_EXCEEDED: % percent is above the maximum', NEW.max_percent USING ERRCODE = 'P0001';
        END IF;
        -- matriks §20: sampai batas supervisor -> rank SUPERVISOR (50); di atasnya -> STORE_MANAGER (70)
        v_required := CASE WHEN NEW.max_percent <= v_sup_max THEN 50 ELSE 70 END;
    ELSIF NEW.action = 'PRICE_OVERRIDE' THEN
        v_perm := 'sale.price_override';
        v_required := 50;
    ELSE
        v_perm := 'sale.void';
        v_required := 50;
    END IF;
    IF NOT pos.user_has_permission_at(NEW.approved_by, v_perm, v_sale.outlet_id) THEN
        RAISE EXCEPTION 'APPROVER_NOT_AUTHORIZED: approver lacks % at this outlet', v_perm USING ERRCODE = 'P0001';
    END IF;
    NEW.approver_rank := pos.user_rank_at(NEW.approved_by, v_sale.outlet_id);
    IF NEW.approver_rank < v_required THEN
        RAISE EXCEPTION 'APPROVER_NOT_AUTHORIZED: approver role level too low' USING ERRCODE = 'P0001';
    END IF;
    NEW.created_at := now();
    NEW.expires_at := now() + interval '2 minutes';
    NEW.used_at := NULL;
    RETURN NEW;
END
$$;

CREATE TRIGGER approvals_guard BEFORE INSERT OR UPDATE ON pos.approvals
    FOR EACH ROW EXECUTE FUNCTION pos.tg_approval_guard();
CREATE TRIGGER approvals_no_delete BEFORE DELETE ON pos.approvals
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- ---------------------------------------------------------------- receipt print (reprint tidak membuat transaksi baru, §30)
CREATE OR REPLACE FUNCTION pos.record_receipt_print(p_sale uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_count integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = p_sale
                   AND s.organization_id = pos.current_org_id()
                   AND (s.employee_id = pos.current_employee_id() OR pos.has_permission('sale.view', s.outlet_id))) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    UPDATE pos.receipts SET print_count = print_count + 1, last_printed_at = now(),
                            last_printed_by = pos.current_app_user_id()
    WHERE sale_id = p_sale
    RETURNING print_count INTO v_count;
    IF v_count IS NULL THEN
        RAISE EXCEPTION 'RECEIPT_NOT_AVAILABLE: sale has no receipt number yet' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_count;
END
$$;
REVOKE ALL ON FUNCTION pos.record_receipt_print(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.record_receipt_print(uuid) TO pos_app_user;

-- ---------------------------------------------------------------- privileges & RLS
GRANT SELECT, INSERT, UPDATE ON pos.sales, pos.sale_items, pos.sale_discounts, pos.approvals TO pos_app_user, pos_system;
GRANT SELECT ON pos.receipts TO pos_app_user, pos_system;

ALTER TABLE pos.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.sale_discounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.terminal_receipt_sequences ENABLE ROW LEVEL SECURITY;

CREATE POLICY sales_system_all ON pos.sales TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY sale_items_system_all ON pos.sale_items TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY sale_discounts_system_all ON pos.sale_discounts TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY approvals_system_all ON pos.approvals TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY receipts_system_all ON pos.receipts TO pos_system USING (true);

-- Lihat: transaksi sendiri, atau sale.view di outlet.
CREATE POLICY sales_select ON pos.sales FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (employee_id = pos.current_employee_id() OR pos.has_permission('sale.view', outlet_id)));
CREATE POLICY sales_insert ON pos.sales FOR INSERT TO pos_app_user
    WITH CHECK (organization_id = pos.current_org_id()
                AND employee_id = pos.current_employee_id()
                AND created_by = pos.current_app_user_id()
                AND pos.has_permission('sale.create', outlet_id));
-- Hanya pemilik transaksi yang mengubahnya (approval orang lain dicatat sebagai baris approval).
CREATE POLICY sales_update ON pos.sales FOR UPDATE TO pos_app_user
    USING (employee_id = pos.current_employee_id() AND organization_id = pos.current_org_id())
    WITH CHECK (employee_id = pos.current_employee_id() AND pos.has_permission('sale.create', outlet_id));

CREATE POLICY sale_items_select ON pos.sale_items FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id));
CREATE POLICY sale_items_insert ON pos.sale_items FOR INSERT TO pos_app_user
    WITH CHECK (created_by = pos.current_app_user_id()
                AND EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()));
CREATE POLICY sale_items_update ON pos.sale_items FOR UPDATE TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()))
    WITH CHECK (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()));

CREATE POLICY sale_discounts_select ON pos.sale_discounts FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id));
CREATE POLICY sale_discounts_insert ON pos.sale_discounts FOR INSERT TO pos_app_user
    WITH CHECK (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()
                        AND pos.has_permission('sale.discount', s.outlet_id)));
CREATE POLICY sale_discounts_update ON pos.sale_discounts FOR UPDATE TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()))
    WITH CHECK (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()));

CREATE POLICY approvals_select ON pos.approvals FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (requested_by = pos.current_app_user_id() OR approved_by = pos.current_app_user_id()
                OR pos.has_permission('sale.view', outlet_id)));
CREATE POLICY approvals_insert ON pos.approvals FOR INSERT TO pos_app_user
    WITH CHECK (requested_by = pos.current_app_user_id()
                AND EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()));
CREATE POLICY approvals_update ON pos.approvals FOR UPDATE TO pos_app_user
    USING (requested_by = pos.current_app_user_id())
    WITH CHECK (requested_by = pos.current_app_user_id());

CREATE POLICY receipts_select ON pos.receipts FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id));

-- Batal buka kasir (V010) hanya bila belum ada transaksi selain yang dibatalkan kosong.
CREATE OR REPLACE FUNCTION pos.tg_cashier_session_sales_check()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF NEW.status = 'CANCELLED' AND OLD.status <> 'CANCELLED'
       AND EXISTS (SELECT 1 FROM pos.sales s WHERE s.cashier_session_id = OLD.id AND s.status <> 'CANCELLED') THEN
        RAISE EXCEPTION 'CASHIER_SESSION_HAS_ACTIVITY: session already has sales' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER cashier_sessions_sales_check BEFORE UPDATE ON pos.cashier_sessions
    FOR EACH ROW EXECUTE FUNCTION pos.tg_cashier_session_sales_check();
