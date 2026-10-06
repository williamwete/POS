-- V017: retur & refund (Phase 8, §28, §29, §74 refund, §86)
--
-- Prinsip:
--  * Retur selalu merujuk transaksi asli; transaksi asli TIDAK diubah (§28, §86 "original remains intact").
--  * Jumlah yang bisa diretur per baris = jumlah terjual − retur sebelumnya (COMPLETED + menunggu approval);
--    retur untuk satu transaksi diserialkan dengan row lock sehingga tidak bisa melebihi sisa.
--  * Nilai refund dihitung database dari nilai bersih baris (setelah diskon); sisa terakhir sebuah baris
--    memakai sisa nilai sehingga total refund tidak pernah melebihi yang dibayar.
--  * Refund restricted (§29): wajib approval pemegang `sale.refund` (rank ≥ SUPERVISOR) yang bukan peminta,
--    kecuali `require_supervisor_for_refund` = false dan peminta sendiri punya `sale.refund`.
--  * Refund dialokasikan ke pembayaran asli (original_payment_id); refund tunai keluar dari laci session
--    pemroses retur (CASH_REFUND), tidak boleh melebihi isi laci.

-- ---------------------------------------------------------------- tabel
CREATE TABLE pos.terminal_return_sequences (
    terminal_id   uuid    NOT NULL REFERENCES pos.terminals (id),
    business_date date    NOT NULL,
    last_no       integer NOT NULL,
    PRIMARY KEY (terminal_id, business_date)
);

