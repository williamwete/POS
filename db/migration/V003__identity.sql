-- V003: identity — employees, users, roles, permissions, scopes
-- pos.users adalah profil aplikasi; kredensial dikelola Supabase Auth (auth.users).

CREATE TABLE pos.employees (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    employee_code    text        NOT NULL,
    full_name        text        NOT NULL,
    phone            text,
    email            text,
    position         text,
    home_outlet_id   uuid,
    hire_date        date,
    active           boolean     NOT NULL DEFAULT true,
    deleted_at       timestamptz,
    deleted_by       uuid,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    version          integer     NOT NULL DEFAULT 0,
    CONSTRAINT employees_org_code_uk UNIQUE (organization_id, employee_code),
    CONSTRAINT employees_code_ck CHECK (employee_code ~ '^[A-Z0-9_-]{2,32}$'),
    CONSTRAINT employees_home_outlet_fk FOREIGN KEY (home_outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT employees_id_org_uk UNIQUE (id, organization_id)
);

CREATE TABLE pos.users (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id     uuid        NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    employee_id      uuid,
    username         text        NOT NULL,
    email            text        NOT NULL,
    display_name     text        NOT NULL,
    active           boolean     NOT NULL DEFAULT true,
    last_login_at    timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    version          integer     NOT NULL DEFAULT 0,
    CONSTRAINT users_auth_user_uk UNIQUE (auth_user_id),
    CONSTRAINT users_employee_uk UNIQUE (employee_id),
    CONSTRAINT users_username_ck CHECK (username ~ '^[a-z0-9._-]{3,64}$'),
    CONSTRAINT users_employee_fk FOREIGN KEY (employee_id, organization_id)
        REFERENCES pos.employees (id, organization_id)
);

CREATE UNIQUE INDEX users_username_uk ON pos.users (lower(username));
CREATE UNIQUE INDEX users_email_uk ON pos.users (lower(email));
CREATE INDEX users_org_idx ON pos.users (organization_id);

CREATE TABLE pos.permissions (
    code         text PRIMARY KEY,
    module       text NOT NULL,
    description  text NOT NULL,
    CONSTRAINT permissions_code_ck CHECK (code ~ '^[a-z_]+\.[a-z_]+$')
);

CREATE TABLE pos.roles (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code         text        NOT NULL,
    name         text        NOT NULL,
    description  text,
    is_system    boolean     NOT NULL DEFAULT false,
    -- Hierarki anti-eskalasi: user hanya dapat memberi/mencabut/mengubah role dengan
    -- rank LEBIH RENDAH dari rank tertinggi role org-wide miliknya.
    rank         smallint    NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid,
    version      integer     NOT NULL DEFAULT 0,
    CONSTRAINT roles_code_uk UNIQUE (code),
    CONSTRAINT roles_code_ck CHECK (code ~ '^[A-Z_]{2,40}$'),
    CONSTRAINT roles_rank_ck CHECK (rank BETWEEN 1 AND 100)
);

CREATE TABLE pos.role_permissions (
    role_id          uuid NOT NULL REFERENCES pos.roles (id),
    permission_code  text NOT NULL REFERENCES pos.permissions (code),
    granted_at       timestamptz NOT NULL DEFAULT now(),
    granted_by       uuid,
    PRIMARY KEY (role_id, permission_code)
);

-- outlet_id NULL => role berlaku org-wide (ASSUMPTIONS B2)
CREATE TABLE pos.user_roles (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES pos.users (id),
    role_id     uuid        NOT NULL REFERENCES pos.roles (id),
    outlet_id   uuid        REFERENCES pos.outlets (id),
    granted_by  uuid,
    granted_at  timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX user_roles_scope_uk
    ON pos.user_roles (user_id, role_id, outlet_id) NULLS NOT DISTINCT;
CREATE INDEX user_roles_user_idx ON pos.user_roles (user_id);

CREATE TABLE pos.user_outlets (
    user_id     uuid        NOT NULL REFERENCES pos.users (id),
    outlet_id   uuid        NOT NULL REFERENCES pos.outlets (id),
    granted_by  uuid,
    granted_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, outlet_id)
);

CREATE INDEX user_outlets_outlet_idx ON pos.user_outlets (outlet_id);
CREATE INDEX employees_home_outlet_idx ON pos.employees (home_outlet_id);

CREATE TRIGGER employees_touch BEFORE UPDATE ON pos.employees
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();
CREATE TRIGGER users_touch BEFORE UPDATE ON pos.users
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();
CREATE TRIGGER roles_touch BEFORE UPDATE ON pos.roles
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();

CREATE TRIGGER employees_no_delete BEFORE DELETE ON pos.employees
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();
CREATE TRIGGER users_no_delete BEFORE DELETE ON pos.users
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- Role sistem tidak boleh dihapus atau diganti kodenya.
CREATE OR REPLACE FUNCTION pos.tg_protect_system_role()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' AND OLD.is_system THEN
        RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED: role % cannot be deleted', OLD.code
            USING ERRCODE = 'P0001';
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.is_system
       AND (NEW.code IS DISTINCT FROM OLD.code
            OR NEW.is_system IS DISTINCT FROM OLD.is_system
            OR NEW.rank IS DISTINCT FROM OLD.rank) THEN
        RAISE EXCEPTION 'SYSTEM_ROLE_PROTECTED: role % code cannot be changed', OLD.code
            USING ERRCODE = 'P0001';
    END IF;
    RETURN COALESCE(NEW, OLD);
END
$$;

CREATE TRIGGER roles_protect BEFORE UPDATE OR DELETE ON pos.roles
    FOR EACH ROW EXECUTE FUNCTION pos.tg_protect_system_role();
