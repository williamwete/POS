package com.pirantisolution.pos.cashier;

import com.pirantisolution.pos.cashier.CashierDtos.AdjustmentRequest;
import com.pirantisolution.pos.cashier.CashierDtos.CancelRequest;
import com.pirantisolution.pos.cashier.CashierDtos.CashApprovalRequest;
import com.pirantisolution.pos.cashier.CashierDtos.CashApprovalView;
import com.pirantisolution.pos.cashier.CashierDtos.CashMovementRequest;
import com.pirantisolution.pos.cashier.CashierDtos.ClosePreview;
import com.pirantisolution.pos.cashier.CashierDtos.ClosePreviewRequest;
import com.pirantisolution.pos.cashier.CashierDtos.CloseRequest;
import com.pirantisolution.pos.cashier.CashierDtos.MovementView;
import com.pirantisolution.pos.cashier.CashierDtos.CashCountRequest;
import com.pirantisolution.pos.cashier.CashierDtos.DenominationView;
import com.pirantisolution.pos.cashier.CashierDtos.LockRequest;
import com.pirantisolution.pos.cashier.CashierDtos.OpenSessionRequest;
import com.pirantisolution.pos.cashier.CashierDtos.SessionView;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.idempotency.IdempotencyService;
import jakarta.validation.Valid;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
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
public class CashierController {

    private static final String BASE = "/api/cashier/sessions";

    private final CashierService service;
    private final CashApprovalService approvals;
    private final IdempotencyService idempotency;

    public CashierController(CashierService service, CashApprovalService approvals, IdempotencyService idempotency) {
        this.service = service;
        this.approvals = approvals;
        this.idempotency = idempotency;
    }

    @GetMapping("/api/cashier/denominations")
    public ResponseEntity<ApiResponse<List<DenominationView>>> denominations() {
        return Responses.ok(service.denominations());
    }

    /** Session aktif milik user yang login (null jika belum buka kasir). */
    @GetMapping(BASE + "/current")
    public ResponseEntity<ApiResponse<SessionView>> current() {
        return Responses.ok(service.current().orElse(null));
    }

    @PostMapping(BASE + "/open")
    public ResponseEntity<?> open(@Valid @RequestBody OpenSessionRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/open", req,
                () -> Responses.created(service.open(req.terminalId(), req.counts(), req.note()), "Kasir dibuka"));
    }

    @PostMapping(BASE + "/{id}/cash-count")
    public ResponseEntity<?> cashCount(@PathVariable UUID id, @Valid @RequestBody CashCountRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/" + id + "/cash-count", req,
                () -> Responses.created(service.cashCount(id, req.counts(), req.note()), "Hitungan kas tercatat"));
    }

    @PostMapping(BASE + "/{id}/lock")
    public ResponseEntity<?> lock(@PathVariable UUID id, @Valid @RequestBody LockRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/" + id + "/lock", req,
                () -> Responses.ok(service.lock(id, req.reason()), "Terminal dikunci"));
    }

    @PostMapping(BASE + "/{id}/unlock")
    public ResponseEntity<?> unlock(@PathVariable UUID id,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/" + id + "/unlock", Map.of(),
                () -> Responses.ok(service.unlock(id), "Terminal dibuka"));
    }

    @PostMapping(BASE + "/{id}/cancel")
    public ResponseEntity<?> cancel(@PathVariable UUID id, @Valid @RequestBody CancelRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/" + id + "/cancel", req,
                () -> Responses.ok(service.cancel(id, req.reason()), "Buka kasir dibatalkan"));
    }

    // ------------------------------------------------------------------ Phase 6: kas & tutup kasir

    @GetMapping(BASE + "/{id}/movements")
    public ResponseEntity<ApiResponse<List<MovementView>>> movements(@PathVariable UUID id) {
        return Responses.ok(service.movements(id));
    }

    @PostMapping(BASE + "/{id}/cash-movements")
    public ResponseEntity<?> cashMovement(@PathVariable UUID id, @Valid @RequestBody CashMovementRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/" + id + "/cash-movements", req,
                () -> Responses.created(service.cashMovement(id, req.type(), req.amount(), req.reason(), req.approvalId()),
                        "CASH_IN".equals(req.type()) ? "Kas masuk tercatat" : "Kas keluar tercatat"));
    }

    @PostMapping(BASE + "/{id}/adjustments")
    public ResponseEntity<?> adjustment(@PathVariable UUID id, @Valid @RequestBody AdjustmentRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/" + id + "/adjustments", req,
                () -> Responses.created(service.adjustment(id, req.amount(), req.reason()), "Penyesuaian kas tercatat"));
    }

    @PostMapping(BASE + "/{id}/close/preview")
    public ResponseEntity<ApiResponse<ClosePreview>> closePreview(@PathVariable UUID id,
            @Valid @RequestBody ClosePreviewRequest req) {
        return Responses.ok(service.closePreview(id, req.counts()));
    }

    @PostMapping(BASE + "/{id}/close")
    public ResponseEntity<?> close(@PathVariable UUID id, @Valid @RequestBody CloseRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", BASE + "/" + id + "/close", req,
                () -> Responses.ok(service.close(id, req), "Kasir ditutup"));
    }

    /** Approval supervisor kas (rate limit seperti login). Tanpa idempotency: password tidak di-hash/disimpan. */
    @PostMapping("/api/cashier/approvals")
    public ResponseEntity<ApiResponse<CashApprovalView>> approve(@Valid @RequestBody CashApprovalRequest req) {
        return Responses.created(approvals.request(req), "Disetujui");
    }

    @GetMapping(BASE + "/{id}")
    public ResponseEntity<ApiResponse<SessionView>> get(@PathVariable UUID id) {
        return Responses.ok(service.get(id));
    }

    /** Session kasir satu outlet (cashier.view): business date tertentu + yang masih aktif. */
    @GetMapping(BASE)
    public ResponseEntity<ApiResponse<List<SessionView>>> outlet(
            @RequestParam UUID outletId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate businessDate,
            @RequestParam(required = false) String status) {
        return Responses.ok(service.outletSessions(outletId, businessDate, status));
    }
}
