-- V009: attendance & break (§11, §12)
--
-- Prinsip:
--  * Waktu SELALU dari server database (now()); client tidak pernah mengirim jam.
--  * Satu attendance terbuka (WORKING/ON_BREAK) per karyawan — dijamin unique index.
--  * Transisi status divalidasi trigger; baris yang sudah selesai tidak bisa diubah.
--  * Tidak ada DELETE (koreksi kehadiran = fitur terpisah dengan approval, bukan hapus).
--  * Attendance terpisah dari cashier session (Phase 3). Pemeriksaan "tidak boleh clock out
--    selama cashier session OPEN" ditambahkan di migration Phase 3 pada trigger yang sama.

CREATE TABLE pos.attendance (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid        NOT NULL REFERENCES pos.organizations (id),
    employee_id        uuid        NOT NULL,
    outlet_id          uuid        NOT NULL,
    business_date      date        NOT NULL,
    clock_in           timestamptz NOT NULL DEFAULT now(),
    clock_out          timestamptz,
    status             text        NOT NULL DEFAULT 'WORKING',
    device_id          text,
    clock_in_by        uuid        NOT NULL,
    clock_out_by       uuid,
    forced_reason      text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    version            integer     NOT NULL DEFAULT 0,
    CONSTRAINT attendance_status_ck CHECK (status IN ('WORKING', 'ON_BREAK', 'COMPLETED', 'FORCED_CLOSED')),
    CONSTRAINT attendance_employee_fk FOREIGN KEY (employee_id, organization_id)
        REFERENCES pos.employees (id, organization_id),
    CONSTRAINT attendance_outlet_fk FOREIGN KEY (outlet_id, organization_id)
        REFERENCES pos.outlets (id, organization_id),
    CONSTRAINT attendance_closed_ck CHECK (
        (status IN ('WORKING', 'ON_BREAK') AND clock_out IS NULL AND clock_out_by IS NULL)
        OR (status IN ('COMPLETED', 'FORCED_CLOSED') AND clock_out IS NOT NULL AND clock_out_by IS NOT NULL)),
    CONSTRAINT attendance_order_ck CHECK (clock_out IS NULL OR clock_out >= clock_in),
    CONSTRAINT attendance_forced_reason_ck CHECK (
        status <> 'FORCED_CLOSED' OR pg_catalog.length(btrim(forced_reason)) >= 5)
);

-- Satu attendance terbuka per karyawan (mencegah double clock-in, termasuk request paralel).
CREATE UNIQUE INDEX attendance_open_per_employee_uk
    ON pos.attendance (employee_id) WHERE status IN ('WORKING', 'ON_BREAK');
CREATE INDEX attendance_employee_idx ON pos.attendance (employee_id, clock_in DESC);
CREATE INDEX attendance_outlet_date_idx ON pos.attendance (outlet_id, business_date);
CREATE INDEX attendance_business_date_idx ON pos.attendance (business_date);

CREATE TABLE pos.attendance_breaks (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    attendance_id     uuid        NOT NULL REFERENCES pos.attendance (id),
    break_start       timestamptz NOT NULL DEFAULT now(),
    break_end         timestamptz,
    duration_seconds  integer,
    reason            text,
    ended_by          uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT breaks_order_ck CHECK (break_end IS NULL OR break_end >= break_start),
    CONSTRAINT breaks_duration_ck CHECK (
        (break_end IS NULL AND duration_seconds IS NULL)
        OR (break_end IS NOT NULL AND duration_seconds IS NOT NULL AND duration_seconds >= 0))
);

CREATE UNIQUE INDEX attendance_breaks_open_uk ON pos.attendance_breaks (attendance_id) WHERE break_end IS NULL;
CREATE INDEX attendance_breaks_attendance_idx ON pos.attendance_breaks (attendance_id);

