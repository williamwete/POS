-- V001: schema, database roles, baseline privileges
-- Lihat docs/ASSUMPTIONS.md A1/A2 untuk model role.
--
--   pos_api       : role LOGIN yang dipakai backend. NOINHERIT => tidak punya privilege
--                   apa pun sampai melakukan SET LOCAL ROLE. Password diset di luar
--                   migration (lihat docs/DATABASE.md).
--   pos_app_user  : konteks request user. Semua tabel dilindungi RLS.
--   pos_system    : konteks job sistem (sync, scheduler, bootstrap login).

CREATE SCHEMA IF NOT EXISTS pos;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_app_user') THEN
        CREATE ROLE pos_app_user NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_system') THEN
        CREATE ROLE pos_system NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_api') THEN
        CREATE ROLE pos_api NOLOGIN NOINHERIT;
    END IF;
END
$$;

ALTER ROLE pos_api NOINHERIT;

GRANT pos_app_user TO pos_api;
GRANT pos_system TO pos_api;

-- Tidak ada akses default ke schema pos.
REVOKE ALL ON SCHEMA pos FROM PUBLIC;
GRANT USAGE ON SCHEMA pos TO pos_app_user, pos_system;

-- Supabase: pastikan role PostgREST tidak pernah mendapat akses ke schema pos.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'REVOKE ALL ON SCHEMA pos FROM anon';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        EXECUTE 'REVOKE ALL ON SCHEMA pos FROM authenticated';
    END IF;
END
$$;

-- Fungsi baru di schema pos tidak bisa dieksekusi PUBLIC kecuali di-grant eksplisit.
ALTER DEFAULT PRIVILEGES IN SCHEMA pos REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Trigger umum: updated_at + optimistic locking version.
CREATE OR REPLACE FUNCTION pos.tg_touch_row()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;

-- Trigger umum: tolak perubahan pada tabel append-only.
CREATE OR REPLACE FUNCTION pos.tg_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'APPEND_ONLY_VIOLATION: % on %.% is not allowed',
        TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'P0001';
END
$$;

GRANT EXECUTE ON FUNCTION pos.tg_touch_row() TO pos_app_user, pos_system;
GRANT EXECUTE ON FUNCTION pos.tg_append_only() TO pos_app_user, pos_system;
