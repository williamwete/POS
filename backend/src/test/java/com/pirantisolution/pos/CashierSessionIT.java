package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

/** Phase 3 — cashier session (§13, §14, §55, §74, §76). Setiap test memakai kasir & terminal baru. */
class CashierSessionIT extends IntegrationTestBase {

    private static final String SESSIONS = "/api/cashier/sessions";

    /** Field null tidak diserialisasi (JSON NON_NULL), jadi "tidak ada" = missing atau null. */
    private static boolean absent(JsonNode n) {
        return n == null || n.isMissingNode() || n.isNull();
    }

    private Map<String, String> denominations(String token) throws Exception {
        Map<String, String> ids = new HashMap<>();
        for (JsonNode d : body(call(token, "GET", "/api/cashier/denominations", null)).get("data")) {
            ids.put(d.get("kind").asText() + ":" + d.get("value").decimalValue().stripTrailingZeros().toPlainString(),
                    d.get("id").asText());
        }
        return ids;
    }

    /** counts: pasangan nilai uang kertas & jumlah lembar. */
    private List<Map<String, Object>> lines(String token, long... valueQty) throws Exception {
        Map<String, String> ids = denominations(token);
        List<Map<String, Object>> out = new ArrayList<>();
        for (int i = 0; i < valueQty.length; i += 2) {
            out.add(Map.of("denominationId", ids.get("NOTE:" + valueQty[i]), "quantity", valueQty[i + 1]));
        }
        return out;
    }

    private MvcResult open(String token, String terminalId, List<Map<String, Object>> counts) throws Exception {
        return call(token, "POST", SESSIONS + "/open", Map.of("terminalId", terminalId, "counts", counts));
    }