-- ---------------------------------------------------------------- integritas transisi
CREATE OR REPLACE FUNCTION pos.tg_attendance_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'WORKING' THEN
            RAISE EXCEPTION 'ATTENDANCE_INVALID_TRANSITION: new attendance must start WORKING' USING ERRCODE = 'P0001';
        END IF;
        -- Waktu & business date ditentukan server, bukan client.
        NEW.clock_in := now();
        NEW.business_date := pos.business_date(NEW.clock_in, NEW.outlet_id);
        RETURN NEW;
    END IF;

    -- UPDATE
    IF OLD.status IN ('COMPLETED', 'FORCED_CLOSED') THEN
        RAISE EXCEPTION 'ATTENDANCE_CLOSED: attendance % is already closed', OLD.id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.employee_id <> OLD.employee_id OR NEW.outlet_id <> OLD.outlet_id
       OR NEW.organization_id <> OLD.organization_id OR NEW.clock_in <> OLD.clock_in
       OR NEW.business_date <> OLD.business_date OR NEW.clock_in_by <> OLD.clock_in_by THEN
        RAISE EXCEPTION 'ATTENDANCE_IMMUTABLE_FIELD: identity and clock-in cannot change' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (
           (OLD.status = 'WORKING'  AND NEW.status IN ('WORKING', 'ON_BREAK', 'COMPLETED', 'FORCED_CLOSED'))
        OR (OLD.status = 'ON_BREAK' AND NEW.status IN ('ON_BREAK', 'WORKING', 'FORCED_CLOSED'))
    ) THEN
        RAISE EXCEPTION 'ATTENDANCE_INVALID_TRANSITION: % -> %', OLD.status, NEW.status USING ERRCODE = 'P0001';
    END IF;
    IF NEW.status IN ('COMPLETED', 'FORCED_CLOSED') THEN
        NEW.clock_out := now();
        -- Clock out normal tidak boleh selagi break masih terbuka (force clock out menutupnya lebih dulu).
        IF EXISTS (SELECT 1 FROM pos.attendance_breaks b WHERE b.attendance_id = OLD.id AND b.break_end IS NULL) THEN
            RAISE EXCEPTION 'BREAK_IN_PROGRESS: end the break before clocking out' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    NEW.updated_at := now();
    NEW.version := OLD.version + 1;
    RETURN NEW;
END
$$;

CREATE TRIGGER attendance_guard BEFORE INSERT OR UPDATE ON pos.attendance
    FOR EACH ROW EXECUTE FUNCTION pos.tg_attendance_guard();
CREATE TRIGGER attendance_no_delete BEFORE DELETE ON pos.attendance
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

CREATE OR REPLACE FUNCTION pos.tg_attendance_break_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status text;
BEGIN
    SELECT a.status INTO v_status FROM pos.attendance a WHERE a.id = NEW.attendance_id;
    IF TG_OP = 'INSERT' THEN
        IF v_status IS DISTINCT FROM 'WORKING' THEN
            RAISE EXCEPTION 'ATTENDANCE_NOT_WORKING: break can only start while WORKING' USING ERRCODE = 'P0001';
        END IF;
        NEW.break_start := now();
        NEW.break_end := NULL;
        NEW.duration_seconds := NULL;
        RETURN NEW;
    END IF;

    -- UPDATE: hanya menutup break yang masih terbuka.
    IF OLD.break_end IS NOT NULL THEN
        RAISE EXCEPTION 'BREAK_CLOSED: break % already ended', OLD.id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.attendance_id <> OLD.attendance_id OR NEW.break_start <> OLD.break_start THEN
        RAISE EXCEPTION 'BREAK_IMMUTABLE_FIELD' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.break_end IS NULL THEN
        RAISE EXCEPTION 'BREAK_INVALID_UPDATE: only ending a break is allowed' USING ERRCODE = 'P0001';
    END IF;
    NEW.break_end := now();
    NEW.duration_seconds := GREATEST(0, floor(extract(epoch FROM (NEW.break_end - OLD.break_start))))::integer;
    RETURN NEW;
END
$$;