CREATE TABLE pos.returns (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id           uuid          NOT NULL REFERENCES pos.outlets (id),
    terminal_id         uuid          NOT NULL REFERENCES pos.terminals (id),
    cashier_session_id  uuid          NOT NULL REFERENCES pos.cashier_sessions (id),
    original_sale_id    uuid          NOT NULL REFERENCES pos.sales (id),
    client_return_id    text          NOT NULL,
    return_no           text          NOT NULL,
    business_date       date          NOT NULL,
    status              text          NOT NULL DEFAULT 'PENDING_APPROVAL',
    reason              text          NOT NULL,
    refund_mode         text          NOT NULL DEFAULT 'CASH',
    refund_reference    text,
    item_count          numeric(18,3) NOT NULL DEFAULT 0,
    total_amount        numeric(18,2) NOT NULL DEFAULT 0,
    tax_amount          numeric(18,2) NOT NULL DEFAULT 0,
    approval_id         uuid          REFERENCES pos.approvals (id),
    approved_by         uuid,
    approved_at         timestamptz,
    reject_reason       text,
    rejected_by         uuid,
    sync_status         text          NOT NULL DEFAULT 'NOT_READY',
    created_by          uuid          NOT NULL,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_tx          bigint        NOT NULL DEFAULT txid_current(),
    updated_at          timestamptz   NOT NULL DEFAULT now(),
    version             integer       NOT NULL DEFAULT 0,
    CONSTRAINT returns_no_uk UNIQUE (return_no),
    CONSTRAINT returns_client_uk UNIQUE (organization_id, client_return_id),
    CONSTRAINT returns_status_ck CHECK (status IN ('PENDING_APPROVAL', 'COMPLETED', 'REJECTED')),
    CONSTRAINT returns_mode_ck CHECK (refund_mode IN ('CASH', 'ORIGINAL')),
    CONSTRAINT returns_reason_ck CHECK (pg_catalog.length(btrim(reason)) >= 3),
    CONSTRAINT returns_amount_ck CHECK (total_amount >= 0 AND tax_amount >= 0 AND item_count >= 0),
    CONSTRAINT returns_completed_ck CHECK (status <> 'COMPLETED' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
    CONSTRAINT returns_rejected_ck CHECK (status <> 'REJECTED'
        OR (rejected_by IS NOT NULL AND pg_catalog.length(btrim(reject_reason)) >= 5)),
    CONSTRAINT returns_sync_ck CHECK (sync_status IN ('NOT_READY', 'PENDING', 'SYNCED', 'FAILED', 'MANUAL_REVIEW'))
);
CREATE INDEX returns_sale_idx ON pos.returns (original_sale_id);
CREATE INDEX returns_session_idx ON pos.returns (cashier_session_id);
CREATE INDEX returns_outlet_date_idx ON pos.returns (outlet_id, business_date);

CREATE TABLE pos.return_items (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    return_id          uuid          NOT NULL REFERENCES pos.returns (id),
    sale_item_id       uuid          NOT NULL REFERENCES pos.sale_items (id),
    product_id         uuid          NOT NULL REFERENCES pos.products (id),
    sku                text          NOT NULL,
    product_name       text          NOT NULL,
    uom                text          NOT NULL,
    quantity           numeric(18,3) NOT NULL,
    unit_price         numeric(18,2) NOT NULL,
    amount             numeric(18,2) NOT NULL,
    tax_amount         numeric(18,2) NOT NULL DEFAULT 0,
    return_to_stock    boolean       NOT NULL DEFAULT true,
    created_at         timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT return_items_line_uk UNIQUE (return_id, sale_item_id),
    CONSTRAINT return_items_qty_ck CHECK (quantity > 0),
    CONSTRAINT return_items_amount_ck CHECK (amount >= 0 AND tax_amount >= 0)
);
CREATE INDEX return_items_sale_item_idx ON pos.return_items (sale_item_id);

CREATE TABLE pos.refunds (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id            uuid          NOT NULL REFERENCES pos.outlets (id),
    return_id            uuid          NOT NULL REFERENCES pos.returns (id),
    original_payment_id  uuid          NOT NULL REFERENCES pos.payments (id),
    cashier_session_id   uuid          NOT NULL REFERENCES pos.cashier_sessions (id),
    payment_method_id    uuid          NOT NULL REFERENCES pos.payment_methods (id),
    refund_method        text          NOT NULL,
    refund_amount        numeric(18,2) NOT NULL,
    status               text          NOT NULL DEFAULT 'COMPLETED',
    reference_number     text,
    approved_by          uuid          NOT NULL,
    created_by           uuid          NOT NULL,
    created_at           timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT refunds_amount_ck CHECK (refund_amount > 0),
    CONSTRAINT refunds_status_ck CHECK (status IN ('COMPLETED'))
);
CREATE INDEX refunds_return_idx ON pos.refunds (return_id);
CREATE INDEX refunds_payment_idx ON pos.refunds (original_payment_id);
CREATE INDEX refunds_session_idx ON pos.refunds (cashier_session_id);

-- ---------------------------------------------------------------- approval REFUND
ALTER TABLE pos.approvals DROP CONSTRAINT approvals_action_ck;
ALTER TABLE pos.approvals
    ADD CONSTRAINT approvals_action_ck CHECK (action IN ('DISCOUNT', 'PRICE_OVERRIDE', 'VOID_SALE', 'PAYMENT_CONFIRM',
                                                         'CASH_OUT', 'CASH_DIFFERENCE', 'REFUND'));

DROP POLICY approvals_insert ON pos.approvals;
CREATE POLICY approvals_insert ON pos.approvals FOR INSERT TO pos_app_user
    WITH CHECK (requested_by = pos.current_app_user_id()
                AND (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id())
                     -- retur: transaksi asal milik siapa pun di outlet tempat peminta bertransaksi
                     OR (action = 'REFUND' AND pos.has_permission('sale.create', outlet_id))
                     OR EXISTS (SELECT 1 FROM pos.cashier_sessions s WHERE s.id = cashier_session_id
                                AND (s.employee_id = pos.current_employee_id()
                                     OR (pos.has_permission('cashier.close', s.outlet_id)
                                         AND pos.has_permission('cash.approve_difference', s.outlet_id))))));

