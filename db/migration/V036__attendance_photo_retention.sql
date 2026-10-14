-- V036: retensi foto absensi (UU PDP: data pribadi tidak disimpan lebih lama dari perlu).
-- Foto tetap append-only untuk aplikasi; hanya fungsi retensi (di bawah) yang boleh menghapus, dan hanya foto yang
-- sudah lewat masa simpan. Baris absensi dan audit log tidak disentuh.
INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('attendance_photo_retention_days', 'NUMBER', '90', 'Lama foto clock in/out disimpan (hari); 0 = simpan selamanya', 'ORGANIZATION');

DROP TRIGGER attendance_photos_append_only ON pos.attendance_photos;
CREATE OR REPLACE FUNCTION pos.tg_attendance_photo_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' AND coalesce(current_setting('pos.retention_purge', true), '') = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'APPEND_ONLY_VIOLATION: % on %.% is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'P0001';
END
$$;
CREATE TRIGGER attendance_photos_append_only BEFORE UPDATE OR DELETE ON pos.attendance_photos
    FOR EACH ROW EXECUTE FUNCTION pos.tg_attendance_photo_guard();

-- Hapus foto yang melewati masa simpan per merchant. Dipanggil job harian (pos_system); mengembalikan jumlah foto.
CREATE OR REPLACE FUNCTION pos.purge_attendance_photos()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    o record;
    v_days integer;
    v_deleted integer;
    v_total integer := 0;
BEGIN
    PERFORM set_config('pos.retention_purge', 'on', true);
    FOR o IN SELECT id FROM pos.organizations LOOP
        SELECT coalesce((SELECT (s.value #>> '{}')::integer FROM pos.settings s
                          WHERE s.organization_id = o.id AND s.outlet_id IS NULL AND s.key = 'attendance_photo_retention_days'),
                        (SELECT d.default_value::integer FROM pos.setting_definitions d WHERE d.key = 'attendance_photo_retention_days'))
          INTO v_days;
        CONTINUE WHEN v_days IS NULL OR v_days <= 0;
        DELETE FROM pos.attendance_photos p
         WHERE p.organization_id = o.id AND p.created_at < now() - make_interval(days => v_days);
        GET DIAGNOSTICS v_deleted = ROW_COUNT;
        IF v_deleted > 0 THEN
            INSERT INTO pos.audit_logs (organization_id, actor_type, action, entity_type, new_value)
            VALUES (o.id, 'SYSTEM', 'RETENTION_PURGE', 'ATTENDANCE_PHOTO',
                    jsonb_build_object('deleted', v_deleted, 'retentionDays', v_days));
            v_total := v_total + v_deleted;
        END IF;
    END LOOP;
    PERFORM set_config('pos.retention_purge', 'off', true);
    RETURN v_total;
END
$$;
REVOKE ALL ON FUNCTION pos.purge_attendance_photos() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.purge_attendance_photos() TO pos_system;
