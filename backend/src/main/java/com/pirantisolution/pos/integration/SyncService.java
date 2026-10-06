package com.pirantisolution.pos.integration;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.config.PosProperties;
import com.pirantisolution.pos.db.SystemTx;
import com.pirantisolution.pos.integration.SyncDtos.MappingRequest;
import com.pirantisolution.pos.integration.SyncDtos.MappingView;
import com.pirantisolution.pos.integration.SyncDtos.RunResult;
import com.pirantisolution.pos.integration.SyncDtos.RunSummary;
import com.pirantisolution.pos.integration.SyncDtos.SyncJobDetail;
import com.pirantisolution.pos.integration.SyncDtos.SyncJobView;
import com.pirantisolution.pos.integration.SyncDtos.SyncStatus;
import com.pirantisolution.pos.security.AccessService;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.stereotype.Service;

/**
 * Endpoint sinkronisasi untuk admin/supervisor (§42 Sync Error Dashboard, §72 /api/sync/*) dan pemetaan
 * Openbravo (§39). Pembacaan & permintaan berjalan sebagai user (RLS sync.view / sync.manage /
 * configuration.manage); pemrosesan antrean dilakukan {@link SyncWorker} dalam konteks sistem.
 */
@Service
public class SyncService {

    private static final List<String> MASTER_TYPES = List.of("MASTER_PRODUCT", "MASTER_PRICE", "MASTER_STOCK",
            "MASTER_CUSTOMER");
    private static final List<String> STATUSES = List.of("PENDING", "PROCESSING", "SUCCESS", "FAILED", "RETRYING",
            "MANUAL_REVIEW");
    private static final List<String> TYPES = List.of("SALE", "RETURN", "CASHUP", "MASTER_PRODUCT", "MASTER_PRICE",
            "MASTER_STOCK", "MASTER_CUSTOMER");

    private final SyncRepository repo;
    private final SyncWorker worker;
    private final OpenbravoClient client;
    private final AccessService access;
    private final AuditService audit;
    private final SystemTx tx;
    private final PosProperties.Openbravo cfg;

    public SyncService(SyncRepository repo, SyncWorker worker, OpenbravoClient client, AccessService access,
            AuditService audit, SystemTx tx, PosProperties properties) {
        this.repo = repo;
        this.worker = worker;
        this.client = client;
        this.access = access;
        this.audit = audit;
        this.tx = tx;
        this.cfg = properties.openbravo();
    }

    public SyncStatus status() {
        return tx.user(() -> {
            requireView();
            return new SyncStatus(client.mode(), client.enabled(), cfg.workerEnabled(), repo.counts(),
                    repo.lastMasterSyncs(), repo.oldestPending().orElse(null));
        });
    }

    public List<SyncJobView> errors() {
        return tx.user(() -> {
            requireView();
            return repo.problems(200);
        });
    }

    public List<SyncJobView> jobs(String status, String jobType) {
        if (status != null && !STATUSES.contains(status)) {
            throw ApiException.validation("Status tidak dikenal");
        }
        if (jobType != null && !TYPES.contains(jobType)) {
            throw ApiException.validation("Jenis job tidak dikenal");
        }
        return tx.user(() -> {
            requireView();
            return repo.recent(status, jobType, 200);
        });
    }

    public SyncJobDetail job(UUID id) {
        return tx.user(() -> {
            requireView();
            SyncJobView j = repo.find(id).orElseThrow(() -> ApiException.notFound("Job sync"));
            return new SyncJobDetail(j, repo.logs(id));
        });
    }

    /**
     * POST /api/sync/run: minta sinkron master (bila {@code types} diisi) lalu langsung memproses antrean yang jatuh
     * tempo. Panggilan Openbravo dilakukan di luar transaksi request.
     */
    public RunResult run(List<String> types) {
        List<UUID> ids = tx.user(() -> {
            access.requireOrg("sync.manage");
            List<UUID> out = new ArrayList<>();
            for (String t : types == null ? List.<String>of() : types) {
                if (!MASTER_TYPES.contains(t)) {
                    throw ApiException.validation("Jenis sinkron tidak dikenal");
                }
                UUID id = repo.requestMaster(t).or(() -> repo.activeMaster(t)).orElseThrow();
                out.add(id);
                audit.record(AuditEvent.of("SYNC_RUN", "SYNC_JOB", id).change(null, Map.of("jobType", t)));
            }
            return out;
        });
        if (!client.enabled() && !ids.isEmpty()) {
            throw new ApiException(ErrorCode.OPENBRAVO_UNAVAILABLE,
                    "Integrasi Openbravo belum dikonfigurasi; permintaan sinkron tersimpan di antrean");
        }
        RunSummary summary = worker.processDue(Math.max(cfg.batchSize(), 50));
        List<SyncJobView> requested = tx.user(() -> ids.stream().map(id -> repo.find(id).orElseThrow()).toList());
        return new RunResult(requested, summary);
    }

    public SyncJobView retry(UUID id) {
        SyncJobView job = tx.user(() -> {
            access.requireOrg("sync.manage");
            SyncJobView j = repo.find(id).orElseThrow(() -> ApiException.notFound("Job sync"));
            if (!repo.retry(id)) {
                throw new ApiException(ErrorCode.SYNC_JOB_NOT_RETRYABLE);
            }
            audit.record(AuditEvent.of("SYNC_RETRY", "SYNC_JOB", id).outlet(j.outletId())
                    .change(Map.of("status", j.status()), Map.of("status", "RETRYING")));
            return j;
        });
        tx.systemRun(() -> repo.logRetryRequested(id, job.attempts()));
        return tx.user(() -> repo.find(id).orElseThrow());
    }

    // ------------------------------------------------------------------ pemetaan (§39)

    public List<MappingView> mappings() {
        return tx.user(() -> {
            if (!access.has("configuration.manage", null) && !access.has("sync.view", null)) {
                throw ApiException.forbidden();
            }
            return repo.mappings();
        });
    }

    public List<MappingView> saveMapping(MappingRequest req) {
        return tx.user(() -> {
            access.requireOrg("configuration.manage");
            String before = repo.mappingValue(req.entityType(), req.posId()).orElse(null);
            repo.upsertMapping(req.entityType(), req.posId(), req.openbravoId());
            audit.record(AuditEvent.of("OPENBRAVO_MAPPING", req.entityType(), req.posId())
                    .change(before == null ? null : Map.of("openbravoId", before), Map.of("openbravoId", req.openbravoId())));
            return repo.mappings();
        });
    }

    private void requireView() {
        access.currentUser();
        boolean any = access.has("sync.view", null) || access.has("sync.manage", null)
                || access.accessibleOutletIds().stream().anyMatch(o -> access.has("sync.view", o));
        if (!any) {
            throw ApiException.forbidden();
        }
    }
}
