package com.pirantisolution.pos;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.auth.local.LocalTokenService;
import java.util.List;
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

    // ------------------------------------------------------------ helper user/terminal baru per test

    /** Kasir baru (karyawan + akun CASHIER di satu outlet) beserta token hasil login password. */
    protected record Cashier(String token, String employeeId, String email, String password) {
    }

    /** Admin membuat karyawan + akun kasir di outlet tertentu, lalu kasir login. */
    protected Cashier newCashier(UUID outletId) throws Exception {
        String code = unique("E").replace("-", "").substring(0, 9);
        MvcResult emp = postAs("admin", "/api/employees",
                Map.of("employeeCode", code, "fullName", "Kasir " + code, "homeOutletId", outletId));
        if (emp.getResponse().getStatus() != 201) {
            throw new IllegalStateException("create employee failed: " + emp.getResponse().getContentAsString());
        }
        String employeeId = body(emp).at("/data/id").asText();

        String cashierRoleId = null;
        for (JsonNode r : body(getAs("admin", "/api/roles")).get("data")) {
            if ("CASHIER".equals(r.get("code").asText())) {
                cashierRoleId = r.get("id").asText();
            }
        }
        String username = ("att." + code).toLowerCase();
        String email = username + "@demo.local";
        String password = "KasirAbsen2026";
        MvcResult user = postAs("admin", "/api/users", Map.of(
                "username", username, "email", email, "displayName", "Kasir " + code,
                "employeeId", employeeId, "password", password,
                "outletIds", List.of(outletId),
                "roles", List.of(Map.of("roleId", cashierRoleId, "outletId", outletId))));
        if (user.getResponse().getStatus() != 201) {
            throw new IllegalStateException("create user failed: " + user.getResponse().getContentAsString());
        }
        return new Cashier(signIn(email, password), employeeId, email, password);
    }

    /** Login lewat endpoint dev (setara signInWithPassword Supabase). */
    protected String signIn(String email, String password) throws Exception {
        MvcResult login = mvc.perform(post("/api/dev-auth/token").contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("email", email, "password", password)))).andReturn();
        return body(login).at("/data/accessToken").asText();
    }

    /** Terminal baru di outlet, agar test tidak berebut terminal seed. */
    protected String newTerminal(UUID outletId) throws Exception {
        MvcResult t = postAs("admin", "/api/terminals",
                Map.of("outletId", outletId, "code", unique("T"), "name", "Terminal test"));
        if (t.getResponse().getStatus() != 201) {
            throw new IllegalStateException("create terminal failed: " + t.getResponse().getContentAsString());
        }
        return body(t).at("/data/id").asText();
    }

    protected MvcResult call(String token, String method, String url, Object body) throws Exception {
        var req = "GET".equals(method) ? get(url) : post(url);
        req.header("Authorization", "Bearer " + token);
        if (body != null) {
            req.contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body));
        }
        return mvc.perform(req).andReturn();
    }

    protected String code(MvcResult r) throws Exception {
        String s = r.getResponse().getContentAsString();
        return s.isEmpty() ? "" : json.readTree(s).path("errorCode").asText();
    }
}
