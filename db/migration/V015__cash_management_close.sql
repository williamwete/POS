-- V015: manajemen kas (Phase 6) + tutup kasir (§25, §48–§51, §74 "close cashier", §82)
--
-- Prinsip:
--  * Kas masuk/keluar/petty cash hanya oleh pemegang laci (session OPEN), wajib alasan; kas keluar di atas
--    ambang `cash_out_approval_threshold` wajib approval supervisor; laci tidak bisa negatif.
--  * Penyesuaian kas (CASH_ADJUSTMENT) restricted: izin `cash.cash_adjustment`, tidak untuk laci sendiri.
--  * Tutup kasir: tidak ada transaksi terbuka/pembayaran pending, hitungan fisik per pecahan, expected cash
--    dan selisih DIHITUNG DATABASE, selisih wajib alasan, di atas `cash_difference_approval_threshold` wajib
--    approval orang lain. Uang laci dicatat keluar sebagai CLOSING_CASH.
--  * Supervisor (cashier.close + cash.approve_difference) dapat menutup laci kasir lain (mis. setelah force
--    clock out); tetap dengan hitungan fisik dan approval orang lain untuk selisih besar.

INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('cash_out_approval_threshold', 'NUMBER', '0',
     'Kas keluar/petty cash di atas nilai ini wajib approval supervisor (0 = selalu)', 'OUTLET'),
    ('allow_close_with_open_orders', 'BOOLEAN', 'false',
     'Izinkan tutup kasir walau masih ada transaksi terbuka/ditahan', 'OUTLET');

-- ---------------------------------------------------------------- approval kas
ALTER TABLE pos.approvals ALTER COLUMN sale_id DROP NOT NULL;
ALTER TABLE pos.approvals ADD COLUMN cashier_session_id uuid REFERENCES pos.cashier_sessions (id);
ALTER TABLE pos.approvals DROP CONSTRAINT approvals_action_ck;
ALTER TABLE pos.approvals
    ADD CONSTRAINT approvals_action_ck CHECK (action IN ('DISCOUNT', 'PRICE_OVERRIDE', 'VOID_SALE', 'PAYMENT_CONFIRM',
                                                         'CASH_OUT', 'CASH_DIFFERENCE')),
    ADD CONSTRAINT approvals_target_ck CHECK (
        (action IN ('CASH_OUT', 'CASH_DIFFERENCE') AND cashier_session_id IS NOT NULL AND sale_id IS NULL AND price > 0)
        OR (action NOT IN ('CASH_OUT', 'CASH_DIFFERENCE') AND sale_id IS NOT NULL AND cashier_session_id IS NULL));
CREATE INDEX approvals_session_idx ON pos.approvals (cashier_session_id);

DROP POLICY approvals_select ON pos.approvals;
DROP POLICY approvals_insert ON pos.approvals;
CREATE POLICY approvals_select ON pos.approvals FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (requested_by = pos.current_app_user_id() OR approved_by = pos.current_app_user_id()
                OR pos.has_permission('sale.view', outlet_id) OR pos.has_permission('cashier.view', outlet_id)));
CREATE POLICY approvals_insert ON pos.approvals FOR INSERT TO pos_app_user
    WITH CHECK (requested_by = pos.current_app_user_id()
                AND (EXISTS (SELECT 1 FROM pos.sales s WHERE s.id = sale_id AND s.employee_id = pos.current_employee_id())
                     OR EXISTS (SELECT 1 FROM pos.cashier_sessions s WHERE s.id = cashier_session_id
                                AND (s.employee_id = pos.current_employee_id()
                                     OR (pos.has_permission('cashier.close', s.outlet_id)
                                         AND pos.has_permission('cash.approve_difference', s.outlet_id))))));

