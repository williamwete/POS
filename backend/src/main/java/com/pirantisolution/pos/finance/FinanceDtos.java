package com.pirantisolution.pos.finance;

import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

public final class FinanceDtos {

    private FinanceDtos() {
    }

    public record BalanceView(BigDecimal total, BigDecimal available, BigDecimal pending, BigDecimal minPayout,
            BigDecimal feePercent, BigDecimal feeFlat, int holdDays, String bankStatus) {
    }

    public record LedgerRow(UUID id, String entryType, BigDecimal amount, OffsetDateTime availableAt,
            String provider, String description, OffsetDateTime createdAt) {
    }

    public record BankAccountView(String bankCode, String accountNumber, String accountName, String status,
            OffsetDateTime updatedAt) {
    }

    public record PayoutRow(UUID id, BigDecimal amount, String status, String bankCode, String accountNumber,
            String accountName, OffsetDateTime requestedAt, OffsetDateTime processedAt, String providerRef, String note) {
    }

    public record SaveBankAccountRequest(
            @NotBlank @Size(max = 20) String bankCode,
            @NotBlank @Size(max = 30) String accountNumber,
            @NotBlank @Size(min = 2, max = 80) String accountName) {
    }

    public record PayoutRequest(@NotNull @DecimalMin("1") @DecimalMax("100000000000") BigDecimal amount) {
    }

    // ------------------------------------------------------------ operator platform
    public record PlatformPayoutRow(UUID id, UUID organizationId, String merchantCode, String merchantName,
            BigDecimal amount, String status, String bankCode, String accountNumber, String accountName,
            OffsetDateTime requestedAt, OffsetDateTime processedAt, String providerRef, String note) {
    }

    public record PlatformBankAccountRow(UUID organizationId, String merchantCode, String merchantName,
            String bankCode, String accountNumber, String accountName, String status, OffsetDateTime updatedAt) {
    }

    public record MerchantBalanceRow(UUID organizationId, String merchantCode, String merchantName, BigDecimal total,
            BigDecimal available, BigDecimal pendingPayout, BigDecimal feePercent, BigDecimal feeFlat, int holdDays,
            BigDecimal minPayout) {
    }

    public record ProcessPayoutRequest(
            @NotBlank @Pattern(regexp = "^(PROCESSING|PAID|REJECTED|FAILED)$") String status,
            @Size(max = 100) String reference,
            @Size(max = 300) String note) {
    }

    public record VerifyBankRequest(boolean verified) {
    }

    public record TermsRequest(
            @NotNull @DecimalMin("0") @DecimalMax("20") BigDecimal feePercent,
            @NotNull @DecimalMin("0") @DecimalMax("100000") BigDecimal feeFlat,
            @NotNull @Min(0) @Max(30) Integer holdDays,
            @NotNull @DecimalMin("0") BigDecimal minPayout) {
    }
}
