package com.pirantisolution.pos.audit;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.common.api.PageResult;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.security.AccessService;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class AuditQueryService {

    private final JdbcClient jdbc;
    private final AccessService access;
    private final ObjectMapper objectMapper;

    public AuditQueryService(JdbcClient jdbc, AccessService access, ObjectMapper objectMapper) {
        this.jdbc = jdbc;
        this.access = access;
        this.objectMapper = objectMapper;
    }

    public record Filter(String action, String entityType, String entityId, UUID outletId,
            UUID actorUserId, OffsetDateTime from, OffsetDateTime to, int page, int size) {
    }

    @Transactional(readOnly = true)
    public PageResult<AuditLogView> search(Filter f) {
        access.currentUser();
        boolean orgWide = access.has("audit.view", null);
        if (!orgWide && (f.outletId() == null || !access.has("audit.view", f.outletId()))) {
            throw new ApiException(ErrorCode.USER_NOT_AUTHORIZED);
        }
        int size = Math.min(Math.max(f.size(), 1), 200);
        int page = Math.max(f.page(), 0);

        StringBuilder where = new StringBuilder(" WHERE 1=1");
        List<Object[]> params = new ArrayList<>();
        if (f.action() != null) {
            where.append(" AND a.action = :action");
            params.add(new Object[] {"action", f.action()});
        }
        if (f.entityType() != null) {
            where.append(" AND a.entity_type = :entityType");
            params.add(new Object[] {"entityType", f.entityType()});
        }
        if (f.entityId() != null) {
            where.append(" AND a.entity_id = :entityId");
            params.add(new Object[] {"entityId", f.entityId()});
        }
        if (f.outletId() != null) {
            where.append(" AND a.outlet_id = :outletId");
            params.add(new Object[] {"outletId", f.outletId()});
        }
        if (f.actorUserId() != null) {
            where.append(" AND a.actor_user_id = :actorUserId");
            params.add(new Object[] {"actorUserId", f.actorUserId()});
        }
        if (f.from() != null) {
            where.append(" AND a.created_at >= :from");
            params.add(new Object[] {"from", f.from()});
        }
        if (f.to() != null) {
            where.append(" AND a.created_at < :to");
            params.add(new Object[] {"to", f.to()});
        }

        // RLS membatasi baris sesuai audit.view (org-wide atau outlet).
        JdbcClient.StatementSpec count = jdbc.sql("SELECT count(*) FROM pos.audit_logs a" + where);
        JdbcClient.StatementSpec list = jdbc.sql("""
                SELECT a.id, a.seq, a.actor_type, a.actor_user_id, u.username AS actor_username,
                       a.actor_employee_id, a.action, a.entity_type, a.entity_id, a.outlet_id,
                       a.terminal_id, a.old_value::text AS old_value, a.new_value::text AS new_value,
                       a.reason, host(a.ip_address) AS ip_address, a.device_id, a.request_id, a.created_at
                FROM pos.audit_logs a
                LEFT JOIN pos.users u ON u.id = a.actor_user_id
                """ + where + " ORDER BY a.seq DESC LIMIT :limit OFFSET :offset");
        for (Object[] p : params) {
            count = count.param((String) p[0], p[1]);
            list = list.param((String) p[0], p[1]);
        }
        long total = count.query(Long.class).single();
        List<AuditLogView> items = list
                .param("limit", size)
                .param("offset", (long) page * size)
                .query(this::map)
                .list();
        return new PageResult<>(items, page, size, total);
    }

    private AuditLogView map(ResultSet rs, int rowNum) throws SQLException {
        return new AuditLogView(
                rs.getObject("id", UUID.class),
                rs.getLong("seq"),
                rs.getString("actor_type"),
                rs.getObject("actor_user_id", UUID.class),
                rs.getString("actor_username"),
                rs.getObject("actor_employee_id", UUID.class),
                rs.getString("action"),
                rs.getString("entity_type"),
                rs.getString("entity_id"),
                rs.getObject("outlet_id", UUID.class),
                rs.getObject("terminal_id", UUID.class),
                json(rs.getString("old_value")),
                json(rs.getString("new_value")),
                rs.getString("reason"),
                rs.getString("ip_address"),
                rs.getString("device_id"),
                rs.getString("request_id"),
                rs.getObject("created_at", OffsetDateTime.class));
    }

    private JsonNode json(String raw) {
        if (raw == null) {
            return null;
        }
        try {
            return objectMapper.readTree(raw);
        } catch (JsonProcessingException e) {
            return null;
        }
    }
}
