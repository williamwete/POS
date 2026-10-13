-- V028: masa percobaan (TRIAL) yang berakhir menutup penjualan baru & pembukaan kasir.
-- Data tetap dapat dilihat; operator memperpanjang lewat "Ganti paket" (memilih TRIAL lagi = 14 hari baru) atau berpindah paket.
CREATE OR REPLACE FUNCTION pos.tg_trial_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM pos.organization_subscriptions s
               WHERE s.organization_id = NEW.organization_id AND s.status = 'TRIAL'
                 AND s.trial_ends_at IS NOT NULL AND s.trial_ends_at < now()) THEN
        RAISE EXCEPTION 'TRIAL_EXPIRED: masa percobaan berakhir, hubungi penyedia layanan untuk berlangganan'
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER aa_trial_guard BEFORE INSERT ON pos.sales
    FOR EACH ROW EXECUTE FUNCTION pos.tg_trial_guard();
CREATE TRIGGER aa_trial_guard BEFORE INSERT ON pos.cashier_sessions
    FOR EACH ROW EXECUTE FUNCTION pos.tg_trial_guard();

-- Memilih paket TRIAL = percobaan baru 14 hari (sebelumnya tanpa batas waktu).
CREATE OR REPLACE FUNCTION pos.platform_set_plan(p_org uuid, p_plan text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    IF NOT EXISTS (SELECT 1 FROM pos.plans WHERE code = p_plan AND active) THEN
        RAISE EXCEPTION 'CATALOG_INVALID: paket tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.organization_subscriptions (organization_id, plan_code, status, trial_ends_at)
    VALUES (p_org, p_plan, CASE WHEN p_plan = 'TRIAL' THEN 'TRIAL' ELSE 'ACTIVE' END,
            CASE WHEN p_plan = 'TRIAL' THEN now() + interval '14 days' END)
    ON CONFLICT (organization_id) DO UPDATE
        SET plan_code = EXCLUDED.plan_code, status = EXCLUDED.status, trial_ends_at = EXCLUDED.trial_ends_at, updated_at = now();
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (p_org, pos.current_app_user_id(), 'MERCHANT_PLAN_CHANGED', 'ORGANIZATION', p_org::text,
            jsonb_build_object('plan', p_plan));
END
$$;

-- Status langganan merchant sendiri (untuk banner di aplikasi).
CREATE OR REPLACE FUNCTION pos.my_subscription()
RETURNS TABLE (plan_code text, plan_name text, status text, trial_ends_at timestamptz, expired boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
    SELECT s.plan_code, p.name, s.status, s.trial_ends_at,
           (s.status = 'TRIAL' AND s.trial_ends_at IS NOT NULL AND s.trial_ends_at < now())
    FROM pos.organization_subscriptions s JOIN pos.plans p ON p.code = s.plan_code
    WHERE s.organization_id = pos.current_org_id()
$$;
REVOKE ALL ON FUNCTION pos.my_subscription() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pos.my_subscription() TO pos_app_user;
