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

/** Laporan penjualan terperinci. Angka & izin (report.view) dihitung di database (pos.sales_report). */
@RestController
public class SalesReportController {

    private final JdbcClient jdbc;
    private final AccessService access;
    private final ObjectMapper mapper;

    public SalesReportController(JdbcClient jdbc, AccessService access, ObjectMapper mapper) {
        this.jdbc = jdbc;
        this.access = access;
        this.mapper = mapper;
    }

    /** group: PRODUCT | CATEGORY | CASHIER | DAY | PAYMENT. */
    @GetMapping("/api/reports/sales")
    @Transactional(readOnly = true)
    public ResponseEntity<ApiResponse<JsonNode>> sales(
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to,
            @RequestParam(required = false) UUID outletId,
            @RequestParam(defaultValue = "PRODUCT") String group) {
        access.currentUser();
        String json = jdbc.sql("SELECT pos.sales_report(:f, :t, CAST(:o AS uuid), :g)::text")
                .param("f", from).param("t", to).param("o", outletId).param("g", group).query(String.class).single();
        try {
            return Responses.ok(mapper.readTree(json));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Laporan tidak dapat dibaca", e);
        }
    }
}