    private void clockIn(Cashier c, UUID outlet) throws Exception {
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", outlet))
                .getResponse().getStatus()).isEqualTo(201);
    }

    @Test
    void openingCashFromDenominationCount() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        List<Map<String, Object>> counts = lines(c.token(), 100000, 2, 50000, 3, 20000, 5, 10000, 5);

        MvcResult early = open(c.token(), terminal, counts);
        assertThat(early.getResponse().getStatus()).isEqualTo(409);
        assertThat(code(early)).isEqualTo("ATTENDANCE_REQUIRED");

        clockIn(c, OUTLET_JKT);
        MvcResult opened = open(c.token(), terminal, counts);
        assertThat(opened.getResponse().getStatus()).isEqualTo(201);
        JsonNode s = body(opened).get("data");
        String sessionId = s.get("id").asText();
        assertThat(s.get("status").asText()).isEqualTo("OPEN");
        assertThat(s.get("openingCash").decimalValue()).isEqualByComparingTo("500000");
        assertThat(absent(s.path("expectedCash"))).as("kasir tidak melihat expected cash").isTrue();
        assertThat(s.at("/counts/0/countType").asText()).isEqualTo("OPENING");
        assertThat(s.at("/counts/0/items")).hasSize(4);

        JsonNode current = body(call(c.token(), "GET", SESSIONS + "/current", null)).get("data");
        assertThat(current.get("id").asText()).isEqualTo(sessionId);

        // §76: buka kedua ditolak; terminal lain juga ditolak selama session ini aktif
        assertThat(code(open(c.token(), terminal, counts))).isEqualTo("CASHIER_SESSION_ALREADY_OPEN");
        assertThat(code(open(c.token(), newTerminal(OUTLET_JKT), counts))).isEqualTo("TERMINAL_MISMATCH");

        // §55: clock out ditolak selama session aktif
        MvcResult out = call(c.token(), "POST", "/api/attendance/clock-out", null);
        assertThat(out.getResponse().getStatus()).isEqualTo(409);
        assertThat(code(out)).isEqualTo("CASHIER_SESSION_OPEN");

        // supervisor melihat session beserta expected cash
        JsonNode list = body(getAs("supervisor.jkt", SESSIONS + "?outletId=" + OUTLET_JKT)).get("data");
        JsonNode seen = null;
        for (JsonNode x : list) {
            if (x.get("id").asText().equals(sessionId)) {
                seen = x;
            }
        }
        assertThat(seen).isNotNull();
        assertThat(seen.get("expectedCash").decimalValue()).isEqualByComparingTo("500000");

        Set<String> actions = new HashSet<>();
        body(getAs("auditor", "/api/audit-logs?entityType=CASHIER_SESSION&entityId=" + sessionId))
                .at("/data/items").forEach(a -> actions.add(a.get("action").asText()));
        assertThat(actions).contains("OPEN_CASHIER");
    }

    @Test
    void terminalCannotHaveTwoOpenSessions() throws Exception {
        String terminal = newTerminal(OUTLET_JKT);
        Cashier a = newCashier(OUTLET_JKT);
        Cashier b = newCashier(OUTLET_JKT);
        clockIn(a, OUTLET_JKT);
        clockIn(b, OUTLET_JKT);
        assertThat(open(a.token(), terminal, lines(a.token(), 50000, 1)).getResponse().getStatus()).isEqualTo(201);
        MvcResult second = open(b.token(), terminal, lines(b.token(), 50000, 1));
        assertThat(second.getResponse().getStatus()).isEqualTo(409);
        assertThat(code(second)).isEqualTo("TERMINAL_ALREADY_OPEN");
    }

    @Test
    void invalidCountsAreRejected() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        clockIn(c, OUTLET_JKT);
        String fifty = denominations(c.token()).get("NOTE:50000");

        assertThat(open(c.token(), terminal, List.of(Map.of("denominationId", fifty, "quantity", 1),
                Map.of("denominationId", fifty, "quantity", 2))).getResponse().getStatus()).isEqualTo(400);
        assertThat(open(c.token(), terminal, List.of(Map.of("denominationId", fifty, "quantity", -1)))
                .getResponse().getStatus()).isEqualTo(400);
        MvcResult unknown = open(c.token(), terminal,
                List.of(Map.of("denominationId", UUID.randomUUID().toString(), "quantity", 1)));
        assertThat(code(unknown)).isEqualTo("DENOMINATION_INVALID");

        // terminal outlet lain & role tanpa cashier.open
        assertThat(code(open(c.token(), newTerminal(OUTLET_BDG), List.of()))).isIn("OUTLET_ACCESS_DENIED", "NOT_FOUND");
        assertThat(postAs("admin", SESSIONS + "/open", Map.of("terminalId", terminal, "counts", List.of()))
                .getResponse().getStatus()).isEqualTo(403);

        // tidak ada session yang tertinggal dari percobaan yang gagal
        assertThat(absent(body(call(c.token(), "GET", SESSIONS + "/current", null)).path("data"))).isTrue();
    }

    @Test
    void lockedTerminalNeedsSignInAgain() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        clockIn(c, OUTLET_JKT);
        String id = body(open(c.token(), terminal, lines(c.token(), 100000, 1))).at("/data/id").asText();
        Thread.sleep(1100); // waktu login (presisi detik) harus sebelum waktu kunci

        MvcResult locked = call(c.token(), "POST", SESSIONS + "/" + id + "/lock", Map.of("reason", "MANUAL"));
        assertThat(locked.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(locked).at("/data/status").asText()).isEqualTo("ON_BREAK");
        assertThat(body(locked).at("/data/lockReason").asText()).isEqualTo("MANUAL");

        assertThat(code(call(c.token(), "POST", SESSIONS + "/" + id + "/cash-count",
                Map.of("counts", lines(c.token(), 100000, 1))))).isEqualTo("CASHIER_SESSION_LOCKED");

        MvcResult stale = call(c.token(), "POST", SESSIONS + "/" + id + "/unlock", null);
        assertThat(stale.getResponse().getStatus()).isEqualTo(403);
        assertThat(code(stale)).isEqualTo("REAUTH_REQUIRED");

        // kasir lain di outlet yang sama tidak bisa membuka kunci
        Cashier other = newCashier(OUTLET_JKT);
        assertThat(call(other.token(), "POST", SESSIONS + "/" + id + "/unlock", null).getResponse().getStatus())
                .isIn(403, 404);

        String fresh = signIn(c.email(), c.password());
        MvcResult unlocked = call(fresh, "POST", SESSIONS + "/" + id + "/unlock", null);
        assertThat(unlocked.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(unlocked).at("/data/status").asText()).isEqualTo("OPEN");
    }

    @Test
    void breakLocksSessionAndCancelAllowsClockOut() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        clockIn(c, OUTLET_JKT);
        String id = body(open(c.token(), terminal, lines(c.token(), 20000, 10))).at("/data/id").asText();
        Thread.sleep(1100);

        assertThat(call(c.token(), "POST", "/api/attendance/break/start", null).getResponse().getStatus())
                .isEqualTo(200);
        JsonNode s = body(call(c.token(), "GET", SESSIONS + "/current", null)).get("data");
        assertThat(s.get("status").asText()).isEqualTo("ON_BREAK");
        assertThat(s.get("lockReason").asText()).isEqualTo("BREAK");

        String fresh = signIn(c.email(), c.password());
        assertThat(code(call(fresh, "POST", SESSIONS + "/" + id + "/unlock", null))).isEqualTo("ATTENDANCE_REQUIRED");
        call(fresh, "POST", "/api/attendance/break/end", null);
        assertThat(call(fresh, "POST", SESSIONS + "/" + id + "/unlock", null).getResponse().getStatus())
                .isEqualTo(200);

        assertThat(call(fresh, "POST", SESSIONS + "/" + id + "/cancel", Map.of("reason", "x"))
                .getResponse().getStatus()).isEqualTo(400);
        MvcResult cancelled = call(fresh, "POST", SESSIONS + "/" + id + "/cancel",
                Map.of("reason", "Salah hitung modal awal"));
        assertThat(cancelled.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(cancelled).at("/data/status").asText()).isEqualTo("CANCELLED");
        assertThat(code(call(fresh, "POST", SESSIONS + "/" + id + "/lock", Map.of("reason", "MANUAL"))))
                .isEqualTo("CASHIER_SESSION_CLOSED");

        assertThat(call(fresh, "POST", "/api/attendance/clock-out", null).getResponse().getStatus()).isEqualTo(200);

        Set<String> actions = new HashSet<>();
        body(getAs("auditor", "/api/audit-logs?entityType=CASHIER_SESSION&entityId=" + id))
                .at("/data/items").forEach(a -> actions.add(a.get("action").asText()));
        assertThat(actions).contains("OPEN_CASHIER", "CASHIER_LOCK", "CASHIER_UNLOCK", "CANCEL_CASHIER");
    }

    @Test
    void midShiftCountIsBlindForCashier() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        clockIn(c, OUTLET_JKT);
        String id = body(open(c.token(), terminal, lines(c.token(), 100000, 1))).at("/data/id").asText();

        MvcResult count = call(c.token(), "POST", SESSIONS + "/" + id + "/cash-count",
                Map.of("counts", lines(c.token(), 50000, 1), "note", "Cek tengah shift"));
        assertThat(count.getResponse().getStatus()).isEqualTo(201);
        JsonNode cc = body(count).get("data");
        assertThat(cc.get("countType").asText()).isEqualTo("MID");
        assertThat(cc.get("totalAmount").decimalValue()).isEqualByComparingTo("50000");
        assertThat(absent(cc.path("difference"))).isTrue();

        JsonNode bySupervisor = body(getAs("supervisor.jkt", SESSIONS + "/" + id)).get("data");
        JsonNode mid = bySupervisor.at("/counts/1");
        assertThat(mid.get("expectedAmount").decimalValue()).isEqualByComparingTo("100000");
        assertThat(mid.get("difference").decimalValue()).isEqualByComparingTo("-50000");
        // jumlah modal awal tidak berubah karena hitungan tengah shift
        assertThat(bySupervisor.get("openingCash").decimalValue()).isEqualByComparingTo("100000");
    }

    @Test
    void forceClockOutLocksTheSession() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        clockIn(c, OUTLET_JKT);
        String id = body(open(c.token(), terminal, lines(c.token(), 10000, 3))).at("/data/id").asText();
        String attendanceId = body(call(c.token(), "GET", "/api/attendance/current", null)).at("/data/id").asText();

        MvcResult forced = postAs("supervisor.jkt", "/api/attendance/" + attendanceId + "/force-clock-out",
                Map.of("reason", "Kasir pulang karena sakit"));
        assertThat(forced.getResponse().getStatus()).isEqualTo(200);
        JsonNode s = body(getAs("supervisor.jkt", SESSIONS + "/" + id)).get("data");
        assertThat(s.get("status").asText()).isEqualTo("ON_BREAK");
        assertThat(s.get("lockReason").asText()).isEqualTo("FORCED_CLOCK_OUT");
    }

    @Test
    void openIsIdempotent() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        clockIn(c, OUTLET_JKT);
        String key = "open-" + UUID.randomUUID();
        String payload = json.writeValueAsString(Map.of("terminalId", terminal, "counts", lines(c.token(), 5000, 4)));
        MvcResult first = mvc.perform(post(SESSIONS + "/open").header("Authorization", "Bearer " + c.token())
                .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(payload)).andReturn();
        MvcResult second = mvc.perform(post(SESSIONS + "/open").header("Authorization", "Bearer " + c.token())
                .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(payload)).andReturn();
        assertThat(first.getResponse().getStatus()).isEqualTo(201);
        assertThat(second.getResponse().getStatus()).isEqualTo(201);
        assertThat(second.getResponse().getHeader("Idempotent-Replayed")).isEqualTo("true");
        assertThat(body(second).at("/data/id").asText()).isEqualTo(body(first).at("/data/id").asText());
    }
}
