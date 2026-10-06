package com.pirantisolution.pos.returns;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class ReturnDtos {

    private ReturnDtos() {
    }

    public record ReturnLine(@NotNull UUID saleItemId, @NotNull @DecimalMin("0.001") BigDecimal quantity,
            Boolean returnToStock) {
    }

    public record CreateReturnRequest(
            @NotBlank @Size(max = 64) @Pattern(regexp = "[A-Za-z0-9._:-]+") String clientReturnId,
            @NotNull UUID originalSaleId,
            @NotBlank @Size(min = 3, max = 500) String reason,
            @NotNull @Pattern(regexp = "CASH|ORIGINAL") String refundMode,
            @Size(max = 100) String refundReference,
            @NotEmpty @Size(max = 200) List<@Valid @NotNull ReturnLine> items) {
    }

    public record ApproveRequest(@Size(max = 100) String refundReference) {
    }

    public record RejectRequest(@NotBlank @Size(min = 5, max = 500) String reason) {
    }

    /** Approval supervisor di terminal kasir (rate limit seperti login). */
    public record TerminalApprovalRequest(
            @NotBlank @Email @Size(max = 254) String email,
            @NotBlank @Size(max = 200) String password,
            @Size(max = 100) String refundReference) {

        @Override
        public String toString() {
            return "TerminalApprovalRequest[email=" + email + "]";
        }
    }

    public record ReturnItemView(UUID saleItemId, String sku, String productName, String uom, BigDecimal quantity,
            BigDecimal unitPrice, BigDecimal amount, BigDecimal taxAmount, boolean returnToStock) {
    }

    public record RefundView(UUID id, UUID originalPaymentId, String refundMethod, BigDecimal refundAmount,
            String referenceNumber, OffsetDateTime createdAt) {
    }

    public record ReturnView(
            UUID id,
            String returnNo,
            String status,
            UUID originalSaleId,
            String originalReceiptNo,
            UUID outletId,
            String terminalCode,
            UUID cashierSessionId,
            LocalDate businessDate,
            String reason,
            String refundMode,
            String refundReference,
            BigDecimal itemCount,
            BigDecimal totalAmount,
            BigDecimal taxAmount,
            String createdByName,
            String approvedByName,
            OffsetDateTime approvedAt,
            String rejectReason,
            String rejectedByName,
            OffsetDateTime createdAt,
            int version,
            List<ReturnItemView> items,
            List<RefundView> refunds) {

        ReturnView with(List<ReturnItemView> i, List<RefundView> r) {
            return new ReturnView(id, returnNo, status, originalSaleId, originalReceiptNo, outletId, terminalCode,
                    cashierSessionId, businessDate, reason, refundMode, refundReference, itemCount, totalAmount,
                    taxAmount, createdByName, approvedByName, approvedAt, rejectReason, rejectedByName, createdAt,
                    version, i, r);
        }
    }
}
