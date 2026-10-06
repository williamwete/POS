-- V016: closing reports (Phase 7) — X report, cash-up / Z report (§52, §53, §54, §84, §85)
--
-- Prinsip:
--  * Angka laporan dihitung database dari transaksi, pembayaran, dan mutasi kas — satu fungsi untuk X dan Z.
--  * Cash-up (Z report) dibuat oleh trigger dalam transaksi yang sama dengan tutup kasir: tidak mungkin ada
--    session CLOSED tanpa cash-up (§85). Cash-up append-only; nomor Z berurutan per terminal.
--  * X report (tengah shift) tidak mengubah apa pun dan berisi expected cash, jadi hanya untuk pemegang
--    cashier.view (blind count kasir tetap terjaga, B21/B43).

CREATE TABLE pos.cashups (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id           uuid          NOT NULL REFERENCES pos.outlets (id),
    terminal_id         uuid          NOT NULL REFERENCES pos.terminals (id),
    cashier_session_id  uuid          NOT NULL REFERENCES pos.cashier_sessions (id),
    employee_id         uuid          NOT NULL REFERENCES pos.employees (id),
    business_date       date          NOT NULL,
    z_number            integer       NOT NULL,
    transaction_count   integer       NOT NULL,
    net_sales           numeric(18,2) NOT NULL,
    expected_cash       numeric(18,2) NOT NULL,
    actual_cash         numeric(18,2) NOT NULL,
    difference          numeric(18,2) NOT NULL,
    report              jsonb         NOT NULL,
    closed_by           uuid          NOT NULL,
    created_at          timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT cashups_session_uk UNIQUE (cashier_session_id),
    CONSTRAINT cashups_z_number_uk UNIQUE (terminal_id, z_number),
    CONSTRAINT cashups_difference_ck CHECK (difference = actual_cash - expected_cash)
);
CREATE INDEX cashups_outlet_date_idx ON pos.cashups (outlet_id, business_date);

