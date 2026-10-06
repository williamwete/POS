-- V018: integrasi Openbravo (Phase 9, §38–§43, §63, §72 sync)
--
-- Prinsip:
--  * Openbravo = system of record ERP; POS mengirim dokumen (penjualan + pembayaran, retur + refund, cash-up)
--    lewat antrean `sync_jobs` dan menerima master data (produk, harga, stok, customer) ke tabel cache.
--  * Job keluar dibuat DI DALAM transaksi yang sama dengan kejadian bisnisnya (sale PAID, retur COMPLETED,
--    cash-up dibuat) — tidak ada transaksi lunas tanpa job sync (§63).
--  * Retry bertahap 30 dtk → 1 mnt → 5 mnt → 15 mnt, lalu MANUAL_REVIEW (§43). Tidak ada retry tanpa batas.
--  * Hanya konteks sistem (pos_system, tanpa JWT) yang mengubah status sync & nomor dokumen Openbravo.
--  * ID Openbravo tidak di-hard-code: tabel `openbravo_mappings` diatur admin (§39).

-- ---------------------------------------------------------------- pemetaan ID Openbravo
CREATE TABLE pos.openbravo_mappings (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    entity_type      text        NOT NULL,
    pos_id           uuid        NOT NULL,
    openbravo_id     text        NOT NULL,
    note             text,
    updated_by       uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    version          integer     NOT NULL DEFAULT 0,
    CONSTRAINT openbravo_mappings_type_ck CHECK (entity_type IN ('ORGANIZATION', 'OUTLET', 'WAREHOUSE', 'TERMINAL',
                                                                 'PAYMENT_METHOD', 'TAX')),
    CONSTRAINT openbravo_mappings_id_ck CHECK (openbravo_id ~ '^[A-Za-z0-9._:-]{1,64}$'),
    CONSTRAINT openbravo_mappings_uk UNIQUE (organization_id, entity_type, pos_id)
);

-- Nilai lama dari kolom yang sudah ada (Phase 4/5) dipindahkan ke tabel pemetaan.
INSERT INTO pos.openbravo_mappings (organization_id, entity_type, pos_id, openbravo_id)
SELECT organization_id, 'PAYMENT_METHOD', id, openbravo_payment_method_id FROM pos.payment_methods
WHERE openbravo_payment_method_id ~ '^[A-Za-z0-9._:-]{1,64}$'
ON CONFLICT DO NOTHING;
INSERT INTO pos.openbravo_mappings (organization_id, entity_type, pos_id, openbravo_id)
SELECT organization_id, 'TAX', id, openbravo_tax_id FROM pos.tax_rates
WHERE openbravo_tax_id ~ '^[A-Za-z0-9._:-]{1,64}$'
ON CONFLICT DO NOTHING;

CREATE FUNCTION pos.tg_openbravo_mapping_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_ok boolean;
BEGIN
    -- entitas POS harus ada di organisasi yang sama
    v_ok := CASE NEW.entity_type
        WHEN 'ORGANIZATION' THEN NEW.pos_id = NEW.organization_id
        WHEN 'OUTLET' THEN EXISTS (SELECT 1 FROM pos.outlets x WHERE x.id = NEW.pos_id AND x.organization_id = NEW.organization_id)
        WHEN 'WAREHOUSE' THEN EXISTS (SELECT 1 FROM pos.warehouses x WHERE x.id = NEW.pos_id AND x.organization_id = NEW.organization_id)
        WHEN 'TERMINAL' THEN EXISTS (SELECT 1 FROM pos.terminals x JOIN pos.outlets o ON o.id = x.outlet_id
                                     WHERE x.id = NEW.pos_id AND o.organization_id = NEW.organization_id)
        WHEN 'PAYMENT_METHOD' THEN EXISTS (SELECT 1 FROM pos.payment_methods x WHERE x.id = NEW.pos_id AND x.organization_id = NEW.organization_id)
        WHEN 'TAX' THEN EXISTS (SELECT 1 FROM pos.tax_rates x WHERE x.id = NEW.pos_id AND x.organization_id = NEW.organization_id)
        ELSE false END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'MAPPING_TARGET_INVALID: % % not found in organization', NEW.entity_type, NEW.pos_id USING ERRCODE = 'P0001';
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.organization_id <> OLD.organization_id OR NEW.entity_type <> OLD.entity_type
                             OR NEW.pos_id <> OLD.pos_id) THEN
        RAISE EXCEPTION 'MAPPING_IMMUTABLE_FIELD' USING ERRCODE = 'P0001';
    END IF;
    NEW.updated_by := pos.current_app_user_id();
    NEW.updated_at := now();
    NEW.version := CASE WHEN TG_OP = 'UPDATE' THEN OLD.version + 1 ELSE 0 END;
    RETURN NEW;
END
$$;
CREATE TRIGGER openbravo_mappings_guard BEFORE INSERT OR UPDATE ON pos.openbravo_mappings
    FOR EACH ROW EXECUTE FUNCTION pos.tg_openbravo_mapping_guard();

-- ---------------------------------------------------------------- customer (master dari Openbravo, §19)
CREATE TABLE pos.customers (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id        uuid        NOT NULL REFERENCES pos.organizations (id),
    openbravo_customer_id  text        NOT NULL,
    code                   text        NOT NULL,
    name                   text        NOT NULL,
    phone                  text,
    email                  text,
    tax_id                 text,
    active                 boolean     NOT NULL DEFAULT true,
    synced_at              timestamptz NOT NULL DEFAULT now(),
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customers_openbravo_uk UNIQUE (organization_id, openbravo_customer_id)
);
CREATE INDEX customers_name_idx ON pos.customers (organization_id, lower(name));

-- ---------------------------------------------------------------- antrean sync
CREATE TABLE pos.sync_jobs (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id        uuid        NOT NULL REFERENCES pos.organizations (id),
    outlet_id              uuid        REFERENCES pos.outlets (id),
    job_type               text        NOT NULL,
    direction              text        NOT NULL,
    entity_id              uuid,
    entity_ref             text,
    status                 text        NOT NULL DEFAULT 'PENDING',
    attempts               integer     NOT NULL DEFAULT 0,
    max_attempts           integer     NOT NULL DEFAULT 5,
    next_attempt_at        timestamptz NOT NULL DEFAULT now(),
    locked_at              timestamptz,
    last_error             text,
    openbravo_document_id  text,
    openbravo_document_no  text,
    sync_started_at        timestamptz,
    sync_finished_at       timestamptz,
    records_processed      integer     NOT NULL DEFAULT 0,
    records_success        integer     NOT NULL DEFAULT 0,
    records_failed         integer     NOT NULL DEFAULT 0,
    error_count            integer     NOT NULL DEFAULT 0,
    requested_by           uuid,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sync_jobs_type_ck CHECK (job_type IN ('SALE', 'RETURN', 'CASHUP', 'MASTER_PRODUCT', 'MASTER_PRICE',
                                                     'MASTER_STOCK', 'MASTER_CUSTOMER')),
    CONSTRAINT sync_jobs_direction_ck CHECK (direction IN ('OUT', 'IN')),
    CONSTRAINT sync_jobs_status_ck CHECK (status IN ('PENDING', 'PROCESSING', 'SUCCESS', 'FAILED', 'RETRYING', 'MANUAL_REVIEW')),
    CONSTRAINT sync_jobs_entity_ck CHECK ((direction = 'OUT') = (entity_id IS NOT NULL)),
    CONSTRAINT sync_jobs_attempts_ck CHECK (attempts >= 0 AND max_attempts BETWEEN 1 AND 20)
);
-- satu job per dokumen (idempotent: kejadian yang sama tidak membuat job kedua)
CREATE UNIQUE INDEX sync_jobs_entity_uk ON pos.sync_jobs (job_type, entity_id) WHERE entity_id IS NOT NULL;
-- satu sinkron master aktif per jenis per organisasi
CREATE UNIQUE INDEX sync_jobs_master_active_uk ON pos.sync_jobs (organization_id, job_type)
    WHERE direction = 'IN' AND status IN ('PENDING', 'PROCESSING', 'RETRYING', 'FAILED');
