package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDate;
import org.junit.jupiter.api.Test;

class DashboardIT extends IntegrationTestBase {

    @Test
    void ownerSeesDashboardAndCashierDoesNot() throws Exception {
        String q = "?from=" + LocalDate.now().minusDays(6) + "&to=" + LocalDate.now();
        var ok = getAs("owner", "/api/dashboard" + q);
        assertThat(ok.getResponse().getStatus()).isEqualTo(200);
        var data = body(ok).get("data");
        assertThat(data.get("daily")).hasSize(7);
        assertThat(data.get("hourly")).hasSize(24);
        assertThat(data.at("/summary/salesCount").isNumber()).isTrue();

        assertThat(getAs("cashier.jkt", "/api/dashboard" + q).getResponse().getStatus()).isEqualTo(403);
        assertThat(getAs("owner", "/api/dashboard?from=2026-01-10&to=2026-01-01").getResponse().getStatus()).isEqualTo(400);
    }
}
