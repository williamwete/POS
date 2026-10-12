-- V019: role Owner, menu aktif/nonaktif per role (dengan default), PIN karyawan, foto clock in/out
--
-- Prinsip:
--  * Menu hanyalah lapisan TAMPILAN. Hak akses sebenarnya tetap permission + RLS: menu yang
--    diaktifkan tidak memberi akses API yang tidak dimiliki role-nya (my_menus mensyaratkan keduanya).
--  * Default menu per role ada di menu_defaults (data referensi). Owner/Admin hanya menyimpan
--    PENYIMPANGAN dari default di menu_settings; menghapus penyimpangan = kembali ke default.
--  * PIN disimpan sebagai hash bcrypt di tabel yang tidak punya policy untuk pos_app_user;
--    hash tidak pernah keluar dari database. Percobaan salah dicatat lewat konteks sistem
--    (transaksi terpisah) agar tidak ikut di-rollback.
--  * Foto clock in/out disimpan di database (JPEG kecil), hanya terbaca lewat fungsi yang memeriksa izin.

-- ---------------------------------------------------------------- izin baru
INSERT INTO pos.permissions (code, module, description) VALUES
    ('menu.configure',        'configuration', 'Aktif/nonaktifkan menu per role'),
    ('employee.reset_pin',    'employee',      'Atur / reset PIN karyawan'),
    ('attendance.view_photo', 'attendance',    'Lihat foto verifikasi clock in/out'),
    ('product.manage',        'catalog',       'Kelola produk (daftar produk, harga, stok awal)'),
    ('category.manage',       'catalog',       'Kelola kategori produk'),
    ('discount.manage',       'catalog',       'Kelola daftar diskon'),
    ('receipt.manage',        'configuration', 'Kelola tampilan struk');

-- ---------------------------------------------------------------- role OWNER (rank 75: di atas Store Manager, di bawah Admin)
INSERT INTO pos.roles (code, name, description, is_system, rank) VALUES
    ('OWNER', 'Owner', 'Pemilik: melihat seluruh operasional & laporan, mengatur diskon/struk/kategori/menu', true, 75);

