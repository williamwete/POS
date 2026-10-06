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

/** Phase 6 — manajemen kas & tutup kasir (§25, §48–§51, §82). Kasir & terminal baru per test. */
class CashManagementIT extends IntegrationTestBase {

    private static final String SESSIONS = "/api/cashier/sessions";
    private static final String SALES = "/api/sales";
    private static final String TISU = "00000000-0000-4000-8000-000000000932";   // 50.000

    private static boolean absent(JsonNode n) {
        return n == null || n.isMissingNode() || n.isNull();
    }

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

    /** Kasir baru, clock in, buka kasir dengan modal sesuai pecahan; mengembalikan id session. */
    private String openSession(Cashier c, long... valueQty) throws Exception {
        String terminal = newTerminal(OUTLET_JKT);
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT))
                .getResponse().getStatus()).isEqualTo(201);
        MvcResult open = call(c.token(), "POST", SESSIONS + "/open",
                Map.of("terminalId", terminal, "counts", lines(c.token(), valueQty)));
        assertThat(open.getResponse().getStatus()).as(open.getResponse().getContentAsString()).isEqualTo(201);
        return body(open).at("/data/id").asText();
    }

    private String paidCashSale(Cashier c, int qty, long received) throws Exception {
        String sale = body(call(c.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID())))
                .at("/data/id").asText();
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/items", Map.of("productId", TISU, "quantity", qty))
                .getResponse().getStatus()).isEqualTo(200);
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/checkout", null).getResponse().getStatus()).isEqualTo(200);
        MvcResult p = call(c.token(), "POST", SALES + "/" + sale + "/payments", Map.of("methodCode", "CASH",
                "amountReceived", received, "amount", 1, "clientPaymentId", "PAY-" + UUID.randomUUID()));
        assertThat(p.getResponse().getStatus()).as(p.getResponse().getContentAsString()).isEqualTo(201);
        return sale;
    }

    private MvcResult move(Cashier c, String session, String type, long amount, String reason, String approvalId)
            throws Exception {
        Map<String, Object> b = new HashMap<>();
        b.put("type", type);
        b.put("amount", amount);
        b.put("reason", reason);
        if (approvalId != null) {
            b.put("approvalId", approvalId);
        }
        return call(c.token(), "POST", SESSIONS + "/" + session + "/cash-movements", b);
    }

    private MvcResult approval(Cashier c, String session, String action, long amount, String password) throws Exception {
        return call(c.token(), "POST", "/api/cashier/approvals", Map.of("action", action, "sessionId", session,
                "amount", amount, "email", "supervisor.jkt@demo.local", "password", password));
    }

    private MvcResult close(String token, String session, List<Map<String, Object>> counts, String reason,
            String approvalId) throws Exception {
        Map<String, Object> b = new HashMap<>();
        b.put("counts", counts);
        if (reason != null) {
            b.put("differenceReason", reason);
        }
        if (approvalId != null) {
            b.put("approvalId", approvalId);
        }
        return call(token, "POST", SESSIONS + "/" + session + "/close", b);
    }

    private Set<String> auditActions(String session) throws Exception {
        Set<String> actions = new HashSet<>();
        body(getAs("auditor", "/api/audit-logs?entityType=CASHIER_SESSION&entityId=" + session))
                .at("/data/items").forEach(a -> actions.add(a.get("action").asText()));
        return actions;
    }

    /** §82: modal + penjualan tunai − kas keluar = expected; hitungan cocok → selisih 0, lalu clock out. */
    @Test
    void closeWithoutDifferenceThenClockOut() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String session = openSession(c, 100000, 10);                  // modal 1.000.000
        paidCashSale(c, 3, 200000);                                  // tunai 150.000
        MvcResult out = move(c, session, "CASH_OUT", 100000, "Bayar ongkos kirim", null);
        assertThat(out.getResponse().getStatus()).as(out.getResponse().getContentAsString()).isEqualTo(201);
        assertThat(body(out).at("/data/amount").decimalValue()).isEqualByComparingTo("-100000");

        assertThat(code(call(c.token(), "POST", "/api/attendance/clock-out", null))).isEqualTo("CASHIER_SESSION_OPEN");

        // blind count: kasir tidak melihat expected sebelum menghitung; mutasi penjualan tidak ditampilkan
        assertThat(absent(body(call(c.token(), "GET", SESSIONS + "/" + session, null)).at("/data/expectedCash"))).isTrue();
        Set<String> types = new HashSet<>();
        body(call(c.token(), "GET", SESSIONS + "/" + session + "/movements", null)).get("data")
                .forEach(m -> types.add(m.get("movementType").asText()));
        assertThat(types).contains("OPENING_CASH", "CASH_OUT").doesNotContain("CASH_SALE");

        List<Map<String, Object>> counts = lines(c.token(), 100000, 10, 50000, 1);   // 1.050.000
        JsonNode preview = body(call(c.token(), "POST", SESSIONS + "/" + session + "/close/preview",
                Map.of("counts", counts))).get("data");
        assertThat(preview.get("expectedCash").decimalValue()).isEqualByComparingTo("1050000");
        assertThat(preview.get("difference").decimalValue()).isEqualByComparingTo("0");
        assertThat(preview.get("approvalRequired").asBoolean()).isFalse();

        MvcResult closed = close(c.token(), session, counts, null, null);
        assertThat(closed.getResponse().getStatus()).as(closed.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode s = body(closed).get("data");
        assertThat(s.get("status").asText()).isEqualTo("CLOSED");
        assertThat(s.get("closingCash").decimalValue()).isEqualByComparingTo("1050000");
        assertThat(s.get("expectedCash").decimalValue()).isEqualByComparingTo("1050000");
        assertThat(s.get("difference").decimalValue()).isEqualByComparingTo("0");
        assertThat(absent(body(call(c.token(), "GET", SESSIONS + "/current", null)).path("data"))).isTrue();

        assertThat(code(move(c, session, "CASH_IN", 1000, "Tambah modal", null))).isEqualTo("CASHIER_SESSION_CLOSED");
        assertThat(call(c.token(), "POST", "/api/attendance/clock-out", null).getResponse().getStatus()).isEqualTo(200);
        assertThat(auditActions(session)).contains("CASH_OUT", "CLOSE_PREVIEW", "CLOSE_CASHIER");
    }

    /** §25: kas keluar di atas ambang (demo 100.000) wajib approval supervisor sekali pakai. */
    @Test
    void cashOutAboveThresholdNeedsApproval() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String session = openSession(c, 100000, 5);                   // 500.000
        MvcResult noAppr = move(c, session, "CASH_OUT", 150000, "Setor ke brankas", null);
        assertThat(noAppr.getResponse().getStatus()).isEqualTo(403);
        assertThat(code(noAppr)).isEqualTo("APPROVAL_REQUIRED");

        assertThat(code(approval(c, session, "CASH_OUT", 150000, "salah-password"))).isEqualTo("APPROVER_INVALID");
        MvcResult a = approval(c, session, "CASH_OUT", 150000, DEMO_PASSWORD);
        assertThat(a.getResponse().getStatus()).as(a.getResponse().getContentAsString()).isEqualTo(201);
        String approvalId = body(a).at("/data/id").asText();

        assertThat(code(move(c, session, "CASH_OUT", 120000, "Setor ke brankas", approvalId)))
                .as("approval untuk nominal lain").isEqualTo("APPROVAL_REQUIRED");
        // percobaan gagal di-rollback: approval masih bisa dipakai untuk nominal yang benar
        MvcResult ok = move(c, session, "CASH_OUT", 150000, "Setor ke brankas", approvalId);
        assertThat(ok.getResponse().getStatus()).as(ok.getResponse().getContentAsString()).isEqualTo(201);
        assertThat(body(ok).at("/data/approvedByName").asText()).isEqualTo("supervisor.jkt");
        assertThat(code(move(c, session, "CASH_OUT", 150000, "Setor ke brankas", approvalId))).isEqualTo("APPROVAL_REQUIRED");

        // sisa laci 350.000: petty cash 99.000 (di bawah ambang) tanpa approval; 400.000 melebihi isi laci
        assertThat(move(c, session, "PETTY_CASH", 99000, "Beli galon", null).getResponse().getStatus()).isEqualTo(201);
        assertThat(code(move(c, session, "PETTY_CASH", 400000, "Beli galon", null))).isEqualTo("CASH_INSUFFICIENT");
        assertThat(move(c, session, "CASH_IN", 1000, "", null).getResponse().getStatus()).isEqualTo(400);
    }

    /** §51: selisih wajib alasan; di atas ambang (demo 20.000) wajib approval supervisor. */
    @Test
    void differenceNeedsReasonAndApproval() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String session = openSession(c, 100000, 3);                   // 300.000
        List<Map<String, Object>> counts = lines(c.token(), 100000, 2, 50000, 1);   // 250.000 → −50.000
        JsonNode preview = body(call(c.token(), "POST", SESSIONS + "/" + session + "/close/preview",
                Map.of("counts", counts))).get("data");
        assertThat(preview.get("difference").decimalValue()).isEqualByComparingTo("-50000");
        assertThat(preview.get("reasonRequired").asBoolean()).isTrue();
        assertThat(preview.get("approvalRequired").asBoolean()).isTrue();

        assertThat(code(close(c.token(), session, counts, null, null))).isEqualTo("CASH_DIFFERENCE_REASON_REQUIRED");
        assertThat(code(close(c.token(), session, counts, "SHORTAGE", null))).isEqualTo("CASH_DIFFERENCE_REQUIRES_APPROVAL");
        String small = body(approval(c, session, "CASH_DIFFERENCE", 40000, DEMO_PASSWORD)).at("/data/id").asText();
        assertThat(code(close(c.token(), session, counts, "SHORTAGE", small))).isEqualTo("APPROVAL_REQUIRED");

        String approvalId = body(approval(c, session, "CASH_DIFFERENCE", 50000, DEMO_PASSWORD)).at("/data/id").asText();
        MvcResult closed = close(c.token(), session, counts, "SHORTAGE", approvalId);
        assertThat(closed.getResponse().getStatus()).as(closed.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode s = body(closed).get("data");
        assertThat(s.get("difference").decimalValue()).isEqualByComparingTo("-50000");
        assertThat(s.get("differenceReason").asText()).isEqualTo("SHORTAGE");
        assertThat(s.get("differenceApprovedByName").asText()).isEqualTo("supervisor.jkt");
    }

    /** §48: transaksi berisi barang memblokir tutup kasir; keranjang kosong dibatalkan otomatis. */
    @Test
    void openOrderBlocksClose() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String session = openSession(c, 100000, 1);
        String sale = body(call(c.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID())))
                .at("/data/id").asText();
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/items", Map.of("productId", TISU, "quantity", 1))
                .getResponse().getStatus()).isEqualTo(200);
        MvcResult blocked = close(c.token(), session, lines(c.token(), 100000, 1), null, null);
        assertThat(blocked.getResponse().getStatus()).isEqualTo(409);
        assertThat(code(blocked)).isEqualTo("OPEN_ORDER_EXISTS");

        // keranjang kosong (sisa layar) tidak menghalangi
        Cashier d = newCashier(OUTLET_JKT);
        String s2 = openSession(d, 100000, 1);
        call(d.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID()));
        MvcResult ok = close(d.token(), s2, lines(d.token(), 100000, 1), null, null);
        assertThat(ok.getResponse().getStatus()).as(ok.getResponse().getContentAsString()).isEqualTo(200);
    }

    /** Penyesuaian kas restricted (store manager); supervisor dapat menutup laci kasir lain. */
    @Test
    void adjustmentAndSupervisorClose() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String session = openSession(c, 100000, 1);
        Map<String, Object> adj = Map.of("amount", 5000, "reason", "Koreksi salah catat modal");
        assertThat(call(c.token(), "POST", SESSIONS + "/" + session + "/adjustments", adj).getResponse().getStatus())
                .isEqualTo(403);
        assertThat(postAs("supervisor.jkt", SESSIONS + "/" + session + "/adjustments", adj).getResponse().getStatus())
                .isEqualTo(403);
        MvcResult m = postAs("manager", SESSIONS + "/" + session + "/adjustments", adj);
        assertThat(m.getResponse().getStatus()).as(m.getResponse().getContentAsString()).isEqualTo(201);
        assertThat(body(m).at("/data/approvedByName").asText()).isEqualTo("manager");

        // kasir lain tidak bisa menutup laci ini
        Cashier other = newCashier(OUTLET_JKT);
        // (session kasir lain tidak terlihat oleh kasir → 404, atau ditolak → 403)
        assertThat(close(other.token(), session, lines(other.token(), 100000, 1), null, null).getResponse().getStatus())
                .isIn(403, 404);

        MvcResult closed = postAs("supervisor.jkt", SESSIONS + "/" + session + "/close",
                Map.of("counts", lines(c.token(), 100000, 1, 5000, 1)));
        assertThat(closed.getResponse().getStatus()).as(closed.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode s = body(closed).get("data");
        assertThat(s.get("status").asText()).isEqualTo("CLOSED");
        assertThat(s.get("difference").decimalValue()).isEqualByComparingTo("0");
        assertThat(s.get("closedByName").asText()).isEqualTo("supervisor.jkt");
        assertThat(call(c.token(), "POST", "/api/attendance/clock-out", null).getResponse().getStatus()).isEqualTo(200);
        assertThat(auditActions(session)).contains("CASH_ADJUSTMENT", "CLOSE_CASHIER");
    }
}
