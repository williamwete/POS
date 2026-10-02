package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

/** §6 alur login, §59 autentikasi. */
class AuthFlowIT extends IntegrationTestBase {

    @Test
    void wrongPasswordIsRejected() throws Exception {
        MvcResult r = mvc.perform(post("/api/dev-auth/token").contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("email", "cashier.jkt@demo.local", "password", "salah-123456"))))
                .andReturn();
        assertThat(r.getResponse().getStatus()).isEqualTo(401);
        assertThat(body(r).get("errorCode").asText()).isEqualTo("INVALID_CREDENTIALS");
        assertThat(r.getResponse().getContentAsString()).doesNotContain("Exception");
    }

    @Test
    void loginThenLoadContext() throws Exception {
        MvcResult login = mvc.perform(post("/api/dev-auth/token").contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("email", "cashier.jkt@demo.local", "password", DEMO_PASSWORD))))
                .andReturn();
        assertThat(login.getResponse().getStatus()).isEqualTo(200);
        String accessToken = body(login).at("/data/accessToken").asText();

        MvcResult session = mvc.perform(post("/api/auth/session").header("Authorization", "Bearer " + accessToken))
                .andReturn();
        assertThat(session.getResponse().getStatus()).isEqualTo(200);
        JsonNode me = body(session).get("data");
        assertThat(me.at("/user/username").asText()).isEqualTo("cashier.jkt");
        assertThat(me.at("/employee/employeeCode").asText()).isEqualTo("EMP005");
        assertThat(me.at("/organization/code").asText()).isEqualTo("DEMO");
        assertThat(me.get("outlets")).hasSize(1);
        assertThat(me.at("/outlets/0/code").asText()).isEqualTo("JKT01");
        List<String> perms = new ArrayList<>();
        me.at("/outlets/0/permissions").forEach(p -> perms.add(p.asText()));
        assertThat(perms).contains("sale.create", "cashier.open").doesNotContain("sale.void", "sale.refund");
        assertThat(me.get("organizationPermissions")).isEmpty();
        assertThat(me.at("/outlets/0/businessDate").asText()).matches("\\d{4}-\\d{2}-\\d{2}");
        assertThat(session.getResponse().getHeader("X-Request-Id")).isNotBlank();
    }

    @Test
    void missingOrInvalidTokenIsUnauthenticated() throws Exception {
        MvcResult none = mvc.perform(get("/api/auth/me")).andReturn();
        assertThat(none.getResponse().getStatus()).isEqualTo(401);
        assertThat(body(none).get("errorCode").asText()).isEqualTo("UNAUTHENTICATED");

        String tampered = token("cashier.jkt") + "x";
        MvcResult bad = mvc.perform(get("/api/auth/me").header("Authorization", "Bearer " + tampered)).andReturn();
        assertThat(bad.getResponse().getStatus()).isEqualTo(401);
    }

    @Test
    void healthEndpointsArePublic() throws Exception {
        assertThat(mvc.perform(get("/actuator/health/liveness")).andReturn().getResponse().getStatus()).isEqualTo(200);
        assertThat(mvc.perform(get("/actuator/health/readiness")).andReturn().getResponse().getStatus()).isEqualTo(200);
    }
}
