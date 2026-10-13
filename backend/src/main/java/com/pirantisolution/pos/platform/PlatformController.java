package com.pirantisolution.pos.platform;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.platform.PlatformDtos.ActiveRequest;
import com.pirantisolution.pos.platform.PlatformDtos.CreateMerchantRequest;
import com.pirantisolution.pos.platform.PlatformDtos.CreatedMerchant;
import com.pirantisolution.pos.platform.PlatformDtos.MerchantRow;
import com.pirantisolution.pos.platform.PlatformDtos.MerchantUserRow;
import com.pirantisolution.pos.platform.PlatformDtos.PlanRequest;
import com.pirantisolution.pos.platform.PlatformDtos.PlanRow;
import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class PlatformController {

    private final PlatformService service;

    public PlatformController(PlatformService service) {
        this.service = service;
    }

    @GetMapping("/api/platform/plans")
    public ResponseEntity<ApiResponse<List<PlanRow>>> plans() {
        return Responses.ok(service.plans());
    }

    @GetMapping("/api/platform/merchants")
    public ResponseEntity<ApiResponse<List<MerchantRow>>> merchants() {
        return Responses.ok(service.merchants());
    }

    @PostMapping("/api/platform/merchants")
    public ResponseEntity<ApiResponse<CreatedMerchant>> create(@Valid @RequestBody CreateMerchantRequest req) {
        return Responses.created(service.create(req), "Merchant dibuat");
    }

    @GetMapping("/api/platform/merchants/{id}/users")
    public ResponseEntity<ApiResponse<List<MerchantUserRow>>> users(@PathVariable UUID id) {
        return Responses.ok(service.users(id));
    }

    @PutMapping("/api/platform/merchants/{id}/plan")
    public ResponseEntity<ApiResponse<MerchantRow>> plan(@PathVariable UUID id, @Valid @RequestBody PlanRequest req) {
        return Responses.ok(service.setPlan(id, req.plan()));
    }

    @PutMapping("/api/platform/merchants/{id}/active")
    public ResponseEntity<ApiResponse<MerchantRow>> active(@PathVariable UUID id, @Valid @RequestBody ActiveRequest req) {
        return Responses.ok(service.setActive(id, req.active(), req.reason()));
    }
}
