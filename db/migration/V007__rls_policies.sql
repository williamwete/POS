-- V007: table privileges & Row Level Security
--
-- pos_app_user : semua akses dibatasi policy di bawah.
-- pos_system   : akses penuh lewat policy USING(true), tetapi tetap tunduk pada
--                trigger append-only / no-delete.

-- ---------------------------------------------------------------- privileges
GRANT SELECT, UPDATE         ON pos.organizations     TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.outlets           TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.warehouses        TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.devices           TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.terminals         TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.employees         TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.users             TO pos_app_user;
GRANT SELECT                 ON pos.permissions       TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.roles             TO pos_app_user;
GRANT SELECT, INSERT, DELETE ON pos.role_permissions  TO pos_app_user;
GRANT SELECT, INSERT, DELETE ON pos.user_roles        TO pos_app_user;
GRANT SELECT, INSERT, DELETE ON pos.user_outlets      TO pos_app_user;
GRANT SELECT, INSERT         ON pos.audit_logs        TO pos_app_user;
GRANT SELECT, INSERT, UPDATE ON pos.idempotency_keys  TO pos_app_user;
GRANT SELECT                 ON pos.setting_definitions TO pos_app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON pos.settings  TO pos_app_user;

GRANT SELECT, INSERT, UPDATE ON
    pos.organizations, pos.outlets, pos.warehouses, pos.devices, pos.terminals,
    pos.employees, pos.users, pos.roles, pos.permissions, pos.setting_definitions
TO pos_system;
GRANT SELECT, INSERT, DELETE ON pos.role_permissions, pos.user_roles, pos.user_outlets TO pos_system;
GRANT SELECT, INSERT         ON pos.audit_logs TO pos_system;
GRANT SELECT, INSERT, UPDATE, DELETE ON pos.idempotency_keys, pos.settings TO pos_system;

-- ---------------------------------------------------------------- enable RLS
ALTER TABLE pos.organizations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.outlets             ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.warehouses          ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.devices             ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.terminals           ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.employees           ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.permissions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.roles               ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.role_permissions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.user_roles          ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.user_outlets        ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.audit_logs          ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.idempotency_keys    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.setting_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.settings            ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------- pos_system
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'organizations', 'outlets', 'warehouses', 'devices', 'terminals', 'employees',
        'users', 'permissions', 'roles', 'role_permissions', 'user_roles', 'user_outlets',
        'audit_logs', 'idempotency_keys', 'setting_definitions', 'settings'
    ] LOOP
        EXECUTE format(
            'CREATE POLICY %I ON pos.%I TO pos_system USING (true) WITH CHECK (true)',
            t || '_system_all', t);
    END LOOP;
END
$$;

-- ---------------------------------------------------------------- organizations
CREATE POLICY organizations_select ON pos.organizations FOR SELECT TO pos_app_user
    USING (id = pos.current_org_id());

CREATE POLICY organizations_update ON pos.organizations FOR UPDATE TO pos_app_user
    USING (id = pos.current_org_id() AND pos.has_permission('configuration.manage', NULL))
    WITH CHECK (id = pos.current_org_id());

-- ---------------------------------------------------------------- outlets
CREATE POLICY outlets_select ON pos.outlets FOR SELECT TO pos_app_user
    USING (pos.can_access_outlet(id));

CREATE POLICY outlets_insert ON pos.outlets FOR INSERT TO pos_app_user
    WITH CHECK (organization_id = pos.current_org_id()
                AND pos.has_permission('outlet.manage', NULL));

CREATE POLICY outlets_update ON pos.outlets FOR UPDATE TO pos_app_user
    USING (pos.can_access_outlet(id) AND pos.has_permission('outlet.manage', NULL))
    WITH CHECK (organization_id = pos.current_org_id());

-- ---------------------------------------------------------------- warehouses
CREATE POLICY warehouses_select ON pos.warehouses FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (outlet_id IS NULL OR pos.can_access_outlet(outlet_id)));

