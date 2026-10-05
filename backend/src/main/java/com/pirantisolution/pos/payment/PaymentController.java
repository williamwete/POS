package com.pirantisolution.pos.payment;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.idempotency.IdempotencyService;
import com.pirantisolution.pos.payment.PaymentDtos.AddPaymentRequest;
import com.pirantisolution.pos.payment.PaymentDtos.CancelPaymentRequest;
import com.pirantisolution.pos.payment.PaymentDtos.ConfirmPaymentRequest;
import com.pirantisolution.pos.payment.PaymentDtos.PaymentMethodView;
import com.pirantisolution.pos.payment.PaymentDtos.PaymentResult;
import com.pirantisolution.pos.payment.PaymentDtos.PaymentView;
import com.pirantisolution.pos.payment.PaymentDtos.UpdatePaymentMethodRequest;
import com.pirantisolution.pos.payment.gateway.CallbackSigner;
import jakarta.validation.Valid;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

/** Pembayaran (§61 "Payment"). Refund: Phase 8. */
@RestController
public class PaymentController {

    private final PaymentService service;
    private final IdempotencyService idempotency;

    public PaymentController(PaymentService service, IdempotencyService idempotency) {
        this.service = service;
        this.idempotency = idempotency;
    }

    @GetMapping("/api/payment-methods")
    public ResponseEntity<ApiResponse<List<PaymentMethodView>>> methods() {
        return Responses.ok(service.methods());
    }

    @GetMapping("/api/sales/{saleId}/payments")
    public ResponseEntity<ApiResponse<List<PaymentView>>> list(@PathVariable UUID saleId) {
        return Responses.ok(service.forSale(saleId));
    }

    @PostMapping("/api/sales/{saleId}/payments")
    public ResponseEntity<?> add(@PathVariable UUID saleId, @Valid @RequestBody AddPaymentRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/sales/" + saleId + "/payments", req,
                () -> Responses.created(service.add(saleId, req), "Pembayaran dicatat"));
    }

    /** Status terbaru (server menanyakan penyedia bila masih menunggu). Dipakai polling layar QR. */
    @GetMapping("/api/payments/{id}")
    public ResponseEntity<ApiResponse<PaymentResult>> get(@PathVariable UUID id) {
        return Responses.ok(service.refresh(id));
    }

    @PostMapping("/api/payments/{id}/cancel")
    public ResponseEntity<?> cancel(@PathVariable UUID id, @Valid @RequestBody CancelPaymentRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/payments/" + id + "/cancel", req,
                () -> Responses.ok(service.cancel(id, req.reason()), "Pembayaran dibatalkan"));
    }

    @PostMapping("/api/payments/{id}/confirm")
    public ResponseEntity<?> confirm(@PathVariable UUID id, @Valid @RequestBody ConfirmPaymentRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idempotency.execute(key, "POST", "/api/payments/" + id + "/confirm", req,
                () -> Responses.ok(service.confirm(id, req.referenceNumber(), req.approvalId()),
                        "Pembayaran dikonfirmasi"));
    }

    /**
     * Callback penyedia pembayaran (tanpa login; diverifikasi HMAC + timestamp). Body dibaca mentah
     * agar tanda tangan dihitung atas byte yang sama dengan yang dikirim penyedia.
     */
    @PostMapping("/api/payments/callback/{provider}")
    public ResponseEntity<ApiResponse<Map<String, String>>> callback(@PathVariable String provider,
            @RequestBody String body,
            @RequestHeader(name = CallbackSigner.SIGNATURE_HEADER, required = false) String signature,
            @RequestHeader(name = CallbackSigner.TIMESTAMP_HEADER, required = false) String timestamp) {
        service.handleCallback(provider, body, signature, timestamp);
        return Responses.ok(Map.of("result", "accepted"));
    }

    // ---------------------------------------------------------------- konfigurasi

    @GetMapping("/api/admin/payment-methods")
    public ResponseEntity<ApiResponse<List<PaymentMethodView>>> allMethods() {
        return Responses.ok(service.allMethods());
    }

    @PutMapping("/api/admin/payment-methods/{id}")
    public ResponseEntity<ApiResponse<PaymentMethodView>> update(@PathVariable UUID id,
            @Valid @RequestBody UpdatePaymentMethodRequest req) {
        return Responses.ok(service.updateMethod(id, req), "Metode pembayaran disimpan");
    }
}
