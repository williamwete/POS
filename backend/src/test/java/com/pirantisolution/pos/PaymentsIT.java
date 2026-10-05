package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

import com.fasterxml.jackson.databind.JsonNode;
import com.pirantisolution.pos.payment.gateway.CallbackSigner;
import java.time.Clock;
import java.time.Instant;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

/** Phase 5 — pembayaran (§22, §23, §24, §63, §64, §78). Kasir & terminal baru per test. */
class PaymentsIT extends IntegrationTestBase {

    private static final String SALES = "/api/sales";
    private static final String TISU = "00000000-0000-4000-8000-000000000932";   // 50.000
    private static final String CALLBACK_SECRET = "test-payment-callback-secret-0123456789";

    private Cashier readyCashier() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT))
                .getResponse().getStatus()).isEqualTo(201);
        MvcResult open = call(c.token(), "POST", "/api/cashier/sessions/open",
                Map.of("terminalId", terminal, "counts", List.of()));
        assertThat(open.getResponse().getStatus()).as(open.getResponse().getContentAsString()).isEqualTo(201);
        return c;
    }

    /** Transaksi CHECKOUT berisi {@code qty} × tisu (Rp 50.000). */
    private String checkedOut(Cashier c, int qty) throws Exception {
        MvcResult r = call(c.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID()));
        String sale = body(r).at("/data/id").asText();
        MvcResult add = call(c.token(), "POST", SALES + "/" + sale + "/items", Map.of("productId", TISU, "quantity", qty));
        assertThat(add.getResponse().getStatus()).as(add.getResponse().getContentAsString()).isEqualTo(200);
        MvcResult co = call(c.token(), "POST", SALES + "/" + sale + "/checkout", null);
        assertThat(co.getResponse().getStatus()).as(co.getResponse().getContentAsString()).isEqualTo(200);
        return sale;
    }

    private MvcResult pay(Cashier c, String sale, Map<String, Object> req) throws Exception {
        Map<String, Object> b = new HashMap<>(req);
        b.putIfAbsent("clientPaymentId", "PAY-" + UUID.randomUUID());
        return call(c.token(), "POST", SALES + "/" + sale + "/payments", b);
    }

    private String approval(Cashier c, String sale, long amount) throws Exception {
        MvcResult r = call(c.token(), "POST", "/api/approvals", Map.of("action", "PAYMENT_CONFIRM", "saleId", sale,
                "price", amount, "email", "supervisor.jkt@demo.local", "password", DEMO_PASSWORD));
        assertThat(r.getResponse().getStatus()).as(r.getResponse().getContentAsString()).isEqualTo(201);
        return body(r).at("/data/id").asText();
    }

    private MvcResult callback(String body, String signature, String timestamp) throws Exception {
        var req = post("/api/payments/callback/SIMULATOR").contentType(MediaType.APPLICATION_JSON).content(body);
        if (signature != null) {
            req.header(CallbackSigner.SIGNATURE_HEADER, signature).header(CallbackSigner.TIMESTAMP_HEADER, timestamp);
        }
        return mvc.perform(req).andReturn();
    }

    @Test
    void cashWithChangeMarksSalePaid() throws Exception {
        Cashier c = readyCashier();
        String sale = checkedOut(c, 1);

        JsonNode methods = body(call(c.token(), "GET", "/api/payment-methods", null)).get("data");
        Set<String> codes = new HashSet<>();
        methods.forEach(m -> codes.add(m.get("code").asText()));
        assertThat(codes).contains("CASH", "DEBIT_CARD", "CREDIT_CARD", "QRIS", "E_WALLET", "BANK_TRANSFER");

        MvcResult r = pay(c, sale, Map.of("methodCode", "CASH", "amountReceived", 100000, "amount", 1));
        assertThat(r.getResponse().getStatus()).as(r.getResponse().getContentAsString()).isEqualTo(201);
        JsonNode p = body(r).at("/data/payment");
        // §24: total 50.000, diterima 100.000, kembali 50.000 — semua tersimpan
        assertThat(p.get("amount").decimalValue()).isEqualByComparingTo("50000");
        assertThat(p.get("amountReceived").decimalValue()).isEqualByComparingTo("100000");
        assertThat(p.get("changeAmount").decimalValue()).isEqualByComparingTo("50000");
        assertThat(p.get("status").asText()).isEqualTo("PAID");
        JsonNode s = body(r).at("/data/sale");
        assertThat(s.get("status").asText()).isEqualTo("PAID");
        assertThat(s.get("syncStatus").asText()).isEqualTo("PENDING");
        assertThat(s.get("changeAmount").decimalValue()).isEqualByComparingTo("50000");

        JsonNode receipt = body(call(c.token(), "GET", SALES + "/" + sale + "/receipt", null)).get("data");
        assertThat(receipt.get("status").asText()).isEqualTo("PAID");
        assertThat(receipt.get("payments")).hasSize(1);
        assertThat(receipt.at("/payments/0/amountReceived").decimalValue()).isEqualByComparingTo("100000");

        assertThat(code(pay(c, sale, Map.of("methodCode", "CASH", "amountReceived", 1000)))).isEqualTo("SALE_ALREADY_PAID");
        String pid = p.get("id").asText();
        assertThat(code(call(c.token(), "POST", "/api/payments/" + pid + "/cancel", Map.of("reason", "Salah input kasir"))))
                .isEqualTo("PAYMENT_NOT_REVERSIBLE");

        Set<String> actions = new HashSet<>();
        body(getAs("auditor", "/api/audit-logs?entityType=SALE&entityId=" + sale))
                .at("/data/items").forEach(a -> actions.add(a.get("action").asText()));
        assertThat(actions).contains("PAYMENT_ADDED", "SALE_PAID");
    }

    /** §78: total 200.000 = tunai 100.000 + QRIS 100.000 → PAID. */
    @Test
    void acceptanceSplitCashAndQris() throws Exception {
        Cashier c = readyCashier();
        String sale = checkedOut(c, 4);
        MvcResult cash = pay(c, sale, Map.of("methodCode", "CASH", "amountReceived", 100000));
        assertThat(body(cash).at("/data/sale/status").asText()).isEqualTo("CHECKOUT");
        String qris = body(pay(c, sale, Map.of("methodCode", "QRIS", "amount", 100000))).at("/data/payment/id").asText();
        MvcResult paid = call(c.token(), "POST", "/api/dev-payments/" + qris + "/simulate", Map.of("result", "PAID"));
        assertThat(body(paid).at("/data/sale/status").asText()).isEqualTo("PAID");
        assertThat(body(paid).at("/data/sale/paidAmount").decimalValue()).isEqualByComparingTo("200000");
        assertThat(body(call(c.token(), "GET", SALES + "/" + sale + "/payments", null)).get("data")).hasSize(2);
    }

    @Test
    void splitPaymentAndDuplicateProtection() throws Exception {
        Cashier c = readyCashier();
        String sale = checkedOut(c, 2);   // 100.000

        MvcResult cash = pay(c, sale, Map.of("methodCode", "CASH", "amountReceived", 40000));
        assertThat(body(cash).at("/data/sale/status").asText()).isEqualTo("CHECKOUT");
        assertThat(body(cash).at("/data/sale/paidAmount").decimalValue()).isEqualByComparingTo("40000");

        assertThat(code(pay(c, sale, Map.of("methodCode", "DEBIT_CARD", "amount", 60000))))
                .isEqualTo("PAYMENT_REFERENCE_REQUIRED");
        assertThat(code(pay(c, sale, Map.of("methodCode", "DEBIT_CARD", "amount", 70000, "referenceNumber", "APPR-01"))))
                .isEqualTo("PAYMENT_EXCEEDS_REMAINING");

        String clientId = "PAY-" + UUID.randomUUID();
        Map<String, Object> debit = Map.of("clientPaymentId", clientId, "methodCode", "DEBIT_CARD", "amount", 60000,
                "referenceNumber", "APPR-01");
        MvcResult first = pay(c, sale, debit);
        assertThat(first.getResponse().getStatus()).isEqualTo(201);
        assertThat(body(first).at("/data/sale/status").asText()).isEqualTo("PAID");
        // kirim ulang (mis. koneksi putus sebelum respons diterima) → pembayaran yang sama, tidak ganda
        MvcResult again = pay(c, sale, debit);
        assertThat(body(again).at("/data/payment/id").asText()).isEqualTo(body(first).at("/data/payment/id").asText());
        assertThat(body(call(c.token(), "GET", SALES + "/" + sale + "/payments", null)).get("data")).hasSize(2);
    }

    @Test
    void qrisWaitsForProviderCallback() throws Exception {
        Cashier c = readyCashier();
        String sale = checkedOut(c, 1);

        MvcResult q = pay(c, sale, Map.of("methodCode", "QRIS", "amount", 50000));
        assertThat(q.getResponse().getStatus()).as(q.getResponse().getContentAsString()).isEqualTo(201);
        JsonNode p = body(q).at("/data/payment");
        assertThat(p.get("status").asText()).isEqualTo("PENDING");
        assertThat(p.get("qrPayload").asText()).isNotBlank();
        assertThat(body(q).at("/data/simulated").asBoolean()).isTrue();
        assertThat(body(q).at("/data/sale/status").asText()).isEqualTo("PAYMENT_PENDING");
        String pid = p.get("id").asText();
        String external = p.get("externalTransactionId").asText();

        // pembayaran lain tidak bisa melebihi tagihan selama QRIS menunggu
        assertThat(code(pay(c, sale, Map.of("methodCode", "CASH", "amountReceived", 50000)))).isEqualTo("SALE_ALREADY_PAID");
        // §64: tidak ada "sudah bayar" manual tanpa konfigurasi & approval
        assertThat(code(call(c.token(), "POST", "/api/payments/" + pid + "/confirm",
                Map.of("referenceNumber", "RRN-1", "approvalId", UUID.randomUUID())))).isEqualTo("PAYMENT_CONFIRMATION_REQUIRED");

        CallbackSigner signer = new CallbackSigner(CALLBACK_SECRET, Clock.systemUTC());
        String ts = signer.now();
        String wrongAmount = json.writeValueAsString(Map.of("externalTransactionId", external, "status", "PAID",
                "amount", "1000", "reference", "RRN-X"));
        assertThat(callback(wrongAmount, signer.sign(ts, wrongAmount), ts).getResponse().getStatus()).isEqualTo(401);
        String good = json.writeValueAsString(Map.of("externalTransactionId", external, "status", "PAID",
                "amount", "50000", "reference", "RRN-777"));
        assertThat(callback(good, "00" + signer.sign(ts, good).substring(2), ts).getResponse().getStatus()).isEqualTo(401);
        assertThat(callback(good, null, null).getResponse().getStatus()).isEqualTo(401);
        String old = Long.toString(Instant.now().minusSeconds(900).getEpochSecond());
        assertThat(callback(good, signer.sign(old, good), old).getResponse().getStatus()).isEqualTo(401);
        assertThat(body(call(c.token(), "GET", "/api/payments/" + pid, null)).at("/data/payment/status").asText())
                .isEqualTo("PENDING");

        MvcResult ok = callback(good, signer.sign(ts, good), ts);
        assertThat(ok.getResponse().getStatus()).as(ok.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode after = body(call(c.token(), "GET", "/api/payments/" + pid, null)).get("data");
        assertThat(after.at("/payment/status").asText()).isEqualTo("PAID");
        assertThat(after.at("/payment/referenceNumber").asText()).isEqualTo("RRN-777");
        assertThat(after.at("/sale/status").asText()).isEqualTo("PAID");
        // callback diulang penyedia: idempoten
        assertThat(callback(good, signer.sign(ts, good), ts).getResponse().getStatus()).isEqualTo(200);
    }

    @Test
    void simulatorDevEndpointPaysEwallet() throws Exception {
        Cashier c = readyCashier();
        String sale = checkedOut(c, 1);
        String pid = body(pay(c, sale, Map.of("methodCode", "E_WALLET", "amount", 50000))).at("/data/payment/id").asText();
        MvcResult sim = call(c.token(), "POST", "/api/dev-payments/" + pid + "/simulate", Map.of("result", "PAID"));
        assertThat(sim.getResponse().getStatus()).as(sim.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(sim).at("/data/sale/status").asText()).isEqualTo("PAID");
    }

    @Test
    void cancelPendingAndReverseCash() throws Exception {
        Cashier c = readyCashier();
        String sale = checkedOut(c, 1);
        String qris = body(pay(c, sale, Map.of("methodCode", "QRIS", "amount", 50000))).at("/data/payment/id").asText();
        MvcResult cancelled = call(c.token(), "POST", "/api/payments/" + qris + "/cancel",
                Map.of("reason", "Pelanggan ganti metode"));
        assertThat(cancelled.getResponse().getStatus()).isEqualTo(200);
        assertThat(body(cancelled).at("/data/sale/status").asText()).isEqualTo("CHECKOUT");

        String cash = body(pay(c, sale, Map.of("methodCode", "CASH", "amountReceived", 20000))).at("/data/payment/id").asText();
        assertThat(code(call(c.token(), "POST", SALES + "/" + sale + "/reopen", null))).isEqualTo("SALE_HAS_PAYMENTS");
        MvcResult reversed = call(c.token(), "POST", "/api/payments/" + cash + "/cancel",
                Map.of("reason", "Pelanggan batal belanja"));
        assertThat(reversed.getResponse().getStatus()).as(reversed.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(reversed).at("/data/sale/paidAmount").decimalValue()).isEqualByComparingTo("0");
        assertThat(call(c.token(), "POST", SALES + "/" + sale + "/reopen", null).getResponse().getStatus()).isEqualTo(200);
    }

    @Test
    void bankTransferNeedsSupervisorApproval() throws Exception {
        Cashier c = readyCashier();
        String sale = checkedOut(c, 1);
        assertThat(code(pay(c, sale, Map.of("methodCode", "BANK_TRANSFER", "amount", 50000, "referenceNumber", "TRF-1"))))
                .isEqualTo("APPROVAL_REQUIRED");
        String approvalId = approval(c, sale, 50000);
        MvcResult ok = pay(c, sale, Map.of("methodCode", "BANK_TRANSFER", "amount", 50000, "referenceNumber", "TRF-1",
                "approvalId", approvalId));
        assertThat(ok.getResponse().getStatus()).as(ok.getResponse().getContentAsString()).isEqualTo(201);
        assertThat(body(ok).at("/data/payment/approvedByUsername").asText()).isEqualTo("supervisor.jkt");
        assertThat(body(ok).at("/data/sale/status").asText()).isEqualTo("PAID");
    }

    @Test
    void paymentRulesForStatusAndOwnership() throws Exception {
        Cashier c = readyCashier();
        MvcResult r = call(c.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID()));
        String draft = body(r).at("/data/id").asText();
        call(c.token(), "POST", SALES + "/" + draft + "/items", Map.of("productId", TISU, "quantity", 1));
        assertThat(code(pay(c, draft, Map.of("methodCode", "CASH", "amountReceived", 50000)))).isEqualTo("SALE_NOT_PAYABLE");
        call(c.token(), "POST", SALES + "/" + draft + "/checkout", null);

        Cashier other = readyCashier();
        assertThat(pay(other, draft, Map.of("methodCode", "CASH", "amountReceived", 50000)).getResponse().getStatus())
                .isIn(403, 404);
        assertThat(code(pay(c, draft, Map.of("methodCode", "CASH", "amountReceived", 1500.5)))).isEqualTo("PAYMENT_AMOUNT_INVALID");
        assertThat(code(pay(c, draft, Map.of("methodCode", "NOPE", "amount", 1)))).isEqualTo("PAYMENT_METHOD_INVALID");
    }

    @Test
    void onlyConfigurationManagersEditMethods() throws Exception {
        Cashier c = readyCashier();
        assertThat(call(c.token(), "GET", "/api/admin/payment-methods", null).getResponse().getStatus()).isEqualTo(403);
        JsonNode list = body(getAs("admin", "/api/admin/payment-methods")).get("data");
        JsonNode cash = null;
        for (JsonNode m : list) {
            if ("CASH".equals(m.get("code").asText())) {
                cash = m;
            }
        }
        assertThat(cash).isNotNull();
        MvcResult off = putAs("admin", "/api/admin/payment-methods/" + cash.get("id").asText(), Map.of(
                "name", "Tunai", "active", false, "requiresReference", false, "requiresApproval", false,
                "manualConfirmAllowed", false, "sortOrder", 10, "version", cash.get("version").asInt()));
        assertThat(off.getResponse().getStatus()).isEqualTo(400);
        MvcResult rename = putAs("admin", "/api/admin/payment-methods/" + cash.get("id").asText(), Map.of(
                "name", "Tunai", "active", true, "requiresReference", false, "requiresApproval", false,
                "manualConfirmAllowed", false, "sortOrder", 10, "version", cash.get("version").asInt()));
        assertThat(rename.getResponse().getStatus()).as(rename.getResponse().getContentAsString()).isEqualTo(200);
    }
}