CREATE OR REPLACE FUNCTION pos.tg_approval_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale     pos.sales%ROWTYPE;
    v_session  pos.cashier_sessions%ROWTYPE;
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
        IF NEW.cashier_session_id IS DISTINCT FROM OLD.cashier_session_id THEN
            RAISE EXCEPTION 'APPROVAL_IMMUTABLE_FIELD' USING ERRCODE = 'P0001';
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

    -- Approval kas (Phase 6): terikat ke cashier session, bukan transaksi
    IF NEW.action IN ('CASH_OUT', 'CASH_DIFFERENCE') THEN
        SELECT * INTO v_session FROM pos.cashier_sessions WHERE id = NEW.cashier_session_id;
        IF v_session.id IS NULL OR v_session.status IN ('CLOSED', 'CANCELLED') OR NEW.sale_id IS NOT NULL THEN
            RAISE EXCEPTION 'CASHIER_SESSION_NOT_FOUND: approval target invalid' USING ERRCODE = 'P0001';
        END IF;
        NEW.organization_id := v_session.organization_id;
        NEW.outlet_id := v_session.outlet_id;
        NEW.requested_by := pos.current_app_user_id();
        IF NEW.approved_by IS NULL OR NEW.approved_by = NEW.requested_by THEN
            RAISE EXCEPTION 'APPROVER_INVALID: approver must be another user (separation of duties)' USING ERRCODE = 'P0001';
        END IF;
        IF NOT pos.user_has_permission_at(NEW.approved_by, 'cash.approve_difference', v_session.outlet_id) THEN
            RAISE EXCEPTION 'APPROVER_NOT_AUTHORIZED: approver lacks cash.approve_difference at this outlet' USING ERRCODE = 'P0001';
        END IF;
        NEW.approver_rank := pos.user_rank_at(NEW.approved_by, v_session.outlet_id);
        IF NEW.approver_rank < 50 THEN
            RAISE EXCEPTION 'APPROVER_NOT_AUTHORIZED: approver role level too low' USING ERRCODE = 'P0001';
        END IF;
        NEW.sale_item_id := NULL;
        NEW.max_percent := NULL;
        NEW.created_at := now();
        NEW.expires_at := now() + interval '2 minutes';
        NEW.used_at := NULL;
        RETURN NEW;
    END IF;
    SELECT * INTO v_sale FROM pos.sales WHERE id = NEW.sale_id;
    IF v_sale.id IS NULL OR v_sale.status IN ('VOID', 'CANCELLED') THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    NEW.cashier_session_id := NULL;
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
    ELSIF NEW.action = 'REFUND' THEN
        -- retur & refund (§29): price = total refund; transaksi asal harus sudah lunas
        IF v_sale.status NOT IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED') THEN
            RAISE EXCEPTION 'RETURN_NOT_ALLOWED: original sale is not completed' USING ERRCODE = 'P0001';
        END IF;
        v_perm := 'sale.refund';
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

