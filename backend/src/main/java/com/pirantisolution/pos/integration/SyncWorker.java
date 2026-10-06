package com.pirantisolution.pos.integration;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.config.PosProperties;
import com.pirantisolution.pos.db.SystemTx;
import com.pirantisolution.pos.integration.OpenbravoClient.DocumentRef;
import com.pirantisolution.pos.integration.OpenbravoClient.MasterType;
import com.pirantisolution.pos.integration.OpenbravoClient.OpenbravoException;
import com.pirantisolution.pos.integration.SyncDtos.RunSummary;
import com.pirantisolution.pos.integration.SyncRepository.ClaimedJob;
import com.pirantisolution.pos.integration.SyncRepository.UpsertResult;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.locks.ReentrantLock;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Pengirim antrean sync (§41–§43). Setiap langkah database berjalan di transaksi sistem terpisah dan
 * panggilan ke Openbravo TIDAK di dalam transaksi database. Kegagalan sementara dijadwalkan ulang dengan
 * jeda bertahap; kegagalan permanen (data ditolak, pemetaan kosong) atau batas percobaan → MANUAL_REVIEW.
 */
@Component
public class SyncWorker {

    private static final Logger log = LoggerFactory.getLogger(SyncWorker.class);

    private final SyncRepository repo;
    private final OpenbravoClient client;
    private final SystemTx tx;
    private final AuditService audit;
    private final ObjectMapper json;
    private final PosProperties.Openbravo cfg;
    private final ReentrantLock running = new ReentrantLock();

    public SyncWorker(SyncRepository repo, OpenbravoClient client, SystemTx tx, AuditService audit, ObjectMapper json,
            PosProperties properties) {
        this.repo = repo;
        this.client = client;
        this.tx = tx;
        this.audit = audit;
        this.json = json;
        this.cfg = properties.openbravo();
    }

    @Scheduled(fixedDelayString = "${pos.openbravo.worker-delay:PT15S}", initialDelayString = "PT30S")
    public void scheduled() {
        if (cfg.workerEnabled() && client.enabled()) {
            try {
                processDue(cfg.batchSize());
            } catch (RuntimeException e) {
                log.warn("Sync worker run failed: {}", e.getMessage());
            }
        }
    }

    public boolean enabled() {
        return client.enabled();
    }

    /** Proses job yang jatuh tempo. Bila worker lain sedang berjalan di instance ini, kembali tanpa memproses. */
    public RunSummary processDue(int limit) {
        if (!client.enabled()) {
            return new RunSummary(0, 0, 0, 0, false);
        }
        if (!running.tryLock()) {
            return new RunSummary(0, 0, 0, 0, true);
        }
        try {
            int success = 0;
            int failed = 0;
            int deferred = 0;
            List<ClaimedJob> jobs = tx.system(() -> repo.claimDue(limit));
            for (ClaimedJob job : jobs) {
                switch (process(job)) {
                    case "SUCCESS" -> success++;
                    case "DEFERRED" -> deferred++;
                    default -> failed++;
                }
            }
            return new RunSummary(jobs.size(), success, failed, deferred, false);
        } finally {
            running.unlock();
        }
    }

    private String process(ClaimedJob job) {
        long t0 = System.nanoTime();
        try {
            if ("OUT".equals(job.direction())) {
                Optional<String> waiting = tx.system(() -> repo.waitingFor(job.id()));
                if (waiting.isPresent()) {
                    tx.systemRun(() -> repo.defer(job.id(), "WAITING: menunggu " + waiting.get() + " terkirim"));
                    return "DEFERRED";
                }
                String payload;
                try {
                    payload = tx.system(() -> repo.payload(job.id()));
                } catch (DataAccessException e) {
                    // pemetaan belum diisi / data tidak lengkap: tidak berguna di-retry otomatis
                    return fail(job, rootMessage(e), true, t0);
                }
                DocumentRef ref = client.post(job.jobType(), json.readTree(payload));
                tx.systemRun(() -> {
                    repo.markSuccess(job, ref.documentId(), ref.documentNo(), null, millis(t0));
                    audit.recordSystem(job.organizationId(), AuditEvent.of("SYNC_SUCCESS", job.jobType(), job.entityId())
                            .outlet(job.outletId()).change(null, Map.of("documentId", ref.documentId(),
                                    "documentNo", String.valueOf(ref.documentNo()), "attempt", job.attempts() + 1)));
                });
                return "SUCCESS";
            }
            MasterType type = MasterType.valueOf(job.jobType().substring("MASTER_".length()));
            List<JsonNode> items = client.fetch(type);
            String itemsJson = json.writeValueAsString(items);
            UpsertResult result = tx.system(() -> repo.upsert(job.jobType(), job.organizationId(), itemsJson));
            tx.systemRun(() -> {
                repo.markSuccess(job, null, null, result, millis(t0));
                Map<String, Object> v = new LinkedHashMap<>();
                v.put("recordsProcessed", result.processed());
                v.put("recordsSuccess", result.success());
                v.put("recordsFailed", result.failed());
                audit.recordSystem(job.organizationId(), AuditEvent.of("SYNC_SUCCESS", "SYNC_JOB", job.id()).change(null, v));
            });
            return "SUCCESS";
        } catch (OpenbravoException e) {
            return fail(job, e.getMessage(), e.permanent(), t0);
        } catch (JsonProcessingException e) {
            return fail(job, "Data tidak valid: " + e.getOriginalMessage(), true, t0);
        } catch (RuntimeException e) {
            log.warn("Sync job {} failed unexpectedly", job.id(), e);
            return fail(job, "Kesalahan internal: " + rootMessage(e), false, t0);
        }
    }

    private String fail(ClaimedJob job, String message, boolean permanent, long t0) {
        String status = tx.system(() -> {
            String s = repo.markFailure(job, message, permanent, millis(t0));
            audit.recordSystem(job.organizationId(), AuditEvent.of("SYNC_FAILED",
                    "OUT".equals(job.direction()) ? job.jobType() : "SYNC_JOB",
                    "OUT".equals(job.direction()) ? job.entityId() : job.id())
                    .outlet(job.outletId()).change(null, Map.of("status", s, "attempt", job.attempts() + 1,
                            "error", message == null ? "" : message)));
            return s;
        });
        return status;
    }

    private static int millis(long t0) {
        return (int) Math.min(Integer.MAX_VALUE, (System.nanoTime() - t0) / 1_000_000);
    }

    private static String rootMessage(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null && t.getCause() != t) {
            t = t.getCause();
        }
        String m = t.getMessage() == null ? t.getClass().getSimpleName() : t.getMessage();
        // pesan PostgreSQL: "ERROR: MAPPING_MISSING: ...\n  Where: ..." → ambil baris pertama tanpa awalan
        m = m.lines().findFirst().orElse(m).replaceFirst("^ERROR:\\s*", "");
        return m;
    }
}
