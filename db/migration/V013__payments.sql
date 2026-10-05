-- V013: pembayaran — metode, split payment, tunai & kembalian, non-tunai, QRIS/e-wallet via gateway (§22, §23, §24, §63, §64)
--
-- Prinsip:
--  * Status sale diturunkan dari tabel payments oleh DATABASE (§23): PAID hanya bila
--    Σ pembayaran sukses ≥ grand total dan tidak ada yang PENDING. Client tidak pernah mengirim "lunas".
--  * Tunai: client mengirim uang diterima; database menghitung jumlah yang diterapkan
--    (min(diterima, sisa tagihan)) dan kembalian (§24, ASSUMPTIONS A5). Kelebihan bayar hanya untuk tunai.
--  * Pembayaran tunai yang sukses langsung tercatat sebagai cash movement CASH_SALE (jumlah diterapkan).
--  * Gateway (QRIS/e-wallet): PENDING sampai callback/polling server menyatakan sukses (§64). User
--    tidak bisa menandai PAID, kecuali metode dikonfigurasi boleh dikonfirmasi manual DAN ada approval
--    supervisor (`payment.approve`).
--  * Pembayaran tidak pernah dihapus; koreksi = CANCELLED (pembalikan, dengan alasan) atau REFUNDED (Phase 8).

-- ---------------------------------------------------------------- izin & setting
INSERT INTO pos.permissions (code, module, description) VALUES
    ('payment.approve', 'payment', 'Setujui konfirmasi manual pembayaran non-tunai (transfer, QRIS statis)');

INSERT INTO pos.role_permissions (role_id, permission_code)
SELECT r.id, 'payment.approve' FROM pos.roles r WHERE r.code IN ('SUPER_ADMIN', 'STORE_MANAGER', 'SUPERVISOR')
ON CONFLICT DO NOTHING;

INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('payment_pending_timeout_minutes', 'NUMBER', '15',
     'Batas waktu pembayaran QRIS/e-wallet menunggu konfirmasi sebelum dibatalkan otomatis', 'OUTLET');

-- ---------------------------------------------------------------- metode pembayaran
CREATE TABLE pos.payment_methods (
    id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id               uuid        NOT NULL REFERENCES pos.organizations (id),
    code                          text        NOT NULL,
    name                          text        NOT NULL,
    kind                          text        NOT NULL,
    -- IMMEDIATE: sukses saat dicatat (tunai); MANUAL: kasir memasukkan nomor referensi (EDC, transfer);
    -- GATEWAY: menunggu konfirmasi penyedia pembayaran (QRIS dinamis, e-wallet).
    confirmation                  text        NOT NULL,
    requires_reference            boolean     NOT NULL DEFAULT false,
    -- MANUAL: wajib approval supervisor saat dicatat. GATEWAY: boleh dikonfirmasi manual dengan approval.
    requires_approval             boolean     NOT NULL DEFAULT false,
    manual_confirm_allowed        boolean     NOT NULL DEFAULT false,
    active                        boolean     NOT NULL DEFAULT true,
    sort_order                    integer     NOT NULL DEFAULT 0,
    openbravo_payment_method_id   text,
    created_at                    timestamptz NOT NULL DEFAULT now(),
    updated_at                    timestamptz NOT NULL DEFAULT now(),
    updated_by                    uuid,
    version                       integer     NOT NULL DEFAULT 0,
    CONSTRAINT payment_methods_code_ck CHECK (code ~ '^[A-Z0-9_]{2,32}$'),
    CONSTRAINT payment_methods_org_code_uk UNIQUE (organization_id, code),
    CONSTRAINT payment_methods_kind_ck CHECK (kind IN ('CASH', 'CARD', 'QRIS', 'EWALLET', 'TRANSFER', 'OTHER')),
    CONSTRAINT payment_methods_confirmation_ck CHECK (confirmation IN ('IMMEDIATE', 'MANUAL', 'GATEWAY')),
    -- hanya tunai yang langsung sukses tanpa bukti; tunai selalu IMMEDIATE
    CONSTRAINT payment_methods_cash_ck CHECK ((kind = 'CASH') = (confirmation = 'IMMEDIATE')),
    CONSTRAINT payment_methods_manual_ref_ck CHECK (confirmation <> 'MANUAL' OR requires_reference),
    CONSTRAINT payment_methods_manual_confirm_ck CHECK (NOT manual_confirm_allowed OR confirmation = 'GATEWAY')
);

