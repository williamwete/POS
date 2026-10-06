package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

/** Phase 8 — retur & refund (§28, §29, §86). Kasir & terminal baru per test. */
class ReturnsIT extends IntegrationTestBase {

    private static final String SESSIONS = "/api/cashier/sessions";
    private static final String SALES = "/api/sales";
    private static final String RETURNS = "/api/returns";
    private static final String AIR = "00000000-0000-4000-8000-000000000921";    // 5.000

    private List<Map<String, Object>> lines(String token, long... valueQty) throws Exception {
        Map<String, String> ids = new HashMap<>();
        for (JsonNode d : body(call(token, "GET", "/api/cashier/denominations", null)).get("data")) {
            ids.put(d.get("kind").asText() + ":" + d.get("value").decimalValue().stripTrailingZeros().toPlainString(),
                    d.get("id").asText());
        }
        List<Map<String, Object>> out = new ArrayList<>();
        for (int i = 0; i < valueQty.length; i += 2) {
            out.add(Map.of("denominationId", ids.get("NOTE:" + valueQty[i]), "quantity", valueQty[i + 1]));
        }
        return out;
    }

    private String openSession(Cashier c) throws Exception {
        String terminal = newTerminal(OUTLET_JKT);
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT))
                .getResponse().getStatus()).isEqualTo(201);
        MvcResult open = call(c.token(), "POST", SESSIONS + "/open",
                Map.of("terminalId", terminal, "counts", lines(c.token(), 100000, 5)));
        assertThat(open.getResponse().getStatus()).as(open.getResponse().getContentAsString()).isEqualTo(201);
        return body(open).at("/data/id").asText();
    }

    /** Transaksi lunas tunai {@code qty} × air mineral; mengembalikan data sale. */
    private JsonNode paidSale(Cashier c, int qty) throws Exception {
        String sale = body(call(c.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID())))
                .at("/data/id").asText();
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/items", Map.of("productId", AIR, "quantity", qty))
                .getResponse().getStatus()).isEqualTo(200);
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/checkout", null).getResponse().getStatus()).isEqualTo(200);
        MvcResult p = call(c.token(), "POST", SALES + "/" + sale + "/payments", Map.of("methodCode", "CASH",
                "amountReceived", qty * 5000L, "amount", 1, "clientPaymentId", "PAY-" + UUID.randomUUID()));
        assertThat(p.getResponse().getStatus()).as(p.getResponse().getContentAsString()).isEqualTo(201);
        return body(p).at("/data/sale");
    }

    private MvcResult createReturn(String token, String clientId, JsonNode sale, String saleItemId, double qty)
            throws Exception {
        return call(token, "POST", RETURNS, Map.of("clientReturnId", clientId, "originalSaleId", sale.get("id").asText(),
                "reason", "Kemasan bocor", "refundMode", "CASH",
                "items", List.of(Map.of("saleItemId", saleItemId, "quantity", qty))));
    }

    @Test
    void partialReturnKeepsOriginalAndCreatesRefund() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String session = openSession(c);                               // modal 500.000
        JsonNode sale = paidSale(c, 10);                              // §86: 10 item = 50.000
        String receiptNo = sale.get("receiptNo").asText();

        JsonNode lookup = body(call(c.token(), "GET", RETURNS + "/lookup?receiptNo=" + receiptNo, null)).get("data");
        assertThat(lookup.get("returnable").asBoolean()).isTrue();
        assertThat(lookup.at("/items/0/remainingQuantity").decimalValue()).isEqualByComparingTo("10");
        String line = lookup.at("/items/0/saleItemId").asText();

        String clientId = "RET-" + UUID.randomUUID();
        MvcResult created = createReturn(c.token(), clientId, sale, line, 2);
        assertThat(created.getResponse().getStatus()).as(created.getResponse().getContentAsString()).isEqualTo(201);
        JsonNode r = body(created).get("data");
        String returnId = r.get("id").asText();
        assertThat(r.get("status").asText()).isEqualTo("PENDING_APPROVAL");
        assertThat(r.get("returnNo").asText()).startsWith("RET-");
        assertThat(r.get("totalAmount").decimalValue()).isEqualByComparingTo("10000");
        assertThat(r.get("originalReceiptNo").asText()).isEqualTo(receiptNo);
        // ID retur sama = retur yang sama
        assertThat(body(createReturn(c.token(), clientId, sale, line, 2)).at("/data/id").asText()).isEqualTo(returnId);
        // sisa yang bisa diretur: 8
        MvcResult tooMany = createReturn(c.token(), "RET-" + UUID.randomUUID(), sale, line, 9);
        assertThat(tooMany.getResponse().getStatus()).isEqualTo(422);
        assertThat(code(tooMany)).isEqualTo("RETURN_QUANTITY_EXCEEDED");

        // §29 restricted: kasir tidak bisa menyetujui sendiri
        assertThat(call(c.token(), "POST", RETURNS + "/" + returnId + "/approve", Map.of()).getResponse().getStatus())
                .isEqualTo(403);
        assertThat(code(call(c.token(), "POST", RETURNS + "/" + returnId + "/approve-at-terminal",
                Map.of("email", "supervisor.jkt@demo.local", "password", "salah-password")))).isEqualTo("APPROVER_INVALID");
        MvcResult ok = call(c.token(), "POST", RETURNS + "/" + returnId + "/approve-at-terminal",
                Map.of("email", "supervisor.jkt@demo.local", "password", DEMO_PASSWORD));
        assertThat(ok.getResponse().getStatus()).as(ok.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode done = body(ok).get("data");
        assertThat(done.get("status").asText()).isEqualTo("COMPLETED");
        assertThat(done.get("approvedByName").asText()).isEqualTo("supervisor.jkt");
        assertThat(done.get("refunds")).hasSize(1);
        assertThat(done.at("/refunds/0/refundMethod").asText()).isEqualTo("CASH");
        assertThat(done.at("/refunds/0/refundAmount").decimalValue()).isEqualByComparingTo("10000");
        assertThat(done.at("/refunds/0/originalPaymentId").asText()).isNotBlank();

        // §86: transaksi asli utuh
        JsonNode original = body(call(c.token(), "GET", SALES + "/" + sale.get("id").asText(), null)).get("data");
        assertThat(original.get("status").asText()).isEqualTo("PAID");
        assertThat(original.get("grandTotal").decimalValue()).isEqualByComparingTo("50000");

        // sisa 8 disetujui supervisor dari akunnya
        String r2 = body(createReturn(c.token(), "RET-" + UUID.randomUUID(), sale, line, 8)).at("/data/id").asText();
        assertThat(code(call(c.token(), "POST", SESSIONS + "/" + session + "/close",
                Map.of("counts", lines(c.token(), 100000, 5))))).isEqualTo("RETURN_PENDING");
        MvcResult approved = postAs("supervisor.jkt", RETURNS + "/" + r2 + "/approve", Map.of());
        assertThat(approved.getResponse().getStatus()).as(approved.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(approved).at("/data/totalAmount").decimalValue()).isEqualByComparingTo("40000");
        assertThat(code(createReturn(c.token(), "RET-" + UUID.randomUUID(), sale, line, 1)))
                .isEqualTo("RETURN_QUANTITY_EXCEEDED");

        JsonNode list = body(getAs("supervisor.jkt", RETURNS + "?outletId=" + OUTLET_JKT)).get("data");
        Set<String> ids = new HashSet<>();
        list.forEach(x -> ids.add(x.get("id").asText()));
        assertThat(ids).contains(returnId, r2);

        // Z report: refund masuk, laci = modal (50.000 masuk, 50.000 dikembalikan)
        MvcResult closed = call(c.token(), "POST", SESSIONS + "/" + session + "/close",
                Map.of("counts", lines(c.token(), 100000, 5)));
        assertThat(closed.getResponse().getStatus()).as(closed.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode z = body(call(c.token(), "GET", SESSIONS + "/" + session + "/z-report", null)).get("data");
        assertThat(z.at("/sales/refund").decimalValue()).isEqualByComparingTo("50000");
        assertThat(z.at("/sales/netSales").decimalValue()).isEqualByComparingTo("0");
        assertThat(z.at("/cash/cashRefund").decimalValue()).isEqualByComparingTo("50000");

        Set<String> actions = new HashSet<>();
        body(getAs("auditor", "/api/audit-logs?entityType=RETURN&entityId=" + returnId))
                .at("/data/items").forEach(a -> actions.add(a.get("action").asText()));
        assertThat(actions).contains("RETURN_CREATED", "APPROVAL", "RETURN_COMPLETED");
    }

    @Test
    void rejectedReturnFreesQuantityAndOtherOutletCannotLookUp() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        openSession(c);
        JsonNode sale = paidSale(c, 1);
        String receiptNo = sale.get("receiptNo").asText();
        String line = body(call(c.token(), "GET", RETURNS + "/lookup?receiptNo=" + receiptNo, null))
                .at("/data/items/0/saleItemId").asText();
        String r = body(createReturn(c.token(), "RET-" + UUID.randomUUID(), sale, line, 1)).at("/data/id").asText();
        MvcResult rejected = call(c.token(), "POST", RETURNS + "/" + r + "/reject", Map.of("reason", "Pelanggan batal retur"));
        assertThat(rejected.getResponse().getStatus()).as(rejected.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(rejected).at("/data/status").asText()).isEqualTo("REJECTED");
        assertThat(body(call(c.token(), "GET", RETURNS + "/lookup?receiptNo=" + receiptNo, null))
                .at("/data/items/0/remainingQuantity").decimalValue()).isEqualByComparingTo("1");
        assertThat(code(call(c.token(), "POST", RETURNS + "/" + r + "/approve-at-terminal",
                Map.of("email", "supervisor.jkt@demo.local", "password", DEMO_PASSWORD)))).isEqualTo("RETURN_CLOSED");

        Cashier bdg = newCashier(OUTLET_BDG);
        assertThat(code(call(bdg.token(), "GET", RETURNS + "/lookup?receiptNo=" + receiptNo, null))).isEqualTo("SALE_NOT_FOUND");
    }
}