-- ---------------------------------------------------------------- nilai yang sudah diretur
-- Retur aktif = COMPLETED atau menunggu approval (keduanya mengurangi sisa yang bisa diretur).
CREATE FUNCTION pos.sale_item_returned(p_sale_item uuid, OUT quantity numeric, OUT amount numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT coalesce(sum(ri.quantity), 0), coalesce(sum(ri.amount), 0)
    FROM pos.return_items ri JOIN pos.returns r ON r.id = ri.return_id
    WHERE ri.sale_item_id = p_sale_item AND r.status IN ('PENDING_APPROVAL', 'COMPLETED')
$$;
REVOKE ALL ON FUNCTION pos.sale_item_returned(uuid) FROM PUBLIC;

CREATE FUNCTION pos.allocate_return_no(p_terminal uuid, p_business_date date)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_no   integer;
    v_code text;
BEGIN
    INSERT INTO pos.terminal_return_sequences AS s (terminal_id, business_date, last_no)
    VALUES (p_terminal, p_business_date, 1)
    ON CONFLICT (terminal_id, business_date) DO UPDATE SET last_no = s.last_no + 1
    RETURNING last_no INTO v_no;
    SELECT t.code INTO v_code FROM pos.terminals t WHERE t.id = p_terminal;
    RETURN 'RET-' || v_code || '-' || to_char(p_business_date, 'YYYYMMDD') || '-' || lpad(v_no::text, 6, '0');
END
$$;
REVOKE ALL ON FUNCTION pos.allocate_return_no(uuid, date) FROM PUBLIC;

-- ---------------------------------------------------------------- guard: returns
CREATE FUNCTION pos.tg_return_guard()
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
        NEW.created_by := v_actor;
        NEW.created_at := now();
        NEW.created_tx := txid_current();
        NEW.refund_reference := nullif(btrim(coalesce(NEW.refund_reference, '')), '');
        RETURN NEW;
    END IF;

    -- UPDATE
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
CREATE TRIGGER returns_guard BEFORE INSERT OR UPDATE ON pos.returns
    FOR EACH ROW EXECUTE FUNCTION pos.tg_return_guard();
CREATE TRIGGER returns_no_delete BEFORE DELETE ON pos.returns
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- ---------------------------------------------------------------- guard: baris retur
CREATE FUNCTION pos.tg_return_item_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_ret  pos.returns%ROWTYPE;
    v_line pos.sale_items%ROWTYPE;
    v_done record;
    v_left numeric;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'RETURN_IMMUTABLE_FIELD: return lines cannot change' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_ret FROM pos.returns WHERE id = NEW.return_id;
    IF v_ret.id IS NULL OR v_ret.status <> 'PENDING_APPROVAL' OR v_ret.created_tx <> txid_current()
       OR v_ret.created_by IS DISTINCT FROM pos.current_app_user_id() THEN
        RAISE EXCEPTION 'RETURN_IMMUTABLE_FIELD: lines are added only when the return is created' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_line FROM pos.sale_items WHERE id = NEW.sale_item_id;
    IF v_line.id IS NULL OR v_line.sale_id <> v_ret.original_sale_id OR v_line.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'RETURN_NOT_ALLOWED: line is not part of the original sale' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_done FROM pos.sale_item_returned(v_line.id);
    v_left := v_line.quantity - v_done.quantity;
    IF NEW.quantity <= 0 OR NEW.quantity > v_left THEN
        RAISE EXCEPTION 'RETURN_QUANTITY_EXCEEDED: % % left to return for %', v_left, v_line.uom, v_line.sku
            USING ERRCODE = 'P0001';
    END IF;
    NEW.product_id := v_line.product_id;
    NEW.sku := v_line.sku;
    NEW.product_name := v_line.product_name;
    NEW.uom := v_line.uom;
    NEW.unit_price := v_line.unit_price;
    IF NEW.quantity = v_left THEN
        -- sisa terakhir: sisa nilai bersih (tidak ada selisih pembulatan)
        NEW.amount := v_line.net_amount - v_done.amount;
    ELSE
        NEW.amount := round(v_line.net_amount * NEW.quantity / v_line.quantity, 0);
    END IF;
    NEW.tax_amount := round(v_line.tax_amount * NEW.amount / nullif(v_line.net_amount, 0), 0);
    NEW.tax_amount := coalesce(NEW.tax_amount, 0);
    NEW.created_at := now();

    PERFORM set_config('pos.return_totals', v_ret.id::text, true);
    UPDATE pos.returns SET item_count = item_count + NEW.quantity, total_amount = total_amount + NEW.amount,
                           tax_amount = tax_amount + NEW.tax_amount
    WHERE id = v_ret.id;
    PERFORM set_config('pos.return_totals', '', true);
    RETURN NEW;
END
$$;
CREATE TRIGGER return_items_guard BEFORE INSERT OR UPDATE OR DELETE ON pos.return_items
    FOR EACH ROW EXECUTE FUNCTION pos.tg_return_item_guard();

-- ---------------------------------------------------------------- refund saat retur selesai
CREATE FUNCTION pos.tg_return_refund()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_left     numeric := NEW.total_amount;
    v_cash     numeric := 0;
    v_take     numeric;
    v_avail    numeric;
    v_balance  numeric;
    v_session  pos.cashier_sessions%ROWTYPE;
    v_cash_m   pos.payment_methods%ROWTYPE;
    p          record;
BEGIN
    SELECT * INTO v_session FROM pos.cashier_sessions WHERE id = NEW.cashier_session_id;
    SELECT * INTO v_cash_m FROM pos.payment_methods m
    WHERE m.organization_id = NEW.organization_id AND m.kind = 'CASH' ORDER BY m.sort_order LIMIT 1;
    -- alokasi ke pembayaran asli (urutan pembayaran), maksimal sisa yang belum direfund per pembayaran
    FOR p IN SELECT py.* FROM pos.payments py
             WHERE py.sale_id = NEW.original_sale_id AND py.status = 'PAID'
             ORDER BY py.created_at, py.id LOOP
        EXIT WHEN v_left <= 0;
        SELECT p.amount - coalesce(sum(r.refund_amount), 0) INTO v_avail
        FROM pos.refunds r WHERE r.original_payment_id = p.id;
        v_take := least(v_left, v_avail);
        CONTINUE WHEN v_take <= 0;
        IF NEW.refund_mode = 'CASH' OR p.method_kind = 'CASH' THEN
            INSERT INTO pos.refunds (organization_id, outlet_id, return_id, original_payment_id, cashier_session_id,
                                     payment_method_id, refund_method, refund_amount, reference_number, approved_by,
                                     created_by)
            VALUES (NEW.organization_id, NEW.outlet_id, NEW.id, p.id, NEW.cashier_session_id, v_cash_m.id, 'CASH',
                    v_take, NULL, NEW.approved_by, pos.current_app_user_id());
            v_cash := v_cash + v_take;
        ELSE
            INSERT INTO pos.refunds (organization_id, outlet_id, return_id, original_payment_id, cashier_session_id,
                                     payment_method_id, refund_method, refund_amount, reference_number, approved_by,
                                     created_by)
            VALUES (NEW.organization_id, NEW.outlet_id, NEW.id, p.id, NEW.cashier_session_id, p.payment_method_id,
                    p.method_code, v_take, NEW.refund_reference, NEW.approved_by, pos.current_app_user_id());
        END IF;
        v_left := v_left - v_take;
    END LOOP;
    IF v_left > 0 THEN
        RAISE EXCEPTION 'REFUND_EXCEEDS_PAYMENT: refund % is more than what was paid', NEW.total_amount
            USING ERRCODE = 'P0001';
    END IF;
    IF v_cash > 0 THEN
        IF v_session.status <> 'OPEN' THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: the drawer of this return is not open' USING ERRCODE = 'P0001';
        END IF;
        SELECT coalesce(sum(m.amount), 0) INTO v_balance FROM pos.cash_movements m
        WHERE m.cashier_session_id = v_session.id AND m.movement_type <> 'CLOSING_CASH';
        IF v_balance < v_cash THEN
            RAISE EXCEPTION 'CASH_INSUFFICIENT: drawer holds %, refund needs %', v_balance, v_cash USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO pos.cash_movements (organization_id, outlet_id, cashier_session_id, business_date, movement_type,
                                        amount, reference_type, reference_id, reason, approved_by, created_by)
        VALUES (NEW.organization_id, NEW.outlet_id, v_session.id, v_session.business_date, 'CASH_REFUND', -v_cash,
                'RETURN', NEW.id, NEW.return_no, NEW.approved_by, pos.current_app_user_id());
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER returns_refund AFTER UPDATE OF status ON pos.returns
    FOR EACH ROW
    WHEN (OLD.status = 'PENDING_APPROVAL' AND NEW.status = 'COMPLETED')
    EXECUTE FUNCTION pos.tg_return_refund();

CREATE TRIGGER refunds_append_only BEFORE UPDATE OR DELETE ON pos.refunds
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Tutup kasir ditolak selama ada retur menunggu approval di laci ini.
CREATE FUNCTION pos.tg_cashier_session_pending_returns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM pos.returns r WHERE r.cashier_session_id = OLD.id AND r.status = 'PENDING_APPROVAL') THEN
        RAISE EXCEPTION 'RETURN_PENDING: approve or reject pending returns before closing' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER cashier_sessions_0_pending_returns
    BEFORE UPDATE OF status ON pos.cashier_sessions
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status IN ('CLOSED', 'CANCELLED'))
    EXECUTE FUNCTION pos.tg_cashier_session_pending_returns();