CREATE INDEX sync_jobs_due_idx ON pos.sync_jobs (next_attempt_at) WHERE status IN ('PENDING', 'RETRYING', 'FAILED');
CREATE INDEX sync_jobs_status_idx ON pos.sync_jobs (organization_id, status, job_type);

CREATE TABLE pos.sync_logs (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id       uuid        NOT NULL REFERENCES pos.sync_jobs (id),
    attempt      integer     NOT NULL,
    status       text        NOT NULL,
    message      text,
    duration_ms  integer,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sync_logs_status_ck CHECK (status IN ('SUCCESS', 'FAILED', 'MANUAL_REVIEW', 'RETRY_REQUESTED'))
);
CREATE INDEX sync_logs_job_idx ON pos.sync_logs (job_id, created_at);
CREATE TRIGGER sync_logs_append_only BEFORE UPDATE OR DELETE ON pos.sync_logs
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Jeda retry (§43): setelah gagal ke-1 30 dtk, ke-2 1 mnt, ke-3 5 mnt, ke-4 15 mnt; gagal ke-5 → MANUAL_REVIEW.
CREATE FUNCTION pos.sync_retry_delay(p_attempts integer)
RETURNS interval
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE p_attempts WHEN 1 THEN interval '30 seconds' WHEN 2 THEN interval '1 minute'
                           WHEN 3 THEN interval '5 minutes' ELSE interval '15 minutes' END
$$;

-- ---------------------------------------------------------------- kolom dokumen Openbravo
ALTER TABLE pos.sales
    ADD COLUMN openbravo_document_id text,
    ADD COLUMN openbravo_document_no text,
    ADD COLUMN last_sync_at timestamptz,
    ADD COLUMN sync_error text;
ALTER TABLE pos.returns
    ADD COLUMN openbravo_document_id text,
    ADD COLUMN openbravo_document_no text,
    ADD COLUMN last_sync_at timestamptz,
    ADD COLUMN sync_error text;

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
    v_paid    numeric;
    v_change  numeric;
    v_pending integer;
    v_open_payments integer;
    v_sync    pos.sales%ROWTYPE;
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
        NEW.openbravo_document_id := NULL;
        NEW.openbravo_document_no := NULL;
        NEW.last_sync_at := NULL;
        NEW.sync_error := NULL;
        NEW.line_count := 0; NEW.item_count := 0; NEW.subtotal := 0; NEW.item_discount_total := 0;
        NEW.cart_discount_total := 0; NEW.discount_total := 0; NEW.tax_total := 0; NEW.grand_total := 0;
        NEW.held_at := NULL; NEW.checked_out_at := NULL; NEW.cancelled_at := NULL; NEW.voided_at := NULL;
        NEW.void_reason := NULL; NEW.voided_by := NULL; NEW.void_approved_by := NULL; NEW.void_approval_id := NULL;
        NEW.paid_amount := 0; NEW.change_amount := 0; NEW.paid_at := NULL;
        NEW.created_at := now();
        NEW.updated_at := now();
        NEW.version := 0;
        RETURN NEW;
    END IF;

    -- UPDATE
    -- Sinkronisasi Openbravo (Phase 9): hanya konteks sistem (tanpa JWT, role pos_system) yang boleh
    -- mengubah status sync & dokumen Openbravo transaksi lunas; kolom lain dipertahankan dari OLD.
    IF pos.jwt_sub() IS NULL AND OLD.status IN ('PAID', 'POSTED', 'RETURNED', 'SYNC_ERROR')
       AND NEW.status IN ('PAID', 'POSTED', 'SYNC_ERROR') THEN
        v_sync := OLD;
        v_sync.status := CASE WHEN OLD.status = 'RETURNED' THEN OLD.status ELSE NEW.status END;
        v_sync.sync_status := NEW.sync_status;
        v_sync.synced_at := NEW.synced_at;
        v_sync.openbravo_document_id := NEW.openbravo_document_id;
        v_sync.openbravo_document_no := NEW.openbravo_document_no;
        v_sync.last_sync_at := NEW.last_sync_at;
        v_sync.sync_error := NEW.sync_error;
        v_sync.updated_at := now();
        v_sync.version := OLD.version + 1;
        RETURN v_sync;
    END IF;
    IF NEW.openbravo_document_id IS DISTINCT FROM OLD.openbravo_document_id
       OR NEW.openbravo_document_no IS DISTINCT FROM OLD.openbravo_document_no
       OR NEW.last_sync_at IS DISTINCT FROM OLD.last_sync_at OR NEW.sync_error IS DISTINCT FROM OLD.sync_error THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE_FIELD: sync fields are set by the integration service' USING ERRCODE = 'P0001';
    END IF;
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

    -- Pembayaran (Phase 5): jumlah dibayar & kembalian SELALU dihitung dari tabel payments.
    IF NEW.paid_at IS DISTINCT FROM OLD.paid_at THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE_FIELD: paid_at is set by the database' USING ERRCODE = 'P0001';
    END IF;
    SELECT coalesce(sum(p.amount) FILTER (WHERE p.status = 'PAID'), 0),
           coalesce(sum(p.change_amount) FILTER (WHERE p.status = 'PAID'), 0),
           count(*) FILTER (WHERE p.status = 'PENDING'),
           count(*) FILTER (WHERE p.status IN ('PAID', 'PENDING'))
      INTO v_paid, v_change, v_pending, v_open_payments
      FROM pos.payments p WHERE p.sale_id = OLD.id;
    NEW.paid_amount := v_paid;
    NEW.change_amount := v_change;

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
        -- Status turunan pembayaran (mis. callback QRIS saat terminal terkunci) tidak butuh session OPEN;
        -- pembayarannya sendiri sudah divalidasi saat dibuat.
        IF v_session.status <> 'OPEN'
           AND NOT (NEW.status IN ('PAID', 'PAYMENT_PENDING')
                    OR (OLD.status = 'PAYMENT_PENDING' AND NEW.status = 'CHECKOUT')) THEN
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
            IF v_open_payments > 0 THEN
                RAISE EXCEPTION 'SALE_HAS_PAYMENTS: cancel the payments before changing the cart' USING ERRCODE = 'P0001';
            END IF;
            NEW.checked_out_at := NULL;
        ELSIF OLD.status = 'CHECKOUT' AND NEW.status = 'PAYMENT_PENDING' THEN
            IF v_pending = 0 THEN
                RAISE EXCEPTION 'SALE_INVALID_TRANSITION: no pending payment' USING ERRCODE = 'P0001';
            END IF;
        ELSIF OLD.status = 'PAYMENT_PENDING' AND NEW.status = 'CHECKOUT' THEN
            IF v_pending > 0 OR NEW.paid_amount >= NEW.grand_total THEN
                RAISE EXCEPTION 'SALE_INVALID_TRANSITION: payments still pending or sale fully paid' USING ERRCODE = 'P0001';
            END IF;
        ELSIF OLD.status IN ('CHECKOUT', 'PAYMENT_PENDING') AND NEW.status = 'PAID' THEN
            -- §23: PAID hanya bila jumlah pembayaran sukses >= grand total dan tidak ada yang pending.
            IF v_pending > 0 OR NEW.paid_amount < NEW.grand_total THEN
                RAISE EXCEPTION 'SALE_NOT_FULLY_PAID: paid % of %', NEW.paid_amount, NEW.grand_total USING ERRCODE = 'P0001';
            END IF;
            NEW.paid_at := now();
            NEW.sync_status := 'PENDING';    -- siap dikirim ke Openbravo (Phase 9)
        ELSIF OLD.status IN ('DRAFT', 'HELD') AND NEW.status = 'CANCELLED' THEN
            IF NEW.line_count > 0 THEN
                RAISE EXCEPTION 'SALE_NOT_EMPTY: void the sale with a reason instead' USING ERRCODE = 'P0001';
            END IF;
            NEW.cancelled_at := now();
        ELSIF OLD.status IN ('DRAFT', 'HELD', 'CHECKOUT', 'PAYMENT_PENDING') AND NEW.status = 'VOID' THEN
            IF v_open_payments > 0 THEN
                RAISE EXCEPTION 'SALE_HAS_PAYMENTS: cancel the payments before voiding' USING ERRCODE = 'P0001';
            END IF;
            NEW.voided_at := now();
            NEW.voided_by := pos.current_app_user_id();
            IF OLD.status IN ('CHECKOUT', 'PAYMENT_PENDING')
               AND coalesce((pos.get_setting('require_supervisor_for_void', OLD.outlet_id))::boolean, true) THEN
                SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.void_approval_id;
                IF v_appr.id IS NULL OR v_appr.action <> 'VOID_SALE' OR v_appr.sale_id <> OLD.id
                   OR v_appr.used_at IS NULL OR v_appr.approved_by IS DISTINCT FROM NEW.void_approved_by THEN
                    RAISE EXCEPTION 'APPROVAL_REQUIRED: voiding a checked-out sale needs supervisor approval'
                        USING ERRCODE = 'P0001';
                END IF;
            END IF;
        ELSE
            -- PAID -> POSTING/POSTED (sync) Phase 9, retur Phase 8.
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

