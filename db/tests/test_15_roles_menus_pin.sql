-- Phase 10a: role Owner, menu aktif/nonaktif per role (+default), PIN, foto clock in
\set JKT '''00000000-0000-4000-8000-000000000101'''

BEGIN;
-- ---- menu default per role
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT array_agg(code ORDER BY sort_order) = ARRAY['pos','clock','beginning-cash','product-list','history','closing']
                    FROM pos.my_menus(:JKT)), 'default kasir: kasir, clock, saldo awal, produk, history, closing');
SELECT pos_test.throws($$SELECT * FROM pos.menu_matrix()$$, 'USER_NOT_AUTHORIZED', 'kasir tidak boleh membuka pengaturan menu');
SELECT pos_test.throws($$SELECT pos.set_menu_enabled('manage-receipt', 'CASHIER', true)$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa mengubah menu');
SELECT pos_test.throws($$SELECT pos.set_employee_pin('00000000-0000-4000-8000-000000000505', '111111')$$, 'USER_NOT_AUTHORIZED', 'kasir tidak bisa reset PIN');
SELECT pos_test.throws($$SELECT pin_hash FROM pos.employee_pins$$, 'permission denied', 'hash PIN tidak terbaca oleh user aplikasi');
RESET ROLE;

SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT bool_and(code <> 'manage-receipt' AND code <> 'manage-categories') AND bool_or(code = 'manage-cashier')
                    FROM pos.my_menus(:JKT)), 'default supervisor: kelola kasir & diskon, tanpa struk/kategori');
RESET ROLE;

SELECT pos_test.login('owner');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT NOT bool_or(code = 'pos') AND bool_or(code = 'manage-receipt') AND bool_or(code = 'dashboard')
                    FROM pos.my_menus(NULL)), 'default owner: tanpa menu transaksi, ada struk & dashboard');
SELECT pos_test.ok((SELECT count(*) = 44 FROM pos.menu_matrix()), 'matriks: 11 menu x 4 peran');

-- owner mengaktifkan menu kasir "manage-discount" -> penyimpangan tercatat; reset kembali ke default
SELECT pos.set_menu_enabled('manage-discount', 'CASHIER', true);
SELECT pos_test.ok((SELECT enabled AND NOT default_enabled FROM pos.menu_matrix() WHERE menu_code = 'manage-discount' AND role_code = 'CASHIER'),
    'owner mengaktifkan menu untuk kasir (default tetap tampil)');
SELECT pos.set_menu_enabled('manage-discount', 'CASHIER', NULL);
SELECT pos_test.ok((SELECT NOT enabled FROM pos.menu_matrix() WHERE menu_code = 'manage-discount' AND role_code = 'CASHIER'),
    'reset ke default');
SELECT pos_test.throws($$SELECT pos.set_menu_enabled('pos', 'SUPER_ADMIN', true)$$, 'MENU_ROLE_NOT_CONFIGURABLE', 'hanya empat peran utama');
SELECT pos_test.throws($$SELECT pos.set_menu_enabled('pos', 'ADMIN', true)$$, 'USER_NOT_AUTHORIZED', 'owner tidak bisa mengatur peran di atasnya');
-- menu hanya tampilan: mengaktifkan menu yang butuh permission tidak memberi akses
SELECT pos.set_menu_enabled('pos', 'OWNER', true);
SELECT pos_test.ok((SELECT NOT bool_or(code = 'pos') FROM pos.my_menus(NULL)), 'menu aktif tetap tersembunyi tanpa permission sale.create');
SELECT pos.set_menu_enabled('pos', 'OWNER', NULL);
RESET ROLE;

-- ---- PIN
SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos.set_employee_pin('00000000-0000-4000-8000-000000000505', '654321');
SELECT pos_test.throws($$SELECT pos.set_employee_pin('00000000-0000-4000-8000-000000000505', '12ab')$$, 'PIN_FORMAT_INVALID', 'PIN 6 digit angka');
SELECT pos_test.throws($$SELECT pos.set_employee_pin('00000000-0000-4000-8000-000000000506', '654321')$$, 'USER_NOT_AUTHORIZED', 'supervisor JKT tidak bisa reset PIN kasir BDG');
SELECT pos_test.ok(pos.employee_has_pin('00000000-0000-4000-8000-000000000505'), 'PIN tersimpan');
SELECT pos_test.throws($$SELECT pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '654321')$$, 'permission denied', 'user aplikasi tidak bisa memanggil verifikasi langsung');
RESET ROLE;

SELECT pos_test.as_system();
SET LOCAL ROLE pos_system;
SELECT pos_test.ok(pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '654321') = 'OK', 'PIN benar');
SELECT pos_test.ok(pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '000000') = 'INVALID:4', 'PIN salah: sisa 4');
SELECT pos_test.ok(pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '000000') = 'INVALID:3', 'sisa 3');
SELECT pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '000000');
SELECT pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '000000');
SELECT pos_test.ok(pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '000000') = 'LOCKED', 'terkunci setelah 5 kali salah');
SELECT pos_test.ok(pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '654321') = 'LOCKED', 'PIN benar pun ditolak saat terkunci');
UPDATE pos.employee_pins SET locked_until = now() - interval '1 second';
SELECT pos_test.ok(pos.verify_employee_pin('00000000-0000-4000-8000-000000000505', '654321') = 'OK', 'kunci berakhir');
SELECT pos_test.ok(pos.verify_employee_pin('00000000-0000-4000-8000-000000000999', '654321') = 'NOT_SET', 'belum ada PIN');
RESET ROLE;

-- ---- foto clock in
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE att AS SELECT pos_test.clock_in(:JKT) AS id;
GRANT SELECT ON att TO PUBLIC;
SELECT pos.attach_attendance_photo((SELECT id FROM att), 'CLOCK_IN', 'image/jpeg', '\xffd8ffe0'::bytea);
SELECT pos_test.throws($$SELECT pos.attach_attendance_photo((SELECT id FROM att), 'CLOCK_IN', 'image/jpeg', '\xffd8ffe0'::bytea)$$, 'duplicate key', 'satu foto per jenis');
SELECT pos_test.throws($$SELECT pos.attach_attendance_photo((SELECT id FROM att), 'CLOCK_OUT', 'text/html', '\x3c'::bytea)$$, 'attendance_photos_type_ck', 'hanya gambar');
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.get_attendance_photo((SELECT id FROM att), 'CLOCK_IN')), 'pemilik melihat fotonya');
RESET ROLE;

SELECT pos_test.login('supervisor.jkt');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 1 FROM pos.get_attendance_photo((SELECT id FROM att), 'CLOCK_IN')), 'supervisor outlet melihat foto');
RESET ROLE;
SELECT pos_test.login('cashier.bdg');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok((SELECT count(*) = 0 FROM pos.get_attendance_photo((SELECT id FROM att), 'CLOCK_IN')), 'kasir lain tidak melihat foto');
RESET ROLE;
ROLLBACK;
