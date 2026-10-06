package com.pirantisolution.pos.report;

import com.fasterxml.jackson.databind.JsonNode;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.report.ReportRepository.TransactionRow;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class ReportController {

    private static final String BASE = "/api/cashier/sessions/{id}";

    private final ReportService service;

    public ReportController(ReportService service) {
        this.service = service;
    }

    /** X report: dibuat saat diminta (tidak menulis apa pun selain audit). */
    @PostMapping(BASE + "/x-report")
    public ResponseEntity<ApiResponse<JsonNode>> xReport(@PathVariable UUID id) {
        return Responses.ok(service.xReport(id));
    }

    @GetMapping(BASE + "/z-report")
    public ResponseEntity<ApiResponse<JsonNode>> zReport(@PathVariable UUID id) {
        return Responses.ok(service.zReport(id));
    }

    @PostMapping(BASE + "/z-report/print")
    public ResponseEntity<ApiResponse<Map<String, Boolean>>> zPrint(@PathVariable UUID id) {
        service.recordZPrint(id);
        return Responses.ok(Map.of("recorded", true));
    }

    @GetMapping(BASE + "/transactions")
    public ResponseEntity<ApiResponse<List<TransactionRow>>> transactions(@PathVariable UUID id) {
        return Responses.ok(service.transactions(id));
    }
}
