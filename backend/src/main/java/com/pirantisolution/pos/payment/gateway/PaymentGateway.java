package com.pirantisolution.pos.payment.gateway;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * Penyedia pembayaran untuk metode GATEWAY (QRIS dinamis, e-wallet) — §64.
 *
 * <p>Status PAID hanya berasal dari penyedia: lewat callback bertanda tangan
 * ({@link #verifyCallback}) atau polling ({@link #status}). Implementasi produksi (mis. Midtrans,
 * Xendit) ditambahkan dengan kontrak yang sama begitu kredensial merchant tersedia.
 */
public interface PaymentGateway {

    /** Nama penyedia, disimpan di payments.provider. */
    String provider();

    /** true bila tidak ada penyedia nyata (pembuatan charge akan ditolak). */
    default boolean configured() {
        return true;
    }

    /** true untuk simulator pengembangan (UI menampilkan tombol simulasi). */
    default boolean simulated() {
        return false;
    }

    Charge create(ChargeRequest request);

    GatewayStatus status(String externalTransactionId);

    /** Batalkan charge yang belum dibayar (best effort). */
    void cancel(String externalTransactionId);

    /**
     * Verifikasi tanda tangan & parse callback. Melempar {@link CallbackRejectedException} bila
     * tanda tangan/format tidak valid.
     */
    CallbackEvent verifyCallback(String rawBody, String signature, String timestamp);

    record ChargeRequest(UUID paymentId, String clientPaymentId, String methodCode, BigDecimal amount,
            String receiptNo, OffsetDateTime expiresAt) {
    }

    record Charge(String externalTransactionId, String qrPayload) {
    }

    enum GatewayStatus { PENDING, PAID, FAILED, EXPIRED }

    record CallbackEvent(String externalTransactionId, GatewayStatus status, BigDecimal amount, String reference) {
    }

    class CallbackRejectedException extends RuntimeException {
        public CallbackRejectedException(String message) {
            super(message);
        }
    }

    class GatewayUnavailableException extends RuntimeException {
        public GatewayUnavailableException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
