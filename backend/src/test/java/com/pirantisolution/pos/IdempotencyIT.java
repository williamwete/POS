package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

/** §37 / §79: request yang sama dikirim ulang menghasilkan tepat satu data. */
class IdempotencyIT extends IntegrationTestBase {

    private MvcResult createTerminal(String key, Map<String, Object> body) throws Exception {
        return mvc.perform(as("admin", post("/api/terminals"))
                .header("Idempotency-Key", key)
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(body))).andReturn();
    }

    private long countTerminalsWithCode(String code) throws Exception {
        JsonNode list = body(getAs("admin", "/api/terminals?outletId=" + OUTLET_BDG)).get("data");
        long n = 0;
        for (JsonNode t : list) {
            if (code.equals(t.get("code").asText())) {
                n++;
            }
        }
        return n;
    }

    @Test
    void replayReturnsSameResultWithoutDuplicate() throws Exception {
        String code = unique("POS-BDG");
        String key = "test-" + UUID.randomUUID();
        Map<String, Object> req = Map.of("outletId", OUTLET_BDG, "code", code, "name", "Kasir Idem");

        MvcResult first = createTerminal(key, req);
        MvcResult second = createTerminal(key, req);

        assertThat(first.getResponse().getStatus()).isEqualTo(201);
        assertThat(second.getResponse().getStatus()).isEqualTo(201);
        assertThat(second.getResponse().getHeader("Idempotent-Replayed")).isEqualTo("true");
        assertThat(body(second).at("/data/id").asText()).isEqualTo(body(first).at("/data/id").asText());
        assertThat(countTerminalsWithCode(code)).isEqualTo(1);
    }

    @Test
    void sameKeyDifferentPayloadIsRejected() throws Exception {
        String key = "test-" + UUID.randomUUID();
        createTerminal(key, Map.of("outletId", OUTLET_BDG, "code", unique("POS-BDG"), "name", "A"));
        MvcResult r = createTerminal(key, Map.of("outletId", OUTLET_BDG, "code", unique("POS-BDG"), "name", "B"));
        assertThat(r.getResponse().getStatus()).isEqualTo(422);
        assertThat(body(r).get("errorCode").asText()).isEqualTo("IDEMPOTENCY_KEY_REUSED");
    }

    @Test
    void failedRequestDoesNotBurnKey() throws Exception {
        String key = "test-" + UUID.randomUUID();
        // kode duplikat -> gagal
        MvcResult fail = createTerminal(key, Map.of("outletId", OUTLET_BDG, "code", "POS-BDG-01", "name", "dup"));
        assertThat(fail.getResponse().getStatus()).isEqualTo(409);
        // key yang sama boleh dipakai ulang setelah kegagalan (transaksi rollback)
        MvcResult ok = createTerminal(key, Map.of("outletId", OUTLET_BDG, "code", "POS-BDG-01", "name", "dup"));
        assertThat(ok.getResponse().getStatus()).isEqualTo(409);
        assertThat(ok.getResponse().getHeader("Idempotent-Replayed")).isNull();
    }

    @Test
    void concurrentRetriesProduceSingleRow() throws Exception {
        String code = unique("POS-BDG");
        String key = "test-" + UUID.randomUUID();
        Map<String, Object> req = Map.of("outletId", OUTLET_BDG, "code", code, "name", "Kasir Paralel");

        ExecutorService pool = Executors.newFixedThreadPool(4);
        try {
            List<Callable<Integer>> calls = new ArrayList<>();
            for (int i = 0; i < 4; i++) {
                calls.add(() -> createTerminal(key, req).getResponse().getStatus());
            }
            List<Integer> statuses = new ArrayList<>();
            for (Future<Integer> f : pool.invokeAll(calls)) {
                statuses.add(f.get());
            }
            assertThat(statuses).allMatch(s -> s == 201);
        } finally {
            pool.shutdownNow();
        }
        assertThat(countTerminalsWithCode(code)).isEqualTo(1);
    }

    @Test
    void invalidKeyFormatIsRejected() throws Exception {
        MvcResult r = createTerminal("bad key!", Map.of("outletId", OUTLET_BDG, "code", unique("POS-BDG"), "name", "x"));
        assertThat(r.getResponse().getStatus()).isEqualTo(400);
        assertThat(body(r).get("errorCode").asText()).isEqualTo("IDEMPOTENCY_KEY_INVALID");
    }
}