-- ---------------------------------------------------------------- pencarian struk untuk retur
-- Kasir boleh meretur transaksi kasir lain di outlet yang sama (pelanggan datang ke kasir mana pun);
-- fungsi ini hanya membuka data yang dibutuhkan untuk retur dari satu nomor struk.
CREATE FUNCTION pos.return_lookup(p_receipt_no text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sale pos.sales%ROWTYPE;
BEGIN
    SELECT * INTO v_sale FROM pos.sales s
    WHERE s.receipt_no = btrim(p_receipt_no) AND s.organization_id = pos.current_org_id();
    IF v_sale.id IS NULL OR NOT (pos.has_permission('sale.create', v_sale.outlet_id)
                                 OR pos.has_permission('sale.refund', v_sale.outlet_id)) THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN jsonb_build_object(
        'saleId', v_sale.id, 'receiptNo', v_sale.receipt_no, 'status', v_sale.status, 'outletId', v_sale.outlet_id,
        'businessDate', v_sale.business_date, 'paidAt', v_sale.paid_at, 'grandTotal', v_sale.grand_total,
        'cashierName', (SELECT e.full_name FROM pos.employees e WHERE e.id = v_sale.employee_id),
        'returnable', v_sale.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED'),
        'items', coalesce((SELECT jsonb_agg(jsonb_build_object(
                    'saleItemId', i.id, 'lineNo', i.line_no, 'sku', i.sku, 'productName', i.product_name, 'uom', i.uom,
                    'quantity', i.quantity, 'unitPrice', i.unit_price, 'netAmount', i.net_amount,
                    'returnedQuantity', d.quantity, 'returnedAmount', d.amount,
                    'remainingQuantity', i.quantity - d.quantity, 'remainingAmount', i.net_amount - d.amount)
                    ORDER BY i.line_no)
                 FROM pos.sale_items i CROSS JOIN LATERAL pos.sale_item_returned(i.id) d
                 WHERE i.sale_id = v_sale.id AND i.status = 'ACTIVE'), '[]'::jsonb),
        'payments', coalesce((SELECT jsonb_agg(jsonb_build_object(
                    'paymentId', p.id, 'methodCode', p.method_code, 'methodKind', p.method_kind, 'amount', p.amount,
                    'refunded', coalesce((SELECT sum(r.refund_amount) FROM pos.refunds r WHERE r.original_payment_id = p.id), 0))
                    ORDER BY p.created_at)
                 FROM pos.payments p WHERE p.sale_id = v_sale.id AND p.status = 'PAID'), '[]'::jsonb),
        'returns', coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'returnNo', r.return_no, 'status', r.status,
                                                                 'totalAmount', r.total_amount, 'createdAt', r.created_at)
                                              ORDER BY r.created_at)
                             FROM pos.returns r WHERE r.original_sale_id = v_sale.id), '[]'::jsonb));