CREATE POLICY warehouses_insert ON pos.warehouses FOR INSERT TO pos_app_user
    WITH CHECK (organization_id = pos.current_org_id()
                AND pos.has_permission('outlet.manage', NULL));

CREATE POLICY warehouses_update ON pos.warehouses FOR UPDATE TO pos_app_user
    USING (organization_id = pos.current_org_id() AND pos.has_permission('outlet.manage', NULL))
    WITH CHECK (organization_id = pos.current_org_id());

-- ---------------------------------------------------------------- devices / terminals
CREATE POLICY devices_select ON pos.devices FOR SELECT TO pos_app_user
    USING (pos.can_access_outlet(outlet_id));

CREATE POLICY devices_insert ON pos.devices FOR INSERT TO pos_app_user
    WITH CHECK (pos.has_permission('terminal.manage', outlet_id));

CREATE POLICY devices_update ON pos.devices FOR UPDATE TO pos_app_user
    USING (pos.has_permission('terminal.manage', outlet_id))
    WITH CHECK (pos.has_permission('terminal.manage', outlet_id));

CREATE POLICY terminals_select ON pos.terminals FOR SELECT TO pos_app_user
    USING (pos.can_access_outlet(outlet_id));

CREATE POLICY terminals_insert ON pos.terminals FOR INSERT TO pos_app_user
    WITH CHECK (pos.has_permission('terminal.manage', outlet_id));

CREATE POLICY terminals_update ON pos.terminals FOR UPDATE TO pos_app_user
    USING (pos.has_permission('terminal.manage', outlet_id))
    WITH CHECK (pos.has_permission('terminal.manage', outlet_id));

-- ---------------------------------------------------------------- employees
CREATE POLICY employees_select ON pos.employees FOR SELECT TO pos_app_user
    USING (
        organization_id = pos.current_org_id()
        AND (
            id = pos.current_employee_id()
            OR pos.has_permission('employee.view', home_outlet_id)
            OR pos.has_permission('employee.manage', home_outlet_id)
        )
    );

CREATE POLICY employees_insert ON pos.employees FOR INSERT TO pos_app_user
    WITH CHECK (organization_id = pos.current_org_id()
                AND pos.has_permission('employee.manage', home_outlet_id));

-- USING memeriksa outlet lama, WITH CHECK outlet baru: memindahkan karyawan
-- butuh hak di kedua outlet.
CREATE POLICY employees_update ON pos.employees FOR UPDATE TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND pos.has_permission('employee.manage', home_outlet_id))
    WITH CHECK (organization_id = pos.current_org_id()
                AND pos.has_permission('employee.manage', home_outlet_id));

-- ---------------------------------------------------------------- users
CREATE POLICY users_select ON pos.users FOR SELECT TO pos_app_user
    USING (pos.can_view_user(id));

CREATE POLICY users_insert ON pos.users FOR INSERT TO pos_app_user
    WITH CHECK (organization_id = pos.current_org_id()
                AND pos.has_permission('user.manage', NULL));

-- Mengubah user lain hanya jika semua role-nya berada di bawah rank pengelola,
-- dan tidak pernah baris diri sendiri (pos.can_manage_user).
CREATE POLICY users_update ON pos.users FOR UPDATE TO pos_app_user
    USING (pos.can_manage_user(id))
    WITH CHECK (organization_id = pos.current_org_id()
                AND id <> pos.current_app_user_id());

-- ---------------------------------------------------------------- catalog
CREATE POLICY permissions_select ON pos.permissions FOR SELECT TO pos_app_user
    USING (pos.current_app_user_id() IS NOT NULL);

CREATE POLICY setting_definitions_select ON pos.setting_definitions FOR SELECT TO pos_app_user
    USING (pos.current_app_user_id() IS NOT NULL);

CREATE POLICY roles_select ON pos.roles FOR SELECT TO pos_app_user
    USING (pos.current_app_user_id() IS NOT NULL);

