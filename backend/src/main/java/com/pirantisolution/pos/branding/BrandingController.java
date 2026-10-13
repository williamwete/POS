package com.pirantisolution.pos.branding;

import com.pirantisolution.pos.branding.BrandingDtos.BrandingView;
import com.pirantisolution.pos.branding.BrandingDtos.SaveBrandingRequest;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class BrandingController {

    private final BrandingService service;

    public BrandingController(BrandingService service) {
        this.service = service;
    }

    @GetMapping("/api/branding")
    public ResponseEntity<ApiResponse<BrandingView>> get() {
        return Responses.ok(service.get());
    }

    @PutMapping("/api/branding")
    public ResponseEntity<ApiResponse<BrandingView>> save(@Valid @RequestBody SaveBrandingRequest req) {
        return Responses.ok(service.save(req), "Branding disimpan");
    }
}
