-- Retensi foto absensi (V036)
\set JKT '''00000000-0000-4000-8000-000000000101'''
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
CREATE TEMP TABLE att AS SELECT pos_test.clock_in(:JKT) AS id;
GRANT SELECT ON att TO PUBLIC;
SELECT pos.attach_attendance_photo((SELECT id FROM att), 'CLOCK_IN', 'image/jpeg', '\xffd8ffe0'::bytea);
SELECT pos_test.throws($$SELECT pos.purge_attendance_photos()$$, 'permission denied', 'aplikasi tidak boleh menjalankan retensi');
RESET ROLE;

SET LOCAL ROLE pos_system;
SELECT pos_test.ok(pos.purge_attendance_photos() = 0, 'foto baru tidak dihapus');
SELECT pos_test.throws($$DELETE FROM pos.attendance_photos$$, 'permission denied', 'sistem tidak bisa menghapus langsung');
RESET ROLE;
SELECT pos_test.ok(pos_test.photo_count((SELECT id FROM att)) = 1, 'foto masih ada');

-- foto dibuat 100 hari lalu (trigger dimatikan hanya oleh helper tes)
SELECT pos_test.backdate_photo((SELECT id FROM att), interval '100 days');
SET LOCAL ROLE pos_system;
SELECT pos_test.throws($$DELETE FROM pos.attendance_photos$$, 'permission denied', 'sistem tetap tidak bisa menghapus langsung');
RESET ROLE;

-- retensi 0 = simpan selamanya
SELECT pos_test.set_photo_retention((SELECT id FROM att), 0);
SET LOCAL ROLE pos_system;
SELECT pos_test.ok(pos.purge_attendance_photos() = 0, 'retensi 0: tidak ada yang dihapus');
RESET ROLE;
SELECT pos_test.set_photo_retention((SELECT id FROM att), 30);
SET LOCAL ROLE pos_system;
SELECT pos_test.ok(pos.purge_attendance_photos() >= 1, 'foto 100 hari dihapus pada retensi 30 hari');
RESET ROLE;
SELECT pos_test.ok(pos_test.photo_count((SELECT id FROM att)) = 0, 'foto lama hilang');
SELECT pos_test.ok(pos_test.purge_audit_count() >= 1, 'penghapusan tercatat di audit log');
ROLLBACK;
