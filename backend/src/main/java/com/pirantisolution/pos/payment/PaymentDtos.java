package com.pirantisolution.pos.payment;

import com.pirantisolution.pos.sale.SaleDtos.SaleView;
import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

public final class PaymentDtos {

    private PaymentDtos() {
    }

    public record PaymentMethodView(
            UUID id,
            String code,
            String name,
            String kind,
            String confirmation,
            boolean requiresReference,
            boolean requiresApproval,
            boolean manualConfirmAllowed,
            boolean active,
            int sortOrder,
            String openbravoPaymentMethodId,
            int version,
            /** false = metode GATEWAY tanpa penyedia & tanpa konfirmasi manual (tidak bisa dipakai). */
            boolean available) {

        PaymentMethodView withAvailable(boolean a) {
            return new PaymentMethodView(id, code, name, kind, confirmation, requiresReference, requiresApproval,
                    manualConfirmAllowed, active, sortOrder, openbravoPaymentMethodId, version, a);
        }
    }

    public record PaymentView(
            UUID id,
            UUID saleId,
            String methodCode,
            String methodName,
            String methodKind,
            String confirmation,
            BigDecimal amount,
            BigDecimal amountReceived,
            BigDecimal changeAmount,
            String status,
            String referenceNumber,
            String provider,
            String externalTransactionId,
            String qrPayload,
            OffsetDateTime expiresAt,
            OffsetDateTime paidAt,
            String failedReason,
            String cancelReason,
            String approvedByUsername,
            boolean manualConfirmAllowed,
            OffsetDateTime createdAt,
            int version) {
    }

    /** Hasil aksi pembayaran: pembayaran + status sale terbaru (lunas/sisa). */
    public record PaymentResult(PaymentView payment, SaleView sale, boolean simulated) {
    }

    /**
     * Tunai: isi {@code amountReceived} (uang diterima; jumlah diterapkan & kembalian dihitung database).
     * Non-tunai: isi {@code amount}.
     */
    public record AddPaymentRequest(
            @NotBlank @Pattern(regexp = "^[A-Za-z0-9._:-]{8,80}$") String clientPaymentId,
            @NotBlank @Pattern(regexp = "^[A-Z0-9_]{2,32}$") String methodCode,
            @DecimalMin("1") @DecimalMax("999999999999") BigDecimal amount,
            @DecimalMin("1") @DecimalMax("999999999999") BigDecimal amountReceived,
            @Size(max = 64) @Pattern(regexp = "^[A-Za-z0-9 ./_-]*$") String referenceNumber,
            UUID approvalId) {
    }

    public record CancelPaymentRequest(@NotBlank @Size(min = 5, max = 500) String reason) {
    }

    public record ConfirmPaymentRequest(
            @NotBlank @Size(min = 3, max = 64) @Pattern(regexp = "^[A-Za-z0-9 ./_-]*$") String referenceNumber,
            @NotNull UUID approvalId) {
    }

    public record UpdatePaymentMethodRequest(
            @NotBlank @Size(max = 60) String name,
            boolean active,
            boolean requiresReference,
            boolean requiresApproval,
            boolean manualConfirmAllowed,
            int sortOrder,
            @Size(max = 64) String openbravoPaymentMethodId,
            @NotNull Integer version) {
    }

    public record SimulateRequest(@NotNull @Pattern(regexp = "PAID|FAILED") String result) {
    }
}
