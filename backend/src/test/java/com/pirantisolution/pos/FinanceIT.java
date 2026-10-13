package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

/** Saldo merchant, rekening bank, dan pencairan: hak akses dan aturan dasar. */
class FinanceIT extends IntegrationTestBase {

    @Test
    void onlyOwnersSeeMoney() throws Exception {
        assertThat(getAs("owner", "/api/finance/balance").getResponse().getStatus()).isEqualTo(200);
        assertThat(getAs("owner", "/api/finance/ledger").getResponse().getStatus()).isEqualTo(200);
        assertThat(getAs("admin", "/api/finance/balance").getResponse().getStatus()).isEqualTo(403);
        assertThat(getAs("supervisor.jkt", "/api/finance/balance").getResponse().getStatus()).isEqualTo(403);
        assertThat(postAs("admin", "/api/finance/payouts", Map.of("amount", 10000)).getResponse().getStatus()).isEqualTo(403);
        assertThat(getAs("owner", "/api/platform/payouts").getResponse().getStatus()).isEqualTo(403);
    }

    @Test
    void bankAccountMustBeVerifiedByOperatorBeforePayout() throws Exception {
        assertThat(putAs("owner", "/api/finance/bank-account",
                Map.of("bankCode", "BCA", "accountNumber", "abc", "accountName", "Hendra")).getResponse().getStatus()).isEqualTo(400);
        MvcResult saved = putAs("owner", "/api/finance/bank-account",
                Map.of("bankCode", "bca", "accountNumber", "1234 567 890", "accountName", "Hendra Wijaya"));
        assertThat(saved.getResponse().getStatus()).as(saved.getResponse().getContentAsString()).isEqualTo(200);
        assertThat(body(saved).at("/data/status").asText()).isEqualTo("PENDING");
        assertThat(body(saved).at("/data/accountNumber").asText()).isEqualTo("1234567890");

        // belum diverifikasi / saldo tidak cukup -> 422, bukan 500
        MvcResult early = postAs("owner", "/api/finance/payouts", Map.of("amount", 100000));
        assertThat(early.getResponse().getStatus()).as(early.getResponse().getContentAsString()).isEqualTo(422);

        // operator memverifikasi
        var pending = body(getAs("platform", "/api/platform/bank-accounts?pendingOnly=true")).get("data");
        assertThat(pending).isNotEmpty();
        String org = ORG.toString();
        assertThat(putAs("platform", "/api/platform/merchants/" + org + "/bank-account/verify", Map.of("verified", true))
                .getResponse().getStatus()).isEqualTo(200);
        assertThat(body(getAs("owner", "/api/finance/bank-account")).at("/data/status").asText()).isEqualTo("VERIFIED");

        // terverifikasi, tapi saldo kosong -> tetap 422
        assertThat(postAs("owner", "/api/finance/payouts", Map.of("amount", 100000)).getResponse().getStatus()).isEqualTo(422);
        assertThat(getAs("platform", "/api/platform/balances").getResponse().getStatus()).isEqualTo(200);
    }

    @Test
    void operatorSetsTerms() throws Exception {
        assertThat(putAs("platform", "/api/platform/merchants/" + ORG + "/terms",
                Map.of("feePercent", 0.7, "feeFlat", 0, "holdDays", 1, "minPayout", 50000)).getResponse().getStatus()).isEqualTo(200);
        assertThat(putAs("platform", "/api/platform/merchants/" + ORG + "/terms",
                Map.of("feePercent", 50, "feeFlat", 0, "holdDays", 1, "minPayout", 50000)).getResponse().getStatus()).isEqualTo(400);
        assertThat(putAs("admin", "/api/platform/merchants/" + ORG + "/terms",
                Map.of("feePercent", 0.7, "feeFlat", 0, "holdDays", 1, "minPayout", 50000)).getResponse().getStatus()).isEqualTo(403);
    }
}