-- Role baru/ubahan selalu di bawah rank pembuatnya.
CREATE POLICY roles_insert ON pos.roles FOR INSERT TO pos_app_user
    WITH CHECK (NOT is_system
                AND pos.has_permission('role.manage', NULL)
                AND rank < pos.current_max_rank());

CREATE POLICY roles_update ON pos.roles FOR UPDATE TO pos_app_user
    USING (pos.has_permission('role.manage', NULL) AND rank < pos.current_max_rank())
    WITH CHECK (pos.has_permission('role.manage', NULL) AND rank < pos.current_max_rank());

CREATE POLICY role_permissions_select ON pos.role_permissions FOR SELECT TO pos_app_user
    USING (pos.current_app_user_id() IS NOT NULL);

-- Hanya boleh menambahkan permission yang dipegang sendiri, ke role di bawah rank sendiri.
CREATE POLICY role_permissions_insert ON pos.role_permissions FOR INSERT TO pos_app_user
    WITH CHECK (
        pos.has_permission('role.manage', NULL)
        AND pos.has_permission(permission_code, NULL)
        AND pos.role_rank(role_id) < pos.current_max_rank()
    );

CREATE POLICY role_permissions_delete ON pos.role_permissions FOR DELETE TO pos_app_user
    USING (
        pos.has_permission('role.manage', NULL)
        AND pos.role_rank(role_id) < pos.current_max_rank()
    );

-- ---------------------------------------------------------------- user_roles / user_outlets
CREATE POLICY user_roles_select ON pos.user_roles FOR SELECT TO pos_app_user
    USING (pos.can_view_user(user_id));

CREATE POLICY user_roles_insert ON pos.user_roles FOR INSERT TO pos_app_user
    WITH CHECK (pos.can_manage_user(user_id) AND pos.can_grant_role(role_id, outlet_id));

CREATE POLICY user_roles_delete ON pos.user_roles FOR DELETE TO pos_app_user
    USING (pos.can_manage_user(user_id) AND pos.can_grant_role(role_id, outlet_id));

CREATE POLICY user_outlets_select ON pos.user_outlets FOR SELECT TO pos_app_user
    USING (pos.can_view_user(user_id));

CREATE POLICY user_outlets_insert ON pos.user_outlets FOR INSERT TO pos_app_user
    WITH CHECK (pos.can_manage_user(user_id) AND pos.can_access_outlet(outlet_id));

CREATE POLICY user_outlets_delete ON pos.user_outlets FOR DELETE TO pos_app_user
    USING (pos.can_manage_user(user_id));

-- ---------------------------------------------------------------- audit_logs
CREATE POLICY audit_logs_select ON pos.audit_logs FOR SELECT TO pos_app_user
    USING (
        organization_id = pos.current_org_id()
        AND (pos.has_permission('audit.view', NULL)
             OR (outlet_id IS NOT NULL AND pos.has_permission('audit.view', outlet_id)))
    );

-- Aktor tidak bisa dipalsukan: harus user yang sedang request.
CREATE POLICY audit_logs_insert ON pos.audit_logs FOR INSERT TO pos_app_user
    WITH CHECK (
        actor_type = 'USER'
        AND actor_user_id = pos.current_app_user_id()
        AND organization_id = pos.current_org_id()
        AND actor_employee_id IS NOT DISTINCT FROM pos.current_employee_id()
    );

-- ---------------------------------------------------------------- idempotency
CREATE POLICY idempotency_own ON pos.idempotency_keys FOR ALL TO pos_app_user
    USING (user_id = pos.current_app_user_id())
    WITH CHECK (user_id = pos.current_app_user_id());

-- ---------------------------------------------------------------- settings
CREATE POLICY settings_select ON pos.settings FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND (outlet_id IS NULL OR pos.can_access_outlet(outlet_id)));

CREATE POLICY settings_write ON pos.settings FOR ALL TO pos_app_user
    USING (organization_id = pos.current_org_id()
           AND pos.has_permission('configuration.manage', outlet_id))
    WITH CHECK (organization_id = pos.current_org_id()
                AND pos.has_permission('configuration.manage', outlet_id));
