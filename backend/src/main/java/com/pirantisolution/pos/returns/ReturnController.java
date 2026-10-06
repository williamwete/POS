package com.pirantisolution.pos.returns;

import com.fasterxml.jackson.databind.JsonNode;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.idempotency.IdempotencyService;
import com.pirantisolution.pos.returns.ReturnDtos.ApproveRequest;
import com.pirantisolution.pos.returns.ReturnDtos.CreateReturnRequest;
import com.pirantisolution.pos.returns.ReturnDtos.RejectRequest;
import com.pirantisolution.pos.returns.ReturnDtos.ReturnView;
import com.pirantisolution.pos.returns.ReturnDtos.TerminalApprovalRequest;
import jakarta.validation.Valid;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class ReturnController {

    private static final String BASE = "/api/returns";

    private final ReturnService service;
    private final ReturnApprovalService approvals;
    private final IdempotencyService idempotency;

    public ReturnController(ReturnService service, ReturnApprovalService approvals, IdempotencyService idempotency) {
        this.service = service;
        this.approvals = approvals;
        this.idempotency = idempotency;
    }

    @GetMapping(BASE + "/lookup")
    public ResponseEntity<ApiResponse<JsonNode>> lookup(@RequestParam String receiptNo) {
        return Responses.ok(service.lookup(receiptNo));
    }

    @PostMapping(BASE)
    public ResponseEntity<?> create(@Valid @RequestBody CreateReturnRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE, req, () -> Responses.created(service.create(req), "Retur dibuat"));
    }

    @GetMapping(BASE + "/{id}")
    public ResponseEntity<ApiResponse<ReturnView>> get(@PathVariable UUID id) {
        return Responses.ok(service.get(id));
    }

    @GetMapping(BASE)
    public ResponseEntity<ApiResponse<List<ReturnView>>> list(
            @RequestParam UUID outletId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate businessDate,
            @RequestParam(required = false) String status) {
        return Responses.ok(service.list(outletId, businessDate, status));
    }

    /** Approver (sale.refund) menyetujui dari akunnya sendiri. */
    @PostMapping(BASE + "/{id}/approve")
    public ResponseEntity<?> approve(@PathVariable UUID id, @Valid @RequestBody(required = false) ApproveRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        String ref = req == null ? null : req.refundReference();
        return idempotency.execute(key, "POST", BASE + "/" + id + "/approve", req == null ? new ApproveRequest(null) : req,
                () -> Responses.ok(service.approve(id, ref), "Refund disetujui"));
    }

    /** Supervisor memasukkan email + password di terminal kasir (rate limit seperti login, tanpa idempotency). */
    @PostMapping(BASE + "/{id}/approve-at-terminal")
    public ResponseEntity<ApiResponse<ReturnView>> approveAtTerminal(@PathVariable UUID id,
            @Valid @RequestBody TerminalApprovalRequest req) {
        return Responses.ok(approvals.approveAtTerminal(id, req), "Refund disetujui");
    }

    @PostMapping(BASE + "/{id}/reject")
    public ResponseEntity<?> reject(@PathVariable UUID id, @Valid @RequestBody RejectRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/" + id + "/reject", req,
                () -> Responses.ok(service.reject(id, req.reason()), "Retur ditolak"));
    }
}
