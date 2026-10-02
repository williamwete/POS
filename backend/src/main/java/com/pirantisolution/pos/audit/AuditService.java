package com.pirantisolution.pos.audit;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.common.web.RequestContext;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Menulis audit log di DALAM transaksi bisnis yang sama (MANDATORY), sehingga perubahan
 * data dan jejak auditnya selalu commit/rollback bersama.
 *
 * <p>Aktor diambil dari database (pos.current_app_user_id), bukan dari input client,
 * dan policy RLS menolak aktor yang dipalsukan.
 */
@Service
@Transactional(propagation = Propagation.MANDATORY)
public class AuditService {

    private final JdbcClient jdbc;
    private final ObjectMapper objectMapper;

    public AuditService(JdbcClient jdbc, ObjectMapper objectMapper) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
    }

    /** Audit untuk aksi user yang sedang request. */
    public void record(AuditEvent event) {
        jdbc.sql("""
                INSERT INTO pos.audit_logs (
                    organization_id, actor_user_id, actor_employee_id, actor_type,
                    action, entity_type, entity_id, outlet_id, terminal_id,
                    old_value, new_value, reason, ip_address, device_id, request_id)
                VALUES (
                    pos.current_org_id(), pos.current_app_user_id(), pos.current_employee_id(), 'USER',
                    :action, :entityType, :entityId, CAST(:outletId AS uuid), CAST(:terminalId AS uuid),
                    CAST(:oldValue AS jsonb), CAST(:newValue AS jsonb), :reason,
                    CAST(:ip AS inet), :deviceId, :requestId)
                """)
                .param("action", event.action())
                .param("entityType", event.entityType())
                .param("entityId", event.entityId())
                .param("outletId", event.outletId())
                .param("terminalId", RequestContext.terminalId())
                .param("oldValue", toJson(event.oldValue()))
                .param("newValue", toJson(event.newValue()))
                .param("reason", event.reason())
                .param("ip", RequestContext.clientIp())
                .param("deviceId", RequestContext.deviceId())
                .param("requestId", RequestContext.requestId())
                .update();
    }

    /** Audit untuk aksi sistem (dipanggil dalam transaksi pos_system). */
    public void recordSystem(UUID organizationId, AuditEvent event) {
        jdbc.sql("""
                INSERT INTO pos.audit_logs (
                    organization_id, actor_type, action, entity_type, entity_id, outlet_id,
                    old_value, new_value, reason, request_id)
                VALUES (
                    CAST(:orgId AS uuid), 'SYSTEM', :action, :entityType, :entityId, CAST(:outletId AS uuid),
                    CAST(:oldValue AS jsonb), CAST(:newValue AS jsonb), :reason, :requestId)
                """)
                .param("orgId", organizationId)
                .param("action", event.action())
                .param("entityType", event.entityType())
                .param("entityId", event.entityId())
                .param("outletId", event.outletId())
                .param("oldValue", toJson(event.oldValue()))
                .param("newValue", toJson(event.newValue()))
                .param("reason", event.reason())
                .param("requestId", RequestContext.requestId())
                .update();
    }

    private String toJson(Object value) {
        if (value == null) {
            return null;
        }
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Cannot serialize audit value", e);
        }
    }
}