CREATE OR REPLACE FUNCTION pos.seed_default_payment_methods(p_org uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    INSERT INTO pos.payment_methods (organization_id, code, name, kind, confirmation, requires_reference,
                                     requires_approval, manual_confirm_allowed, sort_order)
    VALUES (p_org, 'CASH',          'Tunai',          'CASH',     'IMMEDIATE', false, false, false, 10),
           (p_org, 'DEBIT_CARD',    'Kartu Debit',    'CARD',     'MANUAL',    true,  false, false, 20),
           (p_org, 'CREDIT_CARD',   'Kartu Kredit',   'CARD',     'MANUAL',    true,  false, false, 30),
           (p_org, 'QRIS',          'QRIS',           'QRIS',     'GATEWAY',   false, true,  false, 40),
           (p_org, 'E_WALLET',      'E-Wallet',       'EWALLET',  'GATEWAY',   false, true,  false, 50),
           (p_org, 'BANK_TRANSFER', 'Transfer Bank',  'TRANSFER', 'MANUAL',    true,  true,  false, 60)
    ON CONFLICT DO NOTHING
$$;
REVOKE ALL ON FUNCTION pos.seed_default_payment_methods(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pos.tg_org_default_payment_methods()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.seed_default_payment_methods(NEW.id);
    RETURN NULL;
END
$$;
CREATE TRIGGER organizations_default_payment_methods AFTER INSERT ON pos.organizations
    FOR EACH ROW EXECUTE FUNCTION pos.tg_org_default_payment_methods();
SELECT pos.seed_default_payment_methods(id) FROM pos.organizations;

CREATE OR REPLACE FUNCTION pos.tg_payment_method_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.code <> OLD.code OR NEW.organization_id <> OLD.organization_id OR NEW.kind <> OLD.kind THEN
        RAISE EXCEPTION 'PAYMENT_METHOD_IMMUTABLE_FIELD: code and kind cannot change' USING ERRCODE = 'P0001';
    END IF;
    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;
CREATE TRIGGER payment_methods_guard BEFORE UPDATE ON pos.payment_methods
    FOR EACH ROW EXECUTE FUNCTION pos.tg_payment_method_guard();
CREATE TRIGGER payment_methods_no_delete BEFORE DELETE ON pos.payment_methods
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- ---------------------------------------------------------------- sale: kolom pembayaran
ALTER TABLE pos.sales
    ADD COLUMN paid_amount   numeric(18,2) NOT NULL DEFAULT 0,
    ADD COLUMN change_amount numeric(18,2) NOT NULL DEFAULT 0,
    ADD COLUMN paid_at       timestamptz,
    ADD CONSTRAINT sales_paid_ck CHECK (paid_amount >= 0 AND change_amount >= 0
        AND (status <> 'PAID' OR (paid_at IS NOT NULL AND paid_amount >= grand_total)));

-- approval konfirmasi pembayaran: price = jumlah pembayaran yang disetujui
ALTER TABLE pos.approvals DROP CONSTRAINT approvals_action_ck;
ALTER TABLE pos.approvals
    ADD CONSTRAINT approvals_action_ck CHECK (action IN ('DISCOUNT', 'PRICE_OVERRIDE', 'VOID_SALE', 'PAYMENT_CONFIRM')),
    ADD CONSTRAINT approvals_payment_ck CHECK (action <> 'PAYMENT_CONFIRM' OR price > 0);

-- pembalikan pembayaran tunai (sebelum transaksi lunas) — bukan refund
ALTER TABLE pos.cash_movements DROP CONSTRAINT cash_movements_type_ck;
ALTER TABLE pos.cash_movements DROP CONSTRAINT cash_movements_sign_ck;
ALTER TABLE pos.cash_movements
    ADD CONSTRAINT cash_movements_type_ck CHECK (movement_type IN (
        'OPENING_CASH', 'CASH_SALE', 'CASH_SALE_REVERSAL', 'CASH_IN', 'CASH_OUT', 'PETTY_CASH', 'CASH_REFUND',
        'CASH_ADJUSTMENT', 'CLOSING_CASH')),
    ADD CONSTRAINT cash_movements_sign_ck CHECK (
        (movement_type = 'OPENING_CASH' AND amount >= 0)
        OR (movement_type IN ('CASH_SALE', 'CASH_IN') AND amount > 0)
        OR (movement_type IN ('CASH_OUT', 'PETTY_CASH', 'CASH_REFUND', 'CLOSING_CASH', 'CASH_SALE_REVERSAL') AND amount < 0)
        OR (movement_type = 'CASH_ADJUSTMENT' AND amount <> 0));

-- ---------------------------------------------------------------- payments
CREATE TABLE pos.payments (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id          uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id                uuid          NOT NULL,
    sale_id                  uuid          NOT NULL REFERENCES pos.sales (id),
    cashier_session_id       uuid          NOT NULL REFERENCES pos.cashier_sessions (id),
    payment_method_id        uuid          NOT NULL REFERENCES pos.payment_methods (id),
    method_code              text          NOT NULL,
    method_kind              text          NOT NULL,
    confirmation             text          NOT NULL,
    client_payment_id        text          NOT NULL,
    -- jumlah yang diterapkan ke tagihan; untuk tunai: uang diterima & kembalian disimpan terpisah (§24)
    amount                   numeric(18,2) NOT NULL,
    amount_received          numeric(18,2) NOT NULL,
    change_amount            numeric(18,2) NOT NULL DEFAULT 0,
    status                   text          NOT NULL DEFAULT 'PENDING',
    reference_number         text,
    provider                 text,
    external_transaction_id  text,
    qr_payload               text,
    expires_at               timestamptz,
    paid_at                  timestamptz,
    failed_reason            text,
    cancel_reason            text,
    cancelled_at             timestamptz,
    cancelled_by             uuid,
    created_by               uuid          NOT NULL,
    confirmed_by             uuid,
    approval_id              uuid REFERENCES pos.approvals (id),
    approved_by              uuid,
    created_tx               bigint        NOT NULL DEFAULT txid_current(),
    created_at               timestamptz   NOT NULL DEFAULT now(),
    updated_at               timestamptz   NOT NULL DEFAULT now(),
    version                  integer       NOT NULL DEFAULT 0,
    CONSTRAINT payments_status_ck CHECK (status IN ('PENDING', 'PAID', 'FAILED', 'CANCELLED', 'REFUNDED')),
    CONSTRAINT payments_outlet_fk FOREIGN KEY (outlet_id, organization_id) REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT payments_client_uk UNIQUE (organization_id, client_payment_id),
    CONSTRAINT payments_client_ck CHECK (client_payment_id ~ '^[A-Za-z0-9._:-]{8,80}$'),
    CONSTRAINT payments_amount_ck CHECK (amount > 0 AND amount = round(amount, 0)
        AND amount_received = round(amount_received, 0) AND amount_received <= 1000000000000),
    CONSTRAINT payments_change_ck CHECK (change_amount >= 0 AND amount_received = amount + change_amount),
    CONSTRAINT payments_change_cash_ck CHECK (method_kind = 'CASH' OR change_amount = 0),
    CONSTRAINT payments_paid_ck CHECK ((status <> 'PENDING' OR paid_at IS NULL)
        AND (status NOT IN ('PAID', 'REFUNDED') OR paid_at IS NOT NULL)),
    CONSTRAINT payments_cancel_ck CHECK (status <> 'CANCELLED'
        OR (cancelled_at IS NOT NULL AND pg_catalog.length(btrim(cancel_reason)) >= 5)),
    CONSTRAINT payments_external_uk UNIQUE (provider, external_transaction_id)
);
CREATE INDEX payments_sale_idx ON pos.payments (sale_id);
CREATE INDEX payments_status_idx ON pos.payments (status);
CREATE INDEX payments_session_idx ON pos.payments (cashier_session_id);
CREATE INDEX payments_pending_idx ON pos.payments (expires_at) WHERE status = 'PENDING';

-- ---------------------------------------------------------------- guard: payments
CREATE OR REPLACE FUNCTION pos.tg_payment_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale      pos.sales%ROWTYPE;
    v_session   pos.cashier_sessions%ROWTYPE;
    v_method    pos.payment_methods%ROWTYPE;
    v_remaining numeric;
    v_appr      pos.approvals%ROWTYPE;
    v_user      boolean := pos.jwt_sub() IS NOT NULL;   -- false = konteks sistem (callback/job)
    v_timeout   numeric;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NOT v_user THEN
            RAISE EXCEPTION 'PAYMENT_INVALID: payments are created by the cashier' USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_sale FROM pos.sales WHERE id = NEW.sale_id FOR UPDATE;
        IF v_sale.id IS NULL THEN
            RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_sale.status = 'PAID' THEN
            RAISE EXCEPTION 'SALE_ALREADY_PAID: sale % is already paid', v_sale.id USING ERRCODE = 'P0001';
        END IF;
        IF v_sale.status NOT IN ('CHECKOUT', 'PAYMENT_PENDING') THEN
            RAISE EXCEPTION 'SALE_NOT_PAYABLE: checkout the sale first (status %)', v_sale.status USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_session FROM pos.cashier_sessions WHERE id = v_sale.cashier_session_id;
        IF v_session.status <> 'OPEN' THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: cashier session is not open' USING ERRCODE = 'P0001';
        END IF;
        IF v_sale.employee_id IS DISTINCT FROM pos.current_employee_id() THEN
            RAISE EXCEPTION 'CASHIER_SESSION_NOT_OWNER: only the cashier of this sale can take payment' USING ERRCODE = 'P0001';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pos.attendance a WHERE a.employee_id = v_sale.employee_id
                       AND a.status = 'WORKING' AND a.outlet_id = v_sale.outlet_id) THEN
            RAISE EXCEPTION 'ATTENDANCE_REQUIRED: clock in / end break first' USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_method FROM pos.payment_methods WHERE id = NEW.payment_method_id;
        IF v_method.id IS NULL OR v_method.organization_id <> v_sale.organization_id OR NOT v_method.active THEN
            RAISE EXCEPTION 'PAYMENT_METHOD_INVALID: method not available' USING ERRCODE = 'P0001';
        END IF;

        SELECT v_sale.grand_total - coalesce(sum(p.amount), 0) INTO v_remaining
        FROM pos.payments p WHERE p.sale_id = v_sale.id AND p.status IN ('PAID', 'PENDING');
        IF v_remaining <= 0 THEN
            RAISE EXCEPTION 'SALE_ALREADY_PAID: nothing left to pay (pending payments cover the total)' USING ERRCODE = 'P0001';
        END IF;

        NEW.organization_id := v_sale.organization_id;
        NEW.outlet_id := v_sale.outlet_id;
        NEW.cashier_session_id := v_sale.cashier_session_id;
        NEW.method_code := v_method.code;
        NEW.method_kind := v_method.kind;
        NEW.confirmation := v_method.confirmation;
        NEW.created_by := pos.current_app_user_id();
        NEW.created_at := now();
        NEW.updated_at := now();
        NEW.created_tx := txid_current();
        NEW.version := 0;
        NEW.provider := NULL; NEW.external_transaction_id := NULL; NEW.qr_payload := NULL; NEW.expires_at := NULL;
        NEW.failed_reason := NULL; NEW.cancel_reason := NULL; NEW.cancelled_at := NULL; NEW.cancelled_by := NULL;
        NEW.reference_number := nullif(btrim(NEW.reference_number), '');

        IF v_method.kind = 'CASH' THEN
            -- §24 / A5: diterapkan = min(diterima, sisa); kembalian = diterima − diterapkan
            IF NEW.amount_received IS NULL OR NEW.amount_received <= 0 THEN
                RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID: cash received must be positive' USING ERRCODE = 'P0001';
            END IF;
            NEW.amount := least(NEW.amount_received, v_remaining);
            NEW.change_amount := NEW.amount_received - NEW.amount;
        ELSE
            -- non-tunai tidak boleh melebihi sisa tagihan (A5)
            IF NEW.amount IS NULL OR NEW.amount <= 0 THEN
                RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID: amount must be positive' USING ERRCODE = 'P0001';
            END IF;
            IF NEW.amount > v_remaining THEN
                RAISE EXCEPTION 'PAYMENT_EXCEEDS_REMAINING: % exceeds remaining %', NEW.amount, v_remaining USING ERRCODE = 'P0001';
            END IF;
            NEW.amount_received := NEW.amount;
            NEW.change_amount := 0;
        END IF;

        IF v_method.requires_reference AND pg_catalog.length(coalesce(NEW.reference_number, '')) < 3 THEN
            RAISE EXCEPTION 'PAYMENT_REFERENCE_REQUIRED: % needs a reference number', v_method.code USING ERRCODE = 'P0001';
        END IF;

        IF v_method.confirmation = 'GATEWAY' THEN
            NEW.status := 'PENDING';
            NEW.paid_at := NULL;
            NEW.confirmed_by := NULL; NEW.approval_id := NULL; NEW.approved_by := NULL;
            v_timeout := coalesce((pos.get_setting('payment_pending_timeout_minutes', v_sale.outlet_id))::numeric, 15);
            NEW.expires_at := now() + make_interval(mins => greatest(1, v_timeout)::integer);
        ELSE
            IF v_method.confirmation = 'MANUAL' AND v_method.requires_approval THEN
                SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.approval_id;
                IF v_appr.id IS NULL OR v_appr.action <> 'PAYMENT_CONFIRM' OR v_appr.sale_id <> v_sale.id
                   OR v_appr.price <> NEW.amount OR v_appr.used_at IS NULL
                   OR v_appr.requested_by <> NEW.created_by THEN
                    RAISE EXCEPTION 'APPROVAL_REQUIRED: % payment needs supervisor confirmation', v_method.code
                        USING ERRCODE = 'P0001';
                END IF;
                NEW.approved_by := v_appr.approved_by;
            ELSE
                NEW.approval_id := NULL;
                NEW.approved_by := NULL;
            END IF;
            NEW.status := 'PAID';
            NEW.paid_at := now();
            NEW.confirmed_by := NEW.created_by;
        END IF;
        RETURN NEW;
    END IF;

    -- UPDATE
    IF NEW.organization_id <> OLD.organization_id OR NEW.outlet_id <> OLD.outlet_id OR NEW.sale_id <> OLD.sale_id
       OR NEW.cashier_session_id <> OLD.cashier_session_id OR NEW.payment_method_id <> OLD.payment_method_id
       OR NEW.method_code <> OLD.method_code OR NEW.method_kind <> OLD.method_kind
       OR NEW.confirmation <> OLD.confirmation OR NEW.client_payment_id <> OLD.client_payment_id
       OR NEW.amount <> OLD.amount OR NEW.amount_received <> OLD.amount_received
       OR NEW.change_amount <> OLD.change_amount OR NEW.created_by <> OLD.created_by
       OR NEW.created_at <> OLD.created_at OR NEW.created_tx <> OLD.created_tx
       OR NEW.paid_at IS DISTINCT FROM OLD.paid_at THEN
        RAISE EXCEPTION 'PAYMENT_IMMUTABLE_FIELD: amounts and identity cannot change' USING ERRCODE = 'P0001';
    END IF;
    -- data gateway: diisi sekali, saat pembayaran dibuat (transaksi yang sama)
    IF (NEW.provider, NEW.external_transaction_id, NEW.qr_payload, NEW.expires_at)
       IS DISTINCT FROM (OLD.provider, OLD.external_transaction_id, OLD.qr_payload, OLD.expires_at) THEN
        IF OLD.status <> 'PENDING' OR OLD.external_transaction_id IS NOT NULL OR OLD.created_tx <> txid_current() THEN
            RAISE EXCEPTION 'PAYMENT_IMMUTABLE_FIELD: gateway data is set once' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF OLD.status = 'PENDING' AND NEW.status = 'PAID' THEN
            IF v_user THEN
                -- §64: konfirmasi manual hanya bila metode mengizinkan, dengan approval & nomor referensi
                SELECT * INTO v_method FROM pos.payment_methods WHERE id = OLD.payment_method_id;
                SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.approval_id;
                IF NOT v_method.manual_confirm_allowed THEN
                    RAISE EXCEPTION 'PAYMENT_CONFIRMATION_REQUIRED: waiting for the payment provider' USING ERRCODE = 'P0001';
                END IF;
                IF v_appr.id IS NULL OR v_appr.action <> 'PAYMENT_CONFIRM' OR v_appr.sale_id <> OLD.sale_id
                   OR v_appr.price <> OLD.amount OR v_appr.used_at IS NULL
                   OR v_appr.requested_by <> pos.current_app_user_id() THEN
                    RAISE EXCEPTION 'APPROVAL_REQUIRED: manual confirmation needs supervisor approval' USING ERRCODE = 'P0001';
                END IF;
                IF pg_catalog.length(btrim(coalesce(NEW.reference_number, ''))) < 3 THEN
                    RAISE EXCEPTION 'PAYMENT_REFERENCE_REQUIRED: enter the payment reference' USING ERRCODE = 'P0001';
                END IF;
                NEW.approved_by := v_appr.approved_by;
                NEW.confirmed_by := pos.current_app_user_id();
            ELSE
                NEW.approval_id := OLD.approval_id;
                NEW.approved_by := OLD.approved_by;
                NEW.confirmed_by := NULL;
            END IF;
            NEW.paid_at := now();
        ELSIF OLD.status = 'PENDING' AND NEW.status = 'FAILED' THEN
            IF v_user THEN
                RAISE EXCEPTION 'PAYMENT_INVALID_TRANSITION: only the payment provider can fail a payment' USING ERRCODE = 'P0001';
            END IF;
            NEW.failed_reason := coalesce(nullif(btrim(NEW.failed_reason), ''), 'FAILED');
        ELSIF OLD.status = 'PENDING' AND NEW.status = 'CANCELLED' THEN
            NEW.cancelled_at := now();
            NEW.cancelled_by := pos.current_app_user_id();
            NEW.cancel_reason := coalesce(nullif(btrim(NEW.cancel_reason), ''), 'Dibatalkan');
            IF pg_catalog.length(NEW.cancel_reason) < 5 THEN
                NEW.cancel_reason := 'Dibatalkan: ' || NEW.cancel_reason;
            END IF;
        ELSIF OLD.status = 'PAID' AND NEW.status = 'CANCELLED' THEN
            -- pembalikan sebelum transaksi lunas (mis. split dibatalkan). Setelah lunas: refund (Phase 8).
            SELECT * INTO v_sale FROM pos.sales WHERE id = OLD.sale_id FOR UPDATE;
            IF v_sale.status NOT IN ('CHECKOUT', 'PAYMENT_PENDING') THEN
                RAISE EXCEPTION 'PAYMENT_NOT_REVERSIBLE: sale is %, use refund instead', v_sale.status USING ERRCODE = 'P0001';
            END IF;
            IF OLD.confirmation = 'GATEWAY' THEN
                RAISE EXCEPTION 'PAYMENT_NOT_REVERSIBLE: gateway payments are reversed through refund' USING ERRCODE = 'P0001';
            END IF;
            IF NOT v_user THEN
                RAISE EXCEPTION 'PAYMENT_INVALID_TRANSITION' USING ERRCODE = 'P0001';
            END IF;
            SELECT * INTO v_session FROM pos.cashier_sessions WHERE id = OLD.cashier_session_id;
            IF v_session.status <> 'OPEN' THEN
                RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: cashier session is not open' USING ERRCODE = 'P0001';
            END IF;
            IF pg_catalog.length(btrim(coalesce(NEW.cancel_reason, ''))) < 5 THEN
                RAISE EXCEPTION 'PAYMENT_CANCEL_REASON_REQUIRED' USING ERRCODE = 'P0001';
            END IF;
            NEW.cancelled_at := now();
            NEW.cancelled_by := pos.current_app_user_id();
        ELSIF OLD.status = 'PAID' AND NEW.status = 'REFUNDED' THEN
            RAISE EXCEPTION 'PAYMENT_INVALID_TRANSITION: refunds arrive in Phase 8' USING ERRCODE = 'P0001';
        ELSE
            RAISE EXCEPTION 'PAYMENT_INVALID_TRANSITION: % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
        END IF;
    ELSIF (NEW.reference_number, NEW.approval_id, NEW.approved_by, NEW.confirmed_by, NEW.failed_reason,
           NEW.cancel_reason, NEW.cancelled_at, NEW.cancelled_by)
          IS DISTINCT FROM (OLD.reference_number, OLD.approval_id, OLD.approved_by, OLD.confirmed_by,
                            OLD.failed_reason, OLD.cancel_reason, OLD.cancelled_at, OLD.cancelled_by) THEN
        RAISE EXCEPTION 'PAYMENT_IMMUTABLE_FIELD: change only with a status transition' USING ERRCODE = 'P0001';
    END IF;
    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;

CREATE TRIGGER payments_guard BEFORE INSERT OR UPDATE ON pos.payments
    FOR EACH ROW EXECUTE FUNCTION pos.tg_payment_guard();
CREATE TRIGGER payments_no_delete BEFORE DELETE ON pos.payments
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Status sale & cash movement mengikuti pembayaran (satu transaksi database, §63).
CREATE OR REPLACE FUNCTION pos.tg_payment_effects()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale    pos.sales%ROWTYPE;
    v_paid    numeric;
    v_pending integer;
    v_target  text;
BEGIN
    -- cash movement: tunai sukses = CASH_SALE (jumlah diterapkan, A5); pembalikan = CASH_SALE_REVERSAL
    IF NEW.method_kind = 'CASH' THEN
        IF NEW.status = 'PAID' AND (TG_OP = 'INSERT' OR OLD.status <> 'PAID') THEN
            INSERT INTO pos.cash_movements (organization_id, outlet_id, cashier_session_id, business_date,
                                            movement_type, amount, reference_type, reference_id, created_by)
            VALUES (NEW.organization_id, NEW.outlet_id, NEW.cashier_session_id, current_date,
                    'CASH_SALE', NEW.amount, 'PAYMENT', NEW.id, NEW.created_by);
        ELSIF TG_OP = 'UPDATE' AND OLD.status = 'PAID' AND NEW.status = 'CANCELLED' THEN
            INSERT INTO pos.cash_movements (organization_id, outlet_id, cashier_session_id, business_date,
                                            movement_type, amount, reference_type, reference_id, reason, created_by)
            VALUES (NEW.organization_id, NEW.outlet_id, NEW.cashier_session_id, current_date,
                    'CASH_SALE_REVERSAL', -NEW.amount, 'PAYMENT', NEW.id, NEW.cancel_reason,
                    coalesce(NEW.cancelled_by, NEW.created_by));
        END IF;
    END IF;

    -- status sale diturunkan dari pembayaran (§23)
    SELECT * INTO v_sale FROM pos.sales WHERE id = NEW.sale_id FOR UPDATE;
    IF v_sale.status NOT IN ('CHECKOUT', 'PAYMENT_PENDING') THEN
        RETURN NULL;
    END IF;
    SELECT coalesce(sum(p.amount) FILTER (WHERE p.status = 'PAID'), 0), count(*) FILTER (WHERE p.status = 'PENDING')
      INTO v_paid, v_pending
      FROM pos.payments p WHERE p.sale_id = NEW.sale_id;
    v_target := CASE WHEN v_pending > 0 THEN 'PAYMENT_PENDING'
                     WHEN v_paid >= v_sale.grand_total THEN 'PAID'
                     ELSE 'CHECKOUT' END;
    -- UPDATE selalu dijalankan agar paid_amount/change_amount sale ikut dihitung ulang oleh guard sale
    UPDATE pos.sales SET status = v_target WHERE id = NEW.sale_id;
    RETURN NULL;
END
$$;

CREATE TRIGGER payments_effects AFTER INSERT OR UPDATE ON pos.payments
    FOR EACH ROW EXECUTE FUNCTION pos.tg_payment_effects();

-- ---------------------------------------------------------------- guard sale & approval (diperbarui untuk pembayaran)
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
        NEW.paid_amount := 0; NEW.change_amount := 0; NEW.paid_at := NULL;
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
    ELSIF NEW.action = 'PAYMENT_CONFIRM' THEN
        -- konfirmasi manual pembayaran non-tunai (transfer bank, QRIS statis) — §64
        v_perm := 'payment.approve';
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

-- ---------------------------------------------------------------- privileges & RLS
GRANT SELECT, UPDATE ON pos.payment_methods TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.payment_methods TO pos_system;
GRANT SELECT, INSERT, UPDATE ON pos.payments TO pos_app_user, pos_system;

ALTER TABLE pos.payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY payment_methods_system_all ON pos.payment_methods TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY payments_system_all ON pos.payments TO pos_system USING (true) WITH CHECK (true);

CREATE POLICY payment_methods_select ON pos.payment_methods FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
-- Konfigurasi metode pembayaran: level organisasi.
CREATE POLICY payment_methods_update ON pos.payment_methods FOR UPDATE TO pos_app_user
    USING (organization_id = pos.current_org_id() AND pos.has_permission('configuration.manage', NULL))
    WITH CHECK (organization_id = pos.current_org_id() AND pos.has_permission('configuration.manage', NULL)
                AND updated_by = pos.current_app_user_id());

-- Pembayaran mengikuti visibilitas sale (subquery tunduk RLS sales).
CREATE POLICY payments_select ON pos.payments FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id));
CREATE POLICY payments_insert ON pos.payments FOR INSERT TO pos_app_user
    WITH CHECK (
        created_by = pos.current_app_user_id()
        AND pos.has_permission('sale.create', outlet_id)
        AND EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()));
-- Kasir pemilik transaksi: batalkan / konfirmasi manual (aturan detail di trigger).
CREATE POLICY payments_update ON pos.payments FOR UPDATE TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()))
    WITH CHECK (status IN ('PENDING', 'PAID', 'CANCELLED')
                AND EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id()));
