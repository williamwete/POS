package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

/** Phase 4 — penjualan (§15, §18, §20, §26, §27, §30, §31, §77, §79). Kasir & terminal baru per test. */
class SalesIT extends IntegrationTestBase {

    private static final String SALES = "/api/sales";
    private static final String TISU = "00000000-0000-4000-8000-000000000932";      // 50.000, PPN 11%
    private static final String BERAS = "00000000-0000-4000-8000-000000000927";     // 78.000, bebas PPN
    private static final String COKELAT = "00000000-0000-4000-8000-000000000926";   // stok BDG 0

    /** Kasir siap jual: clock in + buka kasir di terminal baru. */
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

    private String newSale(Cashier c) throws Exception {
        MvcResult r = call(c.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID()));
        assertThat(r.getResponse().getStatus()).as(r.getResponse().getContentAsString()).isEqualTo(201);
        return body(r).at("/data/id").asText();
    }

    private MvcResult add(Cashier c, String sale, String productId, Object qty) throws Exception {
        return call(c.token(), "POST", SALES + "/" + sale + "/items", Map.of("productId", productId, "quantity", qty));
    }

    private String approval(Cashier c, Map<String, Object> req, String email) throws Exception {
        Map<String, Object> body = new java.util.HashMap<>(req);
        body.put("email", email);
        body.put("password", DEMO_PASSWORD);
        MvcResult r = call(c.token(), "POST", "/api/approvals", body);
        assertThat(r.getResponse().getStatus()).as(r.getResponse().getContentAsString()).isEqualTo(201);
        return body(r).at("/data/id").asText();
    }

    @Test
    void acceptanceSaleTwoItemsCheckoutAndReceipt() throws Exception {
        Cashier c = readyCashier(OUTLET_JKT);
        String sale = newSale(c);
        MvcResult added = add(c, sale, TISU, 2);
        assertThat(added.getResponse().getStatus()).as(added.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode s = body(added).get("data");
        // §77: 2 × 50.000 = 100.000; PPN termasuk harga = round(100.000 × 11/111) = 9.910
        assertThat(s.get("grandTotal").decimalValue()).isEqualByComparingTo("100000");
        assertThat(s.get("taxTotal").decimalValue()).isEqualByComparingTo("9910");
        assertThat(s.at("/items/0/unitPrice").decimalValue()).isEqualByComparingTo("50000");

        MvcResult receiptEarly = call(c.token(), "GET", SALES + "/" + sale + "/receipt", null);
        assertThat(code(receiptEarly)).isEqualTo("RECEIPT_NOT_AVAILABLE");

        MvcResult out = call(c.token(), "POST", SALES + "/" + sale + "/checkout", null);
        assertThat(out.getResponse().getStatus()).as(out.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode co = body(out).get("data");
        assertThat(co.get("status").asText()).isEqualTo("CHECKOUT");
        assertThat(co.get("receiptNo").asText()).matches("^T-[A-Z0-9]{8}-\\d{8}-000001$");

        assertThat(code(add(c, sale, TISU, 1))).isEqualTo("SALE_NOT_EDITABLE");

        JsonNode receipt = body(call(c.token(), "GET", SALES + "/" + sale + "/receipt", null)).get("data");
        assertThat(receipt.get("receiptNo").asText()).isEqualTo(co.get("receiptNo").asText());
        assertThat(receipt.get("outletName").asText()).isEqualTo("Outlet Jakarta Pusat");
        assertThat(receipt.get("lines")).hasSize(1);
        assertThat(receipt.get("grandTotal").decimalValue()).isEqualByComparingTo("100000");

        JsonNode p1 = body(call(c.token(), "POST", SALES + "/" + sale + "/receipt/print", null)).get("data");
        JsonNode p2 = body(call(c.token(), "POST", SALES + "/" + sale + "/receipt/print", null)).get("data");
        assertThat(p1.get("reprint").asBoolean()).isFalse();
        assertThat(p2.get("printCount").asInt()).isEqualTo(2);
        assertThat(p2.get("reprint").asBoolean()).isTrue();

        Set<String> actions = new HashSet<>();
        body(getAs("auditor", "/api/audit-logs?entityType=SALE&entityId=" + sale))
                .at("/data/items").forEach(a -> actions.add(a.get("action").asText()));
        assertThat(actions).contains("SALE_CREATED", "SALE_CHECKOUT", "RECEIPT_PRINT", "RECEIPT_REPRINT");

        // supervisor (sale.view) melihat transaksi outlet
        boolean seen = false;
        for (JsonNode x : body(getAs("supervisor.jkt", SALES + "?outletId=" + OUTLET_JKT)).get("data")) {
            seen |= x.get("id").asText().equals(sale);
        }
        assertThat(seen).isTrue();
    }

    @Test
    void barcodeScanMergesLinesAndUnknownBarcodeFails() throws Exception {
        Cashier c = readyCashier(OUTLET_JKT);
        String sale = newSale(c);
        for (int i = 0; i < 2; i++) {
            MvcResult r = call(c.token(), "POST", SALES + "/" + sale + "/items",
                    Map.of("barcode", "8990000000017", "quantity", 1));
            assertThat(r.getResponse().getStatus()).as(r.getResponse().getContentAsString()).isEqualTo(200);
        }
        JsonNode s = body(call(c.token(), "GET", SALES + "/" + sale, null)).get("data");
        assertThat(s.get("lineCount").asInt()).isEqualTo(1);
        assertThat(s.at("/items/0/quantity").decimalValue()).isEqualByComparingTo("2");

        MvcResult unknown = call(c.token(), "POST", SALES + "/" + sale + "/items",
                Map.of("barcode", "0000000000000", "quantity", 1));
        assertThat(unknown.getResponse().getStatus()).isEqualTo(404);
        assertThat(code(unknown)).isEqualTo("PRODUCT_NOT_FOUND");
        assertThat(code(add(c, sale, TISU, 1.5))).isEqualTo("QUANTITY_INVALID");

        // pencarian produk
        JsonNode found = body(call(c.token(), "GET", "/api/products?outletId=" + OUTLET_JKT + "&q=tisu", null)).get("data");
        assertThat(found.get(0).get("sku").asText()).isEqualTo("SKU-0012");
        assertThat(found.get(0).get("price").decimalValue()).isEqualByComparingTo("50000");
    }

    @Test
    void discountApprovalMatrix() throws Exception {
        Cashier c = readyCashier(OUTLET_JKT);
        String sale = newSale(c);
        JsonNode s = body(add(c, sale, BERAS, 1)).get("data");
        String line = s.at("/items/0/id").asText();

        // 5% baris: dalam batas kasir
        MvcResult d5 = call(c.token(), "POST", SALES + "/" + sale + "/discounts",
                Map.of("saleItemId", line, "type", "PERCENTAGE", "value", 5, "reason", "Promo member"));
        assertThat(d5.getResponse().getStatus()).as(d5.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(d5).at("/data/grandTotal").decimalValue()).isEqualByComparingTo("74100");

        // 10% transaksi: butuh supervisor
        Map<String, Object> cart10 = Map.of("type", "PERCENTAGE", "value", 10, "reason", "Kompensasi antre");
        MvcResult need = call(c.token(), "POST", SALES + "/" + sale + "/discounts", cart10);
        assertThat(need.getResponse().getStatus()).isEqualTo(403);
        assertThat(code(need)).isEqualTo("APPROVAL_REQUIRED");

        Map<String, Object> req = Map.of("action", "DISCOUNT", "saleId", sale, "discountType", "PERCENTAGE",
                "discountValue", 10);
        Map<String, Object> self = new java.util.HashMap<>(req);
        self.put("email", c.email());
        self.put("password", c.password());
        assertThat(code(call(c.token(), "POST", "/api/approvals", self))).isEqualTo("APPROVER_INVALID");
        Map<String, Object> wrong = new java.util.HashMap<>(req);
        wrong.put("email", "supervisor.jkt@demo.local");
        wrong.put("password", "salah-password");
        assertThat(code(call(c.token(), "POST", "/api/approvals", wrong))).isEqualTo("APPROVER_INVALID");

        String approvalId = approval(c, req, "supervisor.jkt@demo.local");
        Map<String, Object> approved = new java.util.HashMap<>(cart10);
        approved.put("approvalId", approvalId);
        MvcResult ok = call(c.token(), "POST", SALES + "/" + sale + "/discounts", approved);
        assertThat(ok.getResponse().getStatus()).as(ok.getResponse().getContentAsString()).isEqualTo(200);
        // 78.000 − 3.900 = 74.100; 10% = 7.410 → 66.690
        assertThat(body(ok).at("/data/grandTotal").decimalValue()).isEqualByComparingTo("66690");

        // 20% butuh manager; supervisor ditolak database
        String disc = body(ok).at("/data/discounts/1/id").asText();
        call(c.token(), "POST", SALES + "/" + sale + "/discounts/" + disc + "/remove", null);
        Map<String, Object> req20 = Map.of("action", "DISCOUNT", "saleId", sale, "discountType", "PERCENTAGE",
                "discountValue", 20);
        Map<String, Object> bySup = new java.util.HashMap<>(req20);
        bySup.put("email", "supervisor.jkt@demo.local");
        bySup.put("password", DEMO_PASSWORD);
        assertThat(code(call(c.token(), "POST", "/api/approvals", bySup))).isEqualTo("APPROVER_NOT_AUTHORIZED");
        String mgr = approval(c, req20, "manager@demo.local");
        Map<String, Object> cart20 = Map.of("type", "PERCENTAGE", "value", 20, "reason", "Barang rusak ringan",
                "approvalId", mgr);
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/discounts", cart20).getResponse().getStatus())
                .isEqualTo(200);
        // approval sekali pakai
        assertThat(code(call(c.token(), "POST", SALES + "/" + sale + "/discounts", cart20))).isIn("APPROVAL_REQUIRED",
                "DISCOUNT_INVALID");

        MvcResult out = call(c.token(), "POST", SALES + "/" + sale + "/checkout", null);
        assertThat(out.getResponse().getStatus()).as(out.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(out).at("/data/grandTotal").decimalValue()).isEqualByComparingTo("59280");
    }

    @Test
    void priceOverrideNeedsApproval() throws Exception {
        Cashier c = readyCashier(OUTLET_JKT);
        String sale = newSale(c);
        String line = body(add(c, sale, TISU, 1)).at("/data/items/0/id").asText();
        Map<String, Object> change = Map.of("unitPrice", 45000, "reason", "Kemasan penyok");
        MvcResult denied = call(c.token(), "POST", SALES + "/" + sale + "/items/" + line + "/price", change);
        assertThat(code(denied)).isEqualTo("APPROVAL_REQUIRED");
        String a = approval(c, Map.of("action", "PRICE_OVERRIDE", "saleId", sale, "saleItemId", line, "price", 45000),
                "supervisor.jkt@demo.local");
        Map<String, Object> withApproval = new java.util.HashMap<>(change);
        withApproval.put("approvalId", a);
        MvcResult ok = call(c.token(), "POST", SALES + "/" + sale + "/items/" + line + "/price", withApproval);
        assertThat(ok.getResponse().getStatus()).as(ok.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(ok).at("/data/items/0/unitPrice").decimalValue()).isEqualByComparingTo("45000");
        assertThat(body(ok).at("/data/items/0/listPrice").decimalValue()).isEqualByComparingTo("50000");
        assertThat(body(ok).at("/data/grandTotal").decimalValue()).isEqualByComparingTo("45000");
    }

    @Test
    void holdResumeCancelAndVoid() throws Exception {
        Cashier c = readyCashier(OUTLET_JKT);
        String a = newSale(c);
        add(c, a, BERAS, 1);
        assertThat(call(c.token(), "POST", SALES + "/" + a + "/hold", null).getResponse().getStatus()).isEqualTo(200);
        String b = newSale(c);
        assertThat(code(call(c.token(), "POST", SALES + "/" + a + "/resume", null))).isEqualTo("OPEN_ORDER_EXISTS");
        assertThat(body(call(c.token(), "GET", SALES + "/held", null)).get("data")).hasSize(1);
        assertThat(call(c.token(), "POST", SALES + "/" + b + "/cancel", null).getResponse().getStatus()).isEqualTo(200);
        assertThat(call(c.token(), "POST", SALES + "/" + a + "/resume", null).getResponse().getStatus()).isEqualTo(200);
        assertThat(code(call(c.token(), "POST", SALES + "/" + a + "/cancel", null))).isEqualTo("SALE_NOT_EMPTY");

        // void setelah checkout butuh approval supervisor
        assertThat(call(c.token(), "POST", SALES + "/" + a + "/checkout", null).getResponse().getStatus()).isEqualTo(200);
        Map<String, Object> reason = Map.of("reason", "Pelanggan batal membeli");
        MvcResult denied = call(c.token(), "POST", SALES + "/" + a + "/void", reason);
        assertThat(code(denied)).isEqualTo("APPROVAL_REQUIRED");
        String ap = approval(c, Map.of("action", "VOID_SALE", "saleId", a), "supervisor.jkt@demo.local");
        MvcResult voided = call(c.token(), "POST", SALES + "/" + a + "/void",
                Map.of("reason", "Pelanggan batal membeli", "approvalId", ap));
        assertThat(voided.getResponse().getStatus()).as(voided.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(voided).at("/data/status").asText()).isEqualTo("VOID");
        assertThat(body(voided).at("/data/receiptNo").asText()).isNotBlank();

        // session dengan transaksi tidak bisa dibatalkan
        String session = body(call(c.token(), "GET", "/api/cashier/sessions/current", null)).at("/data/id").asText();
        assertThat(code(call(c.token(), "POST", "/api/cashier/sessions/" + session + "/cancel",
                Map.of("reason", "Salah terminal")))).isEqualTo("CASHIER_SESSION_HAS_ACTIVITY");
    }

    @Test
    void stockSessionAndDuplicateRules() throws Exception {
        Cashier bdg = readyCashier(OUTLET_BDG);
        String sale = newSale(bdg);
        MvcResult noStock = add(bdg, sale, COKELAT, 1);
        assertThat(noStock.getResponse().getStatus()).isEqualTo(422);
        assertThat(code(noStock)).isEqualTo("STOCK_UNAVAILABLE");

        // harga khusus outlet Bandung
        JsonNode s = body(add(bdg, sale, "00000000-0000-4000-8000-000000000921", 1)).get("data");
        assertThat(s.at("/items/0/unitPrice").decimalValue()).isEqualByComparingTo("4500");

        // §79: request checkout yang sama dua kali → satu nomor struk
        String key = "co-" + UUID.randomUUID();
        MvcResult first = mvc.perform(post(SALES + "/" + sale + "/checkout").header("Authorization", "Bearer " + bdg.token())
                .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON)).andReturn();
        MvcResult second = mvc.perform(post(SALES + "/" + sale + "/checkout").header("Authorization", "Bearer " + bdg.token())
                .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON)).andReturn();
        assertThat(first.getResponse().getStatus()).isEqualTo(200);
        assertThat(second.getResponse().getHeader("Idempotent-Replayed")).isEqualTo("true");
        assertThat(body(second).at("/data/receiptNo").asText()).isEqualTo(body(first).at("/data/receiptNo").asText());

        // client_transaction_id yang sama → transaksi yang sama
        String tx = "IT-DUP-" + UUID.randomUUID();
        String x = body(call(bdg.token(), "POST", SALES, Map.of("clientTransactionId", tx))).at("/data/id").asText();
        String y = body(call(bdg.token(), "POST", SALES, Map.of("clientTransactionId", tx))).at("/data/id").asText();
        assertThat(y).isEqualTo(x);

        // terminal terkunci → tidak bisa menambah barang
        String session = body(call(bdg.token(), "GET", "/api/cashier/sessions/current", null)).at("/data/id").asText();
        call(bdg.token(), "POST", "/api/cashier/sessions/" + session + "/lock", Map.of("reason", "MANUAL"));
        assertThat(code(add(bdg, x, "00000000-0000-4000-8000-000000000921", 1))).isEqualTo("CASHIER_SESSION_LOCKED");

        // tanpa buka kasir → tidak bisa membuat transaksi
        Cashier noSession = newCashier(OUTLET_BDG);
        assertThat(code(call(noSession.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID()))))
                .isEqualTo("CASHIER_SESSION_REQUIRED");
    }
}
