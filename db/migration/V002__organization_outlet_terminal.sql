-- V002: organization, outlet, warehouse, device, terminal

CREATE TABLE pos.organizations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code            text        NOT NULL,
    name            text        NOT NULL,
    timezone        text        NOT NULL DEFAULT 'Asia/Jakarta',
    currency        char(3)     NOT NULL DEFAULT 'IDR',
    active          boolean     NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid,
    version         integer     NOT NULL DEFAULT 0,
    CONSTRAINT organizations_code_uk UNIQUE (code),
    CONSTRAINT organizations_code_ck CHECK (code ~ '^[A-Z0-9_-]{2,32}$'),
    CONSTRAINT organizations_tz_ck CHECK (pg_catalog.length(timezone) > 0)
);

CREATE TABLE pos.outlets (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       uuid        NOT NULL REFERENCES pos.organizations (id),
    code                  text        NOT NULL,
    name                  text        NOT NULL,
    address               text,
    phone                 text,
    -- NULL => ikuti timezone organisasi
    timezone              text,
    default_warehouse_id  uuid,
    active                boolean     NOT NULL DEFAULT true,
    deleted_at            timestamptz,
    deleted_by            uuid,
    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid,
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            uuid,
    version               integer     NOT NULL DEFAULT 0,
    CONSTRAINT outlets_org_code_uk UNIQUE (organization_id, code),
    CONSTRAINT outlets_code_ck CHECK (code ~ '^[A-Z0-9_-]{2,32}$'),
    -- dipakai sebagai target composite FK agar child selalu satu organisasi
    CONSTRAINT outlets_id_org_uk UNIQUE (id, organization_id)
);

CREATE TABLE pos.warehouses (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES pos.organizations (id),
    outlet_id        uuid,
    code             text        NOT NULL,
    name             text        NOT NULL,
    active           boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid,
    version          integer     NOT NULL DEFAULT 0,
    CONSTRAINT warehouses_org_code_uk UNIQUE (organization_id, code),
    CONSTRAINT warehouses_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id)
);

ALTER TABLE pos.outlets
    ADD CONSTRAINT outlets_default_warehouse_fk
    FOREIGN KEY (default_warehouse_id) REFERENCES pos.warehouses (id);

CREATE TABLE pos.devices (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    outlet_id    uuid        NOT NULL REFERENCES pos.outlets (id),
    device_type  text        NOT NULL,
    code         text        NOT NULL,
    name         text        NOT NULL,
    -- alamat IP printer, serial number, fingerprint browser, dsb.
    identifier   text,
    config       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    active       boolean     NOT NULL DEFAULT true,
    last_seen_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid,
    version      integer     NOT NULL DEFAULT 0,
    CONSTRAINT devices_type_ck CHECK (device_type IN
        ('BROWSER', 'PRINTER', 'CASH_DRAWER', 'SCANNER', 'CUSTOMER_DISPLAY')),
    CONSTRAINT devices_outlet_code_uk UNIQUE (outlet_id, code),
    CONSTRAINT devices_id_outlet_uk UNIQUE (id, outlet_id),
    CONSTRAINT devices_id_outlet_type_uk UNIQUE (id, outlet_id, device_type)
);

CREATE TABLE pos.terminals (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    outlet_id              uuid        NOT NULL REFERENCES pos.outlets (id),
    code                   text        NOT NULL,
    name                   text        NOT NULL,
    -- device yang terikat (browser/PC kasir), printer struk dan laci kas.
    device_id              uuid,
    device_type            text GENERATED ALWAYS AS ('BROWSER') STORED,
    printer_id             uuid,
    printer_type           text GENERATED ALWAYS AS ('PRINTER') STORED,
    cash_drawer_id         uuid,
    cash_drawer_type       text GENERATED ALWAYS AS ('CASH_DRAWER') STORED,
    active                 boolean     NOT NULL DEFAULT true,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid,
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid,
    version                integer     NOT NULL DEFAULT 0,
    -- kode terminal unik global karena menjadi prefix nomor struk (ASSUMPTIONS B7)
    CONSTRAINT terminals_code_uk UNIQUE (code),
    CONSTRAINT terminals_code_ck CHECK (code ~ '^[A-Z0-9_-]{2,32}$'),
    -- device harus berada di outlet yang sama dan bertipe benar
    CONSTRAINT terminals_device_fk FOREIGN KEY (device_id, outlet_id, device_type)
        REFERENCES pos.devices (id, outlet_id, device_type),
    CONSTRAINT terminals_printer_fk FOREIGN KEY (printer_id, outlet_id, printer_type)
        REFERENCES pos.devices (id, outlet_id, device_type),
    CONSTRAINT terminals_cash_drawer_fk FOREIGN KEY (cash_drawer_id, outlet_id, cash_drawer_type)
        REFERENCES pos.devices (id, outlet_id, device_type)
);

-- Satu device browser hanya boleh terikat ke satu terminal aktif.
CREATE UNIQUE INDEX terminals_active_device_uk
    ON pos.terminals (device_id) WHERE device_id IS NOT NULL AND active;

CREATE INDEX outlets_org_idx ON pos.outlets (organization_id);
CREATE INDEX warehouses_outlet_idx ON pos.warehouses (outlet_id);
CREATE INDEX devices_outlet_idx ON pos.devices (outlet_id);
CREATE INDEX terminals_outlet_idx ON pos.terminals (outlet_id);

CREATE TRIGGER organizations_touch BEFORE UPDATE ON pos.organizations
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();
CREATE TRIGGER outlets_touch BEFORE UPDATE ON pos.outlets
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();
CREATE TRIGGER warehouses_touch BEFORE UPDATE ON pos.warehouses
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();
CREATE TRIGGER devices_touch BEFORE UPDATE ON pos.devices
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();
CREATE TRIGGER terminals_touch BEFORE UPDATE ON pos.terminals
    FOR EACH ROW EXECUTE FUNCTION pos.tg_touch_row();

-- Master organisasi tidak boleh dihapus fisik (soft delete via active/deleted_at).
CREATE TRIGGER organizations_no_delete BEFORE DELETE ON pos.organizations
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();
CREATE TRIGGER outlets_no_delete BEFORE DELETE ON pos.outlets
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();
CREATE TRIGGER terminals_no_delete BEFORE DELETE ON pos.terminals
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();
