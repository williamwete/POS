package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

/** Phase 2 — attendance (§11, §12, §55, §75). Setiap test memakai kasir baru agar terisolasi. */
class AttendanceIT extends IntegrationTestBase {

    @Test
    void fullDayFlow() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);

        assertThat(body(call(c.token(), "GET", "/api/attendance/current", null)).get("data")).isNull();

        MvcResult in = call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT));
        assertThat(in.getResponse().getStatus()).isEqualTo(201);
        JsonNode att = body(in).get("data");
        String attendanceId = att.get("id").asText();
        assertThat(att.get("status").asText()).isEqualTo("WORKING");
        assertThat(att.get("businessDate").asText()).matches("\\d{4}-\\d{2}-\\d{2}");

        MvcResult again = call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT));
        assertThat(again.getResponse().getStatus()).isEqualTo(409);
        assertThat(code(again)).isEqualTo("ATTENDANCE_ALREADY_OPEN");

        MvcResult brk = call(c.token(), "POST", "/api/attendance/break/start", Map.of("reason", "Makan siang"));
        assertThat(brk.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(brk).at("/data/status").asText()).isEqualTo("ON_BREAK");

        MvcResult outDuringBreak = call(c.token(), "POST", "/api/attendance/clock-out", null);
        assertThat(outDuringBreak.getResponse().getStatus()).isEqualTo(409);
        assertThat(code(outDuringBreak)).isEqualTo("BREAK_IN_PROGRESS");

        MvcResult endBrk = call(c.token(), "POST", "/api/attendance/break/end", null);
        assertThat(endBrk.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(endBrk).at("/data/status").asText()).isEqualTo("WORKING");
        assertThat(body(endBrk).at("/data/breaks")).hasSize(1);

        MvcResult endAgain = call(c.token(), "POST", "/api/attendance/break/end", null);
        assertThat(code(endAgain)).isEqualTo("NOT_ON_BREAK");

        MvcResult out = call(c.token(), "POST", "/api/attendance/clock-out", null);
        assertThat(out.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(out).at("/data/status").asText()).isEqualTo("COMPLETED");
        assertThat(body(out).at("/data/clockOut").isNull()).isFalse();

        assertThat(body(call(c.token(), "GET", "/api/attendance/current", null)).get("data")).isNull();
        JsonNode history = body(call(c.token(), "GET", "/api/attendance/history", null)).get("data");
        assertThat(history).hasSize(1);

        // Timeline lengkap tercatat di audit (§75)
        Set<String> actions = new HashSet<>();
        body(getAs("auditor", "/api/audit-logs?entityType=ATTENDANCE&entityId=" + attendanceId))
                .at("/data/items").forEach(a -> actions.add(a.get("action").asText()));
        assertThat(actions).containsExactlyInAnyOrder("CLOCK_IN", "BREAK_START", "BREAK_END", "CLOCK_OUT");
    }

    @Test
    void cannotClockInOutsideOwnOutletOrWithoutPermission() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        MvcResult other = call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_BDG));
        assertThat(other.getResponse().getStatus()).isEqualTo(403);
        assertThat(code(other)).isEqualTo("OUTLET_ACCESS_DENIED");

        // admin tidak punya attendance.clock_in
        MvcResult admin = postAs("admin", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT));
        assertThat(admin.getResponse().getStatus()).isEqualTo(403);
    }

    @Test
    void actionsWithoutClockInAreRejected() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        assertThat(code(call(c.token(), "POST", "/api/attendance/break/start", null))).isEqualTo("NO_ACTIVE_ATTENDANCE");
        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-out", null))).isEqualTo("NO_ACTIVE_ATTENDANCE");
    }

    @Test
    void supervisorForceClockOut() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String id = body(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT)))
                .at("/data/id").asText();
        call(c.token(), "POST", "/api/attendance/break/start", null);

        // supervisor melihat kehadiran outlet
        boolean listed = false;
        for (JsonNode a : body(getAs("supervisor.jkt", "/api/attendance?outletId=" + OUTLET_JKT)).get("data")) {
            listed |= id.equals(a.get("id").asText());
        }
        assertThat(listed).isTrue();

        // kasir lain tidak boleh force; alasan wajib
        Cashier other = newCashier(OUTLET_JKT);
        assertThat(call(other.token(), "POST", "/api/attendance/" + id + "/force-clock-out",
                Map.of("reason", "Iseng menutup")).getResponse().getStatus()).isEqualTo(403);
        assertThat(postAs("supervisor.jkt", "/api/attendance/" + id + "/force-clock-out", Map.of("reason", ""))
                .getResponse().getStatus()).isEqualTo(400);

        MvcResult forced = postAs("supervisor.jkt", "/api/attendance/" + id + "/force-clock-out",
                Map.of("reason", "Lupa clock out saat pulang"));
        assertThat(forced.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(forced).at("/data/status").asText()).isEqualTo("FORCED_CLOSED");
        assertThat(body(forced).at("/data/breaks/0/breakEnd").isNull()).isFalse();

        // supervisor BDG? tidak ada; manager (BDG & JKT) tidak bisa menutup yang sudah ditutup
        MvcResult twice = postAs("manager", "/api/attendance/" + id + "/force-clock-out",
                Map.of("reason", "Tutup lagi ya"));
        assertThat(code(twice)).isEqualTo("ATTENDANCE_CLOSED");

        // setelah ditutup, kasir bisa clock in lagi
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT))
                .getResponse().getStatus()).isEqualTo(201);
    }

    @Test
    void cashierCannotSeeOutletAttendance() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        assertThat(call(c.token(), "GET", "/api/attendance?outletId=" + OUTLET_JKT, null)
                .getResponse().getStatus()).isEqualTo(403);
    }

    @Test
    void concurrentClockInCreatesOneAttendance() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        ExecutorService pool = Executors.newFixedThreadPool(4);
        List<Integer> statuses = new ArrayList<>();
        try {
            List<Callable<Integer>> calls = new ArrayList<>();
            for (int i = 0; i < 4; i++) {
                calls.add(() -> call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT))
                        .getResponse().getStatus());
            }
            for (Future<Integer> f : pool.invokeAll(calls)) {
                statuses.add(f.get());
            }
        } finally {
            pool.shutdownNow();
        }
        assertThat(statuses.stream().filter(s -> s == 201).count()).isEqualTo(1);
        assertThat(statuses.stream().filter(s -> s == 409).count()).isEqualTo(3);
    }
}