CREATE OR REPLACE FUNCTION pos.tg_return_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale    pos.sales%ROWTYPE;
    v_session pos.cashier_sessions%ROWTYPE;
    v_appr    pos.approvals%ROWTYPE;
    v_actor   uuid := pos.current_app_user_id();
    v_require boolean;
    v_noncash numeric;
    v_sync    pos.returns%ROWTYPE;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- serialkan retur per transaksi asal
        SELECT * INTO v_sale FROM pos.sales WHERE id = NEW.original_sale_id FOR UPDATE;
        IF v_sale.id IS NULL OR v_sale.status NOT IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED') THEN
            RAISE EXCEPTION 'RETURN_NOT_ALLOWED: original sale must be completed (paid)' USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_session FROM pos.cashier_sessions s
        WHERE s.employee_id = pos.current_employee_id() AND s.status IN ('OPEN', 'ON_BREAK');
        IF v_session.id IS NULL THEN
            RAISE EXCEPTION 'CASHIER_SESSION_REQUIRED: open the cashier to process returns' USING ERRCODE = 'P0001';
        END IF;
        IF v_session.status <> 'OPEN' THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: unlock the terminal first' USING ERRCODE = 'P0001';
        END IF;
        IF v_sale.outlet_id <> v_session.outlet_id OR v_sale.organization_id <> v_session.organization_id THEN
            RAISE EXCEPTION 'RETURN_NOT_ALLOWED: returns are processed at the outlet of the original sale'
                USING ERRCODE = 'P0001';
        END IF;
        NEW.organization_id := v_session.organization_id;
        NEW.outlet_id := v_session.outlet_id;
        NEW.terminal_id := v_session.terminal_id;
        NEW.cashier_session_id := v_session.id;
        NEW.business_date := pos.business_date(now(), v_session.outlet_id);
        NEW.return_no := pos.allocate_return_no(v_session.terminal_id, NEW.business_date);
        NEW.status := 'PENDING_APPROVAL';
        NEW.item_count := 0;
        NEW.total_amount := 0;
        NEW.tax_amount := 0;
        NEW.approval_id := NULL;
        NEW.approved_by := NULL;
        NEW.approved_at := NULL;
        NEW.reject_reason := NULL;
        NEW.rejected_by := NULL;
        NEW.sync_status := 'NOT_READY';
        NEW.openbravo_document_id := NULL;
        NEW.openbravo_document_no := NULL;
        NEW.last_sync_at := NULL;
        NEW.sync_error := NULL;
        NEW.created_by := v_actor;
        NEW.created_at := now();
        NEW.created_tx := txid_current();
        NEW.refund_reference := nullif(btrim(coalesce(NEW.refund_reference, '')), '');
        RETURN NEW;
    END IF;

    -- UPDATE
    -- Sinkronisasi Openbravo (Phase 9): konteks sistem hanya boleh mengubah kolom sync retur selesai.
    IF pos.jwt_sub() IS NULL AND OLD.status = 'COMPLETED' THEN
        v_sync := OLD;
        v_sync.sync_status := NEW.sync_status;
        v_sync.openbravo_document_id := NEW.openbravo_document_id;
        v_sync.openbravo_document_no := NEW.openbravo_document_no;
        v_sync.last_sync_at := NEW.last_sync_at;
        v_sync.sync_error := NEW.sync_error;
        v_sync.updated_at := now();
        v_sync.version := OLD.version + 1;
        RETURN v_sync;
    END IF;
    IF NEW.openbravo_document_id IS DISTINCT FROM OLD.openbravo_document_id
       OR NEW.openbravo_document_no IS DISTINCT FROM OLD.openbravo_document_no
       OR NEW.last_sync_at IS DISTINCT FROM OLD.last_sync_at OR NEW.sync_error IS DISTINCT FROM OLD.sync_error
       OR (NEW.sync_status IS DISTINCT FROM OLD.sync_status AND NOT (OLD.status = 'PENDING_APPROVAL' AND NEW.status = 'COMPLETED')) THEN
        RAISE EXCEPTION 'RETURN_IMMUTABLE_FIELD: sync fields are set by the integration service' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.status <> 'PENDING_APPROVAL' THEN
        RAISE EXCEPTION 'RETURN_CLOSED: return % is already %', OLD.return_no, OLD.status USING ERRCODE = 'P0001';
    END IF;
    IF ROW(NEW.organization_id, NEW.outlet_id, NEW.terminal_id, NEW.cashier_session_id, NEW.original_sale_id,
           NEW.client_return_id, NEW.return_no, NEW.business_date, NEW.reason, NEW.refund_mode, NEW.item_count,
           NEW.total_amount, NEW.tax_amount, NEW.created_by, NEW.created_at, NEW.created_tx)
       IS DISTINCT FROM
       ROW(OLD.organization_id, OLD.outlet_id, OLD.terminal_id, OLD.cashier_session_id, OLD.original_sale_id,
           OLD.client_return_id, OLD.return_no, OLD.business_date, OLD.reason, OLD.refund_mode, OLD.item_count,
           OLD.total_amount, OLD.tax_amount, OLD.created_by, OLD.created_at, OLD.created_tx) THEN
        -- total & jumlah diisi trigger baris retur dalam transaksi pembuatnya
        IF NOT (OLD.created_tx = txid_current() AND NEW.status = OLD.status
                AND ROW(NEW.organization_id, NEW.outlet_id, NEW.terminal_id, NEW.cashier_session_id, NEW.original_sale_id,
                        NEW.client_return_id, NEW.return_no, NEW.business_date, NEW.reason, NEW.refund_mode,
                        NEW.created_by, NEW.created_at, NEW.created_tx)
                    IS NOT DISTINCT FROM
                    ROW(OLD.organization_id, OLD.outlet_id, OLD.terminal_id, OLD.cashier_session_id, OLD.original_sale_id,
                        OLD.client_return_id, OLD.return_no, OLD.business_date, OLD.reason, OLD.refund_mode,
                        OLD.created_by, OLD.created_at, OLD.created_tx)
                AND current_setting('pos.return_totals', true) = OLD.id::text) THEN
            RAISE EXCEPTION 'RETURN_IMMUTABLE_FIELD' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF NEW.status = 'PENDING_APPROVAL' THEN
        IF NEW.approval_id IS DISTINCT FROM OLD.approval_id OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
           OR NEW.rejected_by IS DISTINCT FROM OLD.rejected_by OR NEW.refund_reference IS DISTINCT FROM OLD.refund_reference THEN
            RAISE EXCEPTION 'RETURN_IMMUTABLE_FIELD' USING ERRCODE = 'P0001';
        END IF;
    ELSIF NEW.status = 'REJECTED' THEN
        IF v_actor IS DISTINCT FROM OLD.created_by
           AND NOT pos.user_has_permission_at(v_actor, 'sale.refund', OLD.outlet_id) THEN
            RAISE EXCEPTION 'REFUND_NOT_AUTHORIZED: only the requester or a refund approver can reject' USING ERRCODE = 'P0001';
        END IF;
        NEW.rejected_by := v_actor;
        NEW.approval_id := NULL;
        NEW.approved_by := NULL;
        NEW.approved_at := NULL;
    ELSIF NEW.status = 'COMPLETED' THEN
        IF NOT EXISTS (SELECT 1 FROM pos.return_items ri WHERE ri.return_id = OLD.id) THEN
            RAISE EXCEPTION 'RETURN_EMPTY: choose items to return' USING ERRCODE = 'P0001';
        END IF;
        v_require := coalesce((pos.get_setting('require_supervisor_for_refund', OLD.outlet_id))::boolean, true);
        IF NEW.approval_id IS NOT NULL THEN
            -- approval di terminal kasir (supervisor memasukkan password)
            SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.approval_id;
            IF v_appr.id IS NULL OR v_appr.action <> 'REFUND' OR v_appr.sale_id <> OLD.original_sale_id
               OR v_appr.price <> OLD.total_amount OR v_appr.used_at IS NULL OR v_appr.requested_by <> v_actor THEN
                RAISE EXCEPTION 'REFUND_APPROVAL_REQUIRED: approval does not match this return' USING ERRCODE = 'P0001';
            END IF;
            NEW.approved_by := v_appr.approved_by;
        ELSIF v_actor <> OLD.created_by THEN
            -- approval dari akun approver sendiri (POST /returns/{id}/approve)
            IF NOT pos.user_has_permission_at(v_actor, 'sale.refund', OLD.outlet_id)
               OR pos.user_rank_at(v_actor, OLD.outlet_id) < 50 THEN
                RAISE EXCEPTION 'REFUND_NOT_AUTHORIZED: approver lacks sale.refund' USING ERRCODE = 'P0001';
            END IF;
            NEW.approved_by := v_actor;
        ELSIF NOT v_require AND pos.user_has_permission_at(v_actor, 'sale.refund', OLD.outlet_id) THEN
            NEW.approved_by := v_actor;
        ELSE
            RAISE EXCEPTION 'REFUND_APPROVAL_REQUIRED: refund needs supervisor approval' USING ERRCODE = 'P0001';
        END IF;
        NEW.approved_at := now();
        NEW.sync_status := 'PENDING';
        NEW.reject_reason := NULL;
        NEW.rejected_by := NULL;
        -- refund non-tunai ke metode asal wajib nomor referensi (mis. void EDC / refund QRIS)
        IF OLD.refund_mode = 'ORIGINAL' THEN
            SELECT coalesce(sum(p.amount), 0) INTO v_noncash FROM pos.payments p
            WHERE p.sale_id = OLD.original_sale_id AND p.status = 'PAID' AND p.method_kind <> 'CASH';
            IF v_noncash > 0 AND pg_catalog.length(coalesce(NEW.refund_reference, '')) < 3 THEN
                RAISE EXCEPTION 'PAYMENT_REFERENCE_REQUIRED: reference of the non-cash refund is required'
                    USING ERRCODE = 'P0001';
            END IF;
        END IF;
    ELSE
        RAISE EXCEPTION 'RETURN_INVALID_TRANSITION' USING ERRCODE = 'P0001';
    END IF;
    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;

