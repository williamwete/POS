package com.pirantisolution.pos.audit;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.PageResult;
import com.pirantisolution.pos.common.api.Responses;
import java.time.OffsetDateTime;
import java.util.UUID;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Audit log hanya bisa dibaca; tidak ada endpoint ubah/hapus (§47). */
@RestController
public class AuditController {

    private final AuditQueryService service;

    public AuditController(AuditQueryService service) {
        this.service = service;
    }

    @GetMapping("/api/audit-logs")
    public ResponseEntity<ApiResponse<PageResult<AuditLogView>>> search(
            @RequestParam(required = false) String action,
            @RequestParam(required = false) String entityType,
            @RequestParam(required = false) String entityId,
            @RequestParam(required = false) UUID outletId,
            @RequestParam(required = false) UUID actorUserId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) OffsetDateTime to,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "50") int size) {
        return Responses.ok(service.search(new AuditQueryService.Filter(action, entityType, entityId, outletId,
                actorUserId, from, to, page, size)));
    }
}
