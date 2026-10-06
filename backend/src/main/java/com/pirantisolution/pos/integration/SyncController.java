package com.pirantisolution.pos.integration;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.integration.SyncDtos.MappingRequest;
import com.pirantisolution.pos.integration.SyncDtos.MappingView;
import com.pirantisolution.pos.integration.SyncDtos.RunRequest;
import com.pirantisolution.pos.integration.SyncDtos.RunResult;
import com.pirantisolution.pos.integration.SyncDtos.SyncJobDetail;
import com.pirantisolution.pos.integration.SyncDtos.SyncJobView;
import com.pirantisolution.pos.integration.SyncDtos.SyncStatus;
import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class SyncController {

    private final SyncService service;

    public SyncController(SyncService service) {
        this.service = service;
    }

    @GetMapping("/api/sync/status")
    public ResponseEntity<ApiResponse<SyncStatus>> status() {
        return Responses.ok(service.status());
    }

    @GetMapping("/api/sync/errors")
    public ResponseEntity<ApiResponse<List<SyncJobView>>> errors() {
        return Responses.ok(service.errors());
    }

    @GetMapping("/api/sync/jobs")
    public ResponseEntity<ApiResponse<List<SyncJobView>>> jobs(@RequestParam(required = false) String status,
            @RequestParam(required = false) String jobType) {
        return Responses.ok(service.jobs(status, jobType));
    }

    @GetMapping("/api/sync/jobs/{id}")
    public ResponseEntity<ApiResponse<SyncJobDetail>> job(@PathVariable UUID id) {
        return Responses.ok(service.job(id));
    }

    /** Proses antrean sekarang; {@code types} (opsional) meminta sinkron master data dari Openbravo. */
    @PostMapping("/api/sync/run")
    public ResponseEntity<ApiResponse<RunResult>> run(@Valid @RequestBody(required = false) RunRequest req) {
        return Responses.ok(service.run(req == null ? null : req.types()), "Sinkronisasi dijalankan");
    }

    @PostMapping("/api/sync/{id}/retry")
    public ResponseEntity<ApiResponse<SyncJobView>> retry(@PathVariable UUID id) {
        return Responses.ok(service.retry(id), "Dijadwalkan ulang");
    }

    @GetMapping("/api/admin/openbravo-mappings")
    public ResponseEntity<ApiResponse<List<MappingView>>> mappings() {
        return Responses.ok(service.mappings());
    }

    @PutMapping("/api/admin/openbravo-mappings")
    public ResponseEntity<ApiResponse<List<MappingView>>> saveMapping(@Valid @RequestBody MappingRequest req) {
        return Responses.ok(service.saveMapping(req), "Pemetaan disimpan");
    }
}
