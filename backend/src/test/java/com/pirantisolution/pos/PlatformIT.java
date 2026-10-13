package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

/** Onboarding merchant (SaaS): konsol platform, isolasi antar-tenant, penangguhan. */
class PlatformIT extends IntegrationTestBase {

    private static final String PASSWORD = "Merchant#2026";

    private Map<String, Object> merchantBody(String code, String email, String plan) {
        return Map.ofEntries(Map.entry("code", code), Map.entry("name", "Toko " + code),
                Map.entry("businessType", "FNB"), Map.entry("plan", plan), Map.entry("outletCode", code + "01"),
                Map.entry("outletName", "Outlet " + code), Map.entry("ownerName", "Pemilik " + code),
                Map.entry("ownerEmail", email), Map.entry("ownerPassword", PASSWORD));
    }

    private static String newCode() {
        return "M" + (System.nanoTime() % 1_000_000_000L);
    }

    @Test
    void onlyPlatformOperatorsUseTheConsole() throws Exception {
        assertThat(getAs("admin", "/api/platform/merchants").getResponse().getStatus()).isEqualTo(403);
        assertThat(getAs("superadmin", "/api/platform/plans").getResponse().getStatus()).isEqualTo(403);
        String code = newCode();
        assertThat(postAs("superadmin", "/api/platform/merchants",
                merchantBody(code, code.toLowerCase() + "@x.test", "TRIAL")).getResponse().getStatus()).isEqualTo(403);
        assertThat(getAs("platform", "/api/platform/plans").getResponse().getStatus()).isEqualTo(200);
    }

    @Test
    void provisionIsolateAndSuspend() throws Exception {
        String code = newCode();
        String email = code.toLowerCase() + "@merchant.test";
        MvcResult created = postAs("platform", "/api/platform/merchants", merchantBody(code, email, "STARTER"));
        assertThat(created.getResponse().getStatus()).as(created.getResponse().getContentAsString()).isEqualTo(201);
        JsonNode data = body(created).get("data");
        String org = data.at("/merchant/id").asText();
        assertThat(data.get("ownerUsername").asText()).isEqualTo(code.toLowerCase() + ".owner");
        assertThat(data.at("/merchant/outlets").asInt()).isEqualTo(1);
        assertThat(data.at("/merchant/planCode").asText()).isEqualTo("STARTER");

        // kode kembar ditolak
        assertThat(postAs("platform", "/api/platform/merchants",
                merchantBody(code, "lain-" + email, "STARTER")).getResponse().getStatus()).isEqualTo(409);

        // pemilik baru bisa masuk dan hanya melihat tokonya
        String owner = signIn(email, PASSWORD);
        assertThat(owner).isNotBlank();
        MvcResult mine = call(owner, "GET", "/api/catalog/products", null);
        assertThat(mine.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(mine).get("data")).isEmpty();
        // preset F&B: kategori & opsi awal sudah ada
        assertThat(body(call(owner, "GET", "/api/catalog/categories", null)).get("data")).hasSize(4);
        assertThat(body(call(owner, "GET", "/api/catalog/option-groups", null)).get("data")).hasSize(4);
        String sku = "ISO" + code;
        MvcResult product = call(owner, "POST", "/api/catalog/products",
                Map.of("sku", sku, "name", "Latte", "uom", "PCS", "trackStock", false, "price", 28000));
        assertThat(product.getResponse().getStatus()).as(product.getResponse().getContentAsString()).isEqualTo(201);
        // admin DEMO tidak melihat produk merchant baru, pemilik tidak melihat produk DEMO
        for (JsonNode p : body(getAs("admin", "/api/catalog/products?q=" + sku)).get("data")) {
            assertThat(p.get("sku").asText()).isNotEqualTo(sku);
        }
        assertThat(call(owner, "GET", "/api/catalog/products?q=SKU-0001", null).getResponse().getContentAsString())
                .doesNotContain("SKU-0001");
        // pemilik tidak bisa memakai konsol platform
        assertThat(call(owner, "GET", "/api/platform/merchants", null).getResponse().getStatus()).isEqualTo(403);

        // ganti paket
        MvcResult plan = putAs("platform", "/api/platform/merchants/" + org + "/plan", Map.of("plan", "BUSINESS"));
        assertThat(plan.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(plan).at("/data/planCode").asText()).isEqualTo("BUSINESS");

        // tangguhkan: akses pemilik tertutup, aktifkan lagi: pulih
        assertThat(putAs("platform", "/api/platform/merchants/" + org + "/active",
                Map.of("active", false, "reason", "tunggakan")).getResponse().getStatus()).isEqualTo(200);
        int blocked = call(owner, "GET", "/api/catalog/products", null).getResponse().getStatus();
        assertThat(blocked).isIn(401, 403);
        assertThat(putAs("platform", "/api/platform/merchants/" + org + "/active",
                Map.of("active", true)).getResponse().getStatus()).isEqualTo(200);
        assertThat(call(signIn(email, PASSWORD), "GET", "/api/catalog/products", null).getResponse().getStatus())
                .isEqualTo(200);
    }

    @Test
    void tenantAdminCannotEditBuiltInRoles() throws Exception {
        JsonNode roles = body(getAs("superadmin", "/api/roles")).get("data");
        String cashier = null;
        for (JsonNode r : roles) {
            if (r.get("code").asText().equals("CASHIER")) {
                cashier = r.get("id").asText();
            }
        }
        assertThat(cashier).isNotNull();
        MvcResult res = putAs("superadmin", "/api/roles/" + cashier + "/permissions",
                Map.of("permissionCodes", java.util.List.of("report.view")));
        assertThat(res.getResponse().getStatus()).isEqualTo(403);
    }
}
