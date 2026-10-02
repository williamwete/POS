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
