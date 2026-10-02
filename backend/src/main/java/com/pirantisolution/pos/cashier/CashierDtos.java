package com.pirantisolution.pos.cashier;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class CashierDtos {

    private CashierDtos() {
    }

    public record DenominationView(UUID id, String currency, BigDecimal value, String kind, int sortOrder) {
    }

    /** Satu baris hitungan: denominasi dari master + jumlah lembar/keping. Nilai uang dihitung server. */
    public record CountLine(@NotNull UUID denominationId, @Min(0) @Max(100000) int quantity) {
    }

    public record OpenSessionRequest(
            @NotNull UUID terminalId,
            @NotNull @Size(max = 40) List<@Valid @NotNull CountLine> counts,
            @Size(max = 500) String note) {
    }

    public record CashCountRequest(
            @NotNull @Size(max = 40) List<@Valid @NotNull CountLine> counts,
            @Size(max = 500) String note) {
    }

    public record LockRequest(@NotNull @Pattern(regexp = "MANUAL|IDLE") String reason) {
    }

    public record CancelRequest(@NotBlank @Size(min = 5, max = 500) String reason) {
    }

    public record CountItemView(BigDecimal value, String kind, int quantity, BigDecimal subtotal) {
    }

    public record CashCountView(
            UUID id,
            String countType,
            BigDecimal totalAmount,
            BigDecimal expectedAmount,
            BigDecimal difference,
            String note,
            OffsetDateTime countedAt,
            String countedByUsername,
            List<CountItemView> items) {

        CashCountView withItems(List<CountItemView> i) {
            return new CashCountView(id, countType, totalAmount, expectedAmount, difference, note, countedAt,
                    countedByUsername, i);
        }
    }

    public record SessionView(
            UUID id,
            UUID employeeId,
            String employeeCode,
            String employeeName,
            UUID outletId,
            String outletCode,
            UUID terminalId,
            String terminalCode,
            String terminalName,
            LocalDate businessDate,
            OffsetDateTime openedAt,
            OffsetDateTime closedAt,
            BigDecimal openingCash,
            BigDecimal expectedCash,
            String status,
            OffsetDateTime lockedAt,
            String lockReason,
            String cancelReason,
            int version,
            List<CashCountView> counts) {

        SessionView withCounts(List<CashCountView> c) {
            return new SessionView(id, employeeId, employeeCode, employeeName, outletId, outletCode, terminalId,
                    terminalCode, terminalName, businessDate, openedAt, closedAt, openingCash, expectedCash, status,
                    lockedAt, lockReason, cancelReason, version, c);
        }
    }

    /** Info terminal yang dibutuhkan saat membuka kasir (dibaca di bawah RLS). */
    public record TerminalInfo(UUID id, UUID outletId, String code, boolean active) {
    }
}
