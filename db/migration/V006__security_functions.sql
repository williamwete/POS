-- V006: security helper functions (single source of truth untuk otorisasi)
--
-- Semua fungsi SECURITY DEFINER dengan search_path terkunci agar:
--   1. policy tidak rekursif (fungsi membaca tabel identitas tanpa terkena RLS);
--   2. tidak bisa dibajak lewat objek di schema lain.
-- Backend memanggil fungsi yang SAMA untuk cek permission (ASSUMPTIONS A2).

-- Subject JWT dari konteks transaksi. NULL jika tidak ada / bukan user terautentikasi.
CREATE OR REPLACE FUNCTION pos.jwt_sub()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    raw    text := nullif(current_setting('request.jwt.claims', true), '');
    claims jsonb;
BEGIN
    IF raw IS NULL THEN
        RETURN NULL;
    END IF;
    claims := raw::jsonb;
    IF coalesce(claims ->> 'role', 'authenticated') <> 'authenticated' THEN
        RETURN NULL;
    END IF;
    RETURN nullif(claims ->> 'sub', '')::uuid;
EXCEPTION
    WHEN invalid_text_representation THEN
        RETURN NULL;
END
$$;

-- pos.users.id milik user yang sedang request (hanya jika user & organisasi aktif).
CREATE OR REPLACE FUNCTION pos.current_app_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT u.id
    FROM pos.users u
    JOIN pos.organizations o ON o.id = u.organization_id
    WHERE u.auth_user_id = pos.jwt_sub()
      AND u.active
      AND o.active
$$;

CREATE OR REPLACE FUNCTION pos.current_org_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT u.organization_id FROM pos.users u WHERE u.id = pos.current_app_user_id()
$$;

CREATE OR REPLACE FUNCTION pos.current_employee_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT u.employee_id FROM pos.users u WHERE u.id = pos.current_app_user_id()
$$;

