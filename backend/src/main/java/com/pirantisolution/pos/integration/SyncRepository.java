package com.pirantisolution.pos.integration;

import com.pirantisolution.pos.integration.SyncDtos.MappingView;
import com.pirantisolution.pos.integration.SyncDtos.StatusCount;
import com.pirantisolution.pos.integration.SyncDtos.SyncJobView;
import com.pirantisolution.pos.integration.SyncDtos.SyncLogView;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Antrean sinkronisasi. Metode "worker" dipanggil dalam konteks sistem (pos_system, tanpa JWT);
 * metode tampilan & permintaan dipanggil sebagai user (RLS: sync.view / sync.manage).
 */
@Repository
public class SyncRepository {

    private static final String SELECT = """
            SELECT j.id, j.job_type, j.direction, j.entity_id, j.entity_ref, j.outlet_id, o.code AS outlet_code, j.status,
                   j.attempts, j.max_attempts, j.next_attempt_at, j.last_error, j.openbravo_document_id,
                   j.openbravo_document_no, j.sync_started_at, j.sync_finished_at, j.records_processed, j.records_success,
                   j.records_failed, j.error_count, pos.approver_name(j.requested_by) AS requested_by_name, j.created_at,
                   j.updated_at
            FROM pos.sync_jobs j
            LEFT JOIN pos.outlets o ON o.id = j.outlet_id
            """;

    private final JdbcClient jdbc;

    public SyncRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    // ------------------------------------------------------------------ worker (konteks sistem)

    public record ClaimedJob(UUID id, UUID organizationId, UUID outletId, String jobType, String direction, UUID entityId,
            String entityRef, int attempts, int maxAttempts) {
    }

    /** Ambil job yang jatuh tempo (aman untuk beberapa instance: SKIP LOCKED); job macet > 10 menit diambil ulang. */
    public List<ClaimedJob> claimDue(int limit) {
        return jdbc.sql("""
                UPDATE pos.sync_jobs j SET status = 'PROCESSING', locked_at = now(), sync_started_at = now()
                WHERE j.id IN (SELECT x.id FROM pos.sync_jobs x
                               WHERE (x.status IN ('PENDING', 'RETRYING', 'FAILED') AND x.next_attempt_at <= now())
                                  OR (x.status = 'PROCESSING' AND x.locked_at < now() - interval '10 minutes')
                               ORDER BY x.next_attempt_at, x.created_at
                               LIMIT :n
                               FOR UPDATE SKIP LOCKED)
                RETURNING j.id, j.organization_id, j.outlet_id, j.job_type, j.direction, j.entity_id, j.entity_ref,
                          j.attempts, j.max_attempts
                """)
                .param("n", limit).query(ClaimedJob.class).list();
    }

    public Optional<String> waitingFor(UUID jobId) {
        return jdbc.sql("SELECT pos.sync_waiting_for(:j)").param("j", jobId).query(String.class).optional()
                .filter(s -> s != null && !s.isBlank());
    }

    public void defer(UUID jobId, String reason) {
        jdbc.sql("""
                UPDATE pos.sync_jobs SET status = 'PENDING', locked_at = NULL, next_attempt_at = now() + interval '1 minute',
                       last_error = :why
                WHERE id = :j
                """)
                .param("why", reason).param("j", jobId).update();
    }

    public String payload(UUID jobId) {
        return jdbc.sql("SELECT CAST(pos.sync_payload(:j) AS text)").param("j", jobId).query(String.class).single();
    }

    public record UpsertResult(int processed, int success, int failed, String errors) {
    }

    public UpsertResult upsert(String jobType, UUID organizationId, String itemsJson) {
        String fn = switch (jobType) {
            case "MASTER_PRODUCT" -> "pos.sync_upsert_products";
            case "MASTER_PRICE" -> "pos.sync_upsert_prices";
            case "MASTER_STOCK" -> "pos.sync_upsert_stock";
            case "MASTER_CUSTOMER" -> "pos.sync_upsert_customers";
            default -> throw new IllegalArgumentException(jobType);
        };
        return jdbc.sql("SELECT processed, success, failed, errors FROM " + fn + "(:o, CAST(:items AS jsonb))")
                .param("o", organizationId).param("items", itemsJson).query(UpsertResult.class).single();
    }

