-- V024: saldo merchant, pencairan (payout), dan rekening bank — model "dana pembayaran diterima platform lebih dulu".
--
-- Prinsip:
--  * Setiap uang yang dikumpulkan penyedia pembayaran atas nama merchant tercatat di buku besar (merchant_ledger)
--    yang APPEND-ONLY. Saldo = jumlah entri; tidak ada kolom saldo yang bisa diubah.
--  * Hanya pembayaran yang benar-benar melewati penyedia (payments.provider & external_transaction_id terisi)
--    masuk buku besar. QRIS statis yang dikonfirmasi manual tidak: uangnya langsung ke merchant.
--  * Biaya (persentase + tetap) dipotong saat pembayaran lunas. Dana baru dapat dicairkan setelah masa tahan
--    (hold_days) agar refund/sengketa awal tidak membuat saldo negatif.
--  * Pencairan memotong saldo seketika (agar tidak bisa dicairkan dua kali); ditolak/gagal = entri pembalik.
--  * Rekening bank berubah => status kembali PENDING dan harus diverifikasi operator sebelum bisa dicairkan.

INSERT INTO pos.permissions (code, module, description) VALUES
    ('finance.manage', 'finance', 'Lihat saldo, atur rekening bank, dan ajukan pencairan dana');
INSERT INTO pos.role_permissions (role_id, permission_code)
SELECT r.id, 'finance.manage' FROM pos.roles r WHERE r.code IN ('SUPER_ADMIN', 'OWNER');

-- ---------------------------------------------------------------- ketentuan per merchant
CREATE TABLE pos.organization_payout_terms (
    organization_id  uuid PRIMARY KEY REFERENCES pos.organizations (id),
    fee_percent      numeric(6,3)  NOT NULL DEFAULT 0.7,
    fee_flat         numeric(18,2) NOT NULL DEFAULT 0,
    hold_days        integer       NOT NULL DEFAULT 1,
    min_payout       numeric(18,2) NOT NULL DEFAULT 50000,
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT payout_terms_ck CHECK (fee_percent >= 0 AND fee_percent <= 20 AND fee_flat >= 0 AND fee_flat <= 100000
        AND hold_days BETWEEN 0 AND 30 AND min_payout >= 0)
);
ALTER TABLE pos.organization_payout_terms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pos.organization_payout_terms FROM PUBLIC;

-- Ketentuan efektif (baris merchant, atau bawaan bila belum diatur).
CREATE OR REPLACE FUNCTION pos.payout_terms(p_org uuid)
RETURNS pos.organization_payout_terms
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
    SELECT coalesce(
        (SELECT t FROM pos.organization_payout_terms t WHERE t.organization_id = p_org),
        ROW(p_org, 0.7, 0, 1, 50000, now())::pos.organization_payout_terms)
$$;
REVOKE ALL ON FUNCTION pos.payout_terms(uuid) FROM PUBLIC;

-- ---------------------------------------------------------------- rekening bank
CREATE TABLE pos.merchant_bank_accounts (
    organization_id  uuid PRIMARY KEY REFERENCES pos.organizations (id),
    bank_code        text        NOT NULL,
    account_number   text        NOT NULL,
    account_name     text        NOT NULL,
    status           text        NOT NULL DEFAULT 'PENDING',
    verified_by      uuid,
    verified_at      timestamptz,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT bank_status_ck CHECK (status IN ('PENDING', 'VERIFIED')),
    CONSTRAINT bank_code_ck CHECK (bank_code ~ '^[A-Z0-9 ]{2,20}$'),
    CONSTRAINT bank_number_ck CHECK (account_number ~ '^[0-9]{5,20}$'),
    CONSTRAINT bank_name_ck CHECK (pg_catalog.length(btrim(account_name)) BETWEEN 2 AND 80)
);
ALTER TABLE pos.merchant_bank_accounts ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON pos.merchant_bank_accounts TO pos_app_user;
CREATE POLICY bank_select ON pos.merchant_bank_accounts FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id() AND pos.has_permission('finance.manage', NULL));