-- Organisasi milik user lain (dipakai policy assignment, tanpa membuka baris user).
CREATE OR REPLACE FUNCTION pos.user_org_id(p_user_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT u.organization_id FROM pos.users u WHERE u.id = p_user_id
$$;

-- Apakah user memiliki minimal satu role org-wide (ASSUMPTIONS B3).
CREATE OR REPLACE FUNCTION pos.has_org_wide_role()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT EXISTS (
        SELECT 1 FROM pos.user_roles ur
        WHERE ur.user_id = pos.current_app_user_id() AND ur.outlet_id IS NULL
    )
$$;

-- Outlet yang boleh diakses user saat ini.
CREATE OR REPLACE FUNCTION pos.accessible_outlet_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT o.id
    FROM pos.outlets o
    WHERE o.organization_id = pos.current_org_id()
      AND (
            pos.has_org_wide_role()
         OR EXISTS (SELECT 1 FROM pos.user_outlets uo
                    WHERE uo.user_id = pos.current_app_user_id() AND uo.outlet_id = o.id)
      )
$$;

CREATE OR REPLACE FUNCTION pos.can_access_outlet(p_outlet_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT p_outlet_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM pos.accessible_outlet_ids() a WHERE a = p_outlet_id)
$$;

-- Cek permission.
--   p_outlet_id NULL     => hanya role org-wide yang dihitung (aksi level organisasi)
--   p_outlet_id NOT NULL => user harus punya akses outlet, dan permission berasal dari
--                           role org-wide atau role yang di-scope ke outlet tersebut.
CREATE OR REPLACE FUNCTION pos.has_permission(p_permission text, p_outlet_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_user uuid := pos.current_app_user_id();
BEGIN
    IF v_user IS NULL OR p_permission IS NULL THEN
        RETURN false;
    END IF;

    IF p_outlet_id IS NULL THEN
        RETURN EXISTS (
            SELECT 1
            FROM pos.user_roles ur
            JOIN pos.role_permissions rp ON rp.role_id = ur.role_id
            WHERE ur.user_id = v_user
              AND ur.outlet_id IS NULL
              AND rp.permission_code = p_permission
        );
    END IF;

    IF NOT pos.can_access_outlet(p_outlet_id) THEN
        RETURN false;
    END IF;

    RETURN EXISTS (
        SELECT 1
        FROM pos.user_roles ur
        JOIN pos.role_permissions rp ON rp.role_id = ur.role_id
        WHERE ur.user_id = v_user
          AND (ur.outlet_id IS NULL OR ur.outlet_id = p_outlet_id)
          AND rp.permission_code = p_permission
    );
END
$$;

-- Permission efektif (untuk endpoint /me dan UI). NULL => level organisasi.
CREATE OR REPLACE FUNCTION pos.effective_permissions(p_outlet_id uuid DEFAULT NULL)
RETURNS SETOF text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT DISTINCT rp.permission_code
    FROM pos.user_roles ur
    JOIN pos.role_permissions rp ON rp.role_id = ur.role_id
    WHERE ur.user_id = pos.current_app_user_id()
      AND (
            ur.outlet_id IS NULL
         OR (p_outlet_id IS NOT NULL AND ur.outlet_id = p_outlet_id AND pos.can_access_outlet(p_outlet_id))
      )
    ORDER BY 1
$$;

-- Rank tertinggi dari role ORG-WIDE user saat ini (0 jika tidak ada).
CREATE OR REPLACE FUNCTION pos.current_max_rank()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT coalesce(max(r.rank), 0)::integer
    FROM pos.user_roles ur
    JOIN pos.roles r ON r.id = ur.role_id
    WHERE ur.user_id = pos.current_app_user_id() AND ur.outlet_id IS NULL
$$;

-- Rank tertinggi role apa pun (org-wide maupun outlet) milik user tertentu.
CREATE OR REPLACE FUNCTION pos.user_max_rank(p_user_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT coalesce(max(r.rank), 0)::integer
    FROM pos.user_roles ur
    JOIN pos.roles r ON r.id = ur.role_id
    WHERE ur.user_id = p_user_id
$$;

CREATE OR REPLACE FUNCTION pos.role_rank(p_role_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT r.rank::integer FROM pos.roles r WHERE r.id = p_role_id
$$;

-- Anti privilege escalation (ASSUMPTIONS A7): memberi/mencabut role butuh
-- user.manage org-wide, rank role < rank tertinggi pemberi, dan akses ke outlet scope.
CREATE OR REPLACE FUNCTION pos.can_grant_role(p_role_id uuid, p_outlet_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT pos.has_permission('user.manage', NULL)
       AND coalesce(pos.role_rank(p_role_id), 1000) < pos.current_max_rank()
       AND (p_outlet_id IS NULL OR pos.can_access_outlet(p_outlet_id))
$$;

-- Melihat user lain: user.view/user.manage org-wide, ATAU user.view di outlet
-- tempat user target memiliki akses (mis. store manager melihat staf outletnya).
CREATE OR REPLACE FUNCTION pos.can_view_user(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT p_user_id = pos.current_app_user_id()
        OR (pos.user_org_id(p_user_id) = pos.current_org_id()
            AND (pos.has_permission('user.view', NULL)
                 OR pos.has_permission('user.manage', NULL)
                 OR EXISTS (SELECT 1 FROM pos.user_outlets uo
                            WHERE uo.user_id = p_user_id
                              AND pos.has_permission('user.view', uo.outlet_id))))
$$;

-- Mengelola user lain hanya jika semua role target berada di bawah rank pengelola.
CREATE OR REPLACE FUNCTION pos.can_manage_user(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT p_user_id IS NOT NULL
       AND p_user_id IS DISTINCT FROM pos.current_app_user_id()
       AND pos.user_org_id(p_user_id) = pos.current_org_id()
       AND pos.has_permission('user.manage', NULL)
       AND pos.user_max_rank(p_user_id) < pos.current_max_rank()
$$;

-- Resolusi setting: outlet override -> organisasi -> default definisi.
CREATE OR REPLACE FUNCTION pos.get_setting(p_key text, p_outlet_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org   uuid;
    v_value jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pos.setting_definitions d WHERE d.key = p_key) THEN
        RAISE EXCEPTION 'SETTING_UNKNOWN: %', p_key USING ERRCODE = 'P0001';
    END IF;

    IF p_outlet_id IS NOT NULL THEN
        SELECT o.organization_id INTO v_org FROM pos.outlets o WHERE o.id = p_outlet_id;
        SELECT s.value INTO v_value FROM pos.settings s
        WHERE s.outlet_id = p_outlet_id AND s.key = p_key;
        IF v_value IS NOT NULL THEN
            RETURN v_value;
        END IF;
    ELSE
        v_org := pos.current_org_id();
    END IF;

    IF v_org IS NOT NULL THEN
        SELECT s.value INTO v_value FROM pos.settings s
        WHERE s.organization_id = v_org AND s.outlet_id IS NULL AND s.key = p_key;
        IF v_value IS NOT NULL THEN
            RETURN v_value;
        END IF;
    END IF;

    SELECT d.default_value INTO v_value FROM pos.setting_definitions d WHERE d.key = p_key;
    RETURN v_value;
END
$$;

-- Business date (ASSUMPTIONS B8): waktu lokal outlet dikurangi cutoff.
CREATE OR REPLACE FUNCTION pos.business_date(p_at timestamptz, p_outlet_id uuid)
RETURNS date
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_tz     text;
    v_cutoff time;
BEGIN
    SELECT coalesce(o.timezone, org.timezone)
    INTO v_tz
    FROM pos.outlets o
    JOIN pos.organizations org ON org.id = o.organization_id
    WHERE o.id = p_outlet_id;

    IF v_tz IS NULL THEN
        RAISE EXCEPTION 'OUTLET_NOT_FOUND: %', p_outlet_id USING ERRCODE = 'P0001';
    END IF;

    v_cutoff := (pos.get_setting('business_day_cutoff', p_outlet_id) #>> '{}')::time;
    RETURN ((p_at AT TIME ZONE v_tz) - (v_cutoff - time '00:00'))::date;
END
$$;

REVOKE ALL ON FUNCTION
    pos.jwt_sub(),
    pos.current_app_user_id(),
    pos.current_org_id(),
    pos.current_employee_id(),
    pos.user_org_id(uuid),
    pos.has_org_wide_role(),
    pos.accessible_outlet_ids(),
    pos.can_access_outlet(uuid),
    pos.has_permission(text, uuid),
    pos.effective_permissions(uuid),
    pos.current_max_rank(),
    pos.user_max_rank(uuid),
    pos.role_rank(uuid),
    pos.can_grant_role(uuid, uuid),
    pos.can_manage_user(uuid),
    pos.can_view_user(uuid),
    pos.get_setting(text, uuid),
    pos.business_date(timestamptz, uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    pos.jwt_sub(),
    pos.current_app_user_id(),
    pos.current_org_id(),
    pos.current_employee_id(),
    pos.user_org_id(uuid),
    pos.has_org_wide_role(),
    pos.accessible_outlet_ids(),
    pos.can_access_outlet(uuid),
    pos.has_permission(text, uuid),
    pos.effective_permissions(uuid),
    pos.current_max_rank(),
    pos.user_max_rank(uuid),
    pos.role_rank(uuid),
    pos.can_grant_role(uuid, uuid),
    pos.can_manage_user(uuid),
    pos.can_view_user(uuid),
    pos.get_setting(text, uuid),
    pos.business_date(timestamptz, uuid)
TO pos_app_user, pos_system;
