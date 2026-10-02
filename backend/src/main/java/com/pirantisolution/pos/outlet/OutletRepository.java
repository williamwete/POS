package com.pirantisolution.pos.outlet;

import com.pirantisolution.pos.outlet.OutletDtos.OutletView;
import com.pirantisolution.pos.outlet.OutletDtos.WarehouseView;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Akses data outlet & warehouse. Semua query berjalan di bawah RLS (pos_app_user),
 * sehingga baris di luar scope user tidak pernah terlihat.
 */
@Repository
public class OutletRepository {

    private static final String OUTLET_COLUMNS = """
            id, organization_id, code, name, address, phone, timezone, default_warehouse_id,
            active, version, created_at, updated_at
            """;

    private final JdbcClient jdbc;

    public OutletRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public List<OutletView> findAll() {
        return jdbc.sql("SELECT " + OUTLET_COLUMNS + " FROM pos.outlets ORDER BY code")
                .query(OutletView.class).list();
    }

    public Optional<OutletView> findById(UUID id) {
        return jdbc.sql("SELECT " + OUTLET_COLUMNS + " FROM pos.outlets WHERE id = :id")
                .param("id", id).query(OutletView.class).optional();
    }

    public OutletView insert(OutletDtos.CreateOutletRequest req, String timezone, UUID actorId) {
        return jdbc.sql("""
                INSERT INTO pos.outlets (organization_id, code, name, address, phone, timezone, created_by, updated_by)
                VALUES (pos.current_org_id(), :code, :name, :address, :phone, :tz, :actor, :actor)
                RETURNING """ + " " + OUTLET_COLUMNS)
                .param("code", req.code())
                .param("name", req.name().trim())
                .param("address", req.address())
                .param("phone", req.phone())
                .param("tz", timezone)
                .param("actor", actorId)
                .query(OutletView.class).single();
    }

    public Optional<OutletView> update(UUID id, OutletDtos.UpdateOutletRequest req, String timezone, UUID actorId) {
        return jdbc.sql("""
                UPDATE pos.outlets
                SET name = :name, address = :address, phone = :phone, timezone = :tz,
                    default_warehouse_id = CAST(:wh AS uuid), active = :active, updated_by = :actor
                WHERE id = :id AND version = :version
                RETURNING """ + " " + OUTLET_COLUMNS)
                .param("name", req.name().trim())
                .param("address", req.address())
                .param("phone", req.phone())
                .param("tz", timezone)
                .param("wh", req.defaultWarehouseId())
                .param("active", req.active())
                .param("actor", actorId)
                .param("id", id)
                .param("version", req.version())
                .query(OutletView.class).optional();
    }

    // ------------------------------------------------------------------ warehouses

    private static final String WAREHOUSE_COLUMNS = "id, organization_id, outlet_id, code, name, active, version";

    public List<WarehouseView> findWarehouses(UUID outletIdOrNull) {
        if (outletIdOrNull == null) {
            return jdbc.sql("SELECT " + WAREHOUSE_COLUMNS + " FROM pos.warehouses ORDER BY code")
                    .query(WarehouseView.class).list();
        }
        return jdbc.sql("SELECT " + WAREHOUSE_COLUMNS + " FROM pos.warehouses WHERE outlet_id = :o ORDER BY code")
                .param("o", outletIdOrNull)
                .query(WarehouseView.class).list();
    }

    public Optional<WarehouseView> findWarehouse(UUID id) {
        return jdbc.sql("SELECT " + WAREHOUSE_COLUMNS + " FROM pos.warehouses WHERE id = :id")
                .param("id", id).query(WarehouseView.class).optional();
    }

    public WarehouseView insertWarehouse(OutletDtos.CreateWarehouseRequest req, UUID actorId) {
        return jdbc.sql("""
                INSERT INTO pos.warehouses (organization_id, outlet_id, code, name, created_by, updated_by)
                VALUES (pos.current_org_id(), CAST(:outlet AS uuid), :code, :name, :actor, :actor)
                RETURNING """ + " " + WAREHOUSE_COLUMNS)
                .param("outlet", req.outletId())
                .param("code", req.code())
                .param("name", req.name().trim())
                .param("actor", actorId)
                .query(WarehouseView.class).single();
    }
}
