-- Sinkron master data Openbravo hanya untuk merchant yang diaktifkan operator platform. Merchant katalog
-- lokal tidak boleh kebanjiran produk dari Openbravo/simulator (katalog dobel).
INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('openbravo_enabled', 'BOOLEAN', 'false', 'Merchant memakai integrasi Openbravo (diatur operator platform)', 'ORGANIZATION');

CREATE OR REPLACE FUNCTION pos.platform_set_openbravo(p_org uuid, p_enabled boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    IF p_enabled IS NULL THEN
        RAISE EXCEPTION 'CATALOG_INVALID: nilai wajib diisi' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pos.organizations WHERE id = p_org) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: merchant tidak ditemukan' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.settings (organization_id, outlet_id, key, value)
    VALUES (p_org, NULL, 'openbravo_enabled', to_jsonb(p_enabled))
    ON CONFLICT (organization_id, outlet_id, key) DO UPDATE SET value = EXCLUDED.value;
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (p_org, pos.current_app_user_id(), 'SETTING_CHANGED', 'SETTING', 'openbravo_enabled',
            jsonb_build_object('value', p_enabled));
END
$$;
REVOKE ALL ON FUNCTION pos.platform_set_openbravo(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.platform_set_openbravo(uuid, boolean) TO pos_app_user;