    public void markSuccess(ClaimedJob job, String documentId, String documentNo, UpsertResult counts, int durationMs) {
        jdbc.sql("""
                UPDATE pos.sync_jobs
                SET status = 'SUCCESS', attempts = attempts + 1, locked_at = NULL, sync_finished_at = now(),
                    openbravo_document_id = CAST(:docId AS text), openbravo_document_no = CAST(:docNo AS text),
                    last_error = CAST(:err AS text), records_processed = :p, records_success = :s, records_failed = :f,
                    error_count = error_count + :f
                WHERE id = :j
                """)
                .param("docId", documentId).param("docNo", documentNo)
                .param("err", counts == null ? null : counts.errors())
                .param("p", counts == null ? 1 : counts.processed()).param("s", counts == null ? 1 : counts.success())
                .param("f", counts == null ? 0 : counts.failed()).param("j", job.id()).update();
        log(job.id(), job.attempts() + 1, "SUCCESS", counts == null ? documentNo : summary(counts), durationMs);
        if ("SALE".equals(job.jobType())) {
            jdbc.sql("""
                    UPDATE pos.sales SET status = 'POSTED', sync_status = 'SYNCED', synced_at = now(), last_sync_at = now(),
                           openbravo_document_id = :docId, openbravo_document_no = CAST(:docNo AS text), sync_error = NULL
                    WHERE id = :e
                    """)
                    .param("docId", documentId).param("docNo", documentNo).param("e", job.entityId()).update();
        } else if ("RETURN".equals(job.jobType())) {
            jdbc.sql("""
                    UPDATE pos.returns SET sync_status = 'SYNCED', last_sync_at = now(), openbravo_document_id = :docId,
                           openbravo_document_no = CAST(:docNo AS text), sync_error = NULL
                    WHERE id = :e
                    """)
                    .param("docId", documentId).param("docNo", documentNo).param("e", job.entityId()).update();
        }
    }

    /** @return status baru (FAILED dengan jadwal retry, atau MANUAL_REVIEW). */
    public String markFailure(ClaimedJob job, String message, boolean permanent, int durationMs) {
        int attempt = job.attempts() + 1;
        String status = permanent || attempt >= job.maxAttempts() ? "MANUAL_REVIEW" : "FAILED";
        String msg = message == null ? "Gagal" : (message.length() > 1000 ? message.substring(0, 1000) : message);
        jdbc.sql("""
                UPDATE pos.sync_jobs
                SET status = :st, attempts = :a, locked_at = NULL, sync_finished_at = now(), last_error = :msg,
                    error_count = error_count + 1, next_attempt_at = now() + pos.sync_retry_delay(:a)
                WHERE id = :j
                """)
                .param("st", status).param("a", attempt).param("msg", msg).param("j", job.id()).update();
        log(job.id(), attempt, "MANUAL_REVIEW".equals(status) ? "MANUAL_REVIEW" : "FAILED", msg, durationMs);
        String entityStatus = "MANUAL_REVIEW".equals(status) ? "MANUAL_REVIEW" : "FAILED";
        if ("SALE".equals(job.jobType())) {
            jdbc.sql("UPDATE pos.sales SET sync_status = :s, last_sync_at = now(), sync_error = :msg WHERE id = :e")
                    .param("s", entityStatus).param("msg", msg).param("e", job.entityId()).update();
        } else if ("RETURN".equals(job.jobType())) {
            jdbc.sql("UPDATE pos.returns SET sync_status = :s, last_sync_at = now(), sync_error = :msg WHERE id = :e")
                    .param("s", entityStatus).param("msg", msg).param("e", job.entityId()).update();
        }
        return status;
    }

    private void log(UUID jobId, int attempt, String status, String message, int durationMs) {
        jdbc.sql("""
                INSERT INTO pos.sync_logs (job_id, attempt, status, message, duration_ms)
                VALUES (:j, :a, :s, CAST(:m AS text), :d)
                """)
                .param("j", jobId).param("a", attempt).param("s", status).param("m", message).param("d", durationMs)
                .update();
    }

    private static String summary(UpsertResult r) {
        return r.processed() + " diproses, " + r.success() + " sukses, " + r.failed() + " gagal"
                + (r.errors() == null ? "" : " — " + r.errors());
    }

    // ------------------------------------------------------------------ tampilan & permintaan (user, RLS)

    public List<StatusCount> counts() {
        return jdbc.sql("""
                SELECT job_type, status, count(*) AS count FROM pos.sync_jobs
                WHERE status <> 'SUCCESS' OR updated_at > now() - interval '1 day'
                GROUP BY job_type, status ORDER BY job_type, status
                """)
                .query(StatusCount.class).list();
    }

    public Optional<OffsetDateTime> oldestPending() {
        return jdbc.sql("""
                SELECT min(created_at) FROM pos.sync_jobs
                WHERE direction = 'OUT' AND status NOT IN ('SUCCESS')
                """)
                .query(OffsetDateTime.class).optional();
    }

    public List<SyncJobView> lastMasterSyncs() {
        return jdbc.sql(SELECT + """
                WHERE j.id IN (SELECT DISTINCT ON (job_type) id FROM pos.sync_jobs
                               WHERE direction = 'IN' ORDER BY job_type, created_at DESC)
                ORDER BY j.job_type
                """)
                .query(SyncJobView.class).list();
    }

    public List<SyncJobView> problems(int limit) {
        return jdbc.sql(SELECT + """
                WHERE j.status IN ('FAILED', 'MANUAL_REVIEW', 'RETRYING')
                   OR (j.status = 'PENDING' AND j.last_error IS NOT NULL)
                ORDER BY CASE j.status WHEN 'MANUAL_REVIEW' THEN 0 WHEN 'FAILED' THEN 1 ELSE 2 END, j.updated_at DESC
                LIMIT :n
                """)
                .param("n", limit).query(SyncJobView.class).list();
    }