CREATE TRIGGER attendance_breaks_guard BEFORE INSERT OR UPDATE ON pos.attendance_breaks
    FOR EACH ROW EXECUTE FUNCTION pos.tg_attendance_break_guard();
CREATE TRIGGER attendance_breaks_no_delete BEFORE DELETE ON pos.attendance_breaks
    FOR EACH ROW EXECUTE FUNCTION pos.tg_append_only();

-- ---------------------------------------------------------------- privileges & RLS
GRANT SELECT, INSERT, UPDATE ON pos.attendance, pos.attendance_breaks TO pos_app_user, pos_system;

ALTER TABLE pos.attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos.attendance_breaks ENABLE ROW LEVEL SECURITY;

CREATE POLICY attendance_system_all ON pos.attendance TO pos_system USING (true) WITH CHECK (true);
CREATE POLICY attendance_breaks_system_all ON pos.attendance_breaks TO pos_system USING (true) WITH CHECK (true);

-- Lihat: kehadiran sendiri, atau attendance.view di outlet tersebut.
CREATE POLICY attendance_select ON pos.attendance FOR SELECT TO pos_app_user
    USING (
        organization_id = pos.current_org_id()
        AND (employee_id = pos.current_employee_id() OR pos.has_permission('attendance.view', outlet_id))
    );

-- Clock in hanya untuk diri sendiri, dengan izin di outlet tersebut.
CREATE POLICY attendance_insert ON pos.attendance FOR INSERT TO pos_app_user
    WITH CHECK (
        organization_id = pos.current_org_id()
        AND employee_id = pos.current_employee_id()
        AND clock_in_by = pos.current_app_user_id()
        AND pos.has_permission('attendance.clock_in', outlet_id)
    );

-- Ubah: milik sendiri (break / clock out), atau force clock out karyawan lain dengan izin.
CREATE POLICY attendance_update_own ON pos.attendance FOR UPDATE TO pos_app_user
    USING (employee_id = pos.current_employee_id() AND organization_id = pos.current_org_id())
    WITH CHECK (
        employee_id = pos.current_employee_id()
        AND status IN ('WORKING', 'ON_BREAK', 'COMPLETED')
        AND (clock_out_by IS NULL OR (clock_out_by = pos.current_app_user_id()
                                      AND pos.has_permission('attendance.clock_out', outlet_id)))
    );

CREATE POLICY attendance_update_force ON pos.attendance FOR UPDATE TO pos_app_user
    USING (
        organization_id = pos.current_org_id()
        AND employee_id IS DISTINCT FROM pos.current_employee_id()
        AND pos.has_permission('attendance.force_clock_out', outlet_id)
    )
    WITH CHECK (
        status = 'FORCED_CLOSED'
        AND clock_out_by = pos.current_app_user_id()
        AND employee_id IS DISTINCT FROM pos.current_employee_id()
        AND pos.has_permission('attendance.force_clock_out', outlet_id)
    );

-- Break mengikuti visibilitas attendance-nya (subquery tunduk RLS attendance).
CREATE POLICY attendance_breaks_select ON pos.attendance_breaks FOR SELECT TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.attendance a WHERE a.id = attendance_id));

CREATE POLICY attendance_breaks_insert ON pos.attendance_breaks FOR INSERT TO pos_app_user
    WITH CHECK (EXISTS (SELECT 1 FROM pos.attendance a
                        WHERE a.id = attendance_id AND a.employee_id = pos.current_employee_id()));

-- Menutup break: pemiliknya, atau supervisor yang melakukan force clock out.
CREATE POLICY attendance_breaks_update ON pos.attendance_breaks FOR UPDATE TO pos_app_user
    USING (EXISTS (SELECT 1 FROM pos.attendance a
                   WHERE a.id = attendance_id
                     AND (a.employee_id = pos.current_employee_id()
                          OR pos.has_permission('attendance.force_clock_out', a.outlet_id))))
    WITH CHECK (ended_by = pos.current_app_user_id());