-- ---------------------------------------------------------------- job dibuat bersama kejadian bisnis
CREATE FUNCTION pos.enqueue_sync(p_org uuid, p_outlet uuid, p_type text, p_entity uuid, p_ref text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    -- penanda internal: guard mengizinkan job dokumen hanya dari fungsi ini (bukan dari pengguna)
    PERFORM set_config('pos.sync_enqueue', 'on', true);
    INSERT INTO pos.sync_jobs (organization_id, outlet_id, job_type, direction, entity_id, entity_ref)
    VALUES (p_org, p_outlet, p_type, 'OUT', p_entity, p_ref)
    ON CONFLICT (job_type, entity_id) WHERE entity_id IS NOT NULL DO NOTHING;
    PERFORM set_config('pos.sync_enqueue', '', true);
END
$$;
REVOKE ALL ON FUNCTION pos.enqueue_sync(uuid, uuid, text, uuid, text) FROM PUBLIC;

CREATE FUNCTION pos.tg_sale_enqueue_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.enqueue_sync(NEW.organization_id, NEW.outlet_id, 'SALE', NEW.id, NEW.receipt_no);
    RETURN NULL;
END
$$;
CREATE TRIGGER sales_enqueue_sync AFTER UPDATE OF status ON pos.sales
    FOR EACH ROW WHEN (NEW.status = 'PAID' AND OLD.status IN ('CHECKOUT', 'PAYMENT_PENDING'))
    EXECUTE FUNCTION pos.tg_sale_enqueue_sync();

CREATE FUNCTION pos.tg_return_enqueue_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.enqueue_sync(NEW.organization_id, NEW.outlet_id, 'RETURN', NEW.id, NEW.return_no);
    RETURN NULL;
END
$$;
CREATE TRIGGER returns_enqueue_sync AFTER UPDATE OF status ON pos.returns
    FOR EACH ROW WHEN (OLD.status = 'PENDING_APPROVAL' AND NEW.status = 'COMPLETED')
    EXECUTE FUNCTION pos.tg_return_enqueue_sync();

CREATE FUNCTION pos.tg_cashup_enqueue_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.enqueue_sync(NEW.organization_id, NEW.outlet_id, 'CASHUP', NEW.id,
                             (SELECT t.code FROM pos.terminals t WHERE t.id = NEW.terminal_id) || ' Z#' || NEW.z_number);
    RETURN NULL;
END
$$;
CREATE TRIGGER cashups_enqueue_sync AFTER INSERT ON pos.cashups
    FOR EACH ROW EXECUTE FUNCTION pos.tg_cashup_enqueue_sync();

-- Dokumen yang sudah ada sebelum migration ini masuk antrean.
INSERT INTO pos.sync_jobs (organization_id, outlet_id, job_type, direction, entity_id, entity_ref, created_at)
SELECT organization_id, outlet_id, 'SALE', 'OUT', id, receipt_no, coalesce(paid_at, now())
FROM pos.sales WHERE status = 'PAID' AND sync_status = 'PENDING'
ON CONFLICT DO NOTHING;
INSERT INTO pos.sync_jobs (organization_id, outlet_id, job_type, direction, entity_id, entity_ref, created_at)
SELECT organization_id, outlet_id, 'RETURN', 'OUT', id, return_no, coalesce(approved_at, now())
FROM pos.returns WHERE status = 'COMPLETED'
ON CONFLICT DO NOTHING;
INSERT INTO pos.sync_jobs (organization_id, outlet_id, job_type, direction, entity_id, entity_ref, created_at)
SELECT c.organization_id, c.outlet_id, 'CASHUP', 'OUT', c.id, t.code || ' Z#' || c.z_number, c.created_at
FROM pos.cashups c JOIN pos.terminals t ON t.id = c.terminal_id
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------- guard: sync_jobs (pengguna hanya meminta)
CREATE FUNCTION pos.tg_sync_job_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF pos.jwt_sub() IS NULL OR (TG_OP = 'INSERT' AND current_setting('pos.sync_enqueue', true) = 'on') THEN
        NEW.updated_at := now();
        RETURN NEW;   -- worker sistem / antrean otomatis
    END IF;
    IF TG_OP = 'INSERT' THEN
        -- pengguna (sync.manage) hanya boleh meminta sinkron master data
        IF NEW.direction <> 'IN' THEN
            RAISE EXCEPTION 'SYNC_JOB_INVALID: documents are queued automatically' USING ERRCODE = 'P0001';
        END IF;
        NEW.organization_id := pos.current_org_id();
        NEW.outlet_id := NULL;
        NEW.entity_id := NULL;
        NEW.status := 'PENDING';
        NEW.attempts := 0;
        NEW.max_attempts := 5;
        NEW.next_attempt_at := now();
        NEW.locked_at := NULL;
        NEW.last_error := NULL;
        NEW.openbravo_document_id := NULL;
        NEW.openbravo_document_no := NULL;
        NEW.sync_started_at := NULL;
        NEW.sync_finished_at := NULL;
        NEW.records_processed := 0;
        NEW.records_success := 0;
        NEW.records_failed := 0;
        NEW.error_count := 0;
        NEW.requested_by := pos.current_app_user_id();
        NEW.created_at := now();
        NEW.updated_at := now();
        RETURN NEW;
    END IF;
    -- UPDATE oleh pengguna: hanya "coba lagi" job FAILED / MANUAL_REVIEW
    IF OLD.status NOT IN ('FAILED', 'MANUAL_REVIEW') OR NEW.status <> 'RETRYING' THEN
        RAISE EXCEPTION 'SYNC_JOB_NOT_RETRYABLE: only failed jobs can be retried' USING ERRCODE = 'P0001';
    END IF;
    IF ROW(NEW.organization_id, NEW.outlet_id, NEW.job_type, NEW.direction, NEW.entity_id, NEW.entity_ref,
           NEW.openbravo_document_id, NEW.openbravo_document_no, NEW.created_at)
       IS DISTINCT FROM
       ROW(OLD.organization_id, OLD.outlet_id, OLD.job_type, OLD.direction, OLD.entity_id, OLD.entity_ref,
           OLD.openbravo_document_id, OLD.openbravo_document_no, OLD.created_at) THEN
        RAISE EXCEPTION 'SYNC_JOB_INVALID' USING ERRCODE = 'P0001';
    END IF;
    -- retry manual: jatah percobaan baru, langsung dijadwalkan
    NEW.attempts := 0;
    NEW.next_attempt_at := now();
    NEW.locked_at := NULL;
    NEW.last_error := OLD.last_error;
    NEW.records_processed := OLD.records_processed;
    NEW.records_success := OLD.records_success;
    NEW.records_failed := OLD.records_failed;
    NEW.error_count := OLD.error_count;
    NEW.sync_started_at := OLD.sync_started_at;
    NEW.sync_finished_at := OLD.sync_finished_at;
    NEW.requested_by := pos.current_app_user_id();
    NEW.updated_at := now();
    RETURN NEW;
END
$$;
CREATE TRIGGER sync_jobs_guard BEFORE INSERT OR UPDATE ON pos.sync_jobs
    FOR EACH ROW EXECUTE FUNCTION pos.tg_sync_job_guard();
CREATE TRIGGER sync_jobs_no_delete BEFORE DELETE ON pos.sync_jobs
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- ---------------------------------------------------------------- akses
ALTER TABLE pos.openbravo_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.sync_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.sync_logs ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON pos.openbravo_mappings TO pos_app_user;
GRANT SELECT ON pos.openbravo_mappings TO pos_system;
GRANT SELECT ON pos.customers TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.customers TO pos_system;
GRANT SELECT, INSERT, UPDATE ON pos.sync_jobs TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.sync_jobs TO pos_system;
GRANT SELECT ON pos.sync_logs TO pos_app_user;
GRANT SELECT, INSERT ON pos.sync_logs TO pos_system;

CREATE POLICY openbravo_mappings_select ON pos.openbravo_mappings FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (pos.has_permission('configuration.manage') OR pos.has_permission('sync.view')));
CREATE POLICY openbravo_mappings_insert ON pos.openbravo_mappings FOR INSERT TO pos_app_user
    WITH CHECK (organization_id = pos.current_org_id() AND pos.has_permission('configuration.manage'));