INSERT INTO pos.role_permissions (role_id, permission_code)
SELECT r.id, p.code
FROM pos.roles r
JOIN pos.permissions p ON (
    (r.code = 'SUPER_ADMIN' AND p.code IN ('menu.configure', 'employee.reset_pin', 'attendance.view_photo',
        'product.manage', 'category.manage', 'discount.manage', 'receipt.manage'))
 OR (r.code = 'OWNER' AND p.code IN (
        -- melihat & mengawasi (tanpa melakukan transaksi)
        'attendance.view', 'attendance.view_photo', 'cashier.view', 'sale.view', 'stock.view', 'report.view',
        'employee.view', 'employee.manage', 'employee.reset_pin', 'user.view', 'audit.view', 'sync.view',
        -- persetujuan tingkat atas
        'sale.refund', 'sale.void', 'cash.approve_difference', 'payment.approve',
        -- pengaturan toko
        'menu.configure', 'product.manage', 'category.manage', 'discount.manage', 'receipt.manage'))
 OR (r.code = 'ADMIN' AND p.code IN (
        'menu.configure', 'employee.reset_pin', 'attendance.view_photo',
        'product.manage', 'category.manage', 'discount.manage', 'receipt.manage'))
 OR (r.code IN ('SUPERVISOR', 'STORE_MANAGER') AND p.code IN (
        'employee.reset_pin', 'attendance.view_photo', 'discount.manage'))
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------- setting verifikasi kehadiran
INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('attendance_verification_required', 'BOOLEAN', 'true',
     'Clock in/out wajib foto + PIN agar terbukti kasir yang menjaga adalah orangnya', 'OUTLET');

-- ---------------------------------------------------------------- katalog menu
CREATE TABLE pos.menu_items (
    code                 text PRIMARY KEY,
    label                text    NOT NULL,
    route_name           text    NOT NULL,
    -- salah satu cukup (mis. history: sale.view ATAU sale.create)
    required_any         text[]  NOT NULL,
    sort_order           integer NOT NULL
);

INSERT INTO pos.menu_items (code, label, route_name, required_any, sort_order) VALUES
    ('pos',               'Menu',                  'pos',               ARRAY['sale.create'],          10),
    ('clock',             'Clock in/Clock out',    'my-attendance',     ARRAY['attendance.clock_in'],  20),
    ('beginning-cash',    'Beginning cash balance','cashier-open',      ARRAY['cashier.open'],         30),
    ('product-list',      'Product List',          'product-list',      ARRAY['stock.view'],           40),
    ('history',           'History',               'history',           ARRAY['sale.view', 'sale.create'], 50),
    ('manage-categories', 'Manage Categories',     'manage-categories', ARRAY['category.manage'],      60),
    ('manage-discount',   'Manage Discount',       'manage-discount',   ARRAY['discount.manage'],      70),
    ('manage-cashier',    'Manage Cashier',        'manage-cashier',    ARRAY['employee.view', 'employee.manage'], 80),
    ('manage-receipt',    'Manage Receipt',        'manage-receipt',    ARRAY['receipt.manage'],       90),
    ('closing',           'Closing',               'cashier-close',     ARRAY['cashier.view', 'cashier.close'], 100),
    ('dashboard',         'Dashboard',             'home',              ARRAY['report.view'],          5);

-- Default per role. Role di luar empat peran utama (SUPER_ADMIN, STORE_MANAGER, AUDITOR, STOCK_OPERATOR)
-- mengikuti padanannya agar akun lama tetap berfungsi.
CREATE TABLE pos.menu_defaults (
    menu_code  text    NOT NULL REFERENCES pos.menu_items (code),
    role_code  text    NOT NULL,
    enabled    boolean NOT NULL,
    PRIMARY KEY (menu_code, role_code)
);

INSERT INTO pos.menu_defaults (menu_code, role_code, enabled)
SELECT m.code, r.code,
    CASE r.code
        WHEN 'SUPER_ADMIN' THEN true
        WHEN 'CASHIER' THEN m.code IN ('pos', 'clock', 'beginning-cash', 'product-list', 'history', 'closing')
        WHEN 'SUPERVISOR' THEN m.code IN ('pos', 'clock', 'beginning-cash', 'product-list', 'history',
            'manage-discount', 'manage-cashier', 'closing', 'dashboard')
        WHEN 'STORE_MANAGER' THEN m.code IN ('pos', 'clock', 'beginning-cash', 'product-list', 'history',
            'manage-discount', 'manage-cashier', 'closing', 'dashboard')
        WHEN 'OWNER' THEN m.code IN ('product-list', 'history', 'manage-categories', 'manage-discount',
            'manage-cashier', 'manage-receipt', 'closing', 'dashboard')
        WHEN 'ADMIN' THEN m.code IN ('product-list', 'manage-categories', 'manage-discount', 'manage-cashier',
            'manage-receipt', 'dashboard')
        WHEN 'AUDITOR' THEN m.code IN ('history', 'closing', 'dashboard')
        WHEN 'STOCK_OPERATOR' THEN m.code IN ('clock', 'product-list')
    END
FROM pos.menu_items m CROSS JOIN pos.roles r;

CREATE TABLE pos.menu_settings (
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    menu_code        text        NOT NULL REFERENCES pos.menu_items (code),
    role_code        text        NOT NULL REFERENCES pos.roles (code),
    enabled          boolean     NOT NULL,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    PRIMARY KEY (organization_id, menu_code, role_code)
);

ALTER TABLE pos.menu_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.menu_defaults ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.menu_settings ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON pos.menu_items, pos.menu_defaults, pos.menu_settings TO pos_app_user, pos_system;
CREATE POLICY menu_items_read    ON pos.menu_items    FOR SELECT TO pos_app_user, pos_system USING (true);
CREATE POLICY menu_defaults_read ON pos.menu_defaults FOR SELECT TO pos_app_user, pos_system USING (true);
CREATE POLICY menu_settings_read ON pos.menu_settings FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id());
CREATE POLICY menu_settings_system ON pos.menu_settings TO pos_system USING (true) WITH CHECK (true);