    public List<SyncJobView> recent(String status, String jobType, int limit) {
        return jdbc.sql(SELECT + """
                WHERE (CAST(:st AS text) IS NULL OR j.status = CAST(:st AS text))
                  AND (CAST(:t AS text) IS NULL OR j.job_type = CAST(:t AS text))
                ORDER BY j.updated_at DESC
                LIMIT :n
                """)
                .param("st", status).param("t", jobType).param("n", limit).query(SyncJobView.class).list();
    }

    public Optional<SyncJobView> find(UUID id) {
        return jdbc.sql(SELECT + " WHERE j.id = :id").param("id", id).query(SyncJobView.class).optional();
    }

    public List<SyncLogView> logs(UUID jobId) {
        return jdbc.sql("""
                SELECT attempt, status, message, duration_ms, created_at FROM pos.sync_logs
                WHERE job_id = :j ORDER BY created_at DESC LIMIT 100
                """)
                .param("j", jobId).query(SyncLogView.class).list();
    }

    /** Minta sinkron master; kosong bila jenis yang sama masih berjalan/antre. */
    public Optional<UUID> requestMaster(String jobType) {
        return jdbc.sql("""
                INSERT INTO pos.sync_jobs (organization_id, job_type, direction)
                VALUES (pos.current_org_id(), :t, 'IN')
                ON CONFLICT (organization_id, job_type) WHERE direction = 'IN' AND status IN ('PENDING', 'PROCESSING', 'RETRYING', 'FAILED')
                DO NOTHING
                RETURNING id
                """)
                .param("t", jobType).query(UUID.class).optional();
    }

    public Optional<UUID> activeMaster(String jobType) {
        return jdbc.sql("""
                SELECT id FROM pos.sync_jobs
                WHERE direction = 'IN' AND job_type = :t AND status IN ('PENDING', 'PROCESSING', 'RETRYING', 'FAILED')
                """)
                .param("t", jobType).query(UUID.class).optional();
    }

    public boolean retry(UUID id) {
        return jdbc.sql("UPDATE pos.sync_jobs SET status = 'RETRYING' WHERE id = :id AND status IN ('FAILED', 'MANUAL_REVIEW')")
                .param("id", id).update() == 1;
    }

    public void logRetryRequested(UUID jobId, int attempt) {
        // dicatat sebagai sistem (log hanya ditulis pos_system)
        log(jobId, attempt, "RETRY_REQUESTED", "Dicoba ulang manual", 0);
    }

    // ------------------------------------------------------------------ pemetaan

    public List<MappingView> mappings() {
        return jdbc.sql("""
                WITH targets AS (
                    SELECT 'ORGANIZATION' AS entity_type, g.id AS pos_id, g.code AS pos_code, g.name AS pos_name, 0 AS ord
                    FROM pos.organizations g WHERE g.id = pos.current_org_id()
                    UNION ALL SELECT 'OUTLET', o.id, o.code, o.name, 1 FROM pos.outlets o WHERE o.organization_id = pos.current_org_id()
                    UNION ALL SELECT 'WAREHOUSE', w.id, w.code, w.name, 2 FROM pos.warehouses w WHERE w.organization_id = pos.current_org_id()
                    UNION ALL SELECT 'TERMINAL', t.id, t.code, t.name, 3 FROM pos.terminals t
                              JOIN pos.outlets o ON o.id = t.outlet_id WHERE o.organization_id = pos.current_org_id()
                    UNION ALL SELECT 'PAYMENT_METHOD', m.id, m.code, m.name, 4 FROM pos.payment_methods m
                              WHERE m.organization_id = pos.current_org_id()
                    UNION ALL SELECT 'TAX', x.id, x.code, x.name, 5 FROM pos.tax_rates x WHERE x.organization_id = pos.current_org_id()
                )
                SELECT t.entity_type, t.pos_id, t.pos_code, t.pos_name, m.openbravo_id, m.version, m.updated_at,
                       pos.approver_name(m.updated_by) AS updated_by_name
                FROM targets t
                LEFT JOIN pos.openbravo_mappings m ON m.organization_id = pos.current_org_id()
                     AND m.entity_type = t.entity_type AND m.pos_id = t.pos_id
                ORDER BY t.ord, t.pos_code
                """)
                .query(MappingView.class).list();
    }

    public void upsertMapping(String entityType, UUID posId, String openbravoId) {
        jdbc.sql("""
                INSERT INTO pos.openbravo_mappings (organization_id, entity_type, pos_id, openbravo_id)
                VALUES (pos.current_org_id(), :t, :p, :ob)
                ON CONFLICT (organization_id, entity_type, pos_id) DO UPDATE SET openbravo_id = EXCLUDED.openbravo_id
                """)
                .param("t", entityType).param("p", posId).param("ob", openbravoId).update();
    }

    public Optional<String> mappingValue(String entityType, UUID posId) {
        return jdbc.sql("""
                SELECT openbravo_id FROM pos.openbravo_mappings
                WHERE organization_id = pos.current_org_id() AND entity_type = :t AND pos_id = :p
                """)
                .param("t", entityType).param("p", posId).query(String.class).optional();
    }
}
