package com.pirantisolution.pos.integration;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class SyncDtos {

    private SyncDtos() {
    }

    public record SyncJobView(
            UUID id,
            String jobType,
            String direction,
            UUID entityId,
            String entityRef,
            UUID outletId,
            String outletCode,
            String status,
            int attempts,
            int maxAttempts,
            OffsetDateTime nextAttemptAt,
            String lastError,
            String openbravoDocumentId,
            String openbravoDocumentNo,
            OffsetDateTime syncStartedAt,
            OffsetDateTime syncFinishedAt,
            int recordsProcessed,
            int recordsSuccess,
            int recordsFailed,
            int errorCount,
            String requestedByName,
            OffsetDateTime createdAt,
            OffsetDateTime updatedAt) {
    }

    public record SyncLogView(int attempt, String status, String message, Integer durationMs, OffsetDateTime createdAt) {
    }

    public record SyncJobDetail(SyncJobView job, List<SyncLogView> logs) {
    }

    public record StatusCount(String jobType, String status, long count) {
    }

    public record SyncStatus(String mode, boolean enabled, boolean workerEnabled, List<StatusCount> counts,
            List<SyncJobView> lastMasterSyncs, OffsetDateTime oldestPendingAt) {
    }

    public record RunRequest(@Size(max = 4) List<@Pattern(regexp = "MASTER_PRODUCT|MASTER_PRICE|MASTER_STOCK|MASTER_CUSTOMER") String> types) {
    }

    public record RunSummary(int processed, int success, int failed, int deferred, boolean busy) {
    }

    public record RunResult(List<SyncJobView> requested, RunSummary summary) {
    }

    public record MappingView(String entityType, UUID posId, String posCode, String posName, String openbravoId,
            Integer version, OffsetDateTime updatedAt, String updatedByName) {
    }

    public record MappingRequest(
            @NotNull @Pattern(regexp = "ORGANIZATION|OUTLET|WAREHOUSE|TERMINAL|PAYMENT_METHOD|TAX") String entityType,
            @NotNull UUID posId,
            @NotBlank @Pattern(regexp = "[A-Za-z0-9._:-]{1,64}") String openbravoId) {
    }
}
