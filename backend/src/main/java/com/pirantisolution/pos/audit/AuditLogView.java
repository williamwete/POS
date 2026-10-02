package com.pirantisolution.pos.audit;

import com.fasterxml.jackson.databind.JsonNode;
import java.time.OffsetDateTime;
import java.util.UUID;

public record AuditLogView(
        UUID id,
        long seq,
        String actorType,
        UUID actorUserId,
        String actorUsername,
        UUID actorEmployeeId,
        String action,
        String entityType,
        String entityId,
        UUID outletId,
        UUID terminalId,
        JsonNode oldValue,
        JsonNode newValue,
        String reason,
        String ipAddress,
        String deviceId,
        String requestId,
        OffsetDateTime createdAt) {
}
