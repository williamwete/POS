package com.pirantisolution.pos.auth;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.db.SystemTx;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class AuthService {

    private final JdbcClient jdbc;
    private final AccessService access;
    private final AuditService audit;
    private final SystemTx systemTx;

    public AuthService(JdbcClient jdbc, AccessService access, AuditService audit, SystemTx systemTx) {
        this.jdbc = jdbc;
        this.access = access;
        this.audit = audit;
        this.systemTx = systemTx;
    }

    /**
     * Alur setelah login (§6): user -> employee -> role -> akses outlet -> permission.
     * Pengecekan cashier session aktif ditambahkan pada Phase 3.
     */
    @Transactional(readOnly = true)
    public MeResponse me() {
        CurrentUser cu = access.currentUser();

        MeResponse.UserInfo user = jdbc.sql("""
                SELECT id, username, email, display_name, last_login_at FROM pos.users WHERE id = :id
                """)
                .param("id", cu.userId())
                .query(MeResponse.UserInfo.class)
                .single();

        MeResponse.EmployeeInfo employee = cu.employeeId() == null ? null : jdbc.sql("""
                SELECT id, employee_code, full_name, position, home_outlet_id FROM pos.employees WHERE id = :id
                """)
                .param("id", cu.employeeId())
                .query(MeResponse.EmployeeInfo.class)
                .optional()
                .orElse(null);

        MeResponse.OrganizationInfo org = jdbc.sql("""
                SELECT id, code, name, timezone, currency FROM pos.organizations WHERE id = :id
                """)
                .param("id", cu.organizationId())
                .query(MeResponse.OrganizationInfo.class)
                .single();

        List<MeResponse.RoleAssignment> roles = jdbc.sql("""
                SELECT ur.role_id, r.code AS role_code, r.name AS role_name, ur.outlet_id, o.code AS outlet_code
                FROM pos.user_roles ur
                JOIN pos.roles r ON r.id = ur.role_id
                LEFT JOIN pos.outlets o ON o.id = ur.outlet_id
                WHERE ur.user_id = :id
                ORDER BY r.rank DESC, o.code NULLS FIRST
                """)
                .param("id", cu.userId())
                .query(MeResponse.RoleAssignment.class)
                .list();

        List<String> orgPermissions = access.effectivePermissions(null);

        record OutletRow(UUID id, String code, String name, String timezone, boolean active, String businessDate) {
        }
        List<OutletRow> outletRows = jdbc.sql("""
                SELECT o.id, o.code, o.name, coalesce(o.timezone, org.timezone) AS timezone, o.active,
                       pos.business_date(now(), o.id)::text AS business_date
                FROM pos.outlets o
                JOIN pos.organizations org ON org.id = o.organization_id
                ORDER BY o.code
                """)
                .query(OutletRow.class)
                .list();

        List<MeResponse.OutletAccess> outlets = outletRows.stream()
                .map(o -> new MeResponse.OutletAccess(o.id(), o.code(), o.name(), o.timezone(), o.active(),
                        o.businessDate(), access.effectivePermissions(o.id())))
                .toList();

        return new MeResponse(user, employee, org, roles, orgPermissions, outlets);
    }

    /** Dipanggil frontend tepat setelah login berhasil: audit LOGIN + last_login_at. */
    @Transactional
    public void startSession() {
        CurrentUser cu = access.currentUser();
        audit.record(AuditEvent.of("LOGIN", "USER", cu.userId()));
        // users_update policy melarang user mengubah barisnya sendiri; pakai konteks sistem
        // khusus untuk kolom last_login_at.
        systemTx.systemRun(() -> jdbc.sql("UPDATE pos.users SET last_login_at = :now WHERE id = :id")
                .param("now", OffsetDateTime.now())
                .param("id", cu.userId())
                .update());
    }

    @Transactional
    public void endSession() {
        CurrentUser cu = access.currentUser();
        audit.record(AuditEvent.of("LOGOUT", "USER", cu.userId()).change(null, Map.of("username", cu.username())));
    }
}