-- Empat peran yang boleh diatur dari UI.
CREATE OR REPLACE FUNCTION pos.configurable_menu_roles()
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT ARRAY['ADMIN', 'OWNER', 'SUPERVISOR', 'CASHIER'] $$;

-- Menu untuk user saat ini di outlet tertentu: diizinkan bila ada SATU role-nya yang menyalakan menu
-- DAN user memiliki permission yang dibutuhkan menu itu.
CREATE OR REPLACE FUNCTION pos.my_menus(p_outlet_id uuid DEFAULT NULL)
RETURNS TABLE (code text, label text, route_name text, sort_order integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    WITH my_roles AS (
        SELECT DISTINCT r.code
        FROM pos.user_roles ur
        JOIN pos.roles r ON r.id = ur.role_id
        WHERE ur.user_id = pos.current_app_user_id()
          AND (ur.outlet_id IS NULL
               OR (p_outlet_id IS NOT NULL AND ur.outlet_id = p_outlet_id AND pos.can_access_outlet(p_outlet_id)))
    ), perms AS (
        SELECT * FROM pos.effective_permissions(p_outlet_id) AS permission_code
    )
    SELECT m.code, m.label, m.route_name, m.sort_order
    FROM pos.menu_items m
    WHERE m.required_any && ARRAY(SELECT permission_code FROM perms)
      AND EXISTS (
        SELECT 1
        FROM my_roles mr
        LEFT JOIN pos.menu_defaults d ON d.menu_code = m.code AND d.role_code = mr.code
        LEFT JOIN pos.menu_settings s ON s.organization_id = pos.current_org_id()
                                     AND s.menu_code = m.code AND s.role_code = mr.code
        WHERE coalesce(s.enabled, d.enabled, false)
      )
    ORDER BY m.sort_order
$$;

-- Matriks untuk layar pengaturan (Owner/Admin).
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
    WHERE r.code = ANY (pos.configurable_menu_roles())
    ORDER BY m.sort_order, r.rank DESC;
END
$$;

-- p_enabled NULL = kembali ke default.
CREATE OR REPLACE FUNCTION pos.set_menu_enabled(p_menu text, p_role text, p_enabled boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_default boolean;
BEGIN
    IF NOT pos.has_permission('menu.configure', NULL) THEN
        RAISE EXCEPTION 'USER_NOT_AUTHORIZED: menu.configure required' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (p_role = ANY (pos.configurable_menu_roles())) THEN
        RAISE EXCEPTION 'MENU_ROLE_NOT_CONFIGURABLE: role % cannot be configured here', p_role USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pos.menu_items WHERE code = p_menu) THEN
        RAISE EXCEPTION 'MENU_NOT_FOUND: %', p_menu USING ERRCODE = 'P0001';
    END IF;
    -- anti-eskalasi: tidak boleh mengatur role dengan rank lebih tinggi dari rank sendiri
    IF (SELECT rank FROM pos.roles WHERE code = p_role) > pos.current_max_rank() THEN
        RAISE EXCEPTION 'USER_NOT_AUTHORIZED: cannot configure a higher role' USING ERRCODE = 'P0001';
    END IF;

    SELECT enabled INTO v_default FROM pos.menu_defaults WHERE menu_code = p_menu AND role_code = p_role;
    IF p_enabled IS NULL OR p_enabled IS NOT DISTINCT FROM v_default THEN
        DELETE FROM pos.menu_settings WHERE organization_id = v_org AND menu_code = p_menu AND role_code = p_role;
    ELSE
        INSERT INTO pos.menu_settings (organization_id, menu_code, role_code, enabled, updated_by)
        VALUES (v_org, p_menu, p_role, p_enabled, pos.current_app_user_id())
        ON CONFLICT (organization_id, menu_code, role_code)
        DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now(), updated_by = EXCLUDED.updated_by;
    END IF;
END
$$;

-- ---------------------------------------------------------------- PIN karyawan
CREATE TABLE pos.employee_pins (
    employee_id      uuid PRIMARY KEY,
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    pin_hash         text        NOT NULL,
    failed_attempts  integer     NOT NULL DEFAULT 0,
    locked_until     timestamptz,
    set_at           timestamptz NOT NULL DEFAULT now(),
    set_by           uuid,
    CONSTRAINT employee_pins_emp_fk FOREIGN KEY (employee_id, organization_id)
        REFERENCES pos.employees (id, organization_id)
);
-- RLS aktif TANPA policy untuk pos_app_user: hanya fungsi SECURITY DEFINER di bawah yang menyentuhnya.
ALTER TABLE pos.employee_pins ENABLE ROW LEVEL SECURITY;
CREATE POLICY employee_pins_system ON pos.employee_pins TO pos_system USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE ON pos.employee_pins TO pos_system;

CREATE OR REPLACE FUNCTION pos.set_employee_pin(p_employee uuid, p_pin text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos, public
AS $$
DECLARE
    v_emp pos.employees%ROWTYPE;
BEGIN
    IF p_pin IS NULL OR p_pin !~ '^[0-9]{6}$' THEN
        RAISE EXCEPTION 'PIN_FORMAT_INVALID: PIN harus 6 digit angka' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_emp FROM pos.employees WHERE id = p_employee AND organization_id = pos.current_org_id();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT pos.has_permission('employee.reset_pin', v_emp.home_outlet_id) THEN
        RAISE EXCEPTION 'USER_NOT_AUTHORIZED: employee.reset_pin required' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.employee_pins (employee_id, organization_id, pin_hash, set_by)
    VALUES (p_employee, v_emp.organization_id, crypt(p_pin, gen_salt('bf', 10)), pos.current_app_user_id())
    ON CONFLICT (employee_id) DO UPDATE
        SET pin_hash = EXCLUDED.pin_hash, failed_attempts = 0, locked_until = NULL,
            set_at = now(), set_by = EXCLUDED.set_by;
END
$$;

CREATE OR REPLACE FUNCTION pos.employee_has_pin(p_employee uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT EXISTS (SELECT 1 FROM pos.employee_pins WHERE employee_id = p_employee
                   AND organization_id = pos.current_org_id())
$$;

-- Verifikasi PIN. Hanya konteks sistem (transaksi terpisah) agar hitungan gagal tidak ikut rollback.
-- Mengembalikan 'OK' | 'NOT_SET' | 'INVALID:<sisa>' | 'LOCKED'.
CREATE OR REPLACE FUNCTION pos.verify_employee_pin(p_employee uuid, p_pin text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos, public
AS $$
DECLARE
    v pos.employee_pins%ROWTYPE;
    c_max constant integer := 5;
BEGIN
    SELECT * INTO v FROM pos.employee_pins WHERE employee_id = p_employee FOR UPDATE;
    IF NOT FOUND THEN
        RETURN 'NOT_SET';
    END IF;
    IF v.locked_until IS NOT NULL AND v.locked_until > now() THEN
        RETURN 'LOCKED';
    END IF;
    IF p_pin IS NOT NULL AND v.pin_hash = crypt(p_pin, v.pin_hash) THEN
        UPDATE pos.employee_pins SET failed_attempts = 0, locked_until = NULL WHERE employee_id = p_employee;
        RETURN 'OK';
    END IF;
    UPDATE pos.employee_pins
       SET failed_attempts = CASE WHEN failed_attempts + 1 >= c_max THEN 0 ELSE failed_attempts + 1 END,
           locked_until = CASE WHEN failed_attempts + 1 >= c_max THEN now() + interval '5 minutes' ELSE NULL END
     WHERE employee_id = p_employee;
    IF v.failed_attempts + 1 >= c_max THEN
        RETURN 'LOCKED';
    END IF;
    RETURN 'INVALID:' || (c_max - v.failed_attempts - 1);
END
$$;
REVOKE ALL ON FUNCTION pos.verify_employee_pin(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.verify_employee_pin(uuid, text) TO pos_system;

-- ---------------------------------------------------------------- foto clock in/out
CREATE TABLE pos.attendance_photos (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    attendance_id    uuid        NOT NULL REFERENCES pos.attendance (id),
    kind             text        NOT NULL,
    content_type     text        NOT NULL,
    image            bytea       NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT attendance_photos_kind_ck CHECK (kind IN ('CLOCK_IN', 'CLOCK_OUT')),
    CONSTRAINT attendance_photos_type_ck CHECK (content_type IN ('image/jpeg', 'image/png', 'image/webp')),
    CONSTRAINT attendance_photos_size_ck CHECK (octet_length(image) BETWEEN 1 AND 500000),
    CONSTRAINT attendance_photos_uk UNIQUE (attendance_id, kind)
);
ALTER TABLE pos.attendance_photos ENABLE ROW LEVEL SECURITY;
CREATE POLICY attendance_photos_system ON pos.attendance_photos TO pos_system USING (true) WITH CHECK (true);
GRANT SELECT, INSERT ON pos.attendance_photos TO pos_system;
CREATE TRIGGER attendance_photos_append_only BEFORE UPDATE OR DELETE ON pos.attendance_photos
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

CREATE OR REPLACE FUNCTION pos.attach_attendance_photo(p_attendance uuid, p_kind text, p_type text, p_image bytea)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_att pos.attendance%ROWTYPE;
    v_id uuid;
BEGIN
    SELECT * INTO v_att FROM pos.attendance
     WHERE id = p_attendance AND employee_id = pos.current_employee_id();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.attendance_photos (organization_id, attendance_id, kind, content_type, image)
    VALUES (v_att.organization_id, p_attendance, p_kind, p_type, p_image)
    RETURNING id INTO v_id;
    RETURN v_id;
END
$$;

-- Foto boleh dilihat pemiliknya sendiri atau role dengan attendance.view_photo di outlet tersebut.
CREATE OR REPLACE FUNCTION pos.get_attendance_photo(p_attendance uuid, p_kind text)
RETURNS TABLE (content_type text, image bytea)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT ph.content_type, ph.image
    FROM pos.attendance_photos ph
    JOIN pos.attendance a ON a.id = ph.attendance_id
    WHERE ph.attendance_id = p_attendance AND ph.kind = p_kind
      AND ph.organization_id = pos.current_org_id()
      AND (a.employee_id = pos.current_employee_id() OR pos.has_permission('attendance.view_photo', a.outlet_id))
$$;

CREATE OR REPLACE FUNCTION pos.attendance_has_photo(p_attendance uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pos
AS $$
    SELECT EXISTS (
        SELECT 1 FROM pos.attendance_photos ph JOIN pos.attendance a ON a.id = ph.attendance_id
        WHERE ph.attendance_id = p_attendance AND ph.organization_id = pos.current_org_id()
          AND (a.employee_id = pos.current_employee_id() OR pos.has_permission('attendance.view_photo', a.outlet_id)))
$$;

GRANT EXECUTE ON FUNCTION
    pos.configurable_menu_roles(), pos.my_menus(uuid), pos.menu_matrix(), pos.set_menu_enabled(text, text, boolean),
    pos.set_employee_pin(uuid, text), pos.employee_has_pin(uuid),
    pos.attach_attendance_photo(uuid, text, text, bytea), pos.get_attendance_photo(uuid, text),
    pos.attendance_has_photo(uuid)
TO pos_app_user, pos_system;
