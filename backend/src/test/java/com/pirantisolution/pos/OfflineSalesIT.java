package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

/** Fase 10 tahap 1 — pengiriman transaksi tunai offline, idempotensi, dan peninjauan selisih. */
class OfflineSalesIT extends IntegrationTestBase {

    private static final String TISU = "00000000-0000-4000-8000-000000000932"; // 50.000

    private Cashier readyCashier() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT))
                .getResponse().getStatus()).isEqualTo(201);
        assertThat(call(c.token(), "POST", "/api/cashier/sessions/open",
                Map.of("terminalId", terminal, "counts", List.of())).getResponse().getStatus()).isEqualTo(201);
        return c;
    }

    private Map<String, Object> request(String tx, Object clientTotal) {
        return Map.of("clientTransactionId", tx, "offlineAt", Instant.now().minusSeconds(600).toString(),
                "lines", List.of(Map.of("productId", TISU, "quantity", 2)),
                "clientTotal", clientTotal, "amountReceived", 100000);
    }

    @Test
    void offlineSaleIsRecordedPaidAndResendIsIdempotent() throws Exception {
        Cashier c = readyCashier();
        String tx = "OFF-" + UUID.randomUUID();
        MvcResult first = call(c.token(), "POST", "/api/sales/offline", request(tx, 100000));
        assertThat(first.getResponse().getStatus()).as(first.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode d = body(first).get("data");
        assertThat(d.get("duplicate").asBoolean()).isFalse();
        assertThat(d.at("/sale/grandTotal").decimalValue()).isEqualByComparingTo("100000");
        assertThat(d.at("/sale/status").asText()).isIn("PAID", "POSTING", "POSTED");

        JsonNode again = body(call(c.token(), "POST", "/api/sales/offline", request(tx, 100000))).get("data");
        assertThat(again.get("duplicate").asBoolean()).isTrue();
        assertThat(again.at("/sale/id").asText()).isEqualTo(d.at("/sale/id").asText());
    }

    @Test
    void totalMismatchGoesToReviewAndCashierCannotListIt() throws Exception {
        Cashier c = readyCashier();
        String tx = "OFF-" + UUID.randomUUID();
        JsonNode d = body(call(c.token(), "POST", "/api/sales/offline", request(tx, 90000))).get("data");
        assertThat(d.get("reviewReasons").toString()).contains("berbeda dari total kasir offline");

        String url = "/api/offline-reviews?outletId=" + OUTLET_JKT + "&status=OPEN";
        assertThat(call(c.token(), "GET", url, null).getResponse().getStatus()).isEqualTo(403);
        JsonNode list = body(getAs("owner", url)).get("data");
        JsonNode mine = null;
        for (JsonNode n : list) {
            if (n.get("saleId").asText().equals(d.at("/sale/id").asText())) {
                mine = n;
            }
        }
        assertThat(mine).isNotNull();
        assertThat(mine.get("serverTotal").decimalValue()).isEqualByComparingTo("100000");
        assertThat(mine.get("clientTotal").decimalValue()).isEqualByComparingTo("90000");

        MvcResult res = postAs("owner", "/api/offline-reviews/" + mine.get("id").asText() + "/resolve",
                Map.of("note", "Sudah dicek dengan kasir"));
        assertThat(res.getResponse().getStatus()).as(res.getResponse().getContentAsString()).isEqualTo(200);
    }

    @Test
    void invalidOfflineRequestsAreRejected() throws Exception {
        Cashier c = readyCashier();
        Map<String, Object> bad = Map.of("clientTransactionId", "x", "offlineAt", Instant.now().toString(),
                "lines", List.of(), "clientTotal", 1, "amountReceived", 1);
        assertThat(call(c.token(), "POST", "/api/sales/offline", bad).getResponse().getStatus()).isEqualTo(422);
    }
}
