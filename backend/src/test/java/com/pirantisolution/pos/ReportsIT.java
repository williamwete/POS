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

/** Phase 7 — X report, cash-up / Z report, detail transaksi (§52–§54, §84, §85). */
class ReportsIT extends IntegrationTestBase {

    private static final String SESSIONS = "/api/cashier/sessions";
    private static final String SALES = "/api/sales";
    private static final String TISU = "00000000-0000-4000-8000-000000000932";   // 50.000

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

    private String openSession(Cashier c, long... valueQty) throws Exception {
        String terminal = newTerminal(OUTLET_JKT);
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT))
                .getResponse().getStatus()).isEqualTo(201);
        MvcResult open = call(c.token(), "POST", SESSIONS + "/open",
                Map.of("terminalId", terminal, "counts", lines(c.token(), valueQty)));
        assertThat(open.getResponse().getStatus()).as(open.getResponse().getContentAsString()).isEqualTo(201);
        return body(open).at("/data/id").asText();
    }

    private void paidCashSale(Cashier c, int qty) throws Exception {
        String sale = body(call(c.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID())))
                .at("/data/id").asText();
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/items", Map.of("productId", TISU, "quantity", qty))
                .getResponse().getStatus()).isEqualTo(200);
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/checkout", null).getResponse().getStatus()).isEqualTo(200);
        MvcResult p = call(c.token(), "POST", SALES + "/" + sale + "/payments", Map.of("methodCode", "CASH",
                "amountReceived", qty * 50000L, "amount", 1, "clientPaymentId", "PAY-" + UUID.randomUUID()));
        assertThat(p.getResponse().getStatus()).as(p.getResponse().getContentAsString()).isEqualTo(201);
    }

    private static long amountOf(JsonNode payments, String code) {
        for (JsonNode p : payments) {
            if (p.get("methodCode").asText().equals(code)) {
                return p.get("amount").decimalValue().longValueExact();
            }
        }
        return -1;
    }

    @Test
    void xReportKeepsSessionOpenAndZReportIsCreatedOnClose() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String session = openSession(c, 100000, 2);                    // modal 200.000
        paidCashSale(c, 2);                                           // tunai 100.000

        // §84: X report — kasir tidak boleh (berisi expected cash), supervisor boleh; session tetap OPEN
        assertThat(call(c.token(), "POST", SESSIONS + "/" + session + "/x-report", null).getResponse().getStatus())
                .isEqualTo(403);
        MvcResult x = postAs("supervisor.jkt", SESSIONS + "/" + session + "/x-report", null);
        assertThat(x.getResponse().getStatus()).as(x.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode xr = body(x).get("data");
        assertThat(xr.get("reportType").asText()).isEqualTo("X");
        assertThat(xr.at("/cash/expectedCash").decimalValue()).isEqualByComparingTo("300000");
        assertThat(xr.at("/sales/transactionCount").asInt()).isEqualTo(1);
        assertThat(amountOf(xr.get("payments"), "CASH")).isEqualTo(100000);
        assertThat(body(call(c.token(), "GET", SESSIONS + "/current", null)).at("/data/status").asText()).isEqualTo("OPEN");

        MvcResult noZ = call(c.token(), "GET", SESSIONS + "/" + session + "/z-report", null);
        assertThat(noZ.getResponse().getStatus()).isEqualTo(404);
        assertThat(code(noZ)).isEqualTo("CASHUP_NOT_FOUND");
        // detail transaksi: kasir baru boleh melihat setelah tutup
        assertThat(call(c.token(), "GET", SESSIONS + "/" + session + "/transactions", null).getResponse().getStatus())
                .isEqualTo(403);

        // §85: tutup kasir → cash-up dibuat bersamaan
        MvcResult closed = call(c.token(), "POST", SESSIONS + "/" + session + "/close",
                Map.of("counts", lines(c.token(), 100000, 3)));
        assertThat(closed.getResponse().getStatus()).as(closed.getResponse().getContentAsString()).isEqualTo(200);

        MvcResult z = call(c.token(), "GET", SESSIONS + "/" + session + "/z-report", null);
        assertThat(z.getResponse().getStatus()).as(z.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode zr = body(z).get("data");
        assertThat(zr.get("reportType").asText()).isEqualTo("Z");
        assertThat(zr.get("zNumber").asInt()).isEqualTo(1);
        assertThat(zr.at("/header/status").asText()).isEqualTo("CLOSED");
        assertThat(zr.at("/sales/netSales").decimalValue()).isEqualByComparingTo("100000");
        assertThat(zr.at("/cash/openingCash").decimalValue()).isEqualByComparingTo("200000");
        assertThat(zr.at("/cash/cashSales").decimalValue()).isEqualByComparingTo("100000");
        assertThat(zr.at("/cash/actualCash").decimalValue()).isEqualByComparingTo("300000");
        assertThat(zr.at("/cash/difference").decimalValue()).isEqualByComparingTo("0");
        assertThat(zr.at("/approval/closedByName").asText()).isNotBlank();

        JsonNode tx = body(call(c.token(), "GET", SESSIONS + "/" + session + "/transactions", null)).get("data");
        assertThat(tx).hasSize(1);
        assertThat(tx.get(0).get("status").asText()).isEqualTo("PAID");
        assertThat(tx.get(0).get("paymentMethods").asText()).isEqualTo("Tunai");
        assertThat(body(getAs("supervisor.jkt", SESSIONS + "/" + session + "/transactions")).get("data")).hasSize(1);

        assertThat(call(c.token(), "POST", SESSIONS + "/" + session + "/z-report/print", null).getResponse().getStatus())
                .isEqualTo(200);
        MvcResult xClosed = postAs("supervisor.jkt", SESSIONS + "/" + session + "/x-report", null);
        assertThat(code(xClosed)).isEqualTo("CASHIER_SESSION_CLOSED");

        // kasir lain tidak melihat Z report orang lain
        Cashier other = newCashier(OUTLET_JKT);
        assertThat(call(other.token(), "GET", SESSIONS + "/" + session + "/z-report", null).getResponse().getStatus())
                .isIn(403, 404);

        Set<String> actions = new HashSet<>();
        body(getAs("auditor", "/api/audit-logs?entityType=CASHIER_SESSION&entityId=" + session))
                .at("/data/items").forEach(a -> actions.add(a.get("action").asText()));
        assertThat(actions).contains("X_REPORT", "CLOSE_CASHIER", "Z_REPORT_PRINT");
    }
}
