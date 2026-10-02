-- LOCAL/TEST ONLY. Jangan pernah dijalankan pada project Supabase.
-- Meniru subset schema `auth` milik Supabase (GoTrue) agar migration pos.users
-- (FK ke auth.users) dan login lokal dapat berjalan tanpa Supabase.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email               text UNIQUE,
    encrypted_password  text,
    email_confirmed_at  timestamptz,
    raw_app_meta_data   jsonb NOT NULL DEFAULT '{}'::jsonb,
    raw_user_meta_data  jsonb NOT NULL DEFAULT '{}'::jsonb,
    banned_until        timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- Role yang dipakai endpoint token lokal untuk memverifikasi password.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pos_local_auth') THEN
        CREATE ROLE pos_local_auth NOLOGIN;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION auth.local_verify_password(p_email text, p_password text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, auth, public
AS $$
    SELECT u.id
    FROM auth.users u
    WHERE lower(u.email) = lower(p_email)
      AND u.encrypted_password IS NOT NULL
      AND u.encrypted_password = crypt(p_password, u.encrypted_password)
      AND (u.banned_until IS NULL OR u.banned_until < now())
$$;

CREATE OR REPLACE FUNCTION auth.local_create_user(p_email text, p_password text)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, auth, public
AS $$
    INSERT INTO auth.users (email, encrypted_password, email_confirmed_at)
    VALUES (lower(p_email), crypt(p_password, gen_salt('bf', 10)), now())
    RETURNING id
$$;

REVOKE ALL ON FUNCTION auth.local_verify_password(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION auth.local_create_user(text, text) FROM PUBLIC;
GRANT USAGE ON SCHEMA auth TO pos_local_auth;
GRANT EXECUTE ON FUNCTION auth.local_verify_password(text, text) TO pos_local_auth;
GRANT EXECUTE ON FUNCTION auth.local_create_user(text, text) TO pos_local_auth;