-- ---------------------------------------------------------------- kolom penutupan & movement
ALTER TABLE pos.cashier_sessions
    ADD COLUMN closing_count_id uuid REFERENCES pos.cash_counts (id),
    ADD COLUMN difference_reason text,
    ADD COLUMN difference_note text,
    ADD COLUMN difference_approval_id uuid REFERENCES pos.approvals (id),
    ADD COLUMN difference_approved_by uuid,
    ADD CONSTRAINT cashier_sessions_closed_figures_ck CHECK (
        status <> 'CLOSED' OR (closing_cash IS NOT NULL AND expected_cash IS NOT NULL AND difference IS NOT NULL
                               AND closing_count_id IS NOT NULL AND difference = closing_cash - expected_cash)),
    ADD CONSTRAINT cashier_sessions_difference_reason_ck CHECK (
        difference_reason IS NULL OR difference_reason IN ('SHORTAGE', 'OVERAGE', 'WRONG_CHANGE', 'COUNTING_ERROR', 'OTHER'));

ALTER TABLE pos.cash_movements
    ADD COLUMN reason_code text,
    ADD COLUMN approval_id uuid REFERENCES pos.approvals (id),
    ADD COLUMN approved_by uuid;

-- Penghalang tutup kasir (SECURITY INVOKER: dihitung dari baris yang memang terlihat oleh pemanggil;
-- trigger tutup kasir tetap memeriksa ulang tanpa RLS).
CREATE FUNCTION pos.session_open_orders(p_session uuid)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pos
AS $$
    SELECT count(*)::integer FROM pos.sales s
    WHERE s.cashier_session_id = p_session AND s.status IN ('DRAFT', 'HELD', 'CHECKOUT', 'PAYMENT_PENDING')
$$;
CREATE FUNCTION pos.session_pending_payments(p_session uuid)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pos
AS $$
    SELECT count(*)::integer FROM pos.payments p WHERE p.cashier_session_id = p_session AND p.status = 'PENDING'