END
$$;
REVOKE ALL ON FUNCTION pos.return_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.return_lookup(text) TO pos_app_user;

-- ---------------------------------------------------------------- laporan shift: refund
-- Angka dasar (V016) tetap; pembungkus menambahkan refund. Pemanggil (X report, cash-up) memakai nama yang sama.
ALTER FUNCTION pos.compute_shift_report(uuid) RENAME TO compute_shift_report_base;
CREATE FUNCTION pos.compute_shift_report(p_session uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $fn$
DECLARE
    v_base   jsonb;
    v_refund numeric;
    v_count  integer;
BEGIN
    v_base := pos.compute_shift_report_base(p_session);
    SELECT coalesce(sum(r.total_amount), 0), count(*) INTO v_refund, v_count
    FROM pos.returns r WHERE r.cashier_session_id = p_session AND r.status = 'COMPLETED';
    RETURN jsonb_set(jsonb_set(jsonb_set(v_base,
        '{sales,refund}', to_jsonb(v_refund)),
        '{sales,returnCount}', to_jsonb(v_count)),
        '{sales,netSales}', to_jsonb((v_base #>> '{sales,netSales}')::numeric - v_refund));
END
$fn$;
REVOKE ALL ON FUNCTION pos.compute_shift_report(uuid) FROM PUBLIC;

-- ---------------------------------------------------------------- akses
ALTER TABLE pos.returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.terminal_return_sequences ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON pos.returns TO pos_app_user;
GRANT SELECT, INSERT ON pos.return_items TO pos_app_user;
GRANT SELECT ON pos.refunds TO pos_app_user;
GRANT SELECT, UPDATE ON pos.returns TO pos_system;
GRANT SELECT ON pos.return_items, pos.refunds TO pos_system;

CREATE POLICY returns_select ON pos.returns FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (created_by = pos.current_app_user_id() OR pos.has_permission('sale.view', outlet_id)
                OR pos.has_permission('sale.refund', outlet_id)));
CREATE POLICY returns_insert ON pos.returns FOR INSERT TO pos_app_user
    WITH CHECK (created_by = pos.current_app_user_id() AND pos.has_permission('sale.create', outlet_id));
CREATE POLICY returns_update ON pos.returns FOR UPDATE TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (created_by = pos.current_app_user_id() OR pos.has_permission('sale.refund', outlet_id)))
    WITH CHECK (organization_id = pos.current_org_id());
CREATE POLICY returns_system ON pos.returns TO pos_system USING (true) WITH CHECK (true);

CREATE POLICY return_items_select ON pos.return_items FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.returns r WHERE r.id = return_id));
CREATE POLICY return_items_insert ON pos.return_items FOR INSERT TO pos_app_user
    WITH CHECK (EXISTS (SELECT 1 FROM pos.returns r WHERE r.id = return_id AND r.created_by = pos.current_app_user_id()));
CREATE POLICY return_items_system ON pos.return_items FOR SELECT TO pos_system USING (true);

CREATE POLICY refunds_select ON pos.refunds FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.returns r WHERE r.id = return_id));
CREATE POLICY refunds_system ON pos.refunds FOR SELECT TO pos_system USING (true);
