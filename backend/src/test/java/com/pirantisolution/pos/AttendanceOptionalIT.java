package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

/** Clock in opsional per merchant: kasir bisa buka kasir tanpa clock in bila pengaturan dimatikan. */
class AttendanceOptionalIT extends IntegrationTestBase {

    private MvcResult open(String token, String terminalId) throws Exception {
        var denoms = body(call(token, "GET", "/api/cashier/denominations", null)).get("data");
        String id = denoms.get(0).get("id").asText();
        return call(token, "POST", "/api/cashier/sessions/open",
                Map.of("terminalId", terminalId, "counts", List.of(Map.of("denominationId", id, "quantity", 1))));
    }

    @Test
    void cashierCanOpenWithoutClockInWhenNotRequired() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);

        assertThat(code(open(c.token(), terminal))).isEqualTo("ATTENDANCE_REQUIRED");

        // kasir tidak boleh mengubah pengaturan
        assertThat(putAs("cashier.jkt", "/api/settings/attendance-required", Map.of("required", false))
                .getResponse().getStatus()).isEqualTo(403);

        assertThat(putAs("owner", "/api/settings/attendance-required", Map.of("required", false))
                .getResponse().getStatus()).isEqualTo(200);
        try {
            MvcResult opened = open(c.token(), terminal);
            assertThat(opened.getResponse().getStatus()).isEqualTo(201);
            MvcResult current = call(c.token(), "GET", "/api/attendance/current", null);
            assertThat(body(current).at("/data/status").asText()).isEqualTo("WORKING");
        } finally {
            assertThat(putAs("owner", "/api/settings/attendance-required", Map.of("required", true))
                    .getResponse().getStatus()).isEqualTo(200);
        }
    }
}
