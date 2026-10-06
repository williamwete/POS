package com.pirantisolution.pos.cashier;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Email;
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
            int idleLockMinutes,
            // hasil tutup kasir (hanya terisi bila CLOSED)
            BigDecimal closingCash,
            BigDecimal difference,
            String differenceReason,
            String differenceNote,
            String closedByName,
            String differenceApprovedByName,
            List<CashCountView> counts) {

        SessionView withCounts(List<CashCountView> c) {
            return new SessionView(id, employeeId, employeeCode, employeeName, outletId, outletCode, terminalId,
                    terminalCode, terminalName, businessDate, openedAt, closedAt, openingCash, expectedCash, status,
                    lockedAt, lockReason, cancelReason, version, idleLockMinutes, closingCash, difference,
                    differenceReason, differenceNote, closedByName, differenceApprovedByName, c);
        }
    }

    // ------------------------------------------------------------------ Phase 6: kas & tutup kasir

    /** Kas masuk/keluar/petty cash oleh pemegang laci. Nominal selalu positif; arah dari jenisnya. */
    public record CashMovementRequest(
            @NotNull @Pattern(regexp = "CASH_IN|CASH_OUT|PETTY_CASH") String type,
            @NotNull @DecimalMin("1") BigDecimal amount,
            @NotBlank @Size(min = 3, max = 500) String reason,
            UUID approvalId) {
    }

    /** Penyesuaian kas oleh atasan (bertanda: + menambah, − mengurangi isi laci). */
    public record AdjustmentRequest(
            @NotNull BigDecimal amount,
            @NotBlank @Size(min = 5, max = 500) String reason) {
    }

    public record MovementView(
            UUID id,
            String movementType,
            BigDecimal amount,
            String reason,
            String referenceType,
            OffsetDateTime createdAt,
            String createdByName,
            String approvedByName) {
    }

    public record ClosePreviewRequest(@NotNull @Size(max = 40) List<@Valid @NotNull CountLine> counts) {
    }

    /** Ringkasan sebelum tutup kasir: dihitung server dari hitungan fisik (tidak menulis apa pun selain audit). */
    public record ClosePreview(
            BigDecimal countedCash,
            BigDecimal expectedCash,
            BigDecimal difference,
            BigDecimal approvalThreshold,
            boolean reasonRequired,
            boolean approvalRequired,
            int openOrders,
            int pendingPayments,
            int pendingReturns,
            boolean allowCloseWithOpenOrders) {
    }

    public record CloseRequest(
            @NotNull @Size(max = 40) List<@Valid @NotNull CountLine> counts,
            @Pattern(regexp = "SHORTAGE|OVERAGE|WRONG_CHANGE|COUNTING_ERROR|OTHER") String differenceReason,
            @Size(max = 500) String differenceNote,
            UUID approvalId,
            @Size(max = 500) String note) {
    }

    /** Approval supervisor untuk kas keluar besar / selisih kas (rate limit seperti login). */
    public record CashApprovalRequest(
            @NotNull @Pattern(regexp = "CASH_OUT|CASH_DIFFERENCE") String action,
            @NotNull UUID sessionId,
            @NotNull @DecimalMin("1") BigDecimal amount,
            @NotBlank @Email @Size(max = 254) String email,
            @NotBlank @Size(max = 200) String password) {

        /** Password tidak pernah muncul di log. */
        @Override
        public String toString() {
            return "CashApprovalRequest[action=" + action + ", sessionId=" + sessionId + "]";
        }
    }

    public record CashApprovalView(UUID id, String action, String approverName, BigDecimal amount,
            OffsetDateTime expiresAt) {
    }

    /** Info terminal yang dibutuhkan saat membuka kasir (dibaca di bawah RLS). */
    public record TerminalInfo(UUID id, UUID outletId, String code, boolean active) {
    }
}
