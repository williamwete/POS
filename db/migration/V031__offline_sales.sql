-- Fase 10 tahap 1: penjualan offline. Transaksi tunai yang dibuat saat internet mati dikirim
-- setelah koneksi kembali. Selisih dengan data server dicatat untuk ditinjau (ASSUMPTIONS A3).
CREATE TABLE pos.offline_sales (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid          NOT NULL REFERENCES pos.organizations (id),
    outlet_id        uuid          NOT NULL,
    sale_id          uuid          NOT NULL UNIQUE REFERENCES pos.sales (id),
    offline_at       timestamptz   NOT NULL,
    submitted_at     timestamptz   NOT NULL DEFAULT now(),
    client_total     numeric(18,2) NOT NULL,
    server_total     numeric(18,2) NOT NULL,
    reason           text,
    status           text          NOT NULL,
    resolved_by      uuid,
    resolved_at      timestamptz,
    resolve_note     text,
    CONSTRAINT offline_sales_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT offline_sales_status_ck CHECK (status IN ('CLEAN', 'OPEN', 'RESOLVED')),
    CONSTRAINT offline_sales_reason_ck CHECK ((status = 'CLEAN') = (reason IS NULL)),
    CONSTRAINT offline_sales_resolved_ck CHECK ((status = 'RESOLVED') = (resolved_at IS NOT NULL))
);
CREATE INDEX offline_sales_open_ix ON pos.offline_sales (organization_id, outlet_id) WHERE status = 'OPEN';
ALTER TABLE pos.offline_sales ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON pos.offline_sales TO pos_app_user;
CREATE POLICY offline_sales_select ON pos.offline_sales FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id() AND pos.has_permission('report.view', outlet_id));

-- Dipanggil backend setelah transaksi offline berhasil dibuat di server.
CREATE OR REPLACE FUNCTION pos.record_offline_sale(p_sale uuid, p_offline_at timestamptz, p_client_total numeric,
                                                   p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org  uuid := pos.current_org_id();
    s      pos.sales%ROWTYPE;
    v_id   uuid;
    v_why  text := nullif(btrim(coalesce(p_reason, '')), '');
BEGIN
    SELECT * INTO s FROM pos.sales WHERE id = p_sale AND organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_INVALID: transaksi tidak ditemukan' USING ERRCODE = 'P0001';
    END IF;
    PERFORM pos.require_perm('sale.create', s.outlet_id);
    IF p_offline_at IS NULL OR p_offline_at > now() + interval '5 minutes' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: waktu transaksi offline tidak valid' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.offline_sales (organization_id, outlet_id, sale_id, offline_at, client_total, server_total,
                                   reason, status)
    VALUES (v_org, s.outlet_id, s.id, p_offline_at, p_client_total, s.grand_total, v_why,
            CASE WHEN v_why IS NULL THEN 'CLEAN' ELSE 'OPEN' END)
    ON CONFLICT (sale_id) DO UPDATE SET submitted_at = pos.offline_sales.submitted_at
    RETURNING id INTO v_id;
    IF v_why IS NOT NULL THEN
        INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
        VALUES (v_org, pos.current_app_user_id(), 'OFFLINE_SALE_REVIEW', 'SALE', s.id::text,
                jsonb_build_object('clientTotal', p_client_total, 'serverTotal', s.grand_total, 'reason', v_why));
    END IF;
    RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION pos.offline_reviews(p_outlet uuid, p_status text DEFAULT 'OPEN')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
BEGIN
    PERFORM pos.require_perm('report.view', p_outlet);
    IF p_status NOT IN ('CLEAN', 'OPEN', 'RESOLVED') THEN
        RAISE EXCEPTION 'CATALOG_INVALID: status tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    RETURN coalesce((SELECT jsonb_agg(jsonb_build_object(
            'id', o.id, 'saleId', o.sale_id, 'receiptNo', s.receipt_no, 'offlineAt', o.offline_at,
            'submittedAt', o.submitted_at, 'clientTotal', o.client_total, 'serverTotal', o.server_total,
            'reason', o.reason, 'status', o.status, 'resolveNote', o.resolve_note)
            ORDER BY o.offline_at DESC)
        FROM pos.offline_sales o JOIN pos.sales s ON s.id = o.sale_id
        WHERE o.organization_id = v_org AND o.outlet_id = p_outlet AND o.status = p_status), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION pos.resolve_offline_review(p_id uuid, p_note text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org  uuid := pos.current_org_id();
    o      pos.offline_sales%ROWTYPE;
    v_note text := nullif(btrim(coalesce(p_note, '')), '');
BEGIN
    SELECT * INTO o FROM pos.offline_sales WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_INVALID: data peninjauan tidak ditemukan' USING ERRCODE = 'P0001';
    END IF;
    PERFORM pos.require_perm('report.view', o.outlet_id);
    IF o.status <> 'OPEN' THEN
        RAISE EXCEPTION 'CATALOG_INVALID: peninjauan sudah diselesaikan' USING ERRCODE = 'P0001';
    END IF;
    IF v_note IS NULL OR pg_catalog.length(v_note) < 5 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: catatan minimal 5 karakter' USING ERRCODE = 'P0001';
    END IF;
    UPDATE pos.offline_sales SET status = 'RESOLVED', resolved_by = pos.current_app_user_id(),
           resolved_at = now(), resolve_note = v_note WHERE id = p_id;
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (v_org, pos.current_app_user_id(), 'OFFLINE_REVIEW_RESOLVED', 'SALE', o.sale_id::text,
            jsonb_build_object('note', v_note));
END
$$;

DO $$
DECLARE f text;
BEGIN
    FOREACH f IN ARRAY ARRAY['record_offline_sale(uuid,timestamptz,numeric,text)', 'offline_reviews(uuid,text)',
        'resolve_offline_review(uuid,text)']
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION pos.%s FROM PUBLIC', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION pos.%s TO pos_app_user', f);
    END LOOP;
END
$$;
