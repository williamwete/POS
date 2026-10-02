package com.pirantisolution.pos.outlet;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.idempotency.IdempotencyService;
import com.pirantisolution.pos.outlet.OutletDtos.CreateOutletRequest;
import com.pirantisolution.pos.outlet.OutletDtos.CreateWarehouseRequest;
import com.pirantisolution.pos.outlet.OutletDtos.OutletView;
import com.pirantisolution.pos.outlet.OutletDtos.UpdateOutletRequest;
import com.pirantisolution.pos.outlet.OutletDtos.WarehouseView;
import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class OutletController {

    private final OutletService service;
    private final IdempotencyService idempotency;

    public OutletController(OutletService service, IdempotencyService idempotency) {
        this.service = service;
        this.idempotency = idempotency;
    }

    @GetMapping("/api/outlets")
    public ResponseEntity<ApiResponse<List<OutletView>>> list() {
        return Responses.ok(service.list());
    }

    @GetMapping("/api/outlets/{id}")
    public ResponseEntity<ApiResponse<OutletView>> get(@PathVariable UUID id) {
        return Responses.ok(service.get(id));
    }

    @PostMapping("/api/outlets")
    public ResponseEntity<?> create(@Valid @RequestBody CreateOutletRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/outlets", req,
                () -> Responses.created(service.create(req), "Outlet dibuat"));
    }

    @PutMapping("/api/outlets/{id}")
    public ResponseEntity<ApiResponse<OutletView>> update(@PathVariable UUID id,
            @Valid @RequestBody UpdateOutletRequest req) {
        return Responses.ok(service.update(id, req), "Outlet diperbarui");
    }

    @GetMapping("/api/warehouses")
    public ResponseEntity<ApiResponse<List<WarehouseView>>> warehouses(
            @RequestParam(required = false) UUID outletId) {
        return Responses.ok(service.warehouses(outletId));
    }

    @PostMapping("/api/warehouses")
    public ResponseEntity<?> createWarehouse(@Valid @RequestBody CreateWarehouseRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/warehouses", req,
                () -> Responses.created(service.createWarehouse(req), "Warehouse dibuat"));
    }
}