$$;
REVOKE ALL ON FUNCTION pos.session_open_orders(uuid), pos.session_pending_payments(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.session_open_orders(uuid), pos.session_pending_payments(uuid) TO pos_app_user, pos_system;

-- ---------------------------------------------------------------- guard diperbarui
CREATE OR REPLACE FUNCTION pos.tg_cashier_session_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_terminal_active boolean;
    v_att             pos.attendance%ROWTYPE;
    v_auth            timestamptz;
    v_count           pos.cash_counts%ROWTYPE;
    v_expected        numeric;
    v_threshold       numeric;
    v_appr            pos.approvals%ROWTYPE;
    v_allow_open      boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'OPEN' THEN
            RAISE EXCEPTION 'CASHIER_SESSION_INVALID_TRANSITION: new session must start OPEN' USING ERRCODE = 'P0001';
        END IF;
        SELECT t.active INTO v_terminal_active FROM pos.terminals t WHERE t.id = NEW.terminal_id;
        IF v_terminal_active IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'TERMINAL_INACTIVE: terminal % is not active', NEW.terminal_id USING ERRCODE = 'P0001';
        END IF;
        SELECT * INTO v_att FROM pos.attendance a WHERE a.id = NEW.attendance_id;
        IF v_att.status IS DISTINCT FROM 'WORKING' OR v_att.outlet_id IS DISTINCT FROM NEW.outlet_id THEN
            RAISE EXCEPTION 'ATTENDANCE_REQUIRED: employee must be clocked in (WORKING) at this outlet'
                USING ERRCODE = 'P0001';
        END IF;
        NEW.opened_at := now();
        NEW.business_date := pos.business_date(NEW.opened_at, NEW.outlet_id);
        NEW.opening_cash := 0;          -- diisi dari hitungan OPENING dalam transaksi yang sama
        NEW.closing_cash := NULL;
        NEW.expected_cash := NULL;
        NEW.difference := NULL;
        NEW.locked_at := NULL;
        NEW.lock_reason := NULL;
        NEW.created_tx := txid_current();
        RETURN NEW;
    END IF;

    -- UPDATE
    IF OLD.status IN ('CLOSED', 'CANCELLED') THEN
        RAISE EXCEPTION 'CASHIER_SESSION_CLOSED: session % is already closed', OLD.id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.organization_id <> OLD.organization_id OR NEW.outlet_id <> OLD.outlet_id
       OR NEW.terminal_id <> OLD.terminal_id OR NEW.employee_id <> OLD.employee_id
       OR NEW.attendance_id <> OLD.attendance_id OR NEW.business_date <> OLD.business_date
       OR NEW.opened_at <> OLD.opened_at OR NEW.opened_by <> OLD.opened_by
       OR NEW.created_tx <> OLD.created_tx THEN
        RAISE EXCEPTION 'CASHIER_SESSION_IMMUTABLE_FIELD: identity fields cannot change' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.opening_cash <> OLD.opening_cash AND OLD.created_tx <> txid_current() THEN
        RAISE EXCEPTION 'CASHIER_SESSION_IMMUTABLE_FIELD: opening cash is fixed once the session is committed'
            USING ERRCODE = 'P0001';
    END IF;
    -- Angka penutupan selalu dihitung database saat tutup kasir (client tidak bisa mengisinya).
    IF NEW.closing_cash IS DISTINCT FROM OLD.closing_cash OR NEW.expected_cash IS DISTINCT FROM OLD.expected_cash
       OR NEW.difference IS DISTINCT FROM OLD.difference THEN
        RAISE EXCEPTION 'CASHIER_SESSION_IMMUTABLE_FIELD: closing figures are set by closing' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.status <> 'CLOSED' AND (NEW.closing_count_id IS NOT NULL OR NEW.difference_reason IS NOT NULL
       OR NEW.difference_note IS NOT NULL OR NEW.difference_approval_id IS NOT NULL) THEN
        RAISE EXCEPTION 'CASHIER_SESSION_IMMUTABLE_FIELD: closing fields only when closing' USING ERRCODE = 'P0001';
    END IF;

    IF NEW.status = OLD.status THEN
        IF NEW.locked_at IS DISTINCT FROM OLD.locked_at OR NEW.lock_reason IS DISTINCT FROM OLD.lock_reason THEN
            RAISE EXCEPTION 'CASHIER_SESSION_IMMUTABLE_FIELD: lock changes only with status' USING ERRCODE = 'P0001';
        END IF;
    ELSIF OLD.status = 'OPEN' AND NEW.status = 'ON_BREAK' THEN
        -- kunci terminal
        IF NEW.lock_reason IS NULL THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCK_REASON_REQUIRED: lock reason is required' USING ERRCODE = 'P0001';
        END IF;
        NEW.locked_at := now();
    ELSIF OLD.status = 'ON_BREAK' AND NEW.status = 'OPEN' THEN
        -- buka kunci: pemilik, sudah login ulang setelah dikunci, dan sedang WORKING di outlet ini
        IF pos.current_employee_id() IS DISTINCT FROM OLD.employee_id THEN
            RAISE EXCEPTION 'CASHIER_SESSION_NOT_OWNER: only the session owner can unlock' USING ERRCODE = 'P0001';
        END IF;
        v_auth := pos.jwt_auth_time();
        IF v_auth IS NULL OR v_auth < date_trunc('second', OLD.locked_at) THEN
            RAISE EXCEPTION 'REAUTH_REQUIRED: sign in again to unlock the terminal' USING ERRCODE = 'P0001';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pos.attendance a
                       WHERE a.employee_id = OLD.employee_id AND a.status = 'WORKING'
                         AND a.outlet_id = OLD.outlet_id) THEN
            RAISE EXCEPTION 'ATTENDANCE_REQUIRED: clock in / end break before unlocking' USING ERRCODE = 'P0001';
        END IF;
        NEW.locked_at := NULL;
        NEW.lock_reason := NULL;
    ELSIF OLD.status IN ('OPEN', 'ON_BREAK') AND NEW.status = 'CANCELLED' THEN
        -- Batal buka kasir (salah hitung modal / salah terminal): hanya bila belum ada aktivitas kas.
        IF EXISTS (SELECT 1 FROM pos.cash_movements m
                   WHERE m.cashier_session_id = OLD.id AND m.movement_type <> 'OPENING_CASH') THEN
            RAISE EXCEPTION 'CASHIER_SESSION_HAS_ACTIVITY: session with cash activity must be closed, not cancelled'
                USING ERRCODE = 'P0001';
        END IF;
        NEW.closed_at := now();
        NEW.locked_at := NULL;
        NEW.lock_reason := NULL;
    ELSIF OLD.status IN ('OPEN', 'ON_BREAK') AND NEW.status = 'CLOSED' THEN
        -- §48 tutup kasir. Pemilik menutup session yang tidak terkunci; supervisor dapat menutup session
        -- kasir lain (mis. setelah force clock out) — izin dicek RLS.
        IF OLD.status = 'ON_BREAK' AND pos.current_employee_id() = OLD.employee_id THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: unlock the terminal before closing' USING ERRCODE = 'P0001';
        END IF;
        v_allow_open := coalesce((pos.get_setting('allow_close_with_open_orders', OLD.outlet_id))::boolean, false);
        IF NOT v_allow_open AND EXISTS (SELECT 1 FROM pos.sales s WHERE s.cashier_session_id = OLD.id
                                        AND s.status IN ('DRAFT', 'HELD', 'CHECKOUT', 'PAYMENT_PENDING')) THEN
            RAISE EXCEPTION 'OPEN_ORDER_EXISTS: finish, void or cancel open transactions before closing' USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (SELECT 1 FROM pos.payments p WHERE p.cashier_session_id = OLD.id AND p.status = 'PENDING') THEN
            RAISE EXCEPTION 'PAYMENT_PENDING: payments are still pending' USING ERRCODE = 'P0001';
        END IF;
        -- hitungan fisik (§50) dibuat dalam transaksi yang sama
        SELECT * INTO v_count FROM pos.cash_counts c WHERE c.id = NEW.closing_count_id;
        IF v_count.id IS NULL OR v_count.cashier_session_id <> OLD.id OR v_count.count_type <> 'CLOSING'
           OR v_count.created_tx <> txid_current() THEN
            RAISE EXCEPTION 'CLOSING_COUNT_REQUIRED: count the cash drawer to close' USING ERRCODE = 'P0001';
        END IF;
        SELECT coalesce(sum(m.amount), 0) INTO v_expected FROM pos.cash_movements m
        WHERE m.cashier_session_id = OLD.id AND m.movement_type <> 'CLOSING_CASH';
        NEW.closing_cash := v_count.total_amount;
        NEW.expected_cash := v_expected;
        NEW.difference := v_count.total_amount - v_expected;
        -- §51: selisih wajib alasan; di atas ambang wajib approval orang lain
        IF NEW.difference <> 0 THEN
            IF NEW.difference_reason IS NULL
               OR NEW.difference_reason NOT IN ('SHORTAGE', 'OVERAGE', 'WRONG_CHANGE', 'COUNTING_ERROR', 'OTHER') THEN
                RAISE EXCEPTION 'CASH_DIFFERENCE_REASON_REQUIRED: explain the cash difference' USING ERRCODE = 'P0001';
            END IF;
            IF NEW.difference_reason = 'OTHER' AND pg_catalog.length(btrim(coalesce(NEW.difference_note, ''))) < 5 THEN
                RAISE EXCEPTION 'CASH_DIFFERENCE_REASON_REQUIRED: describe the difference' USING ERRCODE = 'P0001';
            END IF;
            v_threshold := coalesce((pos.get_setting('cash_difference_approval_threshold', OLD.outlet_id))::numeric, 0);
            IF abs(NEW.difference) > v_threshold THEN
                SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.difference_approval_id;
                IF v_appr.id IS NULL OR v_appr.action <> 'CASH_DIFFERENCE' OR v_appr.cashier_session_id <> OLD.id
                   OR v_appr.price <> abs(NEW.difference) OR v_appr.used_at IS NULL
                   OR v_appr.requested_by <> pos.current_app_user_id() THEN
                    RAISE EXCEPTION 'CASH_DIFFERENCE_REQUIRES_APPROVAL: difference % needs supervisor approval', NEW.difference
                        USING ERRCODE = 'P0001';
                END IF;
                NEW.difference_approved_by := v_appr.approved_by;
            ELSE
                NEW.difference_approval_id := NULL;
                NEW.difference_approved_by := NULL;
            END IF;
        ELSE
            NEW.difference_reason := NULL;
            NEW.difference_approval_id := NULL;
            NEW.difference_approved_by := NULL;
        END IF;
        NEW.closed_by := pos.current_app_user_id();
        NEW.closed_at := now();
        NEW.locked_at := NULL;
        NEW.lock_reason := NULL;
        -- uang fisik keluar dari laci (disetor ke brankas) — tidak memengaruhi expected cash
        IF NEW.closing_cash > 0 THEN
            INSERT INTO pos.cash_movements (organization_id, outlet_id, cashier_session_id, business_date, movement_type,
                                            amount, reference_type, reference_id, reason, created_by)
            VALUES (OLD.organization_id, OLD.outlet_id, OLD.id, OLD.business_date, 'CLOSING_CASH', -NEW.closing_cash,
                    'CASH_COUNT', v_count.id, 'Tutup kasir', pos.current_app_user_id());
        END IF;
    ELSE
        -- CLOSING (serah terima bertahap) belum dipakai.
        RAISE EXCEPTION 'CASHIER_SESSION_INVALID_TRANSITION: % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
    END IF;

    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION pos.tg_cash_count_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_status text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT s.status INTO v_status FROM pos.cashier_sessions s WHERE s.id = NEW.cashier_session_id;
        IF v_status IS NULL OR v_status IN ('CLOSED', 'CANCELLED') THEN
            RAISE EXCEPTION 'CASHIER_SESSION_CLOSED: cannot count cash on a closed session' USING ERRCODE = 'P0001';
        END IF;
        IF NEW.count_type = 'MID' AND v_status <> 'OPEN' THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: unlock the terminal before counting cash' USING ERRCODE = 'P0001';
        END IF;
        IF NEW.count_type = 'HANDOVER' THEN
            RAISE EXCEPTION 'CASH_COUNT_TYPE_NOT_ENABLED: handover is not enabled yet' USING ERRCODE = 'P0001';
        END IF;
        IF NEW.count_type = 'CLOSING'
           AND EXISTS (SELECT 1 FROM pos.cash_counts c WHERE c.cashier_session_id = NEW.cashier_session_id
                       AND c.count_type = 'CLOSING' AND c.created_tx = txid_current()) THEN
            RAISE EXCEPTION 'CASH_COUNT_IMMUTABLE: one closing count per close' USING ERRCODE = 'P0001';
        END IF;
        NEW.total_amount := 0;            -- dijumlahkan dari item
        NEW.expected_amount := NULL;      -- diisi dalam transaksi yang sama oleh pos.finalize_cash_count
        NEW.difference := NULL;
        NEW.counted_at := now();
        NEW.created_tx := txid_current();
        RETURN NEW;
    END IF;
    -- UPDATE: hanya dari fungsi internal dalam transaksi pembuatnya.
    IF OLD.created_tx <> txid_current() THEN
        RAISE EXCEPTION 'CASH_COUNT_IMMUTABLE: cash count % is final', OLD.id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.cashier_session_id <> OLD.cashier_session_id OR NEW.count_type <> OLD.count_type
       OR NEW.counted_by <> OLD.counted_by OR NEW.counted_at <> OLD.counted_at THEN
        RAISE EXCEPTION 'CASH_COUNT_IMMUTABLE: identity fields cannot change' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION pos.tg_cash_movement_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_session   pos.cashier_sessions%ROWTYPE;
    v_threshold numeric;
    v_balance   numeric;
    v_appr      pos.approvals%ROWTYPE;
