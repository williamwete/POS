package com.pirantisolution.pos.payment;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.payment.PaymentDtos.PaymentResult;
import com.pirantisolution.pos.payment.PaymentDtos.SimulateRequest;
import com.pirantisolution.pos.payment.gateway.PaymentGateway;
import com.pirantisolution.pos.payment.gateway.PaymentGateway.GatewayStatus;
import com.pirantisolution.pos.payment.gateway.SimulatorGateway;
import jakarta.validation.Valid;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * KHUSUS profile local/test: "pelanggan membayar" QRIS/e-wallet di simulator. Mengirim callback
 * bertanda tangan melalui jalur produksi ({@link PaymentService#handleCallback}).
 */
@RestController
@Profile({"local", "test"})
public class DevPaymentController {

    private final PaymentService service;
    private final PaymentGateway gateway;

    public DevPaymentController(PaymentService service, PaymentGateway gateway) {
        this.service = service;
        this.gateway = gateway;
    }

    @PostMapping("/api/dev-payments/{paymentId}/simulate")
    public ResponseEntity<ApiResponse<PaymentResult>> simulate(@PathVariable UUID paymentId,
            @Valid @RequestBody SimulateRequest req) {
        if (!(gateway instanceof SimulatorGateway sim)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "Simulator pembayaran tidak aktif");
        }
        PaymentResult current = service.refresh(paymentId);
        var p = current.payment();
        if (p.externalTransactionId() == null || !SimulatorGateway.PROVIDER.equals(p.provider())) {
            throw new ApiException(ErrorCode.PAYMENT_INVALID_TRANSITION, "Bukan pembayaran simulator");
        }
        SimulatorGateway.SignedCallback cb = sim.simulate(p.externalTransactionId(),
                GatewayStatus.valueOf(req.result()), p.amount());
        service.handleCallback(SimulatorGateway.PROVIDER, cb.body(), cb.signature(), cb.timestamp());
        return Responses.ok(service.refresh(paymentId));
    }
}
