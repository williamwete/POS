package com.pirantisolution.pos.outlet;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.outlet.OutletDtos.CreateOutletRequest;
import com.pirantisolution.pos.outlet.OutletDtos.CreateWarehouseRequest;
import com.pirantisolution.pos.outlet.OutletDtos.OutletView;
import com.pirantisolution.pos.outlet.OutletDtos.UpdateOutletRequest;
import com.pirantisolution.pos.outlet.OutletDtos.WarehouseView;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class OutletService {

    static final String PERM_MANAGE = "outlet.manage";

    private final OutletRepository repo;
    private final AccessService access;
    private final AuditService audit;

    public OutletService(OutletRepository repo, AccessService access, AuditService audit) {
        this.repo = repo;
        this.access = access;
        this.audit = audit;
    }

    /** Outlet yang dapat diakses user (RLS). */
    @Transactional(readOnly = true)
    public List<OutletView> list() {
        access.currentUser();
        return repo.findAll();
    }

    @Transactional(readOnly = true)
    public OutletView get(UUID id) {
        access.requireOutletAccess(id);
        return repo.findById(id).orElseThrow(() -> ApiException.notFound("Outlet"));
    }

    @Transactional
    public OutletView create(CreateOutletRequest req) {
        access.requireOrg(PERM_MANAGE);
        CurrentUser cu = access.currentUser();
        String tz = Guards.validTimezoneOrNull(req.timezone());
        OutletView created = repo.insert(req, tz, cu.userId());
        audit.record(AuditEvent.of("OUTLET_CREATED", "OUTLET", created.id())
                .outlet(created.id()).change(null, created));
        return created;
    }

    @Transactional
    public OutletView update(UUID id, UpdateOutletRequest req) {
        access.requireOrg(PERM_MANAGE);
        access.requireOutletAccess(id);
        CurrentUser cu = access.currentUser();
        OutletView before = repo.findById(id).orElseThrow(() -> ApiException.notFound("Outlet"));
        if (req.defaultWarehouseId() != null) {
            WarehouseView wh = repo.findWarehouse(req.defaultWarehouseId())
                    .orElseThrow(() -> ApiException.validation("Warehouse tidak ditemukan"));
            if (wh.outletId() != null && !Objects.equals(wh.outletId(), id)) {
                throw ApiException.validation("Warehouse milik outlet lain");
            }
        }
        String tz = Guards.validTimezoneOrNull(req.timezone());
        OutletView after = Guards.requireUpdated(repo.update(id, req, tz, cu.userId()));
        audit.record(AuditEvent.of("OUTLET_UPDATED", "OUTLET", id).outlet(id).change(before, after));
        return after;
    }

    @Transactional(readOnly = true)
    public List<WarehouseView> warehouses(UUID outletId) {
        if (outletId != null) {
            access.requireOutletAccess(outletId);
        } else {
            access.currentUser();
        }
        return repo.findWarehouses(outletId);
    }

    @Transactional
    public WarehouseView createWarehouse(CreateWarehouseRequest req) {
        access.requireOrg(PERM_MANAGE);
        if (req.outletId() != null) {
            access.requireOutletAccess(req.outletId());
        }
        CurrentUser cu = access.currentUser();
        WarehouseView created = repo.insertWarehouse(req, cu.userId());
        audit.record(AuditEvent.of("WAREHOUSE_CREATED", "WAREHOUSE", created.id())
                .outlet(created.outletId()).change(null, created));
        return created;
    }
}
