package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.pirantisolution.pos.integration.OpenbravoClient;
import com.pirantisolution.pos.integration.SimulatorOpenbravoClient;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.MvcResult;

/** Phase 9 — antrean sync Openbravo (simulator), retry & manual review, pemetaan, master data (§38–§43). */
class SyncIT extends IntegrationTestBase {

    private static final String SALES = "/api/sales";
    private static final String TISU = "00000000-0000-4000-8000-000000000932";

    @Autowired
    private OpenbravoClient openbravo;

    @AfterEach
    void resetSimulator() {
        ((SimulatorOpenbravoClient) openbravo).failNext(0, false);
    }

    private record Till(Cashier cashier, String terminalId) {
    }

    private Till openTill() throws Exception {
        Cashier c = newCashier(OUTLET_JKT);
        String terminal = newTerminal(OUTLET_JKT);
        assertThat(call(c.token(), "POST", "/api/attendance/clock-in", Map.of("outletId", OUTLET_JKT))
                .getResponse().getStatus()).isEqualTo(201);
        MvcResult open = call(c.token(), "POST", "/api/cashier/sessions/open",
                Map.of("terminalId", terminal, "counts", List.of()));
        assertThat(open.getResponse().getStatus()).as(open.getResponse().getContentAsString()).isEqualTo(201);
        return new Till(c, terminal);
    }

    private String paidSale(Cashier c) throws Exception {
        String sale = body(call(c.token(), "POST", SALES, Map.of("clientTransactionId", "IT-" + UUID.randomUUID())))
                .at("/data/id").asText();
        call(c.token(), "POST", SALES + "/" + sale + "/items", Map.of("productId", TISU, "quantity", 1));
        call(c.token(), "POST", SALES + "/" + sale + "/checkout", null);
        MvcResult p = call(c.token(), "POST", SALES + "/" + sale + "/payments", Map.of("methodCode", "CASH",
                "amountReceived", 50000, "amount", 1, "clientPaymentId", "PAY-" + UUID.randomUUID()));
        assertThat(p.getResponse().getStatus()).as(p.getResponse().getContentAsString()).isEqualTo(201);
        return sale;
    }

    /** Job SALE milik transaksi ini (dicari lewat daftar job). */
    private JsonNode saleJob(String saleId) throws Exception {
        for (JsonNode j : body(getAs("admin", "/api/sync/jobs?jobType=SALE")).get("data")) {
            if (saleId.equals(j.path("entityId").asText())) {
                return j;
            }
        }
        return null;
    }

    /** Jalankan worker sampai job transaksi ini tidak lagi menunggu (antrean bersama test lain). */
    private JsonNode runUntilProcessed(String saleId) throws Exception {
        JsonNode job = null;
        for (int i = 0; i < 20; i++) {
            MvcResult run = postAs("admin", "/api/sync/run", Map.of());
            assertThat(run.getResponse().getStatus()).as(run.getResponse().getContentAsString()).isEqualTo(200);
            job = saleJob(saleId);
            if (job != null && !List.of("PENDING", "RETRYING", "PROCESSING").contains(job.get("status").asText())) {
                return job;
            }
        }
        return job;
    }

