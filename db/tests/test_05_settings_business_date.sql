-- Konfigurasi (§73) & business date (§10, ASSUMPTIONS B8).
\set JKT '''00000000-0000-4000-8000-000000000101'''
\set BDG '''00000000-0000-4000-8000-000000000102'''

-- Resolusi setting: default -> organisasi -> outlet
BEGIN;
SELECT pos_test.login('superadmin');
SET LOCAL ROLE pos_app_user;
SELECT pos_test.ok(pos.get_setting('allow_negative_stock', :JKT) = 'false'::jsonb, 'default allow_negative_stock = false');
SELECT pos_test.ok(pos.get_setting('max_cashier_discount', :JKT) = '5'::jsonb, 'override organisasi dipakai (5)');
INSERT INTO pos.settings (organization_id, outlet_id, key, value)
VALUES (pos.current_org_id(), :BDG, 'max_cashier_discount', '7');
SELECT pos_test.ok(pos.get_setting('max_cashier_discount', :BDG) = '7'::jsonb, 'override outlet BDG01 dipakai (7)');
SELECT pos_test.ok(pos.get_setting('max_cashier_discount', :JKT) = '5'::jsonb, 'outlet lain tetap nilai organisasi');
SELECT pos_test.throws($$SELECT pos.get_setting('tidak_ada', NULL)$$, 'SETTING_UNKNOWN', 'setting tak dikenal ditolak');
SELECT pos_test.throws(
    $$INSERT INTO pos.settings (organization_id, key, value) VALUES (pos.current_org_id(), 'allow_negative_stock', '"yes"')$$,
    'SETTING_VALUE_INVALID', 'tipe nilai setting divalidasi');
SELECT pos_test.throws(
    $$INSERT INTO pos.settings (organization_id, key, value) VALUES (pos.current_org_id(), 'business_day_cutoff', '"25:00"')$$,
    'SETTING_VALUE_INVALID', 'format jam cutoff divalidasi');
ROLLBACK;

-- Business date dengan cutoff 04:00 Asia/Jakarta (UTC+7)
BEGIN;
SELECT pos_test.login('cashier.jkt');
SET LOCAL ROLE pos_app_user;
-- 2026-10-02 01:30 WIB = 2026-10-01 18:30 UTC -> masih business date 2026-10-01
SELECT pos_test.ok(pos.business_date('2026-10-01 18:30:00+00', :JKT) = date '2026-10-01',
    '01:30 WIB masuk business date hari sebelumnya');
-- 2026-10-02 04:00 WIB tepat -> 2026-10-02
SELECT pos_test.ok(pos.business_date('2026-10-01 21:00:00+00', :JKT) = date '2026-10-02',
    '04:00 WIB tepat masuk business date baru');
-- 2026-10-02 23:59 WIB -> 2026-10-02
SELECT pos_test.ok(pos.business_date('2026-10-02 16:59:00+00', :JKT) = date '2026-10-02',
    '23:59 WIB tetap business date yang sama');
ROLLBACK;

-- Timezone outlet berbeda (mis. outlet di Bali, Asia/Makassar UTC+8) & cutoff 00:00
BEGIN;
SET LOCAL ROLE pos_system;
UPDATE pos.outlets SET timezone = 'Asia/Makassar' WHERE id = :BDG;
INSERT INTO pos.settings (organization_id, outlet_id, key, value)
VALUES ('00000000-0000-4000-8000-000000000001', :BDG, 'business_day_cutoff', '"00:00"');
-- 2026-10-01 16:30 UTC = 2026-10-02 00:30 WITA
SELECT pos_test.ok(pos.business_date('2026-10-01 16:30:00+00', :BDG) = date '2026-10-02',
    'timezone & cutoff per outlet dihormati');
SELECT pos_test.throws($$SELECT pos.business_date(now(), '00000000-0000-4000-8000-0000000009ff')$$,
    'OUTLET_NOT_FOUND', 'outlet tak dikenal ditolak');
ROLLBACK;
