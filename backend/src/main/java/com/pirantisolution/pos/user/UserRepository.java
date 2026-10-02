package com.pirantisolution.pos.user;

import com.pirantisolution.pos.user.UserDtos.OutletRef;
import com.pirantisolution.pos.user.UserDtos.RoleGrant;
import com.pirantisolution.pos.user.UserDtos.UserView;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
public class UserRepository {

    private static final String SELECT = """
            SELECT u.id, u.username, u.email, u.display_name, u.employee_id,
                   e.employee_code, e.full_name AS employee_name, u.active, u.last_login_at, u.version
            FROM pos.users u
            LEFT JOIN pos.employees e ON e.id = u.employee_id
            """;

    private final JdbcClient jdbc;

    public UserRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public List<UserView> findAll(String q, Boolean active) {
        return jdbc.sql(SELECT + """
                WHERE (CAST(:active AS boolean) IS NULL OR u.active = CAST(:active AS boolean))
                  AND (CAST(:q AS text) IS NULL
                       OR u.username ILIKE '%' || CAST(:q AS text) || '%'
                       OR u.display_name ILIKE '%' || CAST(:q AS text) || '%'
                       OR u.email ILIKE '%' || CAST(:q AS text) || '%')
                ORDER BY u.username
                LIMIT 500
                """)
                .param("active", active)
                .param("q", q == null || q.isBlank() ? null
                        : q.trim().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_"))
                .query(UserRepository::mapUser)
                .list();
    }

    public Optional<UserView> findById(UUID id) {
        return jdbc.sql(SELECT + " WHERE u.id = :id")
                .param("id", id)
                .query(UserRepository::mapUser)
                .optional()
                .map(u -> u.withAccess(roles(id), outlets(id)));
    }

    private static UserView mapUser(ResultSet rs, int rowNum) throws SQLException {
        return new UserView(
                rs.getObject("id", UUID.class),
                rs.getString("username"),
                rs.getString("email"),
                rs.getString("display_name"),
                rs.getObject("employee_id", UUID.class),
                rs.getString("employee_code"),
                rs.getString("employee_name"),
                rs.getBoolean("active"),
                rs.getObject("last_login_at", OffsetDateTime.class),
                rs.getInt("version"),
                List.of(),
                List.of());
    }

    public Optional<UUID> findAuthUserId(UUID userId) {
        return jdbc.sql("SELECT auth_user_id FROM pos.users WHERE id = :id")
                .param("id", userId).query(UUID.class).optional();
    }

    public List<RoleGrant> roles(UUID userId) {
        return jdbc.sql("""
                SELECT ur.role_id, r.code AS role_code, r.name AS role_name, r.rank, ur.outlet_id,
                       o.code AS outlet_code
                FROM pos.user_roles ur
                JOIN pos.roles r ON r.id = ur.role_id
                LEFT JOIN pos.outlets o ON o.id = ur.outlet_id
                WHERE ur.user_id = :id
                ORDER BY r.rank DESC, o.code NULLS FIRST
                """)
                .param("id", userId).query(RoleGrant.class).list();
    }

    public List<OutletRef> outlets(UUID userId) {
        return jdbc.sql("""
                SELECT uo.outlet_id, o.code AS outlet_code, o.name AS outlet_name
                FROM pos.user_outlets uo
                JOIN pos.outlets o ON o.id = uo.outlet_id
                WHERE uo.user_id = :id
                ORDER BY o.code
                """)
                .param("id", userId).query(OutletRef.class).list();
    }

    public boolean usernameOrEmailTaken(String username, String email) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM pos.users
                               WHERE lower(username) = lower(:u) OR lower(email) = lower(:e))
                """)
                .param("u", username).param("e", email).query(Boolean.class).single();
    }

    public boolean employeeLinked(UUID employeeId, UUID exceptUserId) {
        return jdbc.sql("""
                SELECT EXISTS (SELECT 1 FROM pos.users
                               WHERE employee_id = :e AND (CAST(:u AS uuid) IS NULL OR id <> CAST(:u AS uuid)))
                """)
                .param("e", employeeId).param("u", exceptUserId).query(Boolean.class).single();
    }

    public UUID insert(UUID authUserId, String username, String email, String displayName, UUID employeeId,
            UUID actorId) {
        return jdbc.sql("""
                INSERT INTO pos.users (auth_user_id, organization_id, employee_id, username, email, display_name,
                                       created_by, updated_by)
                VALUES (:auth, pos.current_org_id(), CAST(:emp AS uuid), :username, :email, :display, :actor, :actor)
                RETURNING id
                """)
                .param("auth", authUserId)
                .param("emp", employeeId)
                .param("username", username)
                .param("email", email)
                .param("display", displayName)
                .param("actor", actorId)
                .query(UUID.class).single();
    }

    public Optional<UUID> update(UUID id, String displayName, UUID employeeId, boolean active, int version,
            UUID actorId) {
        return jdbc.sql("""
                UPDATE pos.users
                SET display_name = :display, employee_id = CAST(:emp AS uuid), active = :active, updated_by = :actor
                WHERE id = :id AND version = :version
                RETURNING id
                """)
                .param("display", displayName)
                .param("emp", employeeId)
                .param("active", active)
                .param("actor", actorId)
                .param("id", id)
                .param("version", version)
                .query(UUID.class).optional();
    }

    public void grantRole(UUID userId, UUID roleId, UUID outletId, UUID actorId) {
        jdbc.sql("""
                INSERT INTO pos.user_roles (user_id, role_id, outlet_id, granted_by)
                VALUES (:u, :r, CAST(:o AS uuid), :actor)
                """)
                .param("u", userId).param("r", roleId).param("o", outletId).param("actor", actorId)
                .update();
    }

    public int revokeRole(UUID userId, UUID roleId, UUID outletId) {
        return jdbc.sql("""
                DELETE FROM pos.user_roles
                WHERE user_id = :u AND role_id = :r AND outlet_id IS NOT DISTINCT FROM CAST(:o AS uuid)
                """)
                .param("u", userId).param("r", roleId).param("o", outletId)
                .update();
    }

    public void grantOutlet(UUID userId, UUID outletId, UUID actorId) {
        jdbc.sql("INSERT INTO pos.user_outlets (user_id, outlet_id, granted_by) VALUES (:u, :o, :actor)")
                .param("u", userId).param("o", outletId).param("actor", actorId)
                .update();
    }

    public int revokeOutlet(UUID userId, UUID outletId) {
        return jdbc.sql("DELETE FROM pos.user_outlets WHERE user_id = :u AND outlet_id = :o")
                .param("u", userId).param("o", outletId)
                .update();
    }

    /** Rank role; null jika role tidak ada. */
    public Optional<RoleInfo> role(UUID roleId) {
        return jdbc.sql("SELECT id, code, name, rank FROM pos.roles WHERE id = :id")
                .param("id", roleId).query(RoleInfo.class).optional();
    }

    public record RoleInfo(UUID id, String code, String name, int rank) {
    }
}
