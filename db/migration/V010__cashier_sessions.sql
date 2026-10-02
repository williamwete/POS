-- V010: cashier session, cash count (denominasi), cash movement (§13, §14, §25, §49, §55, §74, §76)
--
-- Prinsip:
--  * Cashier session = tanggung jawab seorang karyawan atas satu terminal/laci kas.
--  * Satu session aktif per terminal DAN per karyawan (unique index; handover menyusul).
--  * Buka kasir wajib: attendance WORKING di outlet yang sama, terminal aktif di outlet itu,
--    dan hitungan modal awal per denominasi. Konsistensi
--      opening_cash = total hitungan OPENING = movement OPENING_CASH
--    diperiksa constraint trigger DEFERRED saat COMMIT, sehingga tidak ada jalur yang bisa
--    membuat session dengan modal awal yang tidak cocok dengan hitungannya.
--  * Uang: numeric(18,2). Waktu & business date dari server.
--  * Hitungan kas dan movement append-only; hitungan hanya bisa diisi dalam transaksi pembuatnya.
--  * Session lock (status ON_BREAK) hanya bisa dibuka oleh pemilik session dengan token yang
--    diterbitkan SETELAH layar dikunci (login ulang dengan password) — ditegakkan di database.
--  * Clock out normal ditolak selama karyawan masih punya session aktif (§55, ASSUMPTIONS B15).

-- ---------------------------------------------------------------- konteks re-autentikasi
-- Waktu autentikasi terakhir (login dengan password/OTP) dari klaim JWT yang diteruskan backend.
CREATE OR REPLACE FUNCTION pos.jwt_auth_time()
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    raw text := nullif(current_setting('request.jwt.claims', true), '');
BEGIN
    IF raw IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN to_timestamp(nullif(raw::jsonb ->> 'auth_time', '')::double precision);
EXCEPTION
    WHEN others THEN
        RETURN NULL;
END
$$;
GRANT EXECUTE ON FUNCTION pos.jwt_auth_time() TO pos_app_user, pos_system;

-- Kunci terminal otomatis saat tidak ada aktivitas (§73: aturan bisnis tidak di-hard-code).
INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('terminal_idle_lock_minutes', 'NUMBER', '10',
     'Kunci terminal otomatis setelah tidak ada aktivitas (menit, 0 = nonaktif)', 'OUTLET');

-- Komposit key agar FK bisa memastikan "terminal di outlet ini" dan "attendance milik karyawan ini".
ALTER TABLE pos.terminals ADD CONSTRAINT terminals_id_outlet_uk UNIQUE (id, outlet_id);
ALTER TABLE pos.attendance ADD CONSTRAINT attendance_id_employee_uk UNIQUE (id, employee_id);

-- ---------------------------------------------------------------- denominasi
CREATE TABLE pos.cash_denominations (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid          NOT NULL REFERENCES pos.organizations (id),
    currency         char(3)       NOT NULL DEFAULT 'IDR',
    value            numeric(18,2) NOT NULL,
    kind             text          NOT NULL,
    sort_order       integer       NOT NULL DEFAULT 0,
    active           boolean       NOT NULL DEFAULT true,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT cash_denominations_value_ck CHECK (value > 0),
    CONSTRAINT cash_denominations_kind_ck CHECK (kind IN ('NOTE', 'COIN')),
    CONSTRAINT cash_denominations_uk UNIQUE (organization_id, currency, value, kind)
);

