-- V004: audit log (append-only), idempotency keys, configuration

CREATE TABLE pos.audit_logs (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seq                bigint GENERATED ALWAYS AS IDENTITY,
    organization_id    uuid,
    actor_user_id      uuid,
    actor_employee_id  uuid,
    -- 'USER' untuk request user, 'SYSTEM' untuk job sistem
    actor_type         text        NOT NULL DEFAULT 'USER',
    action             text        NOT NULL,
    entity_type        text        NOT NULL,
    entity_id          text,
    outlet_id          uuid,
    terminal_id        uuid,
    old_value          jsonb,
    new_value          jsonb,
    reason             text,
    ip_address         inet,
    device_id          text,
    request_id         text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT audit_logs_actor_type_ck CHECK (actor_type IN ('USER', 'SYSTEM')),
    CONSTRAINT audit_logs_action_ck CHECK (action ~ '^[A-Z_]{2,64}$'),
    CONSTRAINT audit_logs_user_actor_ck CHECK (actor_type = 'SYSTEM' OR actor_user_id IS NOT NULL)
);

CREATE UNIQUE INDEX audit_logs_seq_uk ON pos.audit_logs (seq);
CREATE INDEX audit_logs_entity_idx ON pos.audit_logs (entity_type, entity_id);
CREATE INDEX audit_logs_created_idx ON pos.audit_logs (created_at);
CREATE INDEX audit_logs_actor_idx ON pos.audit_logs (actor_user_id, created_at);
CREATE INDEX audit_logs_outlet_idx ON pos.audit_logs (outlet_id, created_at);

-- Append-only untuk SEMUA role, termasuk owner (ASSUMPTIONS B9).
CREATE TRIGGER audit_logs_no_update BEFORE UPDATE OR DELETE ON pos.audit_logs
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();
CREATE TRIGGER audit_logs_no_truncate BEFORE TRUNCATE ON pos.audit_logs
    FOR EACH STATEMENT EXECUTE FUNCTION pos.tg_append_only();

-- Idempotency: satu key per user. request_hash mencegah key yang sama dipakai
-- untuk payload berbeda.
CREATE TABLE pos.idempotency_keys (
    user_id          uuid        NOT NULL,
    idempotency_key  text        NOT NULL,
    method           text        NOT NULL,
    path             text        NOT NULL,
    request_hash     text        NOT NULL,
    status           text        NOT NULL DEFAULT 'IN_PROGRESS',
    response_status  integer,
    response_body    jsonb,
    created_at       timestamptz NOT NULL DEFAULT now(),
    completed_at     timestamptz,
    expires_at       timestamptz NOT NULL DEFAULT now() + interval '7 days',
    PRIMARY KEY (user_id, idempotency_key),
    CONSTRAINT idempotency_status_ck CHECK (status IN ('IN_PROGRESS', 'COMPLETED')),
    CONSTRAINT idempotency_key_ck CHECK (pg_catalog.length(idempotency_key) BETWEEN 8 AND 128)
);

CREATE INDEX idempotency_expires_idx ON pos.idempotency_keys (expires_at);

-- Definisi setting (§73). Nilai default berlaku jika tidak ada override.
CREATE TABLE pos.setting_definitions (
    key            text PRIMARY KEY,
    value_type     text  NOT NULL,
    default_value  jsonb NOT NULL,
    description    text  NOT NULL,
    -- ORGANIZATION: hanya boleh di-override level org; OUTLET: boleh per outlet
    max_scope      text  NOT NULL DEFAULT 'OUTLET',
    CONSTRAINT setting_def_type_ck CHECK (value_type IN ('BOOLEAN', 'NUMBER', 'STRING', 'TIME')),
    CONSTRAINT setting_def_scope_ck CHECK (max_scope IN ('ORGANIZATION', 'OUTLET'))
);

CREATE TABLE pos.settings (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    outlet_id        uuid,
    key              text        NOT NULL REFERENCES pos.setting_definitions (key),
    value            jsonb       NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    version          integer     NOT NULL DEFAULT 0,
    CONSTRAINT settings_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id)
);

