-- SEED LOKAL (repeatable, idempotent). Tidak dijalankan di staging/production.
-- Isi: operator platform + dua merchant contoh (ALFAMART = makanan/minuman/snack, PERSITA = merchandise & fashion),
-- masing-masing punya owner dan kasir sendiri. Password semua akun: Demo#12345 (PIN karyawan: 123456).
GRANT pos_local_auth TO pos_api;
ALTER ROLE pos_api WITH LOGIN PASSWORD 'pos_api_local_only';

INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at)
VALUES ('00000000-0000-4000-8000-000000000609', 'platform@demo.local', crypt('Demo#12345', gen_salt('bf', 10)), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO pos.users (id, auth_user_id, organization_id, username, email, display_name)
SELECT '00000000-0000-4000-8000-000000000709', '00000000-0000-4000-8000-000000000609', o.id,
       'platform', 'platform@demo.local', 'Operator Platform'
FROM pos.organizations o WHERE o.code = 'PLATFORM'
ON CONFLICT (id) DO NOTHING;

INSERT INTO pos.user_roles (user_id, role_id)
SELECT '00000000-0000-4000-8000-000000000709', r.id FROM pos.roles r WHERE r.code = 'PLATFORM_ADMIN'
ON CONFLICT DO NOTHING;

DO $seed$
DECLARE
    t record;
    v_org uuid; v_outlet uuid; v_owner_auth uuid; v_cash_auth uuid; v_emp uuid; v_user uuid; v_prod uuid;
    p record;
    n integer := 0; i integer; sm integer; v_code text;
BEGIN
    FOR t IN SELECT * FROM (VALUES
        ('ALFAMART', 'Alfamart', 'RETAIL', 'ALF01', 'Alfamart Cabang Pusat', 'Budi Alfa', 'owner@alfamart.local', 'Sinta Kasir', 'kasir@alfamart.local'),
        ('PERSITA',  'Persita Store', 'FASHION', 'PRS01', 'Persita Store Pusat', 'Rudi Persita', 'owner@persita.local', 'Wulan Kasir', 'kasir@persita.local')
    ) AS x(code, name, biz, outlet_code, outlet_name, owner_name, owner_email, cash_name, cash_email)
    LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM pos.organizations WHERE code = t.code);

        INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at)
        VALUES (gen_random_uuid(), t.owner_email, crypt('Demo#12345', gen_salt('bf', 10)), now()) RETURNING id INTO v_owner_auth;
        INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at)
        VALUES (gen_random_uuid(), t.cash_email, crypt('Demo#12345', gen_salt('bf', 10)), now()) RETURNING id INTO v_cash_auth;

        -- Provisioning dijalankan sebagai operator platform
        PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000609', 'role', 'authenticated')::text, false);
        v_org := pos.platform_provision_merchant(t.code, t.name, t.biz, 'BUSINESS', t.outlet_code, t.outlet_name, t.owner_name, t.owner_email, v_owner_auth);
        PERFORM pos.platform_apply_preset(v_org);
        SELECT id INTO v_outlet FROM pos.outlets WHERE organization_id = v_org LIMIT 1;

        -- Kasir
        INSERT INTO pos.employees (organization_id, employee_code, full_name, position, home_outlet_id, email)
        VALUES (v_org, 'KSR01', t.cash_name, 'Kasir', v_outlet, t.cash_email) RETURNING id INTO v_emp;
        INSERT INTO pos.users (auth_user_id, organization_id, employee_id, username, email, display_name)
        VALUES (v_cash_auth, v_org, v_emp, lower(t.code) || '.kasir', t.cash_email, t.cash_name) RETURNING id INTO v_user;
        INSERT INTO pos.user_roles (user_id, role_id, outlet_id) SELECT v_user, r.id, v_outlet FROM pos.roles r WHERE r.code = 'CASHIER';
        INSERT INTO pos.user_outlets (user_id, outlet_id) VALUES (v_user, v_outlet);

        INSERT INTO pos.employee_pins (employee_id, organization_id, pin_hash)
        SELECT e.id, e.organization_id, crypt('123456', gen_salt('bf', 10)) FROM pos.employees e WHERE e.organization_id = v_org
        ON CONFLICT (employee_id) DO NOTHING;

        -- Katalog contoh, dibuat sebagai owner merchant tersebut
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_auth, 'role', 'authenticated')::text, false);
        PERFORM pos.set_attendance_required(false);   -- contoh: tanpa wajib clock in (bisa diubah di menu Pengaturan)
        IF t.code = 'ALFAMART' THEN
            PERFORM pos.save_category(NULL, 'MAKANAN', 'Makanan', true);
            PERFORM pos.save_category(NULL, 'MINUMAN', 'Minuman', true);
            PERFORM pos.save_category(NULL, 'SNACK', 'Snack', true);
        END IF;
        FOR p IN SELECT * FROM (VALUES
            ('ALFAMART', 'MAKANAN', 'ALF-001', 'Mie Instan Goreng', 3500, 120),
            ('ALFAMART', 'MAKANAN', 'ALF-002', 'Roti Tawar', 16500, 40),
            ('ALFAMART', 'MAKANAN', 'ALF-003', 'Sosis Siap Makan', 8000, 60),
            ('ALFAMART', 'MINUMAN', 'ALF-010', 'Air Mineral 600 ml', 4000, 200),
            ('ALFAMART', 'MINUMAN', 'ALF-011', 'Teh Botol 350 ml', 5500, 150),
            ('ALFAMART', 'MINUMAN', 'ALF-012', 'Susu UHT Coklat', 7000, 90),
            ('ALFAMART', 'MINUMAN', 'ALF-013', 'Kopi Sachet', 2000, 300),
            ('ALFAMART', 'SNACK', 'ALF-020', 'Keripik Kentang', 11500, 80),
            ('ALFAMART', 'SNACK', 'ALF-021', 'Biskuit Coklat', 9000, 70),
            ('ALFAMART', 'SNACK', 'ALF-022', 'Wafer Keju', 6500, 100),
            ('PERSITA', 'PAKAIAN', 'PRS-001', 'Jersey Home', 350000, 30),
            ('PERSITA', 'PAKAIAN', 'PRS-002', 'Jersey Away', 350000, 30),
            ('PERSITA', 'PAKAIAN', 'PRS-003', 'Kaos Supporter', 120000, 60),
            ('PERSITA', 'PAKAIAN', 'PRS-004', 'Jaket Parka', 280000, 20),
            ('PERSITA', 'SEPATU', 'PRS-010', 'Sepatu Sneakers', 450000, 25),
            ('PERSITA', 'SEPATU', 'PRS-011', 'Sepatu Futsal', 380000, 25),
            ('PERSITA', 'KAOSKAKI', 'PRS-020', 'Kaos Kaki Bola', 45000, 80),
            ('PERSITA', 'KAOSKAKI', 'PRS-021', 'Kaos Kaki Harian (3 pasang)', 35000, 100),
            ('PERSITA', 'AKSESORIS', 'PRS-030', 'Topi Klub', 90000, 40),
            ('PERSITA', 'AKSESORIS', 'PRS-031', 'Syal Supporter', 75000, 50),
            ('PERSITA', 'AKSESORIS', 'PRS-032', 'Tas Ransel', 150000, 20),
            ('PERSITA', 'MERCH', 'PRS-040', 'Gantungan Kunci', 20000, 150),
            ('PERSITA', 'MERCH', 'PRS-041', 'Stiker Pack', 15000, 200)
        ) AS y(org, cat, sku, name, price, qty) WHERE y.org = t.code
        LOOP
            -- barcode EAN-13 contoh (awalan 899 + nomor urut + digit cek) agar bisa dicoba dengan pemindai
            n := n + 1;
            v_code := '899' || CASE WHEN t.code = 'ALFAMART' THEN '1' ELSE '2' END || lpad(n::text, 8, '0');
            sm := 0;
            FOR i IN 1..12 LOOP
                sm := sm + substr(v_code, i, 1)::integer * CASE WHEN i % 2 = 1 THEN 1 ELSE 3 END;
            END LOOP;
            v_code := v_code || ((10 - sm % 10) % 10)::text;
            v_prod := pos.save_product(NULL, p.sku, p.name, (SELECT id FROM pos.product_categories WHERE organization_id = v_org AND code = p.cat),
                                       'PCS', false, NULL, true, true, NULL, v_code, p.price);
            PERFORM pos.set_local_stock(v_prod, v_outlet, p.qty);
        END LOOP;
        PERFORM set_config('request.jwt.claims', '', false);
    END LOOP;
END
$seed$;