CREATE OR REPLACE FUNCTION pos.seed_default_denominations(p_org uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    INSERT INTO pos.cash_denominations (organization_id, currency, value, kind, sort_order)
    SELECT p_org, 'IDR', v.value, v.kind, v.sort_order
    FROM (VALUES (100000, 'NOTE', 10), (50000, 'NOTE', 20), (20000, 'NOTE', 30), (10000, 'NOTE', 40),
                 (5000, 'NOTE', 50), (2000, 'NOTE', 60), (1000, 'NOTE', 70),
                 (1000, 'COIN', 80), (500, 'COIN', 90), (200, 'COIN', 100), (100, 'COIN', 110))
         AS v(value, kind, sort_order)
    ON CONFLICT DO NOTHING
$$;
REVOKE ALL ON FUNCTION pos.seed_default_denominations(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pos.tg_org_default_denominations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.seed_default_denominations(NEW.id);
    RETURN NULL;
END
$$;

CREATE TRIGGER organizations_default_denominations AFTER INSERT ON pos.organizations
    FOR EACH ROW EXECUTE FUNCTION pos.tg_org_default_denominations();

SELECT pos.seed_default_denominations(id) FROM pos.organizations;

-- ---------------------------------------------------------------- cashier session
CREATE TABLE pos.cashier_sessions (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id   uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id         uuid          NOT NULL,
    terminal_id       uuid          NOT NULL,
    employee_id       uuid          NOT NULL,
    attendance_id     uuid          NOT NULL,
    business_date     date          NOT NULL,
    opened_at         timestamptz   NOT NULL DEFAULT now(),
    closed_at         timestamptz,
    opening_cash      numeric(18,2) NOT NULL DEFAULT 0,
    closing_cash      numeric(18,2),
    expected_cash     numeric(18,2),
    difference        numeric(18,2),
    status            text          NOT NULL DEFAULT 'OPEN',
    locked_at         timestamptz,
    lock_reason       text,
    opened_by         uuid          NOT NULL,
    closed_by         uuid,
    cancel_reason     text,
    device_id         text,
    created_tx        bigint        NOT NULL DEFAULT txid_current(),
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    version           integer       NOT NULL DEFAULT 0,
    CONSTRAINT cashier_sessions_status_ck
        CHECK (status IN ('OPEN', 'ON_BREAK', 'CLOSING', 'CLOSED', 'CANCELLED')),
    CONSTRAINT cashier_sessions_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT cashier_sessions_terminal_fk FOREIGN KEY (terminal_id, outlet_id)
        REFERENCES pos.terminals (id, outlet_id),
    CONSTRAINT cashier_sessions_employee_fk FOREIGN KEY (employee_id, organization_id)
        REFERENCES pos.employees (id, organization_id),
    CONSTRAINT cashier_sessions_attendance_fk FOREIGN KEY (attendance_id, employee_id)
        REFERENCES pos.attendance (id, employee_id),
    CONSTRAINT cashier_sessions_opening_ck CHECK (opening_cash >= 0),
    CONSTRAINT cashier_sessions_lock_ck CHECK (
        (status = 'ON_BREAK') = (locked_at IS NOT NULL AND lock_reason IS NOT NULL)),
    CONSTRAINT cashier_sessions_lock_reason_ck CHECK (
        lock_reason IS NULL OR lock_reason IN ('MANUAL', 'IDLE', 'BREAK', 'FORCED_CLOCK_OUT')),
    CONSTRAINT cashier_sessions_closed_ck CHECK (
        (status IN ('OPEN', 'ON_BREAK', 'CLOSING') AND closed_at IS NULL AND closed_by IS NULL)
        OR (status IN ('CLOSED', 'CANCELLED') AND closed_at IS NOT NULL AND closed_by IS NOT NULL)),
    CONSTRAINT cashier_sessions_cancel_reason_ck CHECK (
        status <> 'CANCELLED' OR pg_catalog.length(btrim(cancel_reason)) >= 5)
);

-- §9/§74: satu terminal tidak boleh punya dua session aktif; karyawan pun hanya satu.
CREATE UNIQUE INDEX cashier_sessions_active_terminal_uk
    ON pos.cashier_sessions (terminal_id) WHERE status IN ('OPEN', 'ON_BREAK', 'CLOSING');
CREATE UNIQUE INDEX cashier_sessions_active_employee_uk
    ON pos.cashier_sessions (employee_id) WHERE status IN ('OPEN', 'ON_BREAK', 'CLOSING');
CREATE INDEX cashier_sessions_outlet_date_idx ON pos.cashier_sessions (outlet_id, business_date);
CREATE INDEX cashier_sessions_employee_idx ON pos.cashier_sessions (employee_id, opened_at DESC);

-- ---------------------------------------------------------------- hitungan kas
CREATE TABLE pos.cash_counts (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cashier_session_id  uuid          NOT NULL REFERENCES pos.cashier_sessions (id),
    count_type          text          NOT NULL,
    total_amount        numeric(18,2) NOT NULL DEFAULT 0,
    expected_amount     numeric(18,2),
    difference          numeric(18,2),
    note                text,
    counted_by          uuid          NOT NULL,
    counted_at          timestamptz   NOT NULL DEFAULT now(),
    created_tx          bigint        NOT NULL DEFAULT txid_current(),
    CONSTRAINT cash_counts_type_ck CHECK (count_type IN ('OPENING', 'MID', 'CLOSING', 'HANDOVER')),
    CONSTRAINT cash_counts_total_ck CHECK (total_amount >= 0)
);
CREATE UNIQUE INDEX cash_counts_opening_uk ON pos.cash_counts (cashier_session_id) WHERE count_type = 'OPENING';
CREATE INDEX cash_counts_session_idx ON pos.cash_counts (cashier_session_id, counted_at);

CREATE TABLE pos.cash_count_items (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cash_count_id    uuid          NOT NULL REFERENCES pos.cash_counts (id),
    denomination_id  uuid          NOT NULL REFERENCES pos.cash_denominations (id),
    value            numeric(18,2) NOT NULL,
    kind             text          NOT NULL,
    quantity         integer       NOT NULL,
    subtotal         numeric(18,2) GENERATED ALWAYS AS (value * quantity) STORED,
    CONSTRAINT cash_count_items_qty_ck CHECK (quantity >= 0 AND quantity <= 100000),
    CONSTRAINT cash_count_items_uk UNIQUE (cash_count_id, denomination_id)
);

-- ---------------------------------------------------------------- cash movement (§25, §49)
CREATE TABLE pos.cash_movements (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id           uuid          NOT NULL,
    cashier_session_id  uuid          NOT NULL REFERENCES pos.cashier_sessions (id),
    business_date       date          NOT NULL,
    movement_type       text          NOT NULL,
    -- bertanda: masuk laci (+), keluar laci (−). Expected cash = SUM(amount).
    amount              numeric(18,2) NOT NULL,
    reference_type      text,
    reference_id        uuid,
    reason              text,
    created_by          uuid          NOT NULL,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    created_tx          bigint        NOT NULL DEFAULT txid_current(),
    CONSTRAINT cash_movements_type_ck CHECK (movement_type IN (
        'OPENING_CASH', 'CASH_SALE', 'CASH_IN', 'CASH_OUT', 'PETTY_CASH', 'CASH_REFUND',
        'CASH_ADJUSTMENT', 'CLOSING_CASH')),
    CONSTRAINT cash_movements_sign_ck CHECK (
        (movement_type = 'OPENING_CASH' AND amount >= 0)
        OR (movement_type IN ('CASH_SALE', 'CASH_IN') AND amount > 0)
        OR (movement_type IN ('CASH_OUT', 'PETTY_CASH', 'CASH_REFUND', 'CLOSING_CASH') AND amount < 0)
        OR (movement_type = 'CASH_ADJUSTMENT' AND amount <> 0)),
    CONSTRAINT cash_movements_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id)
);
CREATE UNIQUE INDEX cash_movements_opening_uk ON pos.cash_movements (cashier_session_id)
    WHERE movement_type = 'OPENING_CASH';
CREATE INDEX cash_movements_session_idx ON pos.cash_movements (cashier_session_id);
CREATE INDEX cash_movements_outlet_date_idx ON pos.cash_movements (outlet_id, business_date);

-- Expected cash (§49): seluruh movement tunai session (non-tunai tidak pernah menjadi cash movement).
CREATE OR REPLACE FUNCTION pos.session_expected_cash(p_session uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pos
AS $$
    -- SECURITY INVOKER: RLS cash_movements tetap berlaku untuk pemanggil.
    SELECT coalesce(sum(m.amount), 0)::numeric(18,2)
    FROM pos.cash_movements m
    WHERE m.cashier_session_id = p_session AND m.movement_type <> 'CLOSING_CASH'
$$;
GRANT EXECUTE ON FUNCTION pos.session_expected_cash(uuid) TO pos_app_user, pos_system;

-- ---------------------------------------------------------------- guard: session
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
    -- Nilai closing diisi Phase 7; sampai saat itu tidak boleh diubah.
    IF NEW.closing_cash IS DISTINCT FROM OLD.closing_cash OR NEW.expected_cash IS DISTINCT FROM OLD.expected_cash
       OR NEW.difference IS DISTINCT FROM OLD.difference THEN
        RAISE EXCEPTION 'CASHIER_SESSION_IMMUTABLE_FIELD: closing figures are set by closing' USING ERRCODE = 'P0001';
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
    ELSE
        -- OPEN -> CLOSING -> CLOSED diaktifkan pada Phase 7 (closing).
        RAISE EXCEPTION 'CASHIER_SESSION_INVALID_TRANSITION: % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
    END IF;

    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;

CREATE TRIGGER cashier_sessions_guard BEFORE INSERT OR UPDATE ON pos.cashier_sessions
    FOR EACH ROW EXECUTE FUNCTION pos.tg_cashier_session_guard();
CREATE TRIGGER cashier_sessions_no_delete BEFORE DELETE ON pos.cashier_sessions
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Diperiksa saat COMMIT: modal awal = hitungan OPENING = movement OPENING_CASH.
CREATE OR REPLACE FUNCTION pos.tg_cashier_session_opening_check()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_session  pos.cashier_sessions%ROWTYPE;
    v_count    numeric;
    v_movement numeric;
BEGIN
    SELECT * INTO v_session FROM pos.cashier_sessions WHERE id = NEW.id;
    SELECT c.total_amount INTO v_count FROM pos.cash_counts c
    WHERE c.cashier_session_id = NEW.id AND c.count_type = 'OPENING';
    SELECT m.amount INTO v_movement FROM pos.cash_movements m
    WHERE m.cashier_session_id = NEW.id AND m.movement_type = 'OPENING_CASH';
    IF v_count IS NULL OR v_movement IS NULL
       OR v_count <> v_session.opening_cash OR v_movement <> v_session.opening_cash THEN
        RAISE EXCEPTION 'OPENING_CASH_MISMATCH: session % opening cash %, count %, movement %',
            NEW.id, v_session.opening_cash, v_count, v_movement USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER cashier_sessions_opening_check
    AFTER INSERT ON pos.cashier_sessions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION pos.tg_cashier_session_opening_check();

-- ---------------------------------------------------------------- guard: hitungan kas
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
        IF NEW.count_type IN ('CLOSING', 'HANDOVER') THEN
            RAISE EXCEPTION 'CASH_COUNT_TYPE_NOT_ENABLED: % count arrives with closing/handover', NEW.count_type
                USING ERRCODE = 'P0001';
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

CREATE TRIGGER cash_counts_guard BEFORE INSERT OR UPDATE ON pos.cash_counts
    FOR EACH ROW EXECUTE FUNCTION pos.tg_cash_count_guard();
CREATE TRIGGER cash_counts_no_delete BEFORE DELETE ON pos.cash_counts
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Item: nilai denominasi disalin dari master (client tidak bisa mengarang nilai),
-- hanya bisa ditambah dalam transaksi pembuat hitungan, dan menambah total hitungan.
CREATE OR REPLACE FUNCTION pos.tg_cash_count_item_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_count pos.cash_counts%ROWTYPE;
    v_den   pos.cash_denominations%ROWTYPE;
    v_org   uuid;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'CASH_COUNT_IMMUTABLE: cash count items cannot be changed' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_count FROM pos.cash_counts WHERE id = NEW.cash_count_id;
    IF v_count.created_tx IS DISTINCT FROM txid_current() THEN
        RAISE EXCEPTION 'CASH_COUNT_IMMUTABLE: items must be added in the same transaction as the count'
            USING ERRCODE = 'P0001';
    END IF;
    SELECT s.organization_id INTO v_org FROM pos.cashier_sessions s WHERE s.id = v_count.cashier_session_id;
    SELECT * INTO v_den FROM pos.cash_denominations WHERE id = NEW.denomination_id;
    IF v_den.id IS NULL OR v_den.organization_id <> v_org OR NOT v_den.active THEN
        RAISE EXCEPTION 'DENOMINATION_INVALID: denomination % not available', NEW.denomination_id USING ERRCODE = 'P0001';
    END IF;
    NEW.value := v_den.value;
    NEW.kind := v_den.kind;
    UPDATE pos.cash_counts SET total_amount = total_amount + (v_den.value * NEW.quantity)
    WHERE id = NEW.cash_count_id;
    RETURN NEW;
END
$$;

CREATE TRIGGER cash_count_items_guard BEFORE INSERT OR UPDATE ON pos.cash_count_items
    FOR EACH ROW EXECUTE FUNCTION pos.tg_cash_count_item_guard();
CREATE TRIGGER cash_count_items_no_delete BEFORE DELETE ON pos.cash_count_items
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Menutup hitungan: isi expected & selisih dari movement (server-side, bukan client).
CREATE OR REPLACE FUNCTION pos.finalize_cash_count(p_count uuid)
RETURNS pos.cash_counts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_count pos.cash_counts%ROWTYPE;
    v_expected numeric(18,2);
BEGIN
    SELECT * INTO v_count FROM pos.cash_counts WHERE id = p_count;
    IF v_count.id IS NULL OR v_count.created_tx <> txid_current()
       OR (pos.jwt_sub() IS NOT NULL AND v_count.counted_by IS DISTINCT FROM pos.current_app_user_id()) THEN
        RAISE EXCEPTION 'CASH_COUNT_IMMUTABLE: cannot finalize count %', p_count USING ERRCODE = 'P0001';
    END IF;
    IF v_count.count_type = 'OPENING' THEN
        v_expected := v_count.total_amount;
    ELSE
        SELECT coalesce(sum(m.amount), 0) INTO v_expected FROM pos.cash_movements m
        WHERE m.cashier_session_id = v_count.cashier_session_id AND m.movement_type <> 'CLOSING_CASH';
    END IF;
    UPDATE pos.cash_counts SET expected_amount = v_expected, difference = total_amount - v_expected
    WHERE id = p_count RETURNING * INTO v_count;
    RETURN v_count;
END
$$;
REVOKE ALL ON FUNCTION pos.finalize_cash_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.finalize_cash_count(uuid) TO pos_app_user, pos_system;

-- ---------------------------------------------------------------- guard: movement
CREATE OR REPLACE FUNCTION pos.tg_cash_movement_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_session pos.cashier_sessions%ROWTYPE;
BEGIN
    SELECT * INTO v_session FROM pos.cashier_sessions WHERE id = NEW.cashier_session_id;
    IF v_session.id IS NULL OR v_session.status IN ('CLOSED', 'CANCELLED') THEN
        RAISE EXCEPTION 'CASHIER_SESSION_CLOSED: no cash movement on a closed session' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.movement_type = 'OPENING_CASH' AND v_session.created_tx <> txid_current() THEN
        RAISE EXCEPTION 'OPENING_CASH_MISMATCH: opening cash is recorded only when the session is opened'
            USING ERRCODE = 'P0001';
    END IF;
    NEW.organization_id := v_session.organization_id;
    NEW.outlet_id := v_session.outlet_id;
    NEW.business_date := v_session.business_date;
    NEW.created_at := now();
    NEW.created_tx := txid_current();
    RETURN NEW;
END
$$;

CREATE TRIGGER cash_movements_guard BEFORE INSERT ON pos.cash_movements
    FOR EACH ROW EXECUTE FUNCTION pos.tg_cash_movement_guard();
CREATE TRIGGER cash_movements_no_update BEFORE UPDATE OR DELETE ON pos.cash_movements
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- ---------------------------------------------------------------- attendance <-> session (§55)
CREATE OR REPLACE FUNCTION pos.employee_has_active_session(p_employee uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT EXISTS (SELECT 1 FROM pos.cashier_sessions s
                   WHERE s.employee_id = p_employee AND s.status IN ('OPEN', 'ON_BREAK', 'CLOSING'))
$$;

CREATE OR REPLACE FUNCTION pos.tg_attendance_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'WORKING' THEN
            RAISE EXCEPTION 'ATTENDANCE_INVALID_TRANSITION: new attendance must start WORKING' USING ERRCODE = 'P0001';
        END IF;
        NEW.clock_in := now();
        NEW.business_date := pos.business_date(NEW.clock_in, NEW.outlet_id);
        RETURN NEW;
    END IF;

    IF OLD.status IN ('COMPLETED', 'FORCED_CLOSED') THEN
        RAISE EXCEPTION 'ATTENDANCE_CLOSED: attendance % is already closed', OLD.id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.employee_id <> OLD.employee_id OR NEW.outlet_id <> OLD.outlet_id
       OR NEW.organization_id <> OLD.organization_id OR NEW.clock_in <> OLD.clock_in
       OR NEW.business_date <> OLD.business_date OR NEW.clock_in_by <> OLD.clock_in_by THEN
        RAISE EXCEPTION 'ATTENDANCE_IMMUTABLE_FIELD: identity and clock-in cannot change' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (
           (OLD.status = 'WORKING'  AND NEW.status IN ('WORKING', 'ON_BREAK', 'COMPLETED', 'FORCED_CLOSED'))
        OR (OLD.status = 'ON_BREAK' AND NEW.status IN ('ON_BREAK', 'WORKING', 'FORCED_CLOSED'))
    ) THEN
        RAISE EXCEPTION 'ATTENDANCE_INVALID_TRANSITION: % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
    END IF;
    IF NEW.status IN ('COMPLETED', 'FORCED_CLOSED') THEN
        NEW.clock_out := now();
        IF EXISTS (SELECT 1 FROM pos.attendance_breaks b WHERE b.attendance_id = OLD.id AND b.break_end IS NULL) THEN
            RAISE EXCEPTION 'BREAK_IN_PROGRESS: end the break before clocking out' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    -- §55: clock out normal ditolak selama cashier session aktif. Force clock out supervisor
    -- diizinkan; session-nya otomatis dikunci (lihat tg_attendance_lock_session).
    IF NEW.status = 'COMPLETED' AND pos.employee_has_active_session(OLD.employee_id) THEN
        RAISE EXCEPTION 'CASHIER_SESSION_OPEN: close the cashier session before clocking out' USING ERRCODE = 'P0001';
    END IF;
    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;

-- Istirahat atau force clock out mengunci session kasir yang sedang terbuka.
CREATE OR REPLACE FUNCTION pos.tg_attendance_lock_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF NEW.status IN ('ON_BREAK', 'FORCED_CLOSED') AND OLD.status IS DISTINCT FROM NEW.status THEN
        UPDATE pos.cashier_sessions
        SET status = 'ON_BREAK',
            lock_reason = CASE WHEN NEW.status = 'ON_BREAK' THEN 'BREAK' ELSE 'FORCED_CLOCK_OUT' END
        WHERE employee_id = NEW.employee_id AND status = 'OPEN';
        -- session yang sudah terkunci karena alasan lain: catat alasan terakhirnya tetap (tidak diubah)
    END IF;
    RETURN NULL;
END
$$;

CREATE TRIGGER attendance_lock_session AFTER UPDATE ON pos.attendance
    FOR EACH ROW EXECUTE FUNCTION pos.tg_attendance_lock_session();

-- ---------------------------------------------------------------- privileges & RLS
GRANT SELECT ON pos.cash_denominations TO pos_app_user, pos_system;
GRANT SELECT, INSERT, UPDATE ON pos.cashier_sessions TO pos_app_user, pos_system;
GRANT SELECT, INSERT ON pos.cash_counts, pos.cash_count_items, pos.cash_movements TO pos_app_user, pos_system;

ALTER TABLE pos.cash_denominations ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.cashier_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.cash_counts ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.cash_count_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.cash_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY cash_denominations_system_all ON pos.cash_denominations TO pos_system USING (true);
CREATE POLICY cashier_sessions_system_all ON pos.cashier_sessions TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY cash_counts_system_all ON pos.cash_counts TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY cash_count_items_system_all ON pos.cash_count_items TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY cash_movements_system_all ON pos.cash_movements TO pos_system USING (true) WITH CHECK (true);

CREATE POLICY cash_denominations_select ON pos.cash_denominations FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());

-- Session: milik sendiri, atau cashier.view di outlet tersebut.
CREATE POLICY cashier_sessions_select ON pos.cashier_sessions FOR SELECT TO pos_app_user
    USING (
        organization_id = pos.current_org_id()
        AND (employee_id = pos.current_employee_id() OR pos.has_permission('cashier.view', outlet_id))
    );

-- Buka kasir hanya untuk diri sendiri dengan cashier.open di outlet tersebut.
CREATE POLICY cashier_sessions_insert ON pos.cashier_sessions FOR INSERT TO pos_app_user
    WITH CHECK (
        organization_id = pos.current_org_id()
        AND employee_id = pos.current_employee_id()
        AND opened_by = pos.current_app_user_id()
        AND pos.has_permission('cashier.open', outlet_id)
    );

-- Pemilik: kunci/buka kunci/batal. Penutupan oleh supervisor menyusul Phase 7.
CREATE POLICY cashier_sessions_update_own ON pos.cashier_sessions FOR UPDATE TO pos_app_user
    USING (employee_id = pos.current_employee_id() AND organization_id = pos.current_org_id())
    WITH CHECK (
        employee_id = pos.current_employee_id()
        AND status IN ('OPEN', 'ON_BREAK', 'CANCELLED')
        AND (closed_by IS NULL OR (closed_by = pos.current_app_user_id()
                                   AND pos.has_permission('cashier.open', outlet_id)))
    );

-- Hitungan & item & movement mengikuti visibilitas session (subquery tunduk RLS session).
CREATE POLICY cash_counts_select ON pos.cash_counts FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.cashier_sessions s WHERE s.id = cashier_session_id));