-- ---------------------------------------------------------------- pencairan
CREATE TABLE pos.payouts (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid          NOT NULL REFERENCES pos.organizations (id),
    amount           numeric(18,2) NOT NULL,
    status           text          NOT NULL DEFAULT 'REQUESTED',
    bank_code        text          NOT NULL,
    account_number   text          NOT NULL,
    account_name     text          NOT NULL,
    requested_by     uuid          NOT NULL,
    requested_at     timestamptz   NOT NULL DEFAULT now(),
    processed_by     uuid,
    processed_at     timestamptz,
    provider_ref     text,
    note             text,
    CONSTRAINT payouts_amount_ck CHECK (amount > 0 AND amount = round(amount, 0)),
    CONSTRAINT payouts_status_ck CHECK (status IN ('REQUESTED', 'PROCESSING', 'PAID', 'REJECTED', 'FAILED')),
    CONSTRAINT payouts_paid_ck CHECK (status <> 'PAID' OR (provider_ref IS NOT NULL AND processed_at IS NOT NULL))
);
CREATE INDEX payouts_org_idx ON pos.payouts (organization_id, requested_at DESC);
CREATE INDEX payouts_status_idx ON pos.payouts (status) WHERE status IN ('REQUESTED', 'PROCESSING');
ALTER TABLE pos.payouts ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON pos.payouts TO pos_app_user;
CREATE POLICY payouts_select ON pos.payouts FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id() AND pos.has_permission('finance.manage', NULL));

-- ---------------------------------------------------------------- buku besar (append-only)
CREATE TABLE pos.merchant_ledger (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq              bigint GENERATED ALWAYS AS IDENTITY,
    organization_id  uuid          NOT NULL REFERENCES pos.organizations (id),
    entry_type       text          NOT NULL,
    amount           numeric(18,2) NOT NULL,
    available_at     timestamptz   NOT NULL DEFAULT now(),
    payment_id       uuid REFERENCES pos.payments (id),
    refund_id        uuid REFERENCES pos.refunds (id),
    payout_id        uuid REFERENCES pos.payouts (id),
    provider         text,
    description      text,
    created_by       uuid,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT ledger_type_ck CHECK (entry_type IN
        ('PAYMENT', 'FEE', 'PAYMENT_REVERSAL', 'FEE_REVERSAL', 'REFUND', 'PAYOUT', 'PAYOUT_REVERSAL', 'ADJUSTMENT')),
    CONSTRAINT ledger_amount_ck CHECK (amount <> 0)
);
CREATE UNIQUE INDEX ledger_payment_once_uk ON pos.merchant_ledger (payment_id, entry_type)
    WHERE entry_type IN ('PAYMENT', 'FEE', 'PAYMENT_REVERSAL', 'FEE_REVERSAL');
CREATE UNIQUE INDEX ledger_refund_once_uk ON pos.merchant_ledger (refund_id) WHERE refund_id IS NOT NULL;
CREATE UNIQUE INDEX ledger_payout_once_uk ON pos.merchant_ledger (payout_id, entry_type) WHERE payout_id IS NOT NULL;
CREATE INDEX ledger_org_idx ON pos.merchant_ledger (organization_id, seq DESC);
CREATE TRIGGER ledger_no_update BEFORE UPDATE ON pos.merchant_ledger FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();
CREATE TRIGGER ledger_no_delete BEFORE DELETE ON pos.merchant_ledger FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();
CREATE TRIGGER ledger_no_truncate BEFORE TRUNCATE ON pos.merchant_ledger FOR EACH STATEMENT EXECUTE FUNCTION pos.tg_append_only();
ALTER TABLE pos.merchant_ledger ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON pos.merchant_ledger TO pos_app_user;
CREATE POLICY ledger_select ON pos.merchant_ledger FOR SELECT TO pos_app_user
    USING (organization_id = pos.current_org_id() AND pos.has_permission('finance.manage', NULL));

-- ---------------------------------------------------------------- pencatatan otomatis dari pembayaran & refund
CREATE OR REPLACE FUNCTION pos.tg_payment_ledger()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_terms pos.organization_payout_terms;
    v_fee numeric(18,2);
BEGIN
    -- hanya uang yang dikumpulkan penyedia (bukan tunai / konfirmasi manual)
    IF NEW.provider IS NULL OR NEW.external_transaction_id IS NULL OR NEW.confirmation <> 'GATEWAY' THEN
        RETURN NULL;
    END IF;
    v_terms := pos.payout_terms(NEW.organization_id);
    v_fee := round(NEW.amount * v_terms.fee_percent / 100 + v_terms.fee_flat, 2);

    IF NEW.status = 'PAID' AND OLD.status IS DISTINCT FROM 'PAID' THEN
        INSERT INTO pos.merchant_ledger (organization_id, entry_type, amount, available_at, payment_id, provider, description)
        VALUES (NEW.organization_id, 'PAYMENT', NEW.amount, NEW.paid_at + make_interval(days => v_terms.hold_days),
                NEW.id, NEW.provider, 'Pembayaran ' || NEW.method_code)
        ON CONFLICT DO NOTHING;
        IF v_fee > 0 THEN
            INSERT INTO pos.merchant_ledger (organization_id, entry_type, amount, available_at, payment_id, provider, description)
            VALUES (NEW.organization_id, 'FEE', -v_fee, NEW.paid_at + make_interval(days => v_terms.hold_days),
                    NEW.id, NEW.provider, 'Biaya layanan')
            ON CONFLICT DO NOTHING;
        END IF;
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER payments_ledger AFTER UPDATE OF status ON pos.payments
    FOR EACH ROW EXECUTE FUNCTION pos.tg_payment_ledger();

