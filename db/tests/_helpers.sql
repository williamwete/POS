-- Helper test SQL (hanya dibuat oleh db/tests/run.sh di database test).
CREATE SCHEMA IF NOT EXISTS pos_test;
GRANT USAGE ON SCHEMA pos_test TO PUBLIC;

-- Set klaim JWT untuk transaksi berjalan, seolah backend menerima token user ini.
CREATE OR REPLACE FUNCTION pos_test.login(p_username text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sub uuid;
BEGIN
    SELECT auth_user_id INTO v_sub FROM pos.users WHERE username = p_username;
    IF v_sub IS NULL THEN
        RAISE EXCEPTION 'test user % not found', p_username;
    END IF;
    PERFORM set_config('request.jwt.claims',
        json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
END
$$;

CREATE OR REPLACE FUNCTION pos_test.ok(p_cond boolean, p_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_cond IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL - %', p_name;
    END IF;
    RAISE NOTICE 'ok - %', p_name;
END
$$;

CREATE OR REPLACE FUNCTION pos_test.rows(p_sql text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    n bigint;
BEGIN
    EXECUTE format('WITH q AS (%s) SELECT count(*) FROM q', p_sql) INTO n;
    RETURN n;
END
$$;

-- Pastikan statement gagal dengan pesan yang cocok dengan pola (regex, case-insensitive).
CREATE OR REPLACE FUNCTION pos_test.throws(p_sql text, p_pattern text, p_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN others THEN
        IF SQLERRM ~* p_pattern THEN
            RAISE NOTICE 'ok - %', p_name;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL - % (unexpected error: %)', p_name, SQLERRM;
    END;
    RAISE EXCEPTION 'FAIL - % (statement succeeded, expected error /%/)', p_name, p_pattern;
END
$$;

-- Jalankan statement DML dan kembalikan jumlah baris yang terkena (0 = diblokir RLS).
CREATE OR REPLACE FUNCTION pos_test.affected(p_sql text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    n bigint;
BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pos_test TO PUBLIC;

-- Buat akun di shim auth.users (pos_api tidak punya akses ke schema auth).
CREATE OR REPLACE FUNCTION pos_test.make_auth_user(p_email text)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, auth
AS $$
    INSERT INTO auth.users (email) VALUES (p_email) RETURNING id
$$;
GRANT EXECUTE ON FUNCTION pos_test.make_auth_user(text) TO PUBLIC;

-- Seperti login, ditambah klaim auth_time = sekarang (user baru saja memasukkan password).
CREATE OR REPLACE FUNCTION pos_test.reauth(p_username text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_sub uuid;
BEGIN
    SELECT auth_user_id INTO v_sub FROM pos.users WHERE username = p_username;
    PERFORM set_config('request.jwt.claims',
        json_build_object('sub', v_sub, 'role', 'authenticated',
                          'auth_time', floor(extract(epoch FROM clock_timestamp())))::text, true);
END
$$;
GRANT EXECUTE ON FUNCTION pos_test.reauth(text) TO PUBLIC;

-- Buka kasir lengkap seperti backend (dijalankan sebagai pemanggil, tunduk RLS):
-- session -> hitungan OPENING + item -> finalize -> opening_cash -> movement OPENING_CASH.
-- p_counts: pasangan (nilai denominasi NOTE, jumlah lembar), mis. '{{100000,2},{50000,3}}'.
CREATE OR REPLACE FUNCTION pos_test.open_session(p_terminal uuid, p_counts numeric[])
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_session uuid;
    v_count   uuid;
    v_total   numeric;
    i         int;
BEGIN
    INSERT INTO pos.cashier_sessions (organization_id, outlet_id, terminal_id, employee_id, attendance_id, opened_by)
    SELECT pos.current_org_id(), t.outlet_id, t.id, pos.current_employee_id(), a.id, pos.current_app_user_id()
    FROM pos.terminals t
    LEFT JOIN pos.attendance a ON a.employee_id = pos.current_employee_id() AND a.status IN ('WORKING', 'ON_BREAK')
    WHERE t.id = p_terminal
    RETURNING id INTO v_session;
    INSERT INTO pos.cash_counts (cashier_session_id, count_type, counted_by)
    VALUES (v_session, 'OPENING', pos.current_app_user_id()) RETURNING id INTO v_count;
    IF p_counts IS NOT NULL THEN
        FOR i IN 1 .. array_length(p_counts, 1) LOOP
            INSERT INTO pos.cash_count_items (cash_count_id, denomination_id, value, kind, quantity)
            SELECT v_count, d.id, 0, 'NOTE', p_counts[i][2]::int
            FROM pos.cash_denominations d
            WHERE d.organization_id = pos.current_org_id() AND d.value = p_counts[i][1] AND d.kind = 'NOTE';
        END LOOP;
    END IF;
    SELECT total_amount INTO v_total FROM pos.finalize_cash_count(v_count);
    UPDATE pos.cashier_sessions SET opening_cash = v_total WHERE id = v_session;
    INSERT INTO pos.cash_movements (organization_id, outlet_id, cashier_session_id, business_date,
                                    movement_type, amount, created_by)
    VALUES (pos.current_org_id(), '00000000-0000-0000-0000-000000000000', v_session, '1900-01-01',
            'OPENING_CASH', v_total, pos.current_app_user_id());
    RETURN v_session;
END
$$;
GRANT EXECUTE ON FUNCTION pos_test.open_session(uuid, numeric[]) TO PUBLIC;

-- Clock in diri sendiri di outlet.
CREATE OR REPLACE FUNCTION pos_test.clock_in(p_outlet uuid)
RETURNS uuid
LANGUAGE sql
AS $$
    INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by)
    VALUES (pos.current_org_id(), pos.current_employee_id(), p_outlet, pos.current_app_user_id())
    RETURNING id
$$;
GRANT EXECUTE ON FUNCTION pos_test.clock_in(uuid) TO PUBLIC;

-- Penjualan baru (DRAFT) di session aktif user saat ini.
CREATE OR REPLACE FUNCTION pos_test.new_sale()
RETURNS uuid
LANGUAGE sql
AS $$
    INSERT INTO pos.sales (organization_id, outlet_id, terminal_id, cashier_session_id, employee_id, created_by,
                           business_date, client_transaction_id)
    SELECT s.organization_id, s.outlet_id, s.terminal_id, s.id, s.employee_id, pos.current_app_user_id(),
           '1900-01-01', 'TEST-' || replace(gen_random_uuid()::text, '-', '')
    FROM pos.cashier_sessions s
    WHERE s.employee_id = pos.current_employee_id() AND s.status IN ('OPEN', 'ON_BREAK')
    RETURNING id
$$;
GRANT EXECUTE ON FUNCTION pos_test.new_sale() TO PUBLIC;

CREATE OR REPLACE FUNCTION pos_test.add_item(p_sale uuid, p_sku text, p_qty numeric)
RETURNS uuid
LANGUAGE sql
AS $$
    INSERT INTO pos.sale_items (sale_id, product_id, sku, product_name, uom, quantity, list_price, unit_price, created_by)
    SELECT p_sale, p.id, 'x', 'x', 'x', p_qty, 1, 1, pos.current_app_user_id()
    FROM pos.products p WHERE p.sku = p_sku
    RETURNING id
$$;
GRANT EXECUTE ON FUNCTION pos_test.add_item(uuid, text, numeric) TO PUBLIC;
