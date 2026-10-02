package com.pirantisolution.pos;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.auth.local.LocalTokenService;
import java.util.Map;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

/**
 * Basis test integrasi: Spring Boot penuh + PostgreSQL sungguhan dengan migration & seed demo.
 * Lihat docs/TESTING.md untuk menyiapkan database test.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
public abstract class IntegrationTestBase {

    // ID dari db/seed/R__demo_seed.sql
    public static final UUID ORG = UUID.fromString("00000000-0000-4000-8000-000000000001");
    public static final UUID OUTLET_JKT = UUID.fromString("00000000-0000-4000-8000-000000000101");
    public static final UUID OUTLET_BDG = UUID.fromString("00000000-0000-4000-8000-000000000102");
    public static final UUID TERMINAL_JKT_01 = UUID.fromString("00000000-0000-4000-8000-000000000401");
    public static final UUID PRINTER_JKT_01 = UUID.fromString("00000000-0000-4000-8000-000000000301");
    public static final UUID DRAWER_JKT_01 = UUID.fromString("00000000-0000-4000-8000-000000000302");
    public static final UUID PRINTER_BDG_01 = UUID.fromString("00000000-0000-4000-8000-000000000304");
    public static final UUID USER_SUPERADMIN = UUID.fromString("00000000-0000-4000-8000-000000000701");
    public static final UUID USER_ADMIN = UUID.fromString("00000000-0000-4000-8000-000000000702");
    public static final UUID USER_CASHIER_JKT = UUID.fromString("00000000-0000-4000-8000-000000000705");

    public static final String DEMO_PASSWORD = "Demo#12345";

    private static final Map<String, UUID> AUTH_IDS = Map.of(
            "superadmin", UUID.fromString("00000000-0000-4000-8000-000000000601"),
            "admin", UUID.fromString("00000000-0000-4000-8000-000000000602"),
            "manager", UUID.fromString("00000000-0000-4000-8000-000000000603"),
            "supervisor.jkt", UUID.fromString("00000000-0000-4000-8000-000000000604"),
            "cashier.jkt", UUID.fromString("00000000-0000-4000-8000-000000000605"),
            "cashier.bdg", UUID.fromString("00000000-0000-4000-8000-000000000606"),
            "auditor", UUID.fromString("00000000-0000-4000-8000-000000000607"));

    @Autowired
    protected MockMvc mvc;

    @Autowired
    protected ObjectMapper json;

    @Autowired
    protected LocalTokenService tokens;

    /** Bearer token untuk user demo (tanpa melalui password). */
    protected String token(String username) {
        UUID authId = AUTH_IDS.get(username);
        if (authId == null) {
            throw new IllegalArgumentException("unknown demo user " + username);
        }
        return tokens.issue(authId, username + "@demo.local").accessToken();
    }

    protected MockHttpServletRequestBuilder as(String username, MockHttpServletRequestBuilder req) {
        return req.header("Authorization", "Bearer " + token(username));
    }

    protected MvcResult getAs(String username, String url) throws Exception {
        return mvc.perform(as(username, get(url))).andReturn();
    }

    protected MvcResult postAs(String username, String url, Object body) throws Exception {
        return mvc.perform(as(username, post(url))
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(body))).andReturn();
    }

    protected MvcResult putAs(String username, String url, Object body) throws Exception {
        return mvc.perform(as(username, put(url))
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(body))).andReturn();
    }

    protected JsonNode body(MvcResult result) throws Exception {
        return json.readTree(result.getResponse().getContentAsString());
    }

    protected static String unique(String prefix) {
        return prefix + "-" + UUID.randomUUID().toString().substring(0, 8).toUpperCase();
    }
}
