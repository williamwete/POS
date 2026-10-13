-- V027: clock in dapat dinonaktifkan per merchant.
-- Bila 'attendance_required' = false, membuka kasir otomatis membuat kehadiran (device 'AUTO') dan
-- menutup kasir otomatis menutup kehadiran itu. Semua aturan lain (sesi kasir, penjualan, pembayaran)
-- tetap sama karena tetap ada kehadiran WORKING.
INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('attendance_required', 'BOOLEAN', 'true', 'Karyawan wajib clock in sebelum membuka kasir', 'ORGANIZATION')
ON CONFLICT (key) DO NOTHING;

-- Owner perlu mengelola pengaturan merchant sendiri.
INSERT INTO pos.role_permissions (role_id, permission_code)
SELECT r.id, 'configuration.manage' FROM pos.roles r WHERE r.code = 'OWNER'
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION pos.attendance_required(p_outlet uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
    SELECT coalesce((pos.get_setting('attendance_required', p_outlet) #>> '{}')::boolean, true)
$$;
GRANT EXECUTE ON FUNCTION pos.attendance_required(uuid) TO pos_app_user;

-- Kehadiran otomatis saat membuka kasir (hanya bila merchant tidak mewajibkan clock in).
CREATE OR REPLACE FUNCTION pos.auto_clock_in(p_outlet uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_emp uuid := pos.current_employee_id();
    v_id uuid;
BEGIN
    PERFORM pos.require_perm('cashier.open', p_outlet);
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_REQUIRED: akun belum terhubung ke karyawan' USING ERRCODE = 'P0001';
    END IF;
    IF pos.attendance_required(p_outlet) THEN
        RAISE EXCEPTION 'ATTENDANCE_REQUIRED: clock in terlebih dahulu' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pos.outlets o WHERE o.id = p_outlet AND o.organization_id = pos.current_org_id()) THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: outlet' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by, device_id)
    VALUES (pos.current_org_id(), v_emp, p_outlet, pos.current_app_user_id(), 'AUTO')
    RETURNING id INTO v_id;
    RETURN v_id;
END
$$;
REVOKE ALL ON FUNCTION pos.auto_clock_in(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.auto_clock_in(uuid) TO pos_app_user;

-- Menutup kehadiran otomatis milik karyawan setelah kasirnya ditutup (oleh dirinya atau supervisor).
-- Hanya menyentuh kehadiran 'AUTO' di organisasi pemanggil; trigger tetap menolak bila kasir masih terbuka.
CREATE OR REPLACE FUNCTION pos.auto_clock_out(p_employee uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF pos.current_org_id() IS NULL THEN
        RAISE EXCEPTION 'USER_NOT_AUTHORIZED: login required' USING ERRCODE = 'P0001';
    END IF;
    UPDATE pos.attendance SET status = 'COMPLETED', clock_out = now(), clock_out_by = pos.current_app_user_id()
    WHERE employee_id = p_employee AND organization_id = pos.current_org_id()
      AND status = 'WORKING' AND device_id = 'AUTO'
      AND NOT EXISTS (SELECT 1 FROM pos.cashier_sessions c WHERE c.employee_id = p_employee AND c.status IN ('OPEN', 'ON_BREAK', 'CLOSING'));
END
$$;
REVOKE ALL ON FUNCTION pos.auto_clock_out(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.auto_clock_out(uuid) TO pos_app_user;

CREATE OR REPLACE FUNCTION pos.set_attendance_required(p_required boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
BEGIN
    PERFORM pos.require_perm('configuration.manage', NULL);
    IF p_required IS NULL THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nilai wajib diisi' USING ERRCODE = 'P0001';
    END IF;
    UPDATE pos.settings SET value = to_jsonb(p_required)
     WHERE organization_id = v_org AND outlet_id IS NULL AND key = 'attendance_required';
    IF NOT FOUND THEN
        INSERT INTO pos.settings (organization_id, outlet_id, key, value)
        VALUES (v_org, NULL, 'attendance_required', to_jsonb(p_required));
    END IF;
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (v_org, pos.current_app_user_id(), 'SETTING_CHANGED', 'SETTING', 'attendance_required',
            jsonb_build_object('value', p_required));
END
$$;
REVOKE ALL ON FUNCTION pos.set_attendance_required(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.set_attendance_required(boolean) TO pos_app_user;

-- Menu Pengaturan
INSERT INTO pos.menu_items (code, label, route_name, required_any, sort_order) VALUES
    ('settings', 'Pengaturan', 'settings', ARRAY['configuration.manage'], 120);
INSERT INTO pos.menu_defaults (menu_code, role_code, enabled)
SELECT 'settings', r.code, r.code IN ('OWNER', 'ADMIN', 'SUPER_ADMIN') FROM pos.roles r;
