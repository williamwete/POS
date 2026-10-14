package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDate;
import org.junit.jupiter.api.Test;

class SalesReportIT extends IntegrationTestBase {

    @Test
    void ownerReadsEveryGroupingAndCashierCannot() throws Exception {
        String q = "?from=" + LocalDate.now().minusDays(6) + "&to=" + LocalDate.now() + "&group=";
        for (String g : new String[] {"PRODUCT", "CATEGORY", "CASHIER", "DAY", "PAYMENT"}) {
            var ok = getAs("owner", "/api/reports/sales" + q + g);
            assertThat(ok.getResponse().getStatus()).as(g).isEqualTo(200);
            assertThat(body(ok).at("/data/group").asText()).isEqualTo(g);
            assertThat(body(ok).at("/data/rows").isArray()).isTrue();
        }
        assertThat(getAs("cashier.jkt", "/api/reports/sales" + q + "PRODUCT").getResponse().getStatus()).isEqualTo(403);
        assertThat(getAs("owner", "/api/reports/sales" + q + "HACK").getResponse().getStatus()).isEqualTo(400);
    }
}
