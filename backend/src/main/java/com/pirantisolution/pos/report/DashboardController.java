package com.pirantisolution.pos.report;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.security.AccessService;
import java.time.LocalDate;
import java.util.UUID;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Dasbor penjualan & closing. Seluruh perhitungan di database (pos.dashboard) agar angka dan izin satu sumber. */
@RestController
public class DashboardController {

    private final JdbcClient jdbc;
    private final AccessService access;
    private final ObjectMapper mapper;

    public DashboardController(JdbcClient jdbc, AccessService access, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.access = access;
        this.mapper = mapper;
    }

    @GetMapping("/api/dashboard")
    @Transactional(readOnly = true)
    public ResponseEntity<ApiResponse<JsonNode>> dashboard(
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to,
            @RequestParam(required = false) UUID outletId) {
        access.currentUser();
        String json = jdbc.sql("SELECT pos.dashboard(:f, :t, CAST(:o AS uuid))::text")
                .param("f", from).param("t", to).param("o", outletId).query(String.class).single();
        try {
            return Responses.ok(mapper.readTree(json));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Dasbor tidak dapat dibaca", e);
        }
    }
}
