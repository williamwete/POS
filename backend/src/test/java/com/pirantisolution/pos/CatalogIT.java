package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

/** Katalog lokal (SaaS): produk, kategori, opsi, preset diskon, profil struk, penjualan dengan opsi. */
class CatalogIT extends IntegrationTestBase {

    private Cashier readyCashier(UUID outlet) throws Exception {
        Cashier c = newCashier(outlet);
        String terminal = newTerminal(outlet);
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", outlet))
                .getResponse().getStatus()).isEqualTo(201);
        MvcResult open = call(c.token(), "POST", "/api/cashier/sessions/open",
                Map.of("terminalId", terminal, "counts", List.of()));
        assertThat(open.getResponse().getStatus()).as(open.getResponse().getContentAsString()).isEqualTo(201);
        return c;
    }

    private JsonNode ok(MvcResult r) throws Exception {
        assertThat(r.getResponse().getStatus()).as(r.getResponse().getContentAsString()).isBetween(200, 201);
        return body(r).get("data");
    }

    @Test
    void onlyCatalogManagersCanWrite() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        Map<String, Object> product = Map.of("sku", unique("S"), "name", "Tes", "uom", "PCS", "price", 1000);
        assertThat(call(c.token(), "POST", "/api/catalog/products", product).getResponse().getStatus()).isEqualTo(403);
        assertThat(postAs("supervisor.jkt", "/api/catalog/products", product).getResponse().getStatus()).isEqualTo(403);
        assertThat(putAs("supervisor.jkt", "/api/catalog/receipt-profiles", Map.of("businessName", "X"))
                .getResponse().getStatus()).isEqualTo(403);
        assertThat(postAs("admin", "/api/catalog/products", product).getResponse().getStatus()).isEqualTo(201);
        // duplikat SKU -> pesan jelas, bukan 500
        MvcResult dup = postAs("admin", "/api/catalog/products", product);
        assertThat(dup.getResponse().getStatus()).isEqualTo(409);
    }

    @Test
    void localProductWithOptionsSellsWithoutStock() throws Exception {
        String sku = unique("MIE").replace("-", "").substring(0, 10);
        JsonNode cat = ok(postAs("admin", "/api/catalog/categories", Map.of("code", sku, "name", "Mie " + sku)));
        JsonNode prod = ok(postAs("admin", "/api/catalog/products", Map.of("sku", sku, "name", "Mie Ayam " + sku,
                "categoryId", cat.get("id").asText(), "uom", "PORSI", "trackStock", false, "price", 25000)));
        assertThat(prod.get("source").asText()).isEqualTo("LOCAL");
        assertThat(prod.get("price").decimalValue()).isEqualByComparingTo("25000");

        String groupName = "Pedas " + sku;
        ok(postAs("admin", "/api/catalog/option-groups", Map.of("name", groupName, "minSelect", 1, "maxSelect", 1)));
        JsonNode groups = ok(getAs("admin", "/api/catalog/option-groups"));
        String groupId = null;
        for (JsonNode g : groups) {
            if (g.get("name").asText().equals(groupName)) {
                groupId = g.get("id").asText();
            }
        }
        assertThat(groupId).isNotNull();
        ok(postAs("admin", "/api/catalog/option-groups/" + groupId + "/options", Map.of("name", "Sedang", "priceDelta", 0)));
        groups = ok(postAs("admin", "/api/catalog/option-groups/" + groupId + "/options",
                Map.of("name", "Extra keju", "priceDelta", 4000)));
        String optionId = null;
        for (JsonNode g : groups) {
            if (g.get("id").asText().equals(groupId)) {
                for (JsonNode o : g.get("options")) {
                    if (o.get("name").asText().equals("Extra keju")) {
                        optionId = o.get("id").asText();
                    }
                }
            }
        }
        assertThat(optionId).isNotNull();
        ok(putAs("admin", "/api/catalog/products/" + prod.get("id").asText() + "/options", Map.of("groupIds", List.of(groupId))));

        Cashier c = readyCashier(OUTLET_JKT);
        // katalog kasir membawa grup opsi dan penanda tanpa stok
        JsonNode found = ok(call(c.token(), "GET", "/api/products?outletId=" + OUTLET_JKT + "&q=" + sku, null));
        assertThat(found.size()).isEqualTo(1);
        assertThat(found.get(0).get("trackStock").asBoolean()).isFalse();
        assertThat(found.get(0).at("/optionGroups/0/options").size()).isEqualTo(2);

        String sale = body(call(c.token(), "POST", "/api/sales", Map.of("clientTransactionId", "IT-" + UUID.randomUUID())))
                .at("/data/id").asText();
        String url = "/api/sales/" + sale + "/items";
        assertThat(code(call(c.token(), "POST", url, Map.of("productId", prod.get("id").asText(), "quantity", 1))))
                .isEqualTo("OPTION_SELECTION_INVALID");
        JsonNode s = ok(call(c.token(), "POST", url, Map.of("productId", prod.get("id").asText(), "quantity", 2,
                "optionIds", List.of(optionId))));
        assertThat(s.at("/items/0/unitPrice").decimalValue()).isEqualByComparingTo("29000");
        assertThat(s.get("grandTotal").decimalValue()).isEqualByComparingTo("58000");
        assertThat(s.at("/items/0/options/0/name").asText()).isEqualTo("Extra keju");
        // opsi yang sama tidak digabung ke baris lama
        s = ok(call(c.token(), "POST", url, Map.of("productId", prod.get("id").asText(), "quantity", 1,
                "optionIds", List.of(optionId))));
        assertThat(s.get("items").size()).isEqualTo(2);
        MvcResult out = call(c.token(), "POST", "/api/sales/" + sale + "/checkout", null);
        assertThat(out.getResponse().getStatus()).as(out.getResponse().getContentAsString()).isEqualTo(200);
    }

    @Test
    void discountPresetsAndReceiptProfile() throws Exception {
        String name = "Member " + unique("D").substring(0, 8);
        JsonNode preset = ok(postAs("supervisor.jkt", "/api/discount-presets",
                Map.of("outletId", OUTLET_JKT.toString(), "name", name, "discountType", "PERCENTAGE", "discountValue", 5)));
        Cashier c = newCashier(OUTLET_JKT);
        JsonNode list = ok(call(c.token(), "GET", "/api/discount-presets?outletId=" + OUTLET_JKT, null));
        boolean seen = false;
        for (JsonNode d : list) {
            seen |= d.get("id").asText().equals(preset.get("id").asText());
        }
        assertThat(seen).isTrue();
        assertThat(call(c.token(), "POST", "/api/discount-presets",
                Map.of("name", "Curang 99", "discountType", "PERCENTAGE", "discountValue", 99)).getResponse().getStatus())
                .isEqualTo(403);

        ok(putAs("admin", "/api/catalog/receipt-profiles", Map.of("businessName", "Warung Uji", "footerText", "Terima kasih",
                "paperWidthMm", 58)));
        JsonNode profile = ok(call(c.token(), "GET", "/api/receipt-profile?outletId=" + OUTLET_JKT, null));
        assertThat(profile.get("businessName").asText()).isEqualTo("Warung Uji");
        assertThat(profile.get("paperWidthMm").asInt()).isEqualTo(58);
        assertThat(putAs("admin", "/api/catalog/receipt-profiles", Map.of("paperWidthMm", 70)).getResponse().getStatus())
                .isEqualTo(400);
    }

    @Test
    void bulkImportCreatesProductsAllOrNothing() throws Exception {
        String a = unique("IMP").replace("-", "").substring(0, 12);
        String b = unique("IMP").replace("-", "").substring(0, 12);
        MvcResult ok = postAs("admin", "/api/catalog/products/import", Map.of("rows", List.of(
                Map.of("sku", a, "name", "Impor A", "category", "Impor Test", "price", "5000"),
                Map.of("sku", b, "name", "Impor B", "price", "7000"))));
        assertThat(ok.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(ok).at("/data/created").asInt()).isEqualTo(2);

        String c = unique("IMP").replace("-", "").substring(0, 12);
        MvcResult bad = postAs("admin", "/api/catalog/products/import", Map.of("rows", List.of(
                Map.of("sku", c, "name", "Baik", "price", "1000"),
                Map.of("sku", "X" + c, "name", "Salah", "price", "-1"))));
        assertThat(bad.getResponse().getStatus()).isEqualTo(400);
        assertThat(body(bad).get("message").asText()).contains("baris 2");

        // kasir tidak boleh impor
        Cashier cashier = newCashier(OUTLET_JKT);
        assertThat(call(cashier.token(), "POST", "/api/catalog/products/import",
                Map.of("rows", List.of(Map.of("sku", c, "name", "x", "price", "1")))).getResponse().getStatus()).isEqualTo(403);
    }
}
