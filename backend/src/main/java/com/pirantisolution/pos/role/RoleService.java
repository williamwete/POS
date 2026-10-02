package com.pirantisolution.pos.role;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Katalog role & permission. Mengubah permission role butuh role.manage org-wide, role
 * target di bawah rank pengubah, dan hanya permission yang dipegang sendiri (A7).
 */
@Service
public class RoleService {

    public record PermissionView(String code, String module, String description) {
    }

    public record RoleView(UUID id, String code, String name, String description, boolean system, int rank,
            List<String> permissions) {
    }

    public record SetPermissionsRequest(@NotNull @Size(max = 200) List<@NotNull String> permissionCodes) {
    }

    private record RoleRow(UUID id, String code, String name, String description, boolean isSystem, int rank) {
    }

    private final JdbcClient jdbc;
    private final AccessService access;
    private final AuditService audit;

    public RoleService(JdbcClient jdbc, AccessService access, AuditService audit) {
        this.jdbc = jdbc;
        this.access = access;
        this.audit = audit;
    }

    @Transactional(readOnly = true)
    public List<PermissionView> permissions() {
        access.currentUser();
        return jdbc.sql("SELECT code, module, description FROM pos.permissions ORDER BY module, code")
                .query(PermissionView.class).list();
    }

    @Transactional(readOnly = true)
    public List<RoleView> roles() {
        access.currentUser();
        List<RoleRow> rows = jdbc.sql("""
                SELECT id, code, name, description, is_system, rank FROM pos.roles ORDER BY rank DESC, code
                """).query(RoleRow.class).list();
        return rows.stream().map(r -> new RoleView(r.id(), r.code(), r.name(), r.description(), r.isSystem(),
                r.rank(), permissionsOf(r.id()))).toList();
    }

    @Transactional
    public RoleView setPermissions(UUID roleId, List<String> requested) {
        access.requireOrg("role.manage");
        CurrentUser actor = access.currentUser();
        RoleRow role = jdbc.sql("SELECT id, code, name, description, is_system, rank FROM pos.roles WHERE id = :id")
                .param("id", roleId).query(RoleRow.class).optional()
                .orElseThrow(() -> ApiException.notFound("Role"));
        int myRank = jdbc.sql("SELECT pos.current_max_rank()").query(Integer.class).single();
        if (role.rank() >= myRank) {
            throw new ApiException(ErrorCode.ROLE_ASSIGNMENT_NOT_ALLOWED,
                    "Tidak dapat mengubah role dengan rank setara atau di atas Anda");
        }

        Set<String> target = new LinkedHashSet<>(requested);
        Set<String> current = new LinkedHashSet<>(permissionsOf(roleId));
        Set<String> toGrant = new LinkedHashSet<>(target);
        toGrant.removeAll(current);
        Set<String> toRevoke = new HashSet<>(current);
        toRevoke.removeAll(target);

        for (String p : toGrant) {
            Boolean exists = jdbc.sql("SELECT EXISTS (SELECT 1 FROM pos.permissions WHERE code = :c)")
                    .param("c", p).query(Boolean.class).single();
            if (!Boolean.TRUE.equals(exists)) {
                throw ApiException.validation("Permission tidak dikenal: " + p);
            }
            if (!access.has(p, null)) {
                throw new ApiException(ErrorCode.ROLE_ASSIGNMENT_NOT_ALLOWED,
                        "Anda tidak dapat menambahkan permission yang tidak Anda miliki: " + p);
            }
        }

        for (String p : toRevoke) {
            jdbc.sql("DELETE FROM pos.role_permissions WHERE role_id = :r AND permission_code = :p")
                    .param("r", roleId).param("p", p).update();
            audit.record(AuditEvent.of("ROLE_PERMISSION_REVOKED", "ROLE", roleId)
                    .change(Map.of("role", role.code(), "permission", p), null));
        }
        for (String p : toGrant) {
            jdbc.sql("""
                    INSERT INTO pos.role_permissions (role_id, permission_code, granted_by) VALUES (:r, :p, :actor)
                    """)
                    .param("r", roleId).param("p", p).param("actor", actor.userId()).update();
            audit.record(AuditEvent.of("ROLE_PERMISSION_GRANTED", "ROLE", roleId)
                    .change(null, Map.of("role", role.code(), "permission", p)));
        }
        return new RoleView(role.id(), role.code(), role.name(), role.description(), role.isSystem(), role.rank(),
                permissionsOf(roleId));
    }

    private List<String> permissionsOf(UUID roleId) {
        return jdbc.sql("SELECT permission_code FROM pos.role_permissions WHERE role_id = :r ORDER BY permission_code")
                .param("r", roleId).query(String.class).list();
    }
}
