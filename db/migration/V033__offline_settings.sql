-- Pengaturan mode offline per merchant (layar Pengaturan). 0 pada batas = tanpa batas.
UPDATE pos.setting_definitions SET description = 'Izinkan penjualan tunai saat server tidak terjangkau; bila mati, transaksi offline tetap diterima tetapi ditandai untuk ditinjau'
 WHERE key = 'allow_offline_sale';
UPDATE pos.setting_definitions SET description = 'Batas nilai satu transaksi offline dalam rupiah (0 = tanpa batas); melebihi batas = ditandai untuk ditinjau'
 WHERE key = 'max_offline_sale_amount';
UPDATE pos.setting_definitions SET description = 'Batas waktu pengiriman transaksi offline dalam menit (0 = tanpa batas); terlambat = ditandai untuk ditinjau'
 WHERE key = 'max_offline_duration_minutes';

CREATE OR REPLACE FUNCTION pos.set_offline_settings(p_allow boolean, p_max_amount numeric, p_max_minutes integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
BEGIN
    PERFORM pos.require_perm('configuration.manage', NULL);
    IF p_allow IS NULL OR p_max_amount IS NULL OR p_max_minutes IS NULL THEN
        RAISE EXCEPTION 'CATALOG_INVALID: semua nilai wajib diisi' USING ERRCODE = 'P0001';
    END IF;
    IF p_max_amount < 0 OR p_max_amount > 100000000 OR p_max_amount <> trunc(p_max_amount) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: batas nilai harus rupiah bulat 0 sampai 100.000.000' USING ERRCODE = 'P0001';
    END IF;
    IF p_max_minutes < 0 OR p_max_minutes > 10080 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: batas durasi 0 sampai 10.080 menit' USING ERRCODE = 'P0001';
    END IF;
    -- pengaturan merchant berlaku untuk semua outlet: hapus penyimpangan per outlet agar tidak membingungkan
    DELETE FROM pos.settings WHERE organization_id = v_org AND outlet_id IS NOT NULL
        AND key IN ('allow_offline_sale', 'max_offline_sale_amount', 'max_offline_duration_minutes');
    INSERT INTO pos.settings (organization_id, outlet_id, key, value) VALUES
        (v_org, NULL, 'allow_offline_sale', to_jsonb(p_allow)),
        (v_org, NULL, 'max_offline_sale_amount', to_jsonb(p_max_amount)),
        (v_org, NULL, 'max_offline_duration_minutes', to_jsonb(p_max_minutes))
    ON CONFLICT (organization_id, outlet_id, key)
        DO UPDATE SET value = EXCLUDED.value;
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (v_org, pos.current_app_user_id(), 'SETTING_CHANGED', 'SETTING', 'offline',
            jsonb_build_object('allow', p_allow, 'maxAmount', p_max_amount, 'maxMinutes', p_max_minutes));
END
$$;
REVOKE ALL ON FUNCTION pos.set_offline_settings(boolean, numeric, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.set_offline_settings(boolean, numeric, integer) TO pos_app_user;
