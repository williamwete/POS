-- V021: onboarding merchant (SaaS) — paket & batas, konsol platform, penutup celah role global.
-- Operator platform = user di organisasi PLATFORM dengan role PLATFORM_ADMIN (permission platform.manage).

-- ---------------------------------------------------------------- permission & role platform
INSERT INTO pos.permissions (code, module, description) VALUES
    ('platform.manage', 'platform', 'Kelola merchant, paket & batas (hanya operator platform)');

INSERT INTO pos.roles (code, name, description, is_system, rank)
VALUES ('PLATFORM_ADMIN', 'Platform Admin', 'Operator platform SaaS: membuat & mengelola merchant', true, 100);

INSERT INTO pos.role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM pos.roles r, pos.permissions p
WHERE r.code = 'PLATFORM_ADMIN' AND p.code IN ('platform.manage', 'role.manage');

ALTER TABLE pos.organizations
    ADD COLUMN business_type text NOT NULL DEFAULT 'GENERAL',
    ADD CONSTRAINT organizations_business_type_ck CHECK (business_type IN ('FNB', 'RETAIL', 'SERVICE', 'GENERAL'));

-- ---------------------------------------------------------------- celah role global
-- Role sistem dipakai bersama semua merchant: permission-nya hanya boleh diubah operator platform.
CREATE OR REPLACE FUNCTION pos.role_permissions_editable(p_role_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT CASE WHEN r.is_system THEN pos.has_permission('platform.manage', NULL) ELSE true END
    FROM pos.roles r WHERE r.id = p_role_id
$$;
REVOKE ALL ON FUNCTION pos.role_permissions_editable(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.role_permissions_editable(uuid) TO pos_app_user;

DROP POLICY role_permissions_insert ON pos.role_permissions;
CREATE POLICY role_permissions_insert ON pos.role_permissions FOR INSERT TO pos_app_user
    WITH CHECK (
        pos.has_permission('role.manage', NULL)
        AND pos.has_permission(permission_code, NULL)
        AND pos.role_rank(role_id) < pos.current_max_rank()
        AND pos.role_permissions_editable(role_id)
    );

DROP POLICY role_permissions_delete ON pos.role_permissions;
CREATE POLICY role_permissions_delete ON pos.role_permissions FOR DELETE TO pos_app_user
    USING (
        pos.has_permission('role.manage', NULL)
        AND pos.role_rank(role_id) < pos.current_max_rank()
        AND pos.role_permissions_editable(role_id)
    );

-- Role platform tidak terlihat/tidak dapat diberikan oleh merchant.
CREATE OR REPLACE FUNCTION pos.tg_guard_platform_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM pos.roles r WHERE r.id = NEW.role_id AND r.code = 'PLATFORM_ADMIN')
       AND NOT EXISTS (SELECT 1 FROM pos.organizations o WHERE o.id = (SELECT organization_id FROM pos.users WHERE id = NEW.user_id)
                       AND o.code = 'PLATFORM') THEN
        RAISE EXCEPTION 'USER_NOT_AUTHORIZED: role platform hanya untuk organisasi PLATFORM' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER user_roles_platform_guard BEFORE INSERT ON pos.user_roles
    FOR EACH ROW EXECUTE FUNCTION pos.tg_guard_platform_role();

-- ---------------------------------------------------------------- paket & langganan
CREATE TABLE pos.plans (
    code            text PRIMARY KEY,
    name            text    NOT NULL,
    max_outlets     integer,
    max_terminals   integer,
    max_users       integer,
    max_products    integer,
    price_monthly   numeric(14,2) NOT NULL DEFAULT 0,
    sort_order      integer NOT NULL DEFAULT 0,
    active          boolean NOT NULL DEFAULT true,
    CONSTRAINT plans_code_ck CHECK (code ~ '^[A-Z0-9_]{2,20}$'),
    CONSTRAINT plans_limits_ck CHECK (coalesce(max_outlets, 1) > 0 AND coalesce(max_terminals, 1) > 0
        AND coalesce(max_users, 1) > 0 AND coalesce(max_products, 1) > 0)
);
-- NULL = tanpa batas
INSERT INTO pos.plans (code, name, max_outlets, max_terminals, max_users, max_products, price_monthly, sort_order) VALUES
    ('TRIAL',      'Trial',      1, 1,    3,   100,      0, 10),
    ('STARTER',    'Starter',    1, 2,    5,   500,  99000, 20),
    ('BUSINESS',   'Business',   5, 10,  30,  5000, 399000, 30),
    ('ENTERPRISE', 'Enterprise', NULL, NULL, NULL, NULL, 0, 40);

CREATE TABLE pos.organization_subscriptions (
    organization_id  uuid PRIMARY KEY REFERENCES pos.organizations (id),
    plan_code        text NOT NULL REFERENCES pos.plans (code),
    status           text NOT NULL DEFAULT 'ACTIVE',
    trial_ends_at    timestamptz,
    notes            text,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT subscriptions_status_ck CHECK (status IN ('TRIAL', 'ACTIVE', 'SUSPENDED', 'CANCELLED'))
);

-- Tabel platform tidak dapat dibaca merchant sama sekali (tanpa policy = tertutup); akses lewat fungsi.
ALTER TABLE pos.plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.organization_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pos.plans, pos.organization_subscriptions FROM PUBLIC;

-- Organisasi yang sudah ada (demo) tanpa batas.
INSERT INTO pos.organization_subscriptions (organization_id, plan_code, status)
SELECT o.id, 'ENTERPRISE', 'ACTIVE' FROM pos.organizations o;

-- Organisasi operator.
INSERT INTO pos.organizations (code, name) VALUES ('PLATFORM', 'Platform Operator');
INSERT INTO pos.organization_subscriptions (organization_id, plan_code, status)
SELECT id, 'ENTERPRISE', 'ACTIVE' FROM pos.organizations WHERE code = 'PLATFORM';

-- ---------------------------------------------------------------- batas paket
CREATE OR REPLACE FUNCTION pos.enforce_plan_limit(p_org uuid, p_kind text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_plan pos.plans%ROWTYPE;
    v_limit integer;
    v_count integer;
    v_label text;
BEGIN
    SELECT p.* INTO v_plan
    FROM pos.organization_subscriptions s JOIN pos.plans p ON p.code = s.plan_code
    WHERE s.organization_id = p_org;
    IF NOT FOUND THEN
        RETURN; -- tanpa langganan = tanpa batas
    END IF;
    IF p_kind = 'OUTLET' THEN
        v_limit := v_plan.max_outlets; v_label := 'outlet';
        SELECT count(*) INTO v_count FROM pos.outlets WHERE organization_id = p_org AND deleted_at IS NULL;
    ELSIF p_kind = 'TERMINAL' THEN
        v_limit := v_plan.max_terminals; v_label := 'terminal';
        SELECT count(*) INTO v_count FROM pos.terminals t JOIN pos.outlets o ON o.id = t.outlet_id
        WHERE o.organization_id = p_org;
    ELSIF p_kind = 'USER' THEN
        v_limit := v_plan.max_users; v_label := 'pengguna';
        SELECT count(*) INTO v_count FROM pos.users WHERE organization_id = p_org AND active;
    ELSIF p_kind = 'PRODUCT' THEN
        v_limit := v_plan.max_products; v_label := 'produk';
        SELECT count(*) INTO v_count FROM pos.products WHERE organization_id = p_org AND source = 'LOCAL';
    ELSE
        RETURN;
    END IF;
    IF v_limit IS NOT NULL AND v_count >= v_limit THEN
        RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: paket % dibatasi % % — upgrade paket untuk menambah',
            v_plan.name, v_limit, v_label USING ERRCODE = 'P0001';
    END IF;
END
$$;
REVOKE ALL ON FUNCTION pos.enforce_plan_limit(uuid, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pos.tg_plan_limit_outlet() RETURNS trigger LANGUAGE plpgsql
    SECURITY DEFINER SET search_path = pg_catalog, pos AS $$
BEGIN PERFORM pos.enforce_plan_limit(NEW.organization_id, 'OUTLET'); RETURN NEW; END $$;
CREATE OR REPLACE FUNCTION pos.tg_plan_limit_terminal() RETURNS trigger LANGUAGE plpgsql
    SECURITY DEFINER SET search_path = pg_catalog, pos AS $$
BEGIN PERFORM pos.enforce_plan_limit((SELECT organization_id FROM pos.outlets WHERE id = NEW.outlet_id), 'TERMINAL'); RETURN NEW; END $$;
CREATE OR REPLACE FUNCTION pos.tg_plan_limit_user() RETURNS trigger LANGUAGE plpgsql
    SECURITY DEFINER SET search_path = pg_catalog, pos AS $$
BEGIN IF NEW.active THEN PERFORM pos.enforce_plan_limit(NEW.organization_id, 'USER'); END IF; RETURN NEW; END $$;
CREATE OR REPLACE FUNCTION pos.tg_plan_limit_product() RETURNS trigger LANGUAGE plpgsql
    SECURITY DEFINER SET search_path = pg_catalog, pos AS $$
BEGIN IF NEW.source = 'LOCAL' THEN PERFORM pos.enforce_plan_limit(NEW.organization_id, 'PRODUCT'); END IF; RETURN NEW; END $$;

CREATE TRIGGER outlets_plan_limit   BEFORE INSERT ON pos.outlets   FOR EACH ROW EXECUTE FUNCTION pos.tg_plan_limit_outlet();
CREATE TRIGGER terminals_plan_limit BEFORE INSERT ON pos.terminals FOR EACH ROW EXECUTE FUNCTION pos.tg_plan_limit_terminal();
CREATE TRIGGER users_plan_limit     BEFORE INSERT ON pos.users     FOR EACH ROW EXECUTE FUNCTION pos.tg_plan_limit_user();
CREATE TRIGGER products_plan_limit  BEFORE INSERT ON pos.products  FOR EACH ROW EXECUTE FUNCTION pos.tg_plan_limit_product();

-- ---------------------------------------------------------------- fungsi konsol platform
CREATE OR REPLACE FUNCTION pos.platform_plans()
RETURNS TABLE (code text, name text, max_outlets integer, max_terminals integer, max_users integer,
               max_products integer, price_monthly numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    RETURN QUERY SELECT p.code, p.name, p.max_outlets, p.max_terminals, p.max_users, p.max_products, p.price_monthly
                 FROM pos.plans p WHERE p.active ORDER BY p.sort_order;
END
$$;

CREATE OR REPLACE FUNCTION pos.platform_list_merchants()
RETURNS TABLE (id uuid, code text, name text, business_type text, active boolean, plan_code text,
               sub_status text, trial_ends_at timestamptz, outlets bigint, terminals bigint, users bigint,
               products bigint, last_sale_at timestamptz, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    RETURN QUERY
    SELECT o.id, o.code, o.name, o.business_type, o.active, s.plan_code, s.status, s.trial_ends_at,
           (SELECT count(*) FROM pos.outlets x WHERE x.organization_id = o.id AND x.deleted_at IS NULL),
           (SELECT count(*) FROM pos.terminals t JOIN pos.outlets x ON x.id = t.outlet_id WHERE x.organization_id = o.id),
           (SELECT count(*) FROM pos.users u WHERE u.organization_id = o.id AND u.active),
           (SELECT count(*) FROM pos.products pr WHERE pr.organization_id = o.id),
           (SELECT max(sa.created_at) FROM pos.sales sa JOIN pos.outlets x ON x.id = sa.outlet_id WHERE x.organization_id = o.id),
           o.created_at
    FROM pos.organizations o
    LEFT JOIN pos.organization_subscriptions s ON s.organization_id = o.id
    WHERE o.code <> 'PLATFORM'
    ORDER BY o.created_at DESC;
END
$$;

CREATE OR REPLACE FUNCTION pos.platform_merchant_users(p_org uuid)
RETURNS TABLE (user_id uuid, auth_user_id uuid, username text, display_name text, email text, active boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    RETURN QUERY SELECT u.id, u.auth_user_id, u.username, u.display_name, u.email, u.active
                 FROM pos.users u WHERE u.organization_id = p_org ORDER BY u.username;
END
$$;

CREATE OR REPLACE FUNCTION pos.platform_provision_merchant(
    p_code text, p_name text, p_business_type text, p_plan text,
    p_outlet_code text, p_outlet_name text, p_owner_name text, p_owner_email text,
    p_auth_user_id uuid, p_timezone text DEFAULT 'Asia/Jakarta')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid; v_outlet uuid; v_wh uuid; v_emp uuid; v_user uuid; v_actor uuid;
    v_code text := upper(btrim(coalesce(p_code, '')));
    v_username text;
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    v_actor := pos.current_app_user_id();
    IF v_code !~ '^[A-Z0-9_-]{2,24}$' OR v_code = 'PLATFORM' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kode merchant 2-24 karakter A-Z, 0-9, - atau _' USING ERRCODE = 'P0001';
    END IF;
    IF coalesce(btrim(p_name), '') = '' OR coalesce(btrim(p_outlet_name), '') = '' OR coalesce(btrim(p_owner_name), '') = '' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nama merchant, outlet, dan pemilik wajib diisi' USING ERRCODE = 'P0001';
    END IF;
    IF p_business_type NOT IN ('FNB', 'RETAIL', 'SERVICE', 'GENERAL') THEN
        RAISE EXCEPTION 'CATALOG_INVALID: jenis usaha tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pos.plans WHERE code = p_plan AND active) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: paket tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    IF p_outlet_code !~ '^[A-Z0-9_-]{2,32}$' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kode outlet 2-32 karakter A-Z, 0-9, - atau _' USING ERRCODE = 'P0001';
    END IF;
    v_username := lower(v_code) || '.owner';
    IF v_username !~ '^[a-z0-9._-]{3,64}$' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: kode merchant tidak valid untuk username' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO pos.organizations (code, name, timezone, business_type)
    VALUES (v_code, btrim(p_name), coalesce(p_timezone, 'Asia/Jakarta'), p_business_type)
    RETURNING id INTO v_org;

    INSERT INTO pos.organization_subscriptions (organization_id, plan_code, status, trial_ends_at)
    VALUES (v_org, p_plan, CASE WHEN p_plan = 'TRIAL' THEN 'TRIAL' ELSE 'ACTIVE' END,
            CASE WHEN p_plan = 'TRIAL' THEN now() + interval '14 days' END);

    INSERT INTO pos.outlets (organization_id, code, name) VALUES (v_org, upper(btrim(p_outlet_code)), btrim(p_outlet_name))
    RETURNING id INTO v_outlet;
    INSERT INTO pos.warehouses (organization_id, outlet_id, code, name)
    VALUES (v_org, v_outlet, 'WH-' || upper(btrim(p_outlet_code)), 'Gudang ' || btrim(p_outlet_name))
    RETURNING id INTO v_wh;
    UPDATE pos.outlets SET default_warehouse_id = v_wh WHERE id = v_outlet;

    INSERT INTO pos.terminals (outlet_id, code, name) VALUES (v_outlet, v_code || '-K1', 'Kasir 1');

    INSERT INTO pos.employees (organization_id, employee_code, full_name, email, position, home_outlet_id)
    VALUES (v_org, 'OWNER', btrim(p_owner_name), lower(btrim(p_owner_email)), 'Pemilik', v_outlet)
    RETURNING id INTO v_emp;
    INSERT INTO pos.users (auth_user_id, organization_id, employee_id, username, email, display_name, created_by)
    VALUES (p_auth_user_id, v_org, v_emp, v_username, lower(btrim(p_owner_email)), btrim(p_owner_name), v_actor)
    RETURNING id INTO v_user;
    INSERT INTO pos.user_roles (user_id, role_id, outlet_id, granted_by)
    SELECT v_user, r.id, NULL, v_actor FROM pos.roles r WHERE r.code IN ('OWNER', 'ADMIN', 'STORE_MANAGER');

    -- data awal: pajak & profil struk
    INSERT INTO pos.tax_rates (organization_id, code, name, rate, active, source) VALUES
        (v_org, 'PPN11', 'PPN 11%', 11, true, 'LOCAL'),
        (v_org, 'PB1', 'PB1 10%', 10, p_business_type = 'FNB', 'LOCAL');
    INSERT INTO pos.receipt_profiles (organization_id, outlet_id, business_name, footer_text)
    VALUES (v_org, NULL, btrim(p_name), 'Terima kasih atas kunjungan Anda');

    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (v_org, v_actor, 'MERCHANT_PROVISIONED', 'ORGANIZATION', v_org::text,
            jsonb_build_object('code', v_code, 'plan', p_plan, 'businessType', p_business_type, 'owner', v_username));
    RETURN v_org;
END
$$;

CREATE OR REPLACE FUNCTION pos.platform_set_plan(p_org uuid, p_plan text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    IF NOT EXISTS (SELECT 1 FROM pos.plans WHERE code = p_plan AND active) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: paket tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.organization_subscriptions (organization_id, plan_code, status, trial_ends_at)
    VALUES (p_org, p_plan, CASE WHEN p_plan = 'TRIAL' THEN 'TRIAL' ELSE 'ACTIVE' END, NULL)
    ON CONFLICT (organization_id) DO UPDATE
        SET plan_code = EXCLUDED.plan_code, status = EXCLUDED.status, trial_ends_at = NULL, updated_at = now();
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (p_org, pos.current_app_user_id(), 'MERCHANT_PLAN_CHANGED', 'ORGANIZATION', p_org::text,
            jsonb_build_object('plan', p_plan));
END
$$;

-- Nonaktifkan = tutup akses seluruh merchant (current_app_user_id() mensyaratkan org aktif).
CREATE OR REPLACE FUNCTION pos.platform_set_active(p_org uuid, p_active boolean, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    IF NOT EXISTS (SELECT 1 FROM pos.organizations WHERE id = p_org AND code <> 'PLATFORM') THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: merchant' USING ERRCODE = 'P0001';
    END IF;
    UPDATE pos.organizations SET active = p_active WHERE id = p_org;
    UPDATE pos.organization_subscriptions SET status = CASE WHEN p_active THEN 'ACTIVE' ELSE 'SUSPENDED' END,
        updated_at = now() WHERE organization_id = p_org;
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, reason)
    VALUES (p_org, pos.current_app_user_id(),
            CASE WHEN p_active THEN 'MERCHANT_REACTIVATED' ELSE 'MERCHANT_SUSPENDED' END,
            'ORGANIZATION', p_org::text, p_reason);
END
$$;

DO $$
DECLARE f text;
BEGIN
    FOREACH f IN ARRAY ARRAY['platform_plans()', 'platform_list_merchants()', 'platform_merchant_users(uuid)',
        'platform_provision_merchant(text,text,text,text,text,text,text,text,uuid,text)',
        'platform_set_plan(uuid,text)', 'platform_set_active(uuid,boolean,text)']
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION pos.%s FROM PUBLIC', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION pos.%s TO pos_app_user', f);
    END LOOP;
END
$$;

-- ---------------------------------------------------------------- menu konsol platform
INSERT INTO pos.menu_items (code, label, route_name, required_any, sort_order)
VALUES ('platform', 'Merchant', 'platform', ARRAY['platform.manage'], 1);
INSERT INTO pos.menu_defaults (menu_code, role_code, enabled)
SELECT 'platform', r.code, r.code = 'PLATFORM_ADMIN' FROM pos.roles r;
INSERT INTO pos.menu_defaults (menu_code, role_code, enabled)
SELECT m.code, 'PLATFORM_ADMIN', false FROM pos.menu_items m WHERE m.code <> 'platform';

-- Menu "Merchant" milik operator platform: tidak muncul di pengaturan menu merchant.
CREATE OR REPLACE FUNCTION pos.menu_matrix()
RETURNS TABLE (menu_code text, label text, role_code text, enabled boolean, default_enabled boolean, sort_order integer)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF NOT pos.has_permission('menu.configure', NULL) THEN
        RAISE EXCEPTION 'USER_NOT_AUTHORIZED: menu.configure required' USING ERRCODE = 'P0001';
    END IF;
    RETURN QUERY
    SELECT m.code, m.label, r.code,
           coalesce(s.enabled, d.enabled, false), coalesce(d.enabled, false), m.sort_order
    FROM pos.menu_items m
    CROSS JOIN pos.roles r
    LEFT JOIN pos.menu_defaults d ON d.menu_code = m.code AND d.role_code = r.code
    LEFT JOIN pos.menu_settings s ON s.organization_id = pos.current_org_id()
                                 AND s.menu_code = m.code AND s.role_code = r.code
    WHERE r.code = ANY (pos.configurable_menu_roles()) AND m.code <> 'platform'
    ORDER BY m.sort_order, r.rank DESC;
END
$$;