BEGIN
    SELECT * INTO v_session FROM pos.cashier_sessions WHERE id = NEW.cashier_session_id;
    IF v_session.id IS NULL OR v_session.status IN ('CLOSED', 'CANCELLED') THEN
        RAISE EXCEPTION 'CASHIER_SESSION_CLOSED: no cash movement on a closed session' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.movement_type = 'OPENING_CASH' AND v_session.created_tx <> txid_current() THEN
        RAISE EXCEPTION 'OPENING_CASH_MISMATCH: opening cash is recorded only when the session is opened'
            USING ERRCODE = 'P0001';
    END IF;
    -- §25: kas masuk/keluar oleh pemegang laci; penyesuaian hanya oleh atasan (restricted)
    IF NEW.movement_type IN ('CASH_IN', 'CASH_OUT', 'PETTY_CASH') THEN
        IF v_session.status <> 'OPEN' THEN
            RAISE EXCEPTION 'CASHIER_SESSION_LOCKED: cashier session is not open' USING ERRCODE = 'P0001';
        END IF;
        IF v_session.employee_id IS DISTINCT FROM pos.current_employee_id() THEN
            RAISE EXCEPTION 'CASHIER_SESSION_NOT_OWNER: only the drawer holder records cash in/out' USING ERRCODE = 'P0001';
        END IF;
        IF pg_catalog.length(btrim(coalesce(NEW.reason, ''))) < 3 THEN
            RAISE EXCEPTION 'CASH_MOVEMENT_REASON_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
        IF NEW.movement_type IN ('CASH_OUT', 'PETTY_CASH') THEN
            SELECT coalesce(sum(m.amount), 0) INTO v_balance FROM pos.cash_movements m
            WHERE m.cashier_session_id = v_session.id AND m.movement_type <> 'CLOSING_CASH';
            IF v_balance + NEW.amount < 0 THEN
                RAISE EXCEPTION 'CASH_INSUFFICIENT: drawer holds %, cannot take out %', v_balance, -NEW.amount
                    USING ERRCODE = 'P0001';
            END IF;
            v_threshold := coalesce((pos.get_setting('cash_out_approval_threshold', v_session.outlet_id))::numeric, 0);
            IF -NEW.amount > v_threshold THEN
                SELECT * INTO v_appr FROM pos.approvals a WHERE a.id = NEW.approval_id;
                IF v_appr.id IS NULL OR v_appr.action <> 'CASH_OUT' OR v_appr.cashier_session_id <> v_session.id
                   OR v_appr.price <> -NEW.amount OR v_appr.used_at IS NULL
                   OR v_appr.requested_by <> pos.current_app_user_id() THEN
                    RAISE EXCEPTION 'APPROVAL_REQUIRED: cash out above % needs supervisor approval', v_threshold
                        USING ERRCODE = 'P0001';
                END IF;
                NEW.approved_by := v_appr.approved_by;
            ELSE
                NEW.approval_id := NULL;
                NEW.approved_by := NULL;
            END IF;
        ELSE
            NEW.approval_id := NULL;
            NEW.approved_by := NULL;
        END IF;
    ELSIF NEW.movement_type = 'CASH_ADJUSTMENT' THEN
        IF pos.jwt_sub() IS NOT NULL AND v_session.employee_id = pos.current_employee_id() THEN
            RAISE EXCEPTION 'SELF_MODIFICATION_NOT_ALLOWED: adjust another cashier''s drawer only' USING ERRCODE = 'P0001';
        END IF;
        IF pg_catalog.length(btrim(coalesce(NEW.reason, ''))) < 5 THEN
            RAISE EXCEPTION 'CASH_MOVEMENT_REASON_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
        NEW.approval_id := NULL;
        NEW.approved_by := pos.current_app_user_id();   -- penyesuaian adalah keputusan atasan itu sendiri
    ELSIF NEW.movement_type = 'CLOSING_CASH' THEN
        IF NOT EXISTS (SELECT 1 FROM pos.cash_counts c WHERE c.cashier_session_id = v_session.id
                       AND c.count_type = 'CLOSING' AND c.created_tx = txid_current()) THEN
            RAISE EXCEPTION 'CLOSING_COUNT_REQUIRED: closing cash is recorded only when closing' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    NEW.organization_id := v_session.organization_id;
    NEW.outlet_id := v_session.outlet_id;
    NEW.business_date := v_session.business_date;
    NEW.created_at := now();
    NEW.created_tx := txid_current();
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

