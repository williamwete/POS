-- V005: permission catalog & system roles (reference data, dipakai di semua environment)

INSERT INTO pos.permissions (code, module, description) VALUES
    ('attendance.clock_in',        'attendance', 'Clock in diri sendiri'),
    ('attendance.clock_out',       'attendance', 'Clock out diri sendiri'),
    ('attendance.force_clock_out', 'attendance', 'Paksa clock out karyawan lain (dengan alasan)'),
    ('attendance.view',            'attendance', 'Lihat attendance karyawan di outlet'),
    ('cashier.open',               'cashier',    'Buka cashier session'),
    ('cashier.close',              'cashier',    'Tutup cashier session'),
    ('cashier.handover',           'cashier',    'Serah terima kasir'),
    ('cashier.view',               'cashier',    'Lihat cashier session lain di outlet'),
    ('sale.create',                'sale',       'Buat transaksi penjualan'),
    ('sale.view',                  'sale',       'Lihat transaksi penjualan di outlet'),
    ('sale.void',                  'sale',       'Void transaksi/item'),
    ('sale.refund',                'sale',       'Proses return & refund'),
    ('sale.discount',              'sale',       'Beri diskon manual'),
    ('sale.price_override',        'sale',       'Ubah harga item'),
    ('cash.cash_in',               'cash',       'Cash in'),
    ('cash.cash_out',              'cash',       'Cash out'),
    ('cash.cash_adjustment',       'cash',       'Penyesuaian kas'),
    ('cash.approve_difference',    'cash',       'Setujui selisih kas'),
    ('stock.view',                 'stock',      'Lihat stok'),
    ('stock.adjust',               'stock',      'Ajukan penyesuaian stok'),
    ('report.view',                'report',     'Lihat laporan'),
    ('user.view',                  'user',       'Lihat user & akses'),
    ('user.manage',                'user',       'Kelola user, role assignment, akses outlet'),
    ('employee.view',              'employee',   'Lihat data karyawan'),
    ('employee.manage',            'employee',   'Kelola data karyawan'),
    ('outlet.manage',              'outlet',     'Kelola outlet & warehouse'),
    ('terminal.manage',            'terminal',   'Kelola terminal & device'),
    ('role.manage',                'role',       'Kelola permission pada role'),
    ('configuration.manage',       'configuration', 'Kelola konfigurasi'),
    ('audit.view',                 'audit',      'Lihat audit log'),
    ('sync.view',                  'sync',       'Lihat status sinkronisasi'),
    ('sync.manage',                'sync',       'Jalankan/retry sinkronisasi');

-- SUPER_ADMIN (100) tidak dapat diberikan lewat aplikasi; hanya via bootstrap/DB.
INSERT INTO pos.roles (code, name, description, is_system, rank) VALUES
    ('SUPER_ADMIN',    'Super Admin',    'Akses penuh', true, 100),
    ('ADMIN',          'Admin',          'Administrasi sistem, tanpa transaksi', true, 90),
    ('AUDITOR',        'Auditor',        'Read-only', true, 80),
    ('STORE_MANAGER',  'Store Manager',  'Manajer toko', true, 70),
    ('SUPERVISOR',     'Supervisor',     'Supervisor shift', true, 50),
    ('STOCK_OPERATOR', 'Stock Operator', 'Operator stok', true, 30),
    ('CASHIER',        'Cashier',        'Kasir', true, 20);

INSERT INTO pos.role_permissions (role_id, permission_code)
SELECT r.id, p.code
FROM pos.roles r
JOIN pos.permissions p ON (
    (r.code = 'SUPER_ADMIN')
 OR (r.code = 'ADMIN' AND p.code IN (
        'user.view', 'user.manage', 'employee.view', 'employee.manage',
        'outlet.manage', 'terminal.manage', 'configuration.manage', 'audit.view',
        'report.view', 'sync.view', 'sync.manage', 'stock.view', 'cashier.view',
        'sale.view', 'attendance.view'))
 OR (r.code = 'STORE_MANAGER' AND p.code IN (
        'attendance.clock_in', 'attendance.clock_out', 'attendance.force_clock_out', 'attendance.view',
        'cashier.open', 'cashier.close', 'cashier.handover', 'cashier.view',
        'sale.create', 'sale.view', 'sale.void', 'sale.refund', 'sale.discount', 'sale.price_override',
        'cash.cash_in', 'cash.cash_out', 'cash.cash_adjustment', 'cash.approve_difference',
        'stock.view', 'stock.adjust', 'report.view', 'employee.view', 'employee.manage',
        'user.view', 'audit.view', 'sync.view'))
 OR (r.code = 'SUPERVISOR' AND p.code IN (
        'attendance.clock_in', 'attendance.clock_out', 'attendance.force_clock_out', 'attendance.view',
        'cashier.open', 'cashier.close', 'cashier.handover', 'cashier.view',
        'sale.create', 'sale.view', 'sale.void', 'sale.refund', 'sale.discount', 'sale.price_override',
        'cash.cash_in', 'cash.cash_out', 'cash.approve_difference',
        'stock.view', 'report.view', 'employee.view', 'sync.view'))
 OR (r.code = 'CASHIER' AND p.code IN (
        'attendance.clock_in', 'attendance.clock_out',
        'cashier.open', 'cashier.close', 'cashier.handover',
        'sale.create', 'sale.discount', 'cash.cash_in', 'cash.cash_out', 'stock.view'))
 OR (r.code = 'STOCK_OPERATOR' AND p.code IN (
        'attendance.clock_in', 'attendance.clock_out', 'stock.view', 'stock.adjust'))
 OR (r.code = 'AUDITOR' AND p.code IN (
        'attendance.view', 'cashier.view', 'sale.view', 'stock.view', 'report.view',
        'user.view', 'employee.view', 'audit.view', 'sync.view'))
);