    private void mapTerminal(String terminalId, String openbravoId) throws Exception {
        MvcResult r = mvc.perform(as("admin", org.springframework.test.web.servlet.request.MockMvcRequestBuilders
                .put("/api/admin/openbravo-mappings"))
                .contentType(org.springframework.http.MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("entityType", "TERMINAL", "posId", terminalId,
                        "openbravoId", openbravoId)))).andReturn();
        assertThat(r.getResponse().getStatus()).as(r.getResponse().getContentAsString()).isEqualTo(200);
    }

    @Test
    void saleIsQueuedSyncedAndUnmappedTerminalGoesToManualReview() throws Exception {
        JsonNode status = body(getAs("admin", "/api/sync/status")).get("data");
        assertThat(status.get("mode").asText()).isEqualTo("SIMULATOR");

        Till till = openTill();
        assertThat(call(till.cashier().token(), "GET", "/api/sync/status", null).getResponse().getStatus()).isEqualTo(403);
        assertThat(call(till.cashier().token(), "POST", "/api/sync/run", Map.of()).getResponse().getStatus()).isEqualTo(403);

        // §63: job sync ada begitu transaksi lunas
        String sale = paidSale(till.cashier());
        JsonNode queued = saleJob(sale);
        assertThat(queued).isNotNull();
        assertThat(queued.get("direction").asText()).isEqualTo("OUT");

        // terminal baru belum dipetakan → manual review (bukan retry tanpa batas), transaksi lokal tetap lunas
        JsonNode review = runUntilProcessed(sale);
        assertThat(review.get("status").asText()).isEqualTo("MANUAL_REVIEW");
        assertThat(review.get("lastError").asText()).contains("MAPPING_MISSING").contains("TERMINAL");
        JsonNode s = body(call(till.cashier().token(), "GET", SALES + "/" + sale, null)).get("data");
        assertThat(s.get("status").asText()).isEqualTo("PAID");
        assertThat(s.get("syncStatus").asText()).isEqualTo("MANUAL_REVIEW");
        boolean listed = false;
        for (JsonNode e : body(getAs("admin", "/api/sync/errors")).get("data")) {
            listed |= e.get("id").asText().equals(review.get("id").asText());
        }
        assertThat(listed).as("tampil di dashboard error sync").isTrue();

        // admin mengisi pemetaan lalu mencoba ulang → terkirim, nomor dokumen Openbravo tersimpan
        mapTerminal(till.terminalId(), "OB-TERM-" + UUID.randomUUID().toString().substring(0, 8));
        assertThat(code(postAs("supervisor.jkt", "/api/sync/" + review.get("id").asText() + "/retry", null)))
                .isIn("USER_NOT_AUTHORIZED", "FORBIDDEN");
        MvcResult retry = postAs("admin", "/api/sync/" + review.get("id").asText() + "/retry", null);
        assertThat(retry.getResponse().getStatus()).as(retry.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode done = runUntilProcessed(sale);
        assertThat(done.get("status").asText()).isEqualTo("SUCCESS");
        assertThat(done.get("openbravoDocumentNo").asText()).startsWith("SIM/SO/");
        s = body(call(till.cashier().token(), "GET", SALES + "/" + sale, null)).get("data");
        assertThat(s.get("status").asText()).isEqualTo("POSTED");
        assertThat(s.get("syncStatus").asText()).isEqualTo("SYNCED");
        assertThat(code(postAs("admin", "/api/sync/" + done.get("id").asText() + "/retry", null)))
                .isEqualTo("SYNC_JOB_NOT_RETRYABLE");

        JsonNode detail = body(getAs("admin", "/api/sync/jobs/" + done.get("id").asText())).get("data");
        assertThat(detail.get("logs").size()).isGreaterThanOrEqualTo(3);   // manual review, retry, sukses
    }

    @Test
    void temporaryFailureIsRetriedWithBackoff() throws Exception {
        Till till = openTill();
        mapTerminal(till.terminalId(), "OB-TERM-" + UUID.randomUUID().toString().substring(0, 8));
        // proses antrean lain dulu agar kegagalan tersuntik mengenai job transaksi ini
        for (int i = 0; i < 20; i++) {
            if (body(postAs("admin", "/api/sync/run", Map.of())).at("/data/summary/processed").asInt() == 0) {
                break;
            }
        }
        String sale = paidSale(till.cashier());
        ((SimulatorOpenbravoClient) openbravo).failNext(1, false);
        JsonNode failed = runUntilProcessed(sale);
        assertThat(failed.get("status").asText()).isEqualTo("FAILED");
        assertThat(failed.get("attempts").asInt()).isEqualTo(1);
        assertThat(failed.get("lastError").asText()).contains("tidak dapat dihubungi");
        // percobaan berikut dijadwalkan ±30 detik lagi (§43), tidak langsung
        assertThat(java.time.OffsetDateTime.parse(failed.get("nextAttemptAt").asText()))
                .isAfter(java.time.OffsetDateTime.now().plusSeconds(15));
        JsonNode s = body(call(till.cashier().token(), "GET", SALES + "/" + sale, null)).get("data");
        assertThat(s.get("status").asText()).isEqualTo("PAID");
        assertThat(s.get("syncStatus").asText()).isEqualTo("FAILED");

        postAs("admin", "/api/sync/" + failed.get("id").asText() + "/retry", null);
        assertThat(runUntilProcessed(sale).get("status").asText()).isEqualTo("SUCCESS");
    }

    @Test
    void masterDataSyncRecordsCounts() throws Exception {
        MvcResult run = postAs("admin", "/api/sync/run", Map.of("types", List.of("MASTER_CUSTOMER", "MASTER_STOCK")));
        assertThat(run.getResponse().getStatus()).as(run.getResponse().getContentAsString()).isEqualTo(200);
        JsonNode requested = body(run).at("/data/requested");
        assertThat(requested).hasSize(2);
        for (JsonNode j : requested) {
            assertThat(j.get("status").asText()).isEqualTo("SUCCESS");
            assertThat(j.get("recordsProcessed").asInt()).isPositive();
            assertThat(j.get("recordsFailed").asInt()).isZero();
            assertThat(j.get("syncStartedAt").asText()).isNotBlank();
            assertThat(j.get("syncFinishedAt").asText()).isNotBlank();
        }
        assertThat(code(postAs("admin", "/api/sync/run", Map.of("types", List.of("SALE"))))).isEqualTo("VALIDATION_FAILED");
        JsonNode mappings = body(getAs("admin", "/api/admin/openbravo-mappings")).get("data");
        assertThat(mappings.size()).isGreaterThan(5);
        assertThat(call(newCashier(OUTLET_JKT).token(), "GET", "/api/admin/openbravo-mappings", null)
                .getResponse().getStatus()).isEqualTo(403);
    }
}
