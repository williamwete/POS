package com.pirantisolution.pos.sale;

import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class SaleDtos {

    private SaleDtos() {
    }

    public enum ApprovalAction { DISCOUNT, PRICE_OVERRIDE, VOID_SALE }

    // ---------------------------------------------------------------- views

    public record SaleItemView(
            UUID id,
            int lineNo,
            UUID productId,
            String sku,
            String productName,
            String barcode,
            String uom,
            BigDecimal quantity,
            BigDecimal listPrice,
            BigDecimal unitPrice,
            String priceOverrideReason,
            BigDecimal taxRate,
            BigDecimal grossAmount,
            BigDecimal itemDiscountAmount,
            BigDecimal cartDiscountAmount,
            BigDecimal netAmount,
            BigDecimal taxAmount,
            String status,
            String voidReason) {
    }

    public record DiscountView(
            UUID id,
            UUID saleItemId,
            String discountType,
            BigDecimal discountValue,
            BigDecimal amount,
            String reason,
            String approvedByUsername,
            String status) {
    }

    public record SaleView(
            UUID id,
            String clientTransactionId,
            String receiptNo,
            String status,
            String syncStatus,
            UUID outletId,
            String outletCode,
            UUID terminalId,
            String terminalCode,
            UUID cashierSessionId,
            UUID employeeId,
            String employeeName,
            LocalDate businessDate,
            boolean pricesIncludeTax,
            int lineCount,
            BigDecimal itemCount,
            BigDecimal subtotal,
            BigDecimal itemDiscountTotal,
            BigDecimal cartDiscountTotal,
            BigDecimal discountTotal,
            BigDecimal taxTotal,
            BigDecimal grandTotal,
            String note,
            OffsetDateTime heldAt,
            OffsetDateTime checkedOutAt,
            OffsetDateTime voidedAt,
            String voidReason,
            OffsetDateTime createdAt,
            int version,
            List<SaleItemView> items,
            List<DiscountView> discounts) {

        SaleView with(List<SaleItemView> i, List<DiscountView> d) {
            return new SaleView(id, clientTransactionId, receiptNo, status, syncStatus, outletId, outletCode,
                    terminalId, terminalCode, cashierSessionId, employeeId, employeeName, businessDate,
                    pricesIncludeTax, lineCount, itemCount, subtotal, itemDiscountTotal, cartDiscountTotal,
                    discountTotal, taxTotal, grandTotal, note, heldAt, checkedOutAt, voidedAt, voidReason, createdAt,
                    version, i, d);
        }
    }

    public record ApprovalView(UUID id, String action, String approverName, BigDecimal maxPercent,
            OffsetDateTime expiresAt) {
    }

    public record ReceiptLine(String name, String sku, BigDecimal quantity, String uom, BigDecimal unitPrice,
            BigDecimal listPrice, BigDecimal discount, BigDecimal amount, BigDecimal taxRate) {
    }

    public record ReceiptView(
            UUID saleId,
            String receiptNo,
            String status,
            String organizationName,
            String outletName,
            String outletAddress,
            String outletPhone,
            String terminalCode,
            String cashierName,
            LocalDate businessDate,
            OffsetDateTime issuedAt,
            boolean pricesIncludeTax,
            List<ReceiptLine> lines,
            BigDecimal itemCount,
            BigDecimal subtotal,
            BigDecimal discountTotal,
            BigDecimal taxTotal,
            BigDecimal grandTotal,
            int printCount) {
    }

    public record PrintResult(int printCount, boolean reprint) {
    }

    // ---------------------------------------------------------------- requests

    public record CreateSaleRequest(
            @NotBlank @Pattern(regexp = "^[A-Za-z0-9._:-]{8,80}$") String clientTransactionId,
            @Size(max = 500) String note) {
    }

    public record AddItemRequest(
            UUID productId,
            @Pattern(regexp = "^[A-Za-z0-9._-]{1,64}$") String barcode,
            @NotNull @DecimalMin("0.001") @DecimalMax("100000") BigDecimal quantity) {
    }

    public record QuantityRequest(@NotNull @DecimalMin("0.001") @DecimalMax("100000") BigDecimal quantity) {
    }

    public record VoidItemRequest(@NotBlank @Size(min = 3, max = 200) String reason) {
    }

    public record PriceRequest(
            @NotNull @DecimalMin("0") @DecimalMax("999999999999") BigDecimal unitPrice,
            @NotBlank @Size(min = 3, max = 200) String reason,
            UUID approvalId) {
    }

    public record DiscountRequest(
            UUID saleItemId,
            @NotNull CartCalculator.Type type,
            @NotNull @DecimalMin("0.01") @DecimalMax("999999999999") BigDecimal value,
            @NotBlank @Size(min = 3, max = 200) String reason,
            UUID approvalId) {
    }

    public record VoidSaleRequest(@NotBlank @Size(min = 5, max = 500) String reason, UUID approvalId) {
    }

    public record ApprovalRequest(
            @NotNull ApprovalAction action,
            @NotNull UUID saleId,
            UUID saleItemId,
            CartCalculator.Type discountType,
            @DecimalMin("0.01") BigDecimal discountValue,
            @DecimalMin("0") BigDecimal price,
            @NotBlank @Email @Size(max = 254) String email,
            @NotBlank @Size(max = 200) String password) {

        /** Password tidak pernah muncul di log/idempotency hash. */
        @Override
        public String toString() {
            return "ApprovalRequest[action=" + action + ", saleId=" + saleId + "]";
        }
    }
}
