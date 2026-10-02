package com.pirantisolution.pos.audit;

import java.util.UUID;

/**
 * Event audit (§47). oldValue/newValue diserialisasi ke JSON; JANGAN pernah memasukkan
 * password, token, atau data kartu.
 */
public record AuditEvent(
        String action,
        String entityType,
        String entityId,
        UUID outletId,
        Object oldValue,
        Object newValue,
        String reason) {

    public static AuditEvent of(String action, String entityType, Object entityId) {
        return new AuditEvent(action, entityType, entityId == null ? null : entityId.toString(),
                null, null, null, null);
    }

    public AuditEvent outlet(UUID outlet) {
        return new AuditEvent(action, entityType, entityId, outlet, oldValue, newValue, reason);
    }

    public AuditEvent change(Object before, Object after) {
        return new AuditEvent(action, entityType, entityId, outletId, before, after, reason);
    }

    public AuditEvent reason(String why) {
        return new AuditEvent(action, entityType, entityId, outletId, oldValue, newValue, why);
    }
}