-- ---------------------------------------------------------------- angka laporan shift
-- Hanya dipanggil fungsi/trigger SECURITY DEFINER lain (tidak di-grant ke role aplikasi).
CREATE FUNCTION pos.compute_shift_report(p_session uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_s        pos.cashier_sessions%ROWTYPE;
    v_header   jsonb;
    v_sales    jsonb;
    v_payments jsonb;
    v_cash     jsonb;
    v_expected numeric;
BEGIN
    SELECT * INTO v_s FROM pos.cashier_sessions WHERE id = p_session;
    IF v_s.id IS NULL THEN
        RAISE EXCEPTION 'CASHIER_SESSION_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;

    SELECT jsonb_build_object(
               'organizationName', org.name, 'outletCode', o.code, 'outletName', o.name, 'outletAddress', o.address,
               'terminalCode', t.code, 'terminalName', t.name, 'businessDate', v_s.business_date,
               'cashierName', e.full_name, 'employeeCode', e.employee_code, 'sessionId', v_s.id,
               'openedAt', v_s.opened_at, 'closedAt', v_s.closed_at, 'status', v_s.status)
    INTO v_header
    FROM pos.outlets o
    JOIN pos.organizations org ON org.id = o.organization_id
    JOIN pos.terminals t ON t.id = v_s.terminal_id
    JOIN pos.employees e ON e.id = v_s.employee_id
    WHERE o.id = v_s.outlet_id;

    -- penjualan selesai (lunas, termasuk yang sudah/sedang dikirim ke Openbravo atau diretur kemudian)
    SELECT jsonb_build_object(
               'transactionCount', count(*) FILTER (WHERE s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')),
               'voidCount', count(*) FILTER (WHERE s.status = 'VOID'),
               'itemCount', coalesce(sum(s.item_count) FILTER (WHERE s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')), 0),
               'grossSales', coalesce(sum(s.subtotal) FILTER (WHERE s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')), 0),
               'discount', coalesce(sum(s.discount_total) FILTER (WHERE s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')), 0),
               'refund', 0,
               'netSales', coalesce(sum(s.grand_total) FILTER (WHERE s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')), 0),
               'tax', coalesce(sum(s.tax_total) FILTER (WHERE s.status IN ('PAID', 'POSTING', 'POSTED', 'SYNC_ERROR', 'RETURNED')), 0),
               'openOrders', count(*) FILTER (WHERE s.status IN ('DRAFT', 'HELD', 'CHECKOUT', 'PAYMENT_PENDING')))
    INTO v_sales
    FROM pos.sales s WHERE s.cashier_session_id = p_session;

    -- pembayaran sukses per metode (semua metode aktif ditampilkan, termasuk yang nol)
    SELECT coalesce(jsonb_agg(jsonb_build_object('methodCode', m.code, 'methodName', m.name, 'methodKind', m.kind,
                                                 'count', coalesce(p.cnt, 0), 'amount', coalesce(p.amt, 0))
                              ORDER BY m.sort_order, m.code), '[]'::jsonb)
    INTO v_payments
    FROM pos.payment_methods m
    LEFT JOIN (SELECT payment_method_id, count(*) AS cnt, sum(amount) AS amt
               FROM pos.payments WHERE cashier_session_id = p_session AND status = 'PAID'
               GROUP BY payment_method_id) p ON p.payment_method_id = m.id
    WHERE m.organization_id = v_s.organization_id AND (m.active OR p.cnt IS NOT NULL);

    SELECT coalesce(sum(amount) FILTER (WHERE movement_type <> 'CLOSING_CASH'), 0) INTO v_expected
    FROM pos.cash_movements WHERE cashier_session_id = p_session;

    SELECT jsonb_build_object(
               'openingCash', coalesce(sum(amount) FILTER (WHERE movement_type = 'OPENING_CASH'), 0),
               'cashSales', coalesce(sum(amount) FILTER (WHERE movement_type IN ('CASH_SALE', 'CASH_SALE_REVERSAL')), 0),
               'cashIn', coalesce(sum(amount) FILTER (WHERE movement_type = 'CASH_IN'), 0),
               'cashOut', coalesce(-sum(amount) FILTER (WHERE movement_type = 'CASH_OUT'), 0),
               'pettyCash', coalesce(-sum(amount) FILTER (WHERE movement_type = 'PETTY_CASH'), 0),
               'cashRefund', coalesce(-sum(amount) FILTER (WHERE movement_type = 'CASH_REFUND'), 0),
               'adjustment', coalesce(sum(amount) FILTER (WHERE movement_type = 'CASH_ADJUSTMENT'), 0),
               'expectedCash', v_expected,
               'actualCash', v_s.closing_cash,
               'difference', v_s.difference,
               'differenceReason', v_s.difference_reason,
               'differenceNote', v_s.difference_note)
    INTO v_cash
    FROM pos.cash_movements WHERE cashier_session_id = p_session;

    RETURN jsonb_build_object(
        'header', v_header,
        'sales', v_sales,
        'payments', v_payments,
        'cash', v_cash,
        'approval', jsonb_build_object(
            'cashierName', v_header ->> 'cashierName',
            'closedByName', pos.approver_name(v_s.closed_by),
            'differenceApprovedByName', pos.approver_name(v_s.difference_approved_by),
            'closedAt', v_s.closed_at),
        'generatedAt', now());
END
$$;
REVOKE ALL ON FUNCTION pos.compute_shift_report(uuid) FROM PUBLIC;

-- X report: laporan tengah shift, tidak mengubah session. Hanya pemegang cashier.view di outlet session.
CREATE FUNCTION pos.x_report(p_session uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_s pos.cashier_sessions%ROWTYPE;
BEGIN
    SELECT * INTO v_s FROM pos.cashier_sessions WHERE id = p_session AND organization_id = pos.current_org_id();
    IF v_s.id IS NULL THEN
        RAISE EXCEPTION 'CASHIER_SESSION_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT pos.has_permission('cashier.view', v_s.outlet_id) THEN
        RAISE EXCEPTION 'REPORT_NOT_AUTHORIZED: X report requires cashier.view' USING ERRCODE = 'P0001';
    END IF;
    IF v_s.status NOT IN ('OPEN', 'ON_BREAK', 'CLOSING') THEN
        RAISE EXCEPTION 'CASHIER_SESSION_CLOSED: use the Z report of a closed session' USING ERRCODE = 'P0001';
    END IF;
    RETURN pos.compute_shift_report(p_session) || jsonb_build_object('reportType', 'X');
END
$$;
REVOKE ALL ON FUNCTION pos.x_report(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.x_report(uuid) TO pos_app_user;

-- ---------------------------------------------------------------- cash-up otomatis saat tutup kasir
CREATE FUNCTION pos.tg_cashier_session_cashup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_report jsonb;
    v_z      integer;
BEGIN
    -- nomor Z berurutan per terminal (diserialkan per terminal)
    PERFORM pg_advisory_xact_lock(hashtextextended('cashup:' || NEW.terminal_id::text, 0));
    SELECT coalesce(max(z_number), 0) + 1 INTO v_z FROM pos.cashups WHERE terminal_id = NEW.terminal_id;
    v_report := pos.compute_shift_report(NEW.id) || jsonb_build_object('reportType', 'Z', 'zNumber', v_z);
    IF (v_report #>> '{cash,expectedCash}')::numeric IS DISTINCT FROM NEW.expected_cash THEN
        RAISE EXCEPTION 'CASHUP_MISMATCH: expected cash changed during closing' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.cashups (organization_id, outlet_id, terminal_id, cashier_session_id, employee_id, business_date,
                             z_number, transaction_count, net_sales, expected_cash, actual_cash, difference, report,
                             closed_by)
    VALUES (NEW.organization_id, NEW.outlet_id, NEW.terminal_id, NEW.id, NEW.employee_id, NEW.business_date,
            v_z, (v_report #>> '{sales,transactionCount}')::integer, (v_report #>> '{sales,netSales}')::numeric,
            NEW.expected_cash, NEW.closing_cash, NEW.difference, v_report, NEW.closed_by);
    RETURN NULL;
END
$$;

CREATE TRIGGER cashier_sessions_cashup
    AFTER UPDATE OF status ON pos.cashier_sessions
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM 'CLOSED' AND NEW.status = 'CLOSED')
    EXECUTE FUNCTION pos.tg_cashier_session_cashup();

-- Penjaga terakhir (§85): setiap session CLOSED wajib punya cash-up saat commit.
CREATE FUNCTION pos.tg_cashier_session_requires_cashup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF NEW.status = 'CLOSED' AND NOT EXISTS (SELECT 1 FROM pos.cashups c WHERE c.cashier_session_id = NEW.id) THEN
        RAISE EXCEPTION 'CASHUP_MISSING: closed session % has no cash-up', NEW.id USING ERRCODE = 'P0001';
    END IF;
    RETURN NULL;
END
$$;
CREATE CONSTRAINT TRIGGER cashier_sessions_requires_cashup
    AFTER UPDATE ON pos.cashier_sessions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (NEW.status = 'CLOSED')
    EXECUTE FUNCTION pos.tg_cashier_session_requires_cashup();

-- Cash-up append-only: tidak ada UPDATE/DELETE bagi siapa pun selain owner.
CREATE TRIGGER cashups_append_only
    BEFORE UPDATE OR DELETE ON pos.cashups
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Session yang sudah CLOSED sebelum migration ini (Phase 6) mendapat cash-up susulan.
DO $$
DECLARE
    r record;
    v_report jsonb;
    v_z integer;
BEGIN
    FOR r IN SELECT * FROM pos.cashier_sessions s
             WHERE s.status = 'CLOSED' AND NOT EXISTS (SELECT 1 FROM pos.cashups c WHERE c.cashier_session_id = s.id)
             ORDER BY s.closed_at, s.id LOOP
        SELECT coalesce(max(z_number), 0) + 1 INTO v_z FROM pos.cashups WHERE terminal_id = r.terminal_id;
        v_report := pos.compute_shift_report(r.id) || jsonb_build_object('reportType', 'Z', 'zNumber', v_z);
        INSERT INTO pos.cashups (organization_id, outlet_id, terminal_id, cashier_session_id, employee_id,
                                 business_date, z_number, transaction_count, net_sales, expected_cash, actual_cash,
                                 difference, report, closed_by, created_at)
        VALUES (r.organization_id, r.outlet_id, r.terminal_id, r.id, r.employee_id, r.business_date, v_z,
                (v_report #>> '{sales,transactionCount}')::integer, (v_report #>> '{sales,netSales}')::numeric,
                r.expected_cash, r.closing_cash, r.difference, v_report, r.closed_by, r.closed_at);
    END LOOP;
END
$$;

-- ---------------------------------------------------------------- akses
ALTER TABLE pos.cashups ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON pos.cashups TO pos_app_user, pos_system;
-- terlihat bila session-nya terlihat (pemilik atau cashier.view di outlet)
CREATE POLICY cashups_select ON pos.cashups FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.cashier_sessions s WHERE s.id = cashier_session_id));
CREATE POLICY cashups_system_select ON pos.cashups FOR SELECT TO pos_system USING (true);