CREATE POLICY openbravo_mappings_update ON pos.openbravo_mappings FOR UPDATE TO pos_app_user
    USING (organization_id = pos.current_org_id() AND pos.has_permission('configuration.manage'))
    WITH CHECK (organization_id = pos.current_org_id() AND pos.has_permission('configuration.manage'));
CREATE POLICY openbravo_mappings_system ON pos.openbravo_mappings FOR SELECT TO pos_system USING (true);

CREATE POLICY customers_select ON pos.customers FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
CREATE POLICY customers_system ON pos.customers TO pos_system USING (true) WITH CHECK (true);

-- sync.view: di level organisasi melihat semua; di level outlet melihat job outlet tsb.
CREATE POLICY sync_jobs_select ON pos.sync_jobs FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (pos.has_permission('sync.view') OR pos.has_permission('sync.manage')
                OR (outlet_id IS NOT NULL AND pos.has_permission('sync.view', outlet_id))));
CREATE POLICY sync_jobs_insert ON pos.sync_jobs FOR INSERT TO pos_app_user
    WITH CHECK (organization_id = pos.current_org_id() AND pos.has_permission('sync.manage'));
CREATE POLICY sync_jobs_update ON pos.sync_jobs FOR UPDATE TO pos_app_user
    USING (organization_id = pos.current_org_id() AND pos.has_permission('sync.manage'))
    WITH CHECK (organization_id = pos.current_org_id() AND pos.has_permission('sync.manage'));
