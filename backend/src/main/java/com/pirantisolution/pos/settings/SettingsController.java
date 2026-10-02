package com.pirantisolution.pos.settings;

import com.fasterxml.jackson.databind.JsonNode;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Konfigurasi efektif (§73) per outlet: override outlet -> organisasi -> default.
 * Phase 1 hanya baca; pengubahan konfigurasi lewat UI ditambahkan saat setting dipakai.
 */
@RestController
public class SettingsController {

    private final SettingsService service;

    public SettingsController(SettingsService service) {
        this.service = service;
    }

    @GetMapping("/api/settings/effective")
    public ResponseEntity<ApiResponse<Map<String, JsonNode>>> effective(@RequestParam(required = false) UUID outletId) {
        return Responses.ok(service.effective(outletId));
    }
}
