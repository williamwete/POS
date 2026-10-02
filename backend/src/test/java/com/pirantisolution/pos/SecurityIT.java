package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

/**
 * §87 SECURITY TEST & §88 RLS TEST melalui API (lapisan service + RLS).
 */
class SecurityIT extends IntegrationTestBase {

    @Test
    void cashierSeesOnlyOwnOutlet() throws Exception {
        JsonNode outlets = body(getAs("cashier.jkt", "/api/outlets")).get("data");
        assertThat(outlets).hasSize(1);
        assertThat(outlets.get(0).get("code").asText()).isEqualTo("JKT01");

        MvcResult other = getAs("cashier.jkt", "/api/outlets/" + OUTLET_BDG);
        assertThat(other.getResponse().getStatus()).isEqualTo(403);
        assertThat(body(other).get("errorCode").asText()).isEqualTo("OUTLET_ACCESS_DENIED");

        MvcResult terminals = getAs("cashier.jkt", "/api/terminals?outletId=" + OUTLET_BDG);
        assertThat(terminals.getResponse().getStatus()).isEqualTo(403);
    }

    @Test
    void supervisorAndManagerScopes() throws Exception {
        assertThat(body(getAs("supervisor.jkt", "/api/outlets")).get("data")).hasSize(1);
        assertThat(body(getAs("manager", "/api/outlets")).get("data")).hasSize(2);
        assertThat(body(getAs("auditor", "/api/outlets")).get("data")).hasSize(2);
    }

    @Test
    void cashierCannotManageMasterData() throws Exception {
        MvcResult terminal = postAs("cashier.jkt", "/api/terminals",
                Map.of("outletId", OUTLET_JKT, "code", unique("POS-X"), "name", "Hack"));
        assertThat(terminal.getResponse().getStatus()).isEqualTo(403);
        assertThat(body(terminal).get("errorCode").asText()).isEqualTo("USER_NOT_AUTHORIZED");

        MvcResult outlet = postAs("cashier.jkt", "/api/outlets", Map.of("code", unique("HX"), "name", "Hack"));
        assertThat(outlet.getResponse().getStatus()).isEqualTo(403);

        MvcResult users = postAs("cashier.jkt", "/api/users", Map.of(
                "username", "hacker", "email", "h@demo.local", "displayName", "x",
                "password", "Password123", "roles", List.of(), "outletIds", List.of()));
        assertThat(users.getResponse().getStatus()).isEqualTo(403);
    }

    @Test
    void auditorIsReadOnly() throws Exception {
        MvcResult r = postAs("auditor", "/api/employees", Map.of("employeeCode", unique("E"), "fullName", "x"));
        assertThat(r.getResponse().getStatus()).isEqualTo(403);
        assertThat(getAs("auditor", "/api/audit-logs").getResponse().getStatus()).isEqualTo(200);
    }

    @Test
    void cashierCannotReadAuditLog() throws Exception {
        assertThat(getAs("cashier.jkt", "/api/audit-logs").getResponse().getStatus()).isEqualTo(403);
        assertThat(getAs("cashier.jkt", "/api/audit-logs?outletId=" + OUTLET_JKT).getResponse().getStatus())
                .isEqualTo(403);
    }

    @Test
    void noEndpointCanModifyAuditLog() throws Exception {
        MvcResult r = postAs("superadmin", "/api/audit-logs", Map.of("action", "X"));
        assertThat(r.getResponse().getStatus()).isIn(404, 405);
    }

    @Test
    void cannotModifyOwnAccess() throws Exception {
        MvcResult r = putAs("admin", "/api/users/" + USER_ADMIN + "/roles", Map.of("roles", List.of()));
        assertThat(r.getResponse().getStatus()).isEqualTo(403);
        assertThat(body(r).get("errorCode").asText()).isEqualTo("SELF_MODIFICATION_NOT_ALLOWED");
    }

    @Test
    void adminCannotEscalateOrTouchSuperiors() throws Exception {
        JsonNode roles = body(getAs("admin", "/api/roles")).get("data");
        String superAdminRoleId = null;
        for (JsonNode role : roles) {
            if ("SUPER_ADMIN".equals(role.get("code").asText())) {
                superAdminRoleId = role.get("id").asText();
            }
        }
        assertThat(superAdminRoleId).isNotNull();

        MvcResult grant = putAs("admin", "/api/users/" + USER_CASHIER_JKT + "/roles",
                Map.of("roles", List.of(Map.of("roleId", superAdminRoleId))));
        assertThat(grant.getResponse().getStatus()).isEqualTo(403);
        assertThat(body(grant).get("errorCode").asText()).isEqualTo("ROLE_ASSIGNMENT_NOT_ALLOWED");

        MvcResult deactivate = putAs("admin", "/api/users/" + USER_SUPERADMIN,
                Map.of("displayName", "x", "active", false, "version", 0));
        assertThat(deactivate.getResponse().getStatus()).isEqualTo(403);
    }

    /** Regresi V008: INSERT ... RETURNING oleh admin sempat ditolak RLS. */
    @Test
    void adminCanCreateOutletAndSeeIt() throws Exception {
        String code = unique("SB").replace("-", "").substring(0, 10);
        MvcResult created = postAs("admin", "/api/outlets", Map.of("code", code, "name", "Outlet Baru"));
        assertThat(created.getResponse().getStatus()).isEqualTo(201);
        String id = body(created).at("/data/id").asText();
        assertThat(getAs("admin", "/api/outlets/" + id).getResponse().getStatus()).isEqualTo(200);
        // kasir JKT tidak bisa melihat outlet baru
        assertThat(getAs("cashier.jkt", "/api/outlets/" + id).getResponse().getStatus()).isEqualTo(403);
    }

    @Test
    void unknownJsonFieldsAreRejected() throws Exception {
        MvcResult r = postAs("admin", "/api/outlets",
                Map.of("code", unique("OK"), "name", "x", "organizationId", ORG));
        assertThat(r.getResponse().getStatus()).isEqualTo(400);
        assertThat(body(r).get("errorCode").asText()).isEqualTo("MALFORMED_REQUEST");
    }
}