-- ---------------------------------------------------------------- RLS kas & penutupan
DROP POLICY cash_movements_insert ON pos.cash_movements;
CREATE POLICY cash_movements_insert ON pos.cash_movements FOR INSERT TO pos_app_user
    WITH CHECK (
        created_by = pos.current_app_user_id()
        AND (
            (movement_type = 'OPENING_CASH'
             AND EXISTS (SELECT 1 FROM pos.cashier_sessions s
                         WHERE s.id = cashier_session_id AND s.employee_id = pos.current_employee_id()))
            OR (movement_type = 'CASH_IN' AND pos.has_permission('cash.cash_in', outlet_id)
                AND EXISTS (SELECT 1 FROM pos.cashier_sessions s
                            WHERE s.id = cashier_session_id AND s.employee_id = pos.current_employee_id()))
            OR (movement_type IN ('CASH_OUT', 'PETTY_CASH') AND pos.has_permission('cash.cash_out', outlet_id)
                AND EXISTS (SELECT 1 FROM pos.cashier_sessions s
                            WHERE s.id = cashier_session_id AND s.employee_id = pos.current_employee_id()))
            OR (movement_type = 'CASH_ADJUSTMENT' AND pos.has_permission('cash.cash_adjustment', outlet_id))
        ));

DROP POLICY cash_counts_insert ON pos.cash_counts;
CREATE POLICY cash_counts_insert ON pos.cash_counts FOR INSERT TO pos_app_user
    WITH CHECK (
        counted_by = pos.current_app_user_id()
        AND EXISTS (SELECT 1 FROM pos.cashier_sessions s
                    WHERE s.id = cashier_session_id
                      AND (s.employee_id = pos.current_employee_id()
                           OR (count_type = 'CLOSING' AND pos.has_permission('cashier.close', s.outlet_id)
                               AND pos.has_permission('cash.approve_difference', s.outlet_id)))));