CREATE UNIQUE INDEX settings_scope_uk
    ON pos.settings (organization_id, outlet_id, key) NULLS NOT DISTINCT;

CREATE TRIGGER settings_touch BEFORE UPDATE ON pos.settings
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();

-- Validasi tipe & scope nilai setting.
CREATE OR REPLACE FUNCTION pos.tg_validate_setting()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    def pos.setting_definitions%ROWTYPE;
BEGIN
    SELECT * INTO def FROM pos.setting_definitions WHERE key = NEW.key;
    IF NEW.outlet_id IS NOT NULL AND def.max_scope = 'ORGANIZATION' THEN
        RAISE EXCEPTION 'SETTING_SCOPE_INVALID: % can only be set at organization level', NEW.key
            USING ERRCODE = 'P0001';
    END IF;
    IF (def.value_type = 'BOOLEAN' AND jsonb_typeof(NEW.value) <> 'boolean')
       OR (def.value_type = 'NUMBER' AND jsonb_typeof(NEW.value) <> 'number')
       OR (def.value_type IN ('STRING', 'TIME') AND jsonb_typeof(NEW.value) <> 'string')
       OR (def.value_type = 'TIME' AND (NEW.value #>> '{}') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') THEN
        RAISE EXCEPTION 'SETTING_VALUE_INVALID: % expects %', NEW.key, def.value_type
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER settings_validate BEFORE INSERT OR UPDATE ON pos.settings
    FOR EACH ROW EXECUTE FUNCTION pos.tg_validate_setting();

INSERT INTO pos.setting_definitions (key, value_type, default_value, description, max_scope) VALUES
    ('allow_negative_stock',                  'BOOLEAN', 'false',   'Izinkan penjualan saat stok tidak cukup', 'OUTLET'),
    ('allow_offline_sale',                    'BOOLEAN', 'false',   'Izinkan penjualan saat backend tidak terjangkau (CASH saja)', 'OUTLET'),
    ('allow_offline_negative_stock',          'BOOLEAN', 'false',   'Izinkan stok negatif saat offline', 'OUTLET'),
    ('max_offline_sale_amount',               'NUMBER',  '0',       'Batas nilai satu transaksi offline (0 = tidak boleh)', 'OUTLET'),
    ('max_offline_duration_minutes',          'NUMBER',  '0',       'Batas durasi offline sebelum penjualan diblokir', 'OUTLET'),
    ('cash_difference_approval_threshold',    'NUMBER',  '0',       'Selisih kas absolut yang mewajibkan approval supervisor', 'OUTLET'),
    ('max_cashier_discount',                  'NUMBER',  '0',       'Diskon maksimum (%) tanpa approval', 'OUTLET'),
    ('max_supervisor_discount',               'NUMBER',  '0',       'Diskon maksimum (%) dengan approval supervisor', 'OUTLET'),
    ('max_manager_discount',                  'NUMBER',  '0',       'Diskon maksimum (%) dengan approval manager', 'OUTLET'),
    ('require_customer',                      'BOOLEAN', 'false',   'Wajib memilih customer pada penjualan', 'OUTLET'),
    ('require_supervisor_for_refund',         'BOOLEAN', 'true',    'Refund wajib approval supervisor', 'OUTLET'),
    ('require_supervisor_for_void',           'BOOLEAN', 'true',    'Void wajib approval supervisor', 'OUTLET'),
    ('require_supervisor_for_price_override', 'BOOLEAN', 'true',    'Ubah harga wajib approval supervisor', 'OUTLET'),
    ('business_day_cutoff',                   'TIME',    '"04:00"', 'Jam pergantian business date (waktu lokal outlet)', 'OUTLET'),
    ('break_enabled',                         'BOOLEAN', 'true',    'Fitur break aktif', 'OUTLET'),
    ('cashier_handover_enabled',              'BOOLEAN', 'false',   'Fitur handover kasir aktif', 'OUTLET');
