package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

/** Siklus hidup user: buat -> login -> nonaktif -> akses hilang; plus audit & optimistic lock. */
class UserManagementIT extends IntegrationTestBase {

    private String roleId(String code) throws Exception {
        for (JsonNode role : body(getAs("admin", "/api/roles")).get("data")) {
            if (code.equals(role.get("code").asText())) {
                return role.get("id").asText();
            }
        }
        throw new IllegalStateException(code);
    }

    private String login(String email, String password) throws Exception {
        MvcResult r = mvc.perform(post("/api/dev-auth/token").contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("email", email, "password", password)))).andReturn();
        return r.getResponse().getStatus() == 200 ? body(r).at("/data/accessToken").asText() : null;
    }

    @Test
    void createLoginDeactivate() throws Exception {
        String username = ("kasir." + unique("x")).toLowerCase();
        String email = username + "@demo.local";
        String password = "KasirBaru2026";

        // Admin membuat kasir baru di JKT01
        MvcResult created = postAs("admin", "/api/users", Map.of(
                "username", username, "email", email, "displayName", "Kasir Baru",
                "password", password,
                "outletIds", List.of(OUTLET_JKT),
                "roles", List.of(Map.of("roleId", roleId("CASHIER"), "outletId", OUTLET_JKT))));
        assertThat(created.getResponse().getStatus()).isEqualTo(201);
        assertThat(created.getResponse().getContentAsString()).doesNotContain(password);
        JsonNode user = body(created).get("data");
        String userId = user.get("id").asText();
        assertThat(user.get("roles")).hasSize(1);

        // User baru bisa login & mendapat permission kasir di JKT01 saja
        String token = login(email, password);
        assertThat(token).isNotNull();
        JsonNode me = body(mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + token)).andReturn())
                .get("data");
        assertThat(me.get("outlets")).hasSize(1);

        // Audit tercatat dengan aktor admin
        JsonNode audit = body(getAs("auditor", "/api/audit-logs?entityType=USER&entityId=" + userId)).at("/data/items");
        assertThat(audit).isNotEmpty();
        boolean createdLogged = false;
        for (JsonNode a : audit) {
            if ("USER_CREATED".equals(a.get("action").asText())) {
                createdLogged = true;
                assertThat(a.get("actorUsername").asText()).isEqualTo("admin");
                assertThat(a.toString()).doesNotContain(password);
            }
        }
        assertThat(createdLogged).isTrue();

        // Nonaktifkan -> token lama langsung tidak berlaku di DB, login baru ditolak
        MvcResult deactivated = putAs("admin", "/api/users/" + userId,
                Map.of("displayName", "Kasir Baru", "active", false, "version", user.get("version").asInt()));
        assertThat(deactivated.getResponse().getStatus()).isEqualTo(200);

        MvcResult afterDeactivate = mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + token))
                .andReturn();
        assertThat(afterDeactivate.getResponse().getStatus()).isEqualTo(403);
        assertThat(body(afterDeactivate).get("errorCode").asText()).isEqualTo("USER_NOT_PROVISIONED");
        assertThat(login(email, password)).isNull();
    }

    @Test
    void outletScopedRoleRequiresOutletAccess() throws Exception {
        MvcResult r = postAs("admin", "/api/users", Map.of(
                "username", ("x." + unique("y")).toLowerCase(), "email", unique("e").toLowerCase() + "@demo.local",
                "displayName", "X", "password", "Password2026",
                "outletIds", List.of(),
                "roles", List.of(Map.of("roleId", roleId("CASHIER"), "outletId", OUTLET_BDG))));
        assertThat(r.getResponse().getStatus()).isEqualTo(400);
    }

    @Test
    void weakPasswordIsRejected() throws Exception {
        MvcResult r = postAs("admin", "/api/users", Map.of(
                "username", ("x." + unique("y")).toLowerCase(), "email", unique("e").toLowerCase() + "@demo.local",
                "displayName", "X", "password", "onlyletters",
                "outletIds", List.of(), "roles", List.of()));
        assertThat(r.getResponse().getStatus()).isEqualTo(400);
    }

    @Test
    void staleVersionIsRejected() throws Exception {
        JsonNode terminal = body(getAs("admin", "/api/terminals/" + TERMINAL_JKT_01)).get("data");
        int version = terminal.get("version").asInt();
        Map<String, Object> update = new java.util.HashMap<>();
        update.put("name", terminal.get("name").asText());
        update.put("printerId", PRINTER_JKT_01);
        update.put("cashDrawerId", DRAWER_JKT_01);
        update.put("active", true);
        update.put("version", version);

        MvcResult first = putAs("admin", "/api/terminals/" + TERMINAL_JKT_01, update);
        assertThat(first.getResponse().getStatus()).isEqualTo(200);
        MvcResult stale = putAs("admin", "/api/terminals/" + TERMINAL_JKT_01, update);
        assertThat(stale.getResponse().getStatus()).isEqualTo(409);
        assertThat(body(stale).get("errorCode").asText()).isEqualTo("CONCURRENT_MODIFICATION");
    }

    @Test
    void deviceFromOtherOutletIsRejected() throws Exception {
        MvcResult r = postAs("admin", "/api/terminals", Map.of(
                "outletId", OUTLET_JKT, "code", unique("POS-JKT"), "name", "x", "printerId", PRINTER_BDG_01));
        assertThat(r.getResponse().getStatus()).isEqualTo(422);
        assertThat(body(r).get("errorCode").asText()).isEqualTo("INVALID_DEVICE");
    }

    @Test
    void managerManagesEmployeesOnlyInOwnOutlets() throws Exception {
        MvcResult ok = postAs("manager", "/api/employees", Map.of(
                "employeeCode", unique("E"), "fullName", "Staf Baru", "homeOutletId", OUTLET_JKT));
        assertThat(ok.getResponse().getStatus()).isEqualTo(201);

        MvcResult hq = postAs("manager", "/api/employees", Map.of("employeeCode", unique("E"), "fullName", "Staf Pusat"));
        assertThat(hq.getResponse().getStatus()).isEqualTo(403);
    }
}