CREATE POLICY sync_jobs_system ON pos.sync_jobs TO pos_system USING (true) WITH CHECK (true);

CREATE POLICY sync_logs_select ON pos.sync_logs FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.sync_jobs j WHERE j.id = job_id));
CREATE POLICY sync_logs_system ON pos.sync_logs TO pos_system USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------- payload dokumen keluar
-- ID Openbravo dari tabel pemetaan; pemetaan yang belum ada = error permanen (MANUAL_REVIEW), bukan retry.
CREATE FUNCTION pos.openbravo_id(p_org uuid, p_type text, p_pos_id uuid, p_label text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_id text;
BEGIN
    SELECT m.openbravo_id INTO v_id FROM pos.openbravo_mappings m
    WHERE m.organization_id = p_org AND m.entity_type = p_type AND m.pos_id = p_pos_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'MAPPING_MISSING: % %', p_type, coalesce(p_label, p_pos_id::text) USING ERRCODE = 'P0001';
    END IF;
    RETURN v_id;
END
$$;
REVOKE ALL ON FUNCTION pos.openbravo_id(uuid, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.openbravo_id(uuid, text, uuid, text) TO pos_system;

CREATE FUNCTION pos.sync_payload(p_job uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_job  pos.sync_jobs%ROWTYPE;
    v_sale pos.sales%ROWTYPE;
    v_ret  pos.returns%ROWTYPE;
    v_cu   pos.cashups%ROWTYPE;
    v_wh   uuid;
    v_missing text;
BEGIN
    SELECT * INTO v_job FROM pos.sync_jobs WHERE id = p_job;
    IF v_job.job_type = 'SALE' THEN
        SELECT * INTO v_sale FROM pos.sales WHERE id = v_job.entity_id;
        SELECT o.default_warehouse_id INTO v_wh FROM pos.outlets o WHERE o.id = v_sale.outlet_id;
        SELECT string_agg(DISTINCT i.sku, ', ') INTO v_missing FROM pos.sale_items i JOIN pos.products p ON p.id = i.product_id
        WHERE i.sale_id = v_sale.id AND i.status = 'ACTIVE' AND p.openbravo_product_id IS NULL;
        IF v_missing IS NOT NULL THEN
            RAISE EXCEPTION 'MAPPING_MISSING: PRODUCT %', v_missing USING ERRCODE = 'P0001';
        END IF;
        RETURN jsonb_build_object(
            'documentType', 'SALE',
            'externalId', v_sale.id,
            'documentNo', v_sale.receipt_no,
            'organizationId', pos.openbravo_id(v_sale.organization_id, 'ORGANIZATION', v_sale.organization_id, 'organisasi'),
            'outletId', pos.openbravo_id(v_sale.organization_id, 'OUTLET', v_sale.outlet_id,
                                         (SELECT code FROM pos.outlets WHERE id = v_sale.outlet_id)),
            'warehouseId', pos.openbravo_id(v_sale.organization_id, 'WAREHOUSE', v_wh,
                                            (SELECT code FROM pos.warehouses WHERE id = v_wh)),
            'terminalId', pos.openbravo_id(v_sale.organization_id, 'TERMINAL', v_sale.terminal_id,
                                           (SELECT code FROM pos.terminals WHERE id = v_sale.terminal_id)),
            'businessDate', v_sale.business_date, 'paidAt', v_sale.paid_at,
            'cashier', (SELECT e.employee_code FROM pos.employees e WHERE e.id = v_sale.employee_id),
            'pricesIncludeTax', v_sale.prices_include_tax,
            'subtotal', v_sale.subtotal, 'discountTotal', v_sale.discount_total, 'taxTotal', v_sale.tax_total,
            'grandTotal', v_sale.grand_total, 'paidAmount', v_sale.paid_amount, 'changeAmount', v_sale.change_amount,
            'lines', (SELECT jsonb_agg(jsonb_build_object(
                          'lineNo', i.line_no, 'productId', p.openbravo_product_id, 'sku', i.sku, 'quantity', i.quantity,
                          'uom', i.uom, 'listPrice', i.list_price, 'unitPrice', i.unit_price, 'grossAmount', i.gross_amount,
                          'discountAmount', i.item_discount_amount + i.cart_discount_amount, 'netAmount', i.net_amount,
                          'taxId', CASE WHEN i.tax_rate_id IS NULL THEN NULL
                                        ELSE pos.openbravo_id(v_sale.organization_id, 'TAX', i.tax_rate_id, i.sku) END,
                          'taxRate', i.tax_rate, 'taxAmount', i.tax_amount) ORDER BY i.line_no)
                      FROM pos.sale_items i JOIN pos.products p ON p.id = i.product_id
                      WHERE i.sale_id = v_sale.id AND i.status = 'ACTIVE'),
            'payments', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                             'externalId', y.id, 'paymentMethodId',
                             pos.openbravo_id(v_sale.organization_id, 'PAYMENT_METHOD', y.payment_method_id, y.method_code),
                             'methodCode', y.method_code, 'amount', y.amount, 'amountReceived', y.amount_received,
                             'changeAmount', y.change_amount, 'reference', y.reference_number, 'paidAt', y.paid_at)
                             ORDER BY y.created_at), '[]'::jsonb)
                         FROM pos.payments y WHERE y.sale_id = v_sale.id AND y.status = 'PAID'));
    ELSIF v_job.job_type = 'RETURN' THEN
        SELECT * INTO v_ret FROM pos.returns WHERE id = v_job.entity_id;
        SELECT * INTO v_sale FROM pos.sales WHERE id = v_ret.original_sale_id;
        SELECT o.default_warehouse_id INTO v_wh FROM pos.outlets o WHERE o.id = v_ret.outlet_id;
        RETURN jsonb_build_object(
            'documentType', 'RETURN',
            'externalId', v_ret.id,
            'documentNo', v_ret.return_no,
            'originalExternalId', v_sale.id,
            'originalDocumentId', v_sale.openbravo_document_id,
            'originalDocumentNo', v_sale.openbravo_document_no,
            'organizationId', pos.openbravo_id(v_ret.organization_id, 'ORGANIZATION', v_ret.organization_id, 'organisasi'),
            'outletId', pos.openbravo_id(v_ret.organization_id, 'OUTLET', v_ret.outlet_id,
                                         (SELECT code FROM pos.outlets WHERE id = v_ret.outlet_id)),
            'warehouseId', pos.openbravo_id(v_ret.organization_id, 'WAREHOUSE', v_wh,
                                            (SELECT code FROM pos.warehouses WHERE id = v_wh)),
            'terminalId', pos.openbravo_id(v_ret.organization_id, 'TERMINAL', v_ret.terminal_id,
                                           (SELECT code FROM pos.terminals WHERE id = v_ret.terminal_id)),
            'businessDate', v_ret.business_date, 'approvedAt', v_ret.approved_at, 'reason', v_ret.reason,
            'totalAmount', v_ret.total_amount, 'taxAmount', v_ret.tax_amount,
            'lines', (SELECT jsonb_agg(jsonb_build_object(
                          'productId', p.openbravo_product_id, 'sku', ri.sku, 'quantity', ri.quantity, 'uom', ri.uom,
                          'unitPrice', ri.unit_price, 'amount', ri.amount, 'taxAmount', ri.tax_amount,
                          'returnToStock', ri.return_to_stock, 'originalLineNo', si.line_no) ORDER BY si.line_no)
                      FROM pos.return_items ri JOIN pos.products p ON p.id = ri.product_id
                      JOIN pos.sale_items si ON si.id = ri.sale_item_id
                      WHERE ri.return_id = v_ret.id),
            'refunds', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'externalId', f.id, 'originalPaymentExternalId', f.original_payment_id,
                            'paymentMethodId', pos.openbravo_id(v_ret.organization_id, 'PAYMENT_METHOD', f.payment_method_id,
                                                                f.refund_method),
                            'methodCode', f.refund_method, 'amount', f.refund_amount, 'reference', f.reference_number)
                            ORDER BY f.created_at), '[]'::jsonb)
                        FROM pos.refunds f WHERE f.return_id = v_ret.id));
    ELSIF v_job.job_type = 'CASHUP' THEN
        SELECT * INTO v_cu FROM pos.cashups WHERE id = v_job.entity_id;
        RETURN jsonb_build_object(
            'documentType', 'CASHUP',
            'externalId', v_cu.id,
            'organizationId', pos.openbravo_id(v_cu.organization_id, 'ORGANIZATION', v_cu.organization_id, 'organisasi'),
            'outletId', pos.openbravo_id(v_cu.organization_id, 'OUTLET', v_cu.outlet_id,
                                         (SELECT code FROM pos.outlets WHERE id = v_cu.outlet_id)),
            'terminalId', pos.openbravo_id(v_cu.organization_id, 'TERMINAL', v_cu.terminal_id,
                                           (SELECT code FROM pos.terminals WHERE id = v_cu.terminal_id)),
            'businessDate', v_cu.business_date, 'zNumber', v_cu.z_number,
            'expectedCash', v_cu.expected_cash, 'actualCash', v_cu.actual_cash, 'difference', v_cu.difference,
            'report', v_cu.report,
            'documents', (SELECT coalesce(jsonb_agg(jsonb_build_object('externalId', s.id, 'documentNo', s.receipt_no,
                                                                       'openbravoDocumentId', s.openbravo_document_id)),
                                          '[]'::jsonb)
                          FROM pos.sales s WHERE s.cashier_session_id = v_cu.cashier_session_id
                            AND s.status IN ('PAID', 'POSTED', 'SYNC_ERROR', 'RETURNED')));
    END IF;
    RAISE EXCEPTION 'SYNC_JOB_INVALID: % has no payload', v_job.job_type USING ERRCODE = 'P0001';
