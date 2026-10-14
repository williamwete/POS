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

    public record AttendanceRequiredRequest(@jakarta.validation.constraints.NotNull Boolean required) {
    }

    @org.springframework.web.bind.annotation.PutMapping("/api/settings/attendance-required")
    public ResponseEntity<ApiResponse<Map<String, Boolean>>> attendanceRequired(
            @jakarta.validation.Valid @org.springframework.web.bind.annotation.RequestBody AttendanceRequiredRequest req) {
        service.setAttendanceRequired(req.required());
        return Responses.ok(Map.of("required", req.required()));
    }

    public record OfflineSettingsRequest(
            @jakarta.validation.constraints.NotNull Boolean allow,
            @jakarta.validation.constraints.NotNull @jakarta.validation.constraints.DecimalMin("0")
            @jakarta.validation.constraints.DecimalMax("100000000") java.math.BigDecimal maxAmount,
            @jakarta.validation.constraints.NotNull @jakarta.validation.constraints.Min(0)
            @jakarta.validation.constraints.Max(10080) Integer maxMinutes) {
    }

    @org.springframework.web.bind.annotation.PutMapping("/api/settings/offline")
    public ResponseEntity<ApiResponse<Map<String, Boolean>>> offline(
            @jakarta.validation.Valid @org.springframework.web.bind.annotation.RequestBody OfflineSettingsRequest req) {
        service.setOfflineSettings(req.allow(), req.maxAmount(), req.maxMinutes());
        return Responses.ok(Map.of("allow", req.allow()));
    }
}