CREATE POLICY cash_counts_insert ON pos.cash_counts FOR INSERT TO pos_app_user
    WITH CHECK (
        counted_by = pos.current_app_user_id()
        AND EXISTS (SELECT 1 FROM pos.cashier_sessions s
                    WHERE s.id = cashier_session_id AND s.employee_id = pos.current_employee_id()));

CREATE POLICY cash_count_items_select ON pos.cash_count_items FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.cash_counts c WHERE c.id = cash_count_id));

CREATE POLICY cash_count_items_insert ON pos.cash_count_items FOR INSERT TO pos_app_user
    WITH CHECK (EXISTS (SELECT 1 FROM pos.cash_counts c
                        WHERE c.id = cash_count_id AND c.counted_by = pos.current_app_user_id()));

CREATE POLICY cash_movements_select ON pos.cash_movements FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.cashier_sessions s WHERE s.id = cashier_session_id));

-- Phase 3 hanya mencatat OPENING_CASH oleh pemilik session. Cash in/out menyusul Phase 6.
CREATE POLICY cash_movements_insert ON pos.cash_movements FOR INSERT TO pos_app_user
    WITH CHECK (
        created_by = pos.current_app_user_id()
        AND movement_type = 'OPENING_CASH'
        AND EXISTS (SELECT 1 FROM pos.cashier_sessions s
                    WHERE s.id = cashier_session_id AND s.employee_id = pos.current_employee_id()));