END
$$;
REVOKE ALL ON FUNCTION pos.sync_payload(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.sync_payload(uuid) TO pos_system;

-- Dokumen yang harus terkirim lebih dulu (retur butuh pesanan asal; cash-up butuh semua dokumen session).
CREATE FUNCTION pos.sync_waiting_for(p_job uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT CASE j.job_type
        WHEN 'RETURN' THEN (
            SELECT 'penjualan ' || d.entity_ref FROM pos.returns r
            JOIN pos.sync_jobs d ON d.job_type = 'SALE' AND d.entity_id = r.original_sale_id
            WHERE r.id = j.entity_id AND d.status <> 'SUCCESS')
        WHEN 'CASHUP' THEN (
            SELECT count(*) || ' dokumen session' FROM pos.cashups c
            JOIN pos.sync_jobs d ON d.job_type IN ('SALE', 'RETURN') AND d.status <> 'SUCCESS'
            AND d.entity_id IN (SELECT s.id FROM pos.sales s WHERE s.cashier_session_id = c.cashier_session_id
                                UNION ALL SELECT r.id FROM pos.returns r WHERE r.cashier_session_id = c.cashier_session_id)
            WHERE c.id = j.entity_id
            HAVING count(*) > 0)
        END
    FROM pos.sync_jobs j WHERE j.id = p_job
$$;
REVOKE ALL ON FUNCTION pos.sync_waiting_for(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.sync_waiting_for(uuid) TO pos_system;

-- ---------------------------------------------------------------- master data masuk (Openbravo → POS, §40)
-- Setiap fungsi mengembalikan (diproses, sukses, gagal, contoh error); baris gagal tidak membatalkan yang lain.
CREATE FUNCTION pos.sync_upsert_products(p_org uuid, p_items jsonb,
                                         OUT processed integer, OUT success integer, OUT failed integer, OUT errors text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    it   jsonb;
    v_cat uuid;
    v_tax uuid;
    v_pid uuid;
    v_bc  text;
BEGIN
    processed := 0; success := 0; failed := 0; errors := NULL;
    FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) LOOP
        processed := processed + 1;
        BEGIN
            v_cat := NULL;
            IF it ->> 'categoryId' IS NOT NULL THEN
                INSERT INTO pos.product_categories (organization_id, code, name, openbravo_category_id, synced_at)
                VALUES (p_org, coalesce(it ->> 'categoryCode', it ->> 'categoryId'), coalesce(it ->> 'categoryName', it ->> 'categoryId'),
                        it ->> 'categoryId', now())
                ON CONFLICT (organization_id, code) DO UPDATE
                    SET name = EXCLUDED.name, openbravo_category_id = EXCLUDED.openbravo_category_id,
                        synced_at = now(), updated_at = now()
                RETURNING id INTO v_cat;
            END IF;
            SELECT m.pos_id INTO v_tax FROM pos.openbravo_mappings m
            WHERE m.organization_id = p_org AND m.entity_type = 'TAX' AND m.openbravo_id = it ->> 'taxId';
            INSERT INTO pos.products (organization_id, openbravo_product_id, sku, name, category_id, uom, allow_decimal_qty,
                                      tax_rate_id, active, source, synced_at)
            VALUES (p_org, it ->> 'id', it ->> 'sku', it ->> 'name', v_cat, coalesce(it ->> 'uom', 'PCS'),
                    coalesce((it ->> 'allowDecimal')::boolean, false), v_tax, coalesce((it ->> 'active')::boolean, true),
                    'OPENBRAVO', now())
            ON CONFLICT (organization_id, sku) DO UPDATE
                SET openbravo_product_id = EXCLUDED.openbravo_product_id, name = EXCLUDED.name,
                    category_id = coalesce(EXCLUDED.category_id, pos.products.category_id), uom = EXCLUDED.uom,
                    allow_decimal_qty = EXCLUDED.allow_decimal_qty,
                    tax_rate_id = coalesce(EXCLUDED.tax_rate_id, pos.products.tax_rate_id),
                    active = EXCLUDED.active, synced_at = now(), updated_at = now()
            RETURNING id INTO v_pid;
            FOR v_bc IN SELECT jsonb_array_elements_text(coalesce(it -> 'barcodes', '[]'::jsonb)) LOOP
                INSERT INTO pos.product_barcodes (organization_id, product_id, barcode, barcode_type, is_primary)
                SELECT p_org, v_pid, v_bc, CASE WHEN v_bc ~ '^[0-9]{13}$' THEN 'EAN13' ELSE 'INTERNAL' END,
                       NOT EXISTS (SELECT 1 FROM pos.product_barcodes b WHERE b.product_id = v_pid AND b.is_primary AND b.active)
                WHERE NOT EXISTS (SELECT 1 FROM pos.product_barcodes b
                                  WHERE b.organization_id = p_org AND b.barcode = v_bc AND b.active);
            END LOOP;
            success := success + 1;
        EXCEPTION WHEN others THEN
            failed := failed + 1;
            errors := coalesce(errors || '; ', '') || coalesce(it ->> 'sku', '?') || ': ' || left(SQLERRM, 120);
        END;
    END LOOP;
END
$$;

CREATE FUNCTION pos.sync_upsert_prices(p_org uuid, p_items jsonb,
                                       OUT processed integer, OUT success integer, OUT failed integer, OUT errors text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    it      jsonb;
    v_pid   uuid;
    v_out   uuid;
    v_cur   numeric;
    v_ver   integer;
BEGIN
    processed := 0; success := 0; failed := 0; errors := NULL;
    FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) LOOP
        processed := processed + 1;
        BEGIN
            SELECT id INTO v_pid FROM pos.products WHERE organization_id = p_org AND openbravo_product_id = it ->> 'productId';
            IF v_pid IS NULL THEN
                RAISE EXCEPTION 'product % not synced yet', it ->> 'productId';
            END IF;
            v_out := NULL;
            IF it ->> 'outletId' IS NOT NULL THEN
                SELECT m.pos_id INTO v_out FROM pos.openbravo_mappings m
                WHERE m.organization_id = p_org AND m.entity_type = 'OUTLET' AND m.openbravo_id = it ->> 'outletId';
                IF v_out IS NULL THEN
                    RAISE EXCEPTION 'outlet % not mapped', it ->> 'outletId';
                END IF;
            END IF;
            SELECT c.price, c.version INTO v_cur, v_ver FROM pos.product_price_cache c
            WHERE c.product_id = v_pid AND c.outlet_id IS NOT DISTINCT FROM v_out AND c.price_list_code = 'DEFAULT'
            ORDER BY c.version DESC LIMIT 1;
            -- harga berubah = versi baru (riwayat harga tidak ditimpa, §17)
            IF v_cur IS DISTINCT FROM (it ->> 'price')::numeric THEN
                INSERT INTO pos.product_price_cache (organization_id, product_id, outlet_id, price, source, version, valid_from)
                VALUES (p_org, v_pid, v_out, (it ->> 'price')::numeric, 'OPENBRAVO', coalesce(v_ver, 0) + 1,
                        coalesce((it ->> 'validFrom')::timestamptz, now()));
            END IF;
            success := success + 1;
        EXCEPTION WHEN others THEN
            failed := failed + 1;
            errors := coalesce(errors || '; ', '') || coalesce(it ->> 'productId', '?') || ': ' || left(SQLERRM, 120);
        END;
    END LOOP;
END
$$;

CREATE FUNCTION pos.sync_upsert_stock(p_org uuid, p_items jsonb,
                                      OUT processed integer, OUT success integer, OUT failed integer, OUT errors text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    it    jsonb;
    v_pid uuid;
    v_wh  uuid;
BEGIN
    processed := 0; success := 0; failed := 0; errors := NULL;
    FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) LOOP
        processed := processed + 1;
        BEGIN
            SELECT id INTO v_pid FROM pos.products WHERE organization_id = p_org AND openbravo_product_id = it ->> 'productId';
            SELECT m.pos_id INTO v_wh FROM pos.openbravo_mappings m
            WHERE m.organization_id = p_org AND m.entity_type = 'WAREHOUSE' AND m.openbravo_id = it ->> 'warehouseId';
            IF v_pid IS NULL OR v_wh IS NULL THEN
                RAISE EXCEPTION 'product % / warehouse % not mapped', it ->> 'productId', it ->> 'warehouseId';
            END IF;
            -- snapshot stok Openbravo (bukan dihitung POS, §3.2 / §34)
            INSERT INTO pos.product_stock_cache (organization_id, product_id, warehouse_id, openbravo_product_id, quantity,
                                                 available_quantity, source, synced_at)
            VALUES (p_org, v_pid, v_wh, it ->> 'productId', (it ->> 'quantity')::numeric,
                    coalesce((it ->> 'available')::numeric, (it ->> 'quantity')::numeric), 'OPENBRAVO', now())
            ON CONFLICT (product_id, warehouse_id) DO UPDATE
                SET quantity = EXCLUDED.quantity, available_quantity = EXCLUDED.available_quantity,
                    openbravo_product_id = EXCLUDED.openbravo_product_id, source = 'OPENBRAVO', synced_at = now();
            success := success + 1;
        EXCEPTION WHEN others THEN
            failed := failed + 1;
            errors := coalesce(errors || '; ', '') || coalesce(it ->> 'productId', '?') || ': ' || left(SQLERRM, 120);
        END;
    END LOOP;
END
$$;

CREATE FUNCTION pos.sync_upsert_customers(p_org uuid, p_items jsonb,
                                          OUT processed integer, OUT success integer, OUT failed integer, OUT errors text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    it jsonb;
BEGIN
    processed := 0; success := 0; failed := 0; errors := NULL;
    FOR it IN SELECT * FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) LOOP
        processed := processed + 1;
        BEGIN
            -- kunci = ID Openbravo, sehingga sinkron berulang tidak membuat customer duplikat (§19)
            INSERT INTO pos.customers (organization_id, openbravo_customer_id, code, name, phone, email, tax_id, active, synced_at)
            VALUES (p_org, it ->> 'id', coalesce(it ->> 'code', it ->> 'id'), it ->> 'name', it ->> 'phone', it ->> 'email',
                    it ->> 'taxId', coalesce((it ->> 'active')::boolean, true), now())
            ON CONFLICT (organization_id, openbravo_customer_id) DO UPDATE
                SET code = EXCLUDED.code, name = EXCLUDED.name, phone = EXCLUDED.phone, email = EXCLUDED.email,
                    tax_id = EXCLUDED.tax_id, active = EXCLUDED.active, synced_at = now(), updated_at = now();
            success := success + 1;
        EXCEPTION WHEN others THEN
            failed := failed + 1;
            errors := coalesce(errors || '; ', '') || coalesce(it ->> 'id', '?') || ': ' || left(SQLERRM, 120);
        END;
    END LOOP;
END
$$;
REVOKE ALL ON FUNCTION pos.sync_upsert_products(uuid, jsonb), pos.sync_upsert_prices(uuid, jsonb),
    pos.sync_upsert_stock(uuid, jsonb), pos.sync_upsert_customers(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.sync_upsert_products(uuid, jsonb), pos.sync_upsert_prices(uuid, jsonb),
    pos.sync_upsert_stock(uuid, jsonb), pos.sync_upsert_customers(uuid, jsonb) TO pos_system;
