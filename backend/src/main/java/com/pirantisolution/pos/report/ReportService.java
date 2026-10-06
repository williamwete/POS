package com.pirantisolution.pos.report;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.report.ReportRepository.Cashup;
import com.pirantisolution.pos.report.ReportRepository.SessionRef;
import com.pirantisolution.pos.report.ReportRepository.TransactionRow;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Laporan closing (§52–§54, §84, §85).
 *
 * <ul>
 *   <li>X report: laporan tengah shift, session tetap terbuka. Berisi expected cash sehingga hanya untuk
 *       pemegang {@code cashier.view} (blind count kasir, B48).</li>
 *   <li>Z report: cash-up yang dibuat database dalam transaksi tutup kasir; dapat dibaca pemilik session dan
 *       pemegang {@code cashier.view}. Cetak ulang dicatat di audit.</li>
 *   <li>Detail transaksi per session: pemegang {@code cashier.view}, atau pemilik setelah session ditutup.</li>
 * </ul>
 */
@Service
public class ReportService {

    private final ReportRepository repo;
    private final AccessService access;
    private final AuditService audit;
    private final ObjectMapper json;

    public ReportService(ReportRepository repo, AccessService access, AuditService audit, ObjectMapper json) {
        this.repo = repo;
        this.access = access;
        this.audit = audit;
        this.json = json;
    }

    @Transactional
    public JsonNode xReport(UUID sessionId) {
        SessionRef s = session(sessionId);
        access.requireOutlet("cashier.view", s.outletId());
        JsonNode report = parse(repo.xReport(sessionId));
        audit.record(AuditEvent.of("X_REPORT", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(null, Map.of("expectedCash", report.at("/cash/expectedCash").asText(),
                        "netSales", report.at("/sales/netSales").asText())));
        return report;
    }

    @Transactional(readOnly = true)
    public JsonNode zReport(UUID sessionId) {
        SessionRef s = session(sessionId);
        requireOwnerOrViewer(s);
        Cashup c = repo.cashup(sessionId).orElseThrow(() -> new ApiException(ErrorCode.CASHUP_NOT_FOUND));
        ObjectNode report = (ObjectNode) parse(c.report());
        report.put("cashupId", c.id().toString());
        report.put("zNumber", c.zNumber());
        return report;
    }

    /** Catat cetak Z report (cetak ulang tidak mengubah cash-up). */
    @Transactional
    public void recordZPrint(UUID sessionId) {
        SessionRef s = session(sessionId);
        requireOwnerOrViewer(s);
        Cashup c = repo.cashup(sessionId).orElseThrow(() -> new ApiException(ErrorCode.CASHUP_NOT_FOUND));
        audit.record(AuditEvent.of("Z_REPORT_PRINT", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(null, Map.of("cashupId", c.id().toString(), "zNumber", c.zNumber())));
    }

    @Transactional(readOnly = true)
    public List<TransactionRow> transactions(UUID sessionId) {
        CurrentUser cu = access.currentUser();
        SessionRef s = session(sessionId);
        boolean viewer = access.has("cashier.view", s.outletId());
        boolean ownerClosed = s.employeeId().equals(cu.employeeId()) && "CLOSED".equals(s.status());
        if (!viewer && !ownerClosed) {
            throw ApiException.forbidden();
        }
        return repo.transactions(sessionId);
    }

    private SessionRef session(UUID sessionId) {
        return repo.session(sessionId).orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_NOT_FOUND));
    }

    private void requireOwnerOrViewer(SessionRef s) {
        CurrentUser cu = access.currentUser();
        if (!s.employeeId().equals(cu.employeeId()) && !access.has("cashier.view", s.outletId())) {
            throw ApiException.forbidden();
        }
    }

    private JsonNode parse(String raw) {
        try {
            return json.readTree(raw);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Laporan dari database tidak valid", e);
        }
    }
}
