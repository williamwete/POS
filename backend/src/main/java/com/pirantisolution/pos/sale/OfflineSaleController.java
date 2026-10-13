package com.pirantisolution.pos.sale;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.sale.OfflineSaleService.OfflineSaleRequest;
import com.pirantisolution.pos.sale.OfflineSaleService.OfflineSaleResult;
import com.pirantisolution.pos.security.AccessService;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Pengiriman transaksi tunai offline dan peninjauan selisihnya (Fase 10). */
@RestController
public class OfflineSaleController {

    public record ResolveRequest(@NotBlank @Size(min = 5, max = 500) String note) {
    }

    private final OfflineSaleService service;
    private final JdbcClient jdbc;
    private final AccessService access;
    private final ObjectMapper mapper;

    public OfflineSaleController(OfflineSaleService service, JdbcClient jdbc, AccessService access,
                                 ObjectMapper mapper) {
        this.service = service;
        this.jdbc = jdbc;
        this.access = access;
        this.mapper = mapper;
    }

    @PostMapping("/api/sales/offline")
    public ResponseEntity<ApiResponse<OfflineSaleResult>> submit(@RequestBody OfflineSaleRequest req) {
        return Responses.ok(service.submit(req));
    }

    @GetMapping("/api/offline-reviews")
    @Transactional(readOnly = true)
    public ResponseEntity<ApiResponse<JsonNode>> reviews(@RequestParam UUID outletId,
                                                         @RequestParam(defaultValue = "OPEN") String status) {
        access.currentUser();
        String json = jdbc.sql("SELECT pos.offline_reviews(:o, :s)::text")
                .param("o", outletId).param("s", status).query(String.class).single();
        try {
            return Responses.ok(mapper.readTree(json));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Daftar peninjauan tidak dapat dibaca", e);
        }
    }

    @PostMapping("/api/offline-reviews/{id}/resolve")
    @Transactional
    public ResponseEntity<ApiResponse<Map<String, Boolean>>> resolve(@PathVariable UUID id,
                                                                    @RequestBody ResolveRequest req) {
        access.currentUser();
        jdbc.sql("SELECT pos.resolve_offline_review(:i, :n)").param("i", id).param("n", req.note())
                .query().singleRow();
        return Responses.ok(Map.of("resolved", true));
    }
}