-- Refund atas pembayaran penyedia mengurangi saldo (biaya layanan tidak dikembalikan).
CREATE OR REPLACE FUNCTION pos.tg_refund_ledger()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_pay pos.payments%ROWTYPE;
BEGIN
    SELECT * INTO v_pay FROM pos.payments WHERE id = NEW.original_payment_id;
    IF v_pay.provider IS NOT NULL AND v_pay.external_transaction_id IS NOT NULL AND v_pay.confirmation = 'GATEWAY' THEN
        INSERT INTO pos.merchant_ledger (organization_id, entry_type, amount, payment_id, refund_id, provider, description)
        VALUES (NEW.organization_id, 'REFUND', -NEW.refund_amount, v_pay.id, NEW.id, v_pay.provider, 'Refund pembayaran');
    END IF;
    RETURN NULL;
END
$$;
CREATE TRIGGER refunds_ledger AFTER INSERT ON pos.refunds FOR EACH ROW EXECUTE FUNCTION pos.tg_refund_ledger();

-- ---------------------------------------------------------------- sisi merchant
CREATE OR REPLACE FUNCTION pos.my_balance()
RETURNS TABLE (total numeric, available numeric, pending numeric, min_payout numeric, fee_percent numeric,
               fee_flat numeric, hold_days integer, bank_status text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_terms pos.organization_payout_terms;
    v_total numeric; v_avail numeric;
BEGIN
    PERFORM pos.require_perm('finance.manage', NULL);
    v_terms := pos.payout_terms(v_org);
    SELECT coalesce(sum(l.amount), 0), coalesce(sum(l.amount) FILTER (WHERE l.available_at <= now()), 0)
      INTO v_total, v_avail FROM pos.merchant_ledger l WHERE l.organization_id = v_org;
    RETURN QUERY SELECT v_total, greatest(v_avail, 0), v_total - greatest(v_avail, 0), v_terms.min_payout,
                        v_terms.fee_percent, v_terms.fee_flat, v_terms.hold_days,
                        (SELECT b.status FROM pos.merchant_bank_accounts b WHERE b.organization_id = v_org);
END
$$;

CREATE OR REPLACE FUNCTION pos.save_bank_account(p_bank text, p_number text, p_name text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_bank text := upper(btrim(coalesce(p_bank, '')));
    v_number text := regexp_replace(coalesce(p_number, ''), '[\s-]', '', 'g');
    v_name text := btrim(coalesce(p_name, ''));
BEGIN
    PERFORM pos.require_perm('finance.manage', NULL);
    IF v_bank !~ '^[A-Z0-9 ]{2,20}$' OR v_number !~ '^[0-9]{5,20}$' OR pg_catalog.length(v_name) NOT BETWEEN 2 AND 80 THEN
        RAISE EXCEPTION 'CATALOG_INVALID: bank, nomor rekening (5-20 angka), dan nama pemilik wajib diisi dengan benar' USING ERRCODE = 'P0001';
    END IF;
    -- hanya satu pencairan berjalan: mengganti rekening saat ada pencairan menunggu bisa membelokkan dana
    IF EXISTS (SELECT 1 FROM pos.payouts WHERE organization_id = v_org AND status IN ('REQUESTED', 'PROCESSING')) THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: rekening tidak dapat diganti selama ada pencairan yang diproses' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.merchant_bank_accounts (organization_id, bank_code, account_number, account_name)
    VALUES (v_org, v_bank, v_number, v_name)
    ON CONFLICT (organization_id) DO UPDATE
        SET bank_code = EXCLUDED.bank_code, account_number = EXCLUDED.account_number, account_name = EXCLUDED.account_name,
            status = CASE WHEN (pos.merchant_bank_accounts.bank_code, pos.merchant_bank_accounts.account_number,
                                pos.merchant_bank_accounts.account_name)
                               IS NOT DISTINCT FROM (EXCLUDED.bank_code, EXCLUDED.account_number, EXCLUDED.account_name)
                          THEN pos.merchant_bank_accounts.status ELSE 'PENDING' END,
            verified_by = CASE WHEN (pos.merchant_bank_accounts.bank_code, pos.merchant_bank_accounts.account_number,
                                     pos.merchant_bank_accounts.account_name)
                                    IS NOT DISTINCT FROM (EXCLUDED.bank_code, EXCLUDED.account_number, EXCLUDED.account_name)
                               THEN pos.merchant_bank_accounts.verified_by END,
            verified_at = CASE WHEN (pos.merchant_bank_accounts.bank_code, pos.merchant_bank_accounts.account_number,
                                     pos.merchant_bank_accounts.account_name)
                                    IS NOT DISTINCT FROM (EXCLUDED.bank_code, EXCLUDED.account_number, EXCLUDED.account_name)
                               THEN pos.merchant_bank_accounts.verified_at END,
            updated_at = now();
END
$$;

CREATE OR REPLACE FUNCTION pos.request_payout(p_amount numeric)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_org uuid := pos.current_org_id();
    v_terms pos.organization_payout_terms;
    v_bank pos.merchant_bank_accounts%ROWTYPE;
    v_avail numeric;
    v_id uuid;
BEGIN
    PERFORM pos.require_perm('finance.manage', NULL);
    -- serialkan pengajuan per merchant agar saldo tidak terhitung dua kali
    PERFORM 1 FROM pos.organizations WHERE id = v_org FOR UPDATE;
    v_terms := pos.payout_terms(v_org);
    SELECT * INTO v_bank FROM pos.merchant_bank_accounts WHERE organization_id = v_org;
    IF NOT FOUND OR v_bank.status <> 'VERIFIED' THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: rekening bank belum diisi atau belum diverifikasi' USING ERRCODE = 'P0001';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 0) THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: jumlah pencairan harus bilangan bulat positif' USING ERRCODE = 'P0001';
    END IF;
    IF p_amount < v_terms.min_payout THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: pencairan minimal Rp %', to_char(v_terms.min_payout, 'FM999G999G999G999') USING ERRCODE = 'P0001';
    END IF;
    SELECT coalesce(sum(l.amount) FILTER (WHERE l.available_at <= now()), 0) INTO v_avail
      FROM pos.merchant_ledger l WHERE l.organization_id = v_org;
    -- saldo total juga tidak boleh menjadi negatif (mis. refund yang belum jatuh tempo)
    IF p_amount > v_avail OR p_amount > (SELECT coalesce(sum(amount), 0) FROM pos.merchant_ledger WHERE organization_id = v_org) THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: saldo yang dapat dicairkan tidak mencukupi' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.payouts (organization_id, amount, bank_code, account_number, account_name, requested_by)
    VALUES (v_org, p_amount, v_bank.bank_code, v_bank.account_number, v_bank.account_name, pos.current_app_user_id())
    RETURNING id INTO v_id;
    INSERT INTO pos.merchant_ledger (organization_id, entry_type, amount, payout_id, description, created_by)
    VALUES (v_org, 'PAYOUT', -p_amount, v_id, 'Pencairan ke ' || v_bank.bank_code, pos.current_app_user_id());
    RETURN v_id;
END
$$;

-- ---------------------------------------------------------------- sisi operator platform
CREATE OR REPLACE FUNCTION pos.platform_payouts(p_status text DEFAULT NULL)
RETURNS TABLE (id uuid, organization_id uuid, merchant_code text, merchant_name text, amount numeric, status text,
               bank_code text, account_number text, account_name text, requested_at timestamptz,
               processed_at timestamptz, provider_ref text, note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    RETURN QUERY
    SELECT p.id, p.organization_id, o.code, o.name, p.amount, p.status, p.bank_code, p.account_number, p.account_name,
           p.requested_at, p.processed_at, p.provider_ref, p.note
    FROM pos.payouts p JOIN pos.organizations o ON o.id = p.organization_id
    WHERE p_status IS NULL OR p.status = p_status
    ORDER BY (p.status IN ('REQUESTED', 'PROCESSING')) DESC, p.requested_at DESC
    LIMIT 200;
END
$$;

CREATE OR REPLACE FUNCTION pos.platform_process_payout(p_id uuid, p_status text, p_ref text, p_note text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
DECLARE
    v_pay pos.payouts%ROWTYPE;
    v_ref text := nullif(btrim(coalesce(p_ref, '')), '');
    v_note text := nullif(btrim(coalesce(p_note, '')), '');
    v_actor uuid := pos.current_app_user_id();
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    SELECT * INTO v_pay FROM pos.payouts WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: pencairan' USING ERRCODE = 'P0001';
    END IF;
    IF v_pay.status NOT IN ('REQUESTED', 'PROCESSING') THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: pencairan sudah selesai diproses' USING ERRCODE = 'P0001';
    END IF;
    IF p_status NOT IN ('PROCESSING', 'PAID', 'REJECTED', 'FAILED') THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: status tidak dikenal' USING ERRCODE = 'P0001';
    END IF;
    IF p_status = 'PAID' AND (v_ref IS NULL OR pg_catalog.length(v_ref) < 3) THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: nomor referensi transfer wajib diisi' USING ERRCODE = 'P0001';
    END IF;
    IF p_status IN ('REJECTED', 'FAILED') AND (v_note IS NULL OR pg_catalog.length(v_note) < 5) THEN
        RAISE EXCEPTION 'PAYOUT_INVALID: alasan wajib diisi (min. 5 karakter)' USING ERRCODE = 'P0001';
    END IF;

    UPDATE pos.payouts SET status = p_status, provider_ref = coalesce(v_ref, provider_ref), note = coalesce(v_note, note),
        processed_by = v_actor, processed_at = CASE WHEN p_status = 'PROCESSING' THEN NULL ELSE now() END
    WHERE id = p_id;
    IF p_status IN ('REJECTED', 'FAILED') THEN
        INSERT INTO pos.merchant_ledger (organization_id, entry_type, amount, payout_id, description, created_by)
        VALUES (v_pay.organization_id, 'PAYOUT_REVERSAL', v_pay.amount, p_id,
                CASE p_status WHEN 'REJECTED' THEN 'Pencairan ditolak' ELSE 'Pencairan gagal' END, v_actor);
    END IF;
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value, reason)
    VALUES (v_pay.organization_id, v_actor, 'PAYOUT_' || p_status, 'PAYOUT', p_id::text,
            jsonb_build_object('amount', v_pay.amount, 'reference', v_ref), v_note);
END
$$;

CREATE OR REPLACE FUNCTION pos.platform_bank_accounts(p_pending_only boolean DEFAULT false)
RETURNS TABLE (organization_id uuid, merchant_code text, merchant_name text, bank_code text, account_number text,
               account_name text, status text, updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    RETURN QUERY
    SELECT b.organization_id, o.code, o.name, b.bank_code, b.account_number, b.account_name, b.status, b.updated_at
    FROM pos.merchant_bank_accounts b JOIN pos.organizations o ON o.id = b.organization_id
    WHERE NOT p_pending_only OR b.status = 'PENDING'
    ORDER BY (b.status = 'PENDING') DESC, b.updated_at DESC;
END
$$;

CREATE OR REPLACE FUNCTION pos.platform_verify_bank_account(p_org uuid, p_verified boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    UPDATE pos.merchant_bank_accounts
       SET status = CASE WHEN p_verified THEN 'VERIFIED' ELSE 'PENDING' END,
           verified_by = CASE WHEN p_verified THEN pos.current_app_user_id() END,
           verified_at = CASE WHEN p_verified THEN now() END
     WHERE organization_id = p_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: rekening' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (p_org, pos.current_app_user_id(), CASE WHEN p_verified THEN 'BANK_ACCOUNT_VERIFIED' ELSE 'BANK_ACCOUNT_UNVERIFIED' END,
            'ORGANIZATION', p_org::text, '{}'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION pos.platform_set_terms(p_org uuid, p_fee_percent numeric, p_fee_flat numeric,
                                                  p_hold_days integer, p_min_payout numeric)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    IF NOT EXISTS (SELECT 1 FROM pos.organizations WHERE id = p_org AND code <> 'PLATFORM') THEN
        RAISE EXCEPTION 'CATALOG_NOT_FOUND: merchant' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO pos.organization_payout_terms (organization_id, fee_percent, fee_flat, hold_days, min_payout)
    VALUES (p_org, p_fee_percent, p_fee_flat, p_hold_days, p_min_payout)
    ON CONFLICT (organization_id) DO UPDATE
        SET fee_percent = EXCLUDED.fee_percent, fee_flat = EXCLUDED.fee_flat, hold_days = EXCLUDED.hold_days,
            min_payout = EXCLUDED.min_payout, updated_at = now();
    INSERT INTO pos.audit_logs (organization_id, actor_user_id, action, entity_type, entity_id, new_value)
    VALUES (p_org, pos.current_app_user_id(), 'MERCHANT_TERMS_CHANGED', 'ORGANIZATION', p_org::text,
            jsonb_build_object('feePercent', p_fee_percent, 'feeFlat', p_fee_flat, 'holdDays', p_hold_days, 'minPayout', p_min_payout));
END
$$;

-- Kewajiban platform ke merchant: dasar rekonsiliasi dengan saldo rekening penampung.
CREATE OR REPLACE FUNCTION pos.platform_balances()
RETURNS TABLE (organization_id uuid, merchant_code text, merchant_name text, total numeric, available numeric,
               pending_payout numeric, fee_percent numeric, fee_flat numeric, hold_days integer, min_payout numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    PERFORM pos.require_perm('platform.manage', NULL);
    RETURN QUERY
    SELECT o.id, o.code, o.name,
           coalesce((SELECT sum(l.amount) FROM pos.merchant_ledger l WHERE l.organization_id = o.id), 0),
           coalesce((SELECT sum(l.amount) FROM pos.merchant_ledger l WHERE l.organization_id = o.id AND l.available_at <= now()), 0),
           coalesce((SELECT sum(p.amount) FROM pos.payouts p WHERE p.organization_id = o.id AND p.status IN ('REQUESTED', 'PROCESSING')), 0),
           (pos.payout_terms(o.id)).fee_percent, (pos.payout_terms(o.id)).fee_flat,
           (pos.payout_terms(o.id)).hold_days, (pos.payout_terms(o.id)).min_payout
    FROM pos.organizations o WHERE o.code <> 'PLATFORM' ORDER BY o.code;
END
$$;

DO $$
DECLARE f text;
BEGIN
    FOREACH f IN ARRAY ARRAY['my_balance()', 'save_bank_account(text,text,text)', 'request_payout(numeric)',
        'platform_payouts(text)', 'platform_process_payout(uuid,text,text,text)', 'platform_bank_accounts(boolean)',
        'platform_verify_bank_account(uuid,boolean)', 'platform_set_terms(uuid,numeric,numeric,integer,numeric)',
        'platform_balances()']
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION pos.%s FROM PUBLIC', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION pos.%s TO pos_app_user', f);
    END LOOP;
END
$$;

-- ---------------------------------------------------------------- menu
INSERT INTO pos.menu_items (code, label, route_name, required_any, sort_order) VALUES
    ('finance', 'Saldo & pencairan', 'finance', ARRAY['finance.manage'], 110),
    ('platform-payouts', 'Pencairan', 'platform-payouts', ARRAY['platform.manage'], 2);
INSERT INTO pos.menu_defaults (menu_code, role_code, enabled)
SELECT m.code, r.code,
       CASE m.code WHEN 'finance' THEN r.code IN ('OWNER', 'SUPER_ADMIN')
                   ELSE r.code = 'PLATFORM_ADMIN' END
FROM pos.menu_items m CROSS JOIN pos.roles r WHERE m.code IN ('finance', 'platform-payouts');

-- menu_matrix: sembunyikan menu platform dari pengaturan merchant (menggantikan filter V021)
CREATE OR REPLACE FUNCTION pos.menu_matrix()
RETURNS TABLE (menu_code text, label text, role_code text, enabled boolean, default_enabled boolean, sort_order integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pos
AS $$
BEGIN
    IF NOT pos.has_permission('menu.configure', NULL) THEN
        RAISE EXCEPTION 'USER_NOT_AUTHORIZED: menu.configure required' USING ERRCODE = 'P0001';
    END IF;
    RETURN QUERY
    SELECT m.code, m.label, r.code,
           coalesce(s.enabled, d.enabled, false), coalesce(d.enabled, false), m.sort_order
    FROM pos.menu_items m
    CROSS JOIN pos.roles r
    LEFT JOIN pos.menu_defaults d ON d.menu_code = m.code AND d.role_code = r.code
    LEFT JOIN pos.menu_settings s ON s.organization_id = pos.current_org_id()
                                 AND s.menu_code = m.code AND s.role_code = r.code
    WHERE r.code = ANY (pos.configurable_menu_roles()) AND m.code NOT IN ('platform', 'platform-payouts')
    ORDER BY m.sort_order, r.rank DESC;
END
$$;