DROP POLICY cashier_sessions_update_own ON pos.cashier_sessions;
CREATE POLICY cashier_sessions_update_own ON pos.cashier_sessions FOR UPDATE TO pos_app_user
    USING (employee_id = pos.current_employee_id() AND organization_id = pos.current_org_id())
    WITH CHECK (
        employee_id = pos.current_employee_id()
        AND status IN ('OPEN', 'ON_BREAK', 'CANCELLED', 'CLOSED')
        AND (closed_by IS NULL
             OR (closed_by = pos.current_app_user_id()
                 AND pos.has_permission(CASE WHEN status = 'CLOSED' THEN 'cashier.close' ELSE 'cashier.open' END,
                                        outlet_id)))
    );
-- Supervisor/manager menutup laci kasir lain (mis. kasir pulang setelah force clock out).
CREATE POLICY cashier_sessions_close_other ON pos.cashier_sessions FOR UPDATE TO pos_app_user
    USING (
        organization_id = pos.current_org_id()
        AND employee_id IS DISTINCT FROM pos.current_employee_id()
        AND pos.has_permission('cashier.close', outlet_id)
        AND pos.has_permission('cash.approve_difference', outlet_id))
    WITH CHECK (
        status = 'CLOSED' AND closed_by = pos.current_app_user_id()
        AND pos.has_permission('cashier.close', outlet_id)
        AND pos.has_permission('cash.approve_difference', outlet_id));
