package com.pirantisolution.pos.terminal;

import com.pirantisolution.pos.terminal.TerminalDtos.CreateDeviceRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.CreateTerminalRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.DeviceView;
import com.pirantisolution.pos.terminal.TerminalDtos.TerminalView;
import com.pirantisolution.pos.terminal.TerminalDtos.UpdateDeviceRequest;
import com.pirantisolution.pos.terminal.TerminalDtos.UpdateTerminalRequest;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
public class TerminalRepository {

    private static final String TERMINAL_SELECT = """
            SELECT t.id, t.outlet_id, o.code AS outlet_code, t.code, t.name, t.device_id,
                   t.printer_id, p.name AS printer_name, t.cash_drawer_id, d.name AS cash_drawer_name,
                   t.active, t.version, t.updated_at
            FROM pos.terminals t
            JOIN pos.outlets o ON o.id = t.outlet_id
            LEFT JOIN pos.devices p ON p.id = t.printer_id
            LEFT JOIN pos.devices d ON d.id = t.cash_drawer_id
            """;

    private static final String DEVICE_COLUMNS =
            "id, outlet_id, device_type, code, name, identifier, active, last_seen_at, version";

    private final JdbcClient jdbc;

    public TerminalRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public List<TerminalView> findTerminals(UUID outletIdOrNull) {
        if (outletIdOrNull == null) {
            return jdbc.sql(TERMINAL_SELECT + " ORDER BY o.code, t.code").query(TerminalView.class).list();
        }
        return jdbc.sql(TERMINAL_SELECT + " WHERE t.outlet_id = :o ORDER BY t.code")
                .param("o", outletIdOrNull).query(TerminalView.class).list();
    }

    public Optional<TerminalView> findTerminal(UUID id) {
        return jdbc.sql(TERMINAL_SELECT + " WHERE t.id = :id")
                .param("id", id).query(TerminalView.class).optional();
    }

    public UUID insertTerminal(CreateTerminalRequest req, UUID actorId) {
        return jdbc.sql("""
                INSERT INTO pos.terminals (outlet_id, code, name, device_id, printer_id, cash_drawer_id,
                                           created_by, updated_by)
                VALUES (:outlet, :code, :name, CAST(:device AS uuid), CAST(:printer AS uuid),
                        CAST(:drawer AS uuid), :actor, :actor)
                RETURNING id
                """)
                .param("outlet", req.outletId())
                .param("code", req.code())
                .param("name", req.name().trim())
                .param("device", req.deviceId())
                .param("printer", req.printerId())
                .param("drawer", req.cashDrawerId())
                .param("actor", actorId)
                .query(UUID.class).single();
    }

    /** Mengembalikan id jika versi cocok; kosong jika sudah diubah orang lain. */
    public Optional<UUID> updateTerminal(UUID id, UpdateTerminalRequest req, UUID actorId) {
        return jdbc.sql("""
                UPDATE pos.terminals
                SET name = :name, device_id = CAST(:device AS uuid), printer_id = CAST(:printer AS uuid),
                    cash_drawer_id = CAST(:drawer AS uuid), active = :active, updated_by = :actor
                WHERE id = :id AND version = :version
                RETURNING id
                """)
                .param("name", req.name().trim())
                .param("device", req.deviceId())
                .param("printer", req.printerId())
                .param("drawer", req.cashDrawerId())
                .param("active", req.active())
                .param("actor", actorId)
                .param("id", id)
                .param("version", req.version())
                .query(UUID.class).optional();
    }

    // ------------------------------------------------------------------ devices

    public List<DeviceView> findDevices(UUID outletIdOrNull) {
        if (outletIdOrNull == null) {
            return jdbc.sql("SELECT " + DEVICE_COLUMNS + " FROM pos.devices ORDER BY code")
                    .query(DeviceView.class).list();
        }
        return jdbc.sql("SELECT " + DEVICE_COLUMNS + " FROM pos.devices WHERE outlet_id = :o ORDER BY code")
                .param("o", outletIdOrNull).query(DeviceView.class).list();
    }

    public Optional<DeviceView> findDevice(UUID id) {
        return jdbc.sql("SELECT " + DEVICE_COLUMNS + " FROM pos.devices WHERE id = :id")
                .param("id", id).query(DeviceView.class).optional();
    }

    public DeviceView insertDevice(CreateDeviceRequest req, UUID actorId) {
        return jdbc.sql("INSERT INTO pos.devices (outlet_id, device_type, code, name, identifier, created_by, updated_by) "
                        + "VALUES (:outlet, :type, :code, :name, :identifier, :actor, :actor) "
                        + "RETURNING " + DEVICE_COLUMNS)
                .param("outlet", req.outletId())
                .param("type", req.deviceType())
                .param("code", req.code())
                .param("name", req.name().trim())
                .param("identifier", req.identifier())
                .param("actor", actorId)
                .query(DeviceView.class).single();
    }

    public Optional<DeviceView> updateDevice(UUID id, UpdateDeviceRequest req, UUID actorId) {
        return jdbc.sql("UPDATE pos.devices SET name = :name, identifier = :identifier, active = :active, "
                        + "updated_by = :actor WHERE id = :id AND version = :version "
                        + "RETURNING " + DEVICE_COLUMNS)
                .param("name", req.name().trim())
                .param("identifier", req.identifier())
                .param("active", req.active())
                .param("actor", actorId)
                .param("id", id)
                .param("version", req.version())
                .query(DeviceView.class).optional();
    }

    /** Device masih dipakai oleh terminal aktif? (mencegah menonaktifkan printer yang terpasang) */
    public boolean deviceInUse(UUID deviceId) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM pos.terminals
                               WHERE active AND (device_id = :d OR printer_id = :d OR cash_drawer_id = :d))
                """)
                .param("d", deviceId).query(Boolean.class).single();
    }
}
