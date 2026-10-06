package com.pirantisolution.pos.returns;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.returns.ReturnDtos.CreateReturnRequest;
import com.pirantisolution.pos.returns.ReturnDtos.ReturnLine;
import com.pirantisolution.pos.returns.ReturnDtos.ReturnView;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.time.LocalDate;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Retur & refund (§28, §29, §86).
 *
 * <p>Alur: kasir mencari struk → memilih barang & jumlah → retur dibuat (menunggu approval) → supervisor
 * menyetujui di terminal (email + password) atau dari akunnya sendiri → refund dibuat database ke pembayaran
 * asli; bagian tunai keluar dari laci kasir pemroses. Transaksi asli tidak pernah diubah.
 */
@Service
public class ReturnService {

    private static final List<String> STATUSES = List.of("PENDING_APPROVAL", "COMPLETED", "REJECTED");

    private final ReturnRepository repo;
    private final AccessService access;
    private final AuditService audit;
    private final ObjectMapper json;
    private final JdbcClient jdbc;

    public ReturnService(ReturnRepository repo, AccessService access, AuditService audit, ObjectMapper json,
            JdbcClient jdbc) {
        this.repo = repo;
        this.access = access;
        this.audit = audit;
        this.json = json;
        this.jdbc = jdbc;
    }

    @Transactional(readOnly = true)
    public JsonNode lookup(String receiptNo) {
        access.currentUser();
        String no = receiptNo == null ? "" : receiptNo.trim();
        if (no.isEmpty() || no.length() > 64) {
            throw ApiException.validation("Nomor struk wajib diisi");
        }
        try {
            return json.readTree(repo.lookup(no));
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
    }

    @Transactional
    public ReturnView create(CreateReturnRequest req) {
        CurrentUser cu = requireEmployee();
        // request yang dikirim ulang dengan ID yang sama menghasilkan retur yang sama
        var existing = repo.findByClientId(req.clientReturnId());
        if (existing.isPresent()) {
            return get(existing.get());
        }
        Set<UUID> seen = new HashSet<>();
        for (ReturnLine l : req.items()) {
            if (!seen.add(l.saleItemId())) {
                throw ApiException.validation("Baris yang sama dikirim lebih dari sekali");
            }
            if (l.quantity().scale() > 3) {
                throw ApiException.validation("Jumlah maksimal 3 angka desimal");
            }
        }
        String reference = Guards.trimToNull(req.refundReference());
        UUID id = repo.insert(req.originalSaleId(), req.clientReturnId(), req.reason().trim(), req.refundMode(),
                reference, cu.userId());
        for (ReturnLine l : req.items()) {
            repo.insertItem(id, l.saleItemId(), l.quantity(), l.returnToStock() == null || l.returnToStock());
        }
        ReturnView r = get(id);
        access.requireOutlet("sale.create", r.outletId());
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("returnNo", r.returnNo());
        v.put("originalReceiptNo", r.originalReceiptNo());
        v.put("totalAmount", r.totalAmount());
        v.put("refundMode", r.refundMode());
        v.put("items", r.items().stream().map(i -> Map.of("sku", i.sku(), "quantity", i.quantity(),
                "amount", i.amount())).toList());
        audit.record(AuditEvent.of("RETURN_CREATED", "RETURN", id).outlet(r.outletId()).change(null, v)
                .reason(r.reason()));
        // tanpa kewajiban approval & peminta punya sale.refund: langsung selesai
        if (repo.selfApprovalAllowed(r.outletId())) {
            return finish(r, null, reference, "RETURN_COMPLETED");
        }
        return r;
    }

    /** Selesaikan dengan approval terminal: password approver sudah diverifikasi pemanggil (di luar transaksi). */
    @Transactional
    public ReturnView completeWithApprover(UUID returnId, UUID approverAuthId, String refundReference) {
        CurrentUser cu = requireEmployee();
        ReturnView r = pending(returnId);
        if (!cu.userId().equals(createdBy(returnId))) {
            throw ApiException.forbidden();
        }
        ReturnRepository.Approver approver = repo.approver(approverAuthId)
                .orElseThrow(() -> new ApiException(ErrorCode.APPROVER_INVALID));
        if (approver.userId().equals(cu.userId())) {
            throw new ApiException(ErrorCode.APPROVER_INVALID, "Persetujuan harus dari user lain (bukan Anda sendiri)");
        }
        UUID approval = repo.insertApproval(returnId, approver.userId());
        repo.useApproval(approval);
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("approvalId", approval);
        v.put("action", "REFUND");
        v.put("approver", approver.username());
        v.put("price", r.totalAmount());
        audit.record(AuditEvent.of("APPROVAL", "RETURN", returnId).outlet(r.outletId()).change(null, v));
        return finish(r, approval, Guards.trimToNull(refundReference), "RETURN_COMPLETED");
    }

    /** POST /returns/{id}/approve — approver (sale.refund) dari akunnya sendiri, bukan peminta. */
    @Transactional
    public ReturnView approve(UUID returnId, String refundReference) {
        CurrentUser cu = access.currentUser();
        ReturnView r = pending(returnId);
        access.requireOutlet("sale.refund", r.outletId());
        if (cu.userId().equals(createdBy(returnId))) {
            throw new ApiException(ErrorCode.REFUND_APPROVAL_REQUIRED, "Retur Anda sendiri harus disetujui orang lain");
        }
        return finish(r, null, Guards.trimToNull(refundReference), "RETURN_APPROVED");
    }

    @Transactional
    public ReturnView reject(UUID returnId, String reason) {
        CurrentUser cu = access.currentUser();
        ReturnView r = pending(returnId);
        if (!cu.userId().equals(createdBy(returnId))) {
            access.requireOutlet("sale.refund", r.outletId());
        }
        String why = reason.trim();
        if (!repo.reject(returnId, why)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        ReturnView after = get(returnId);
        audit.record(AuditEvent.of("RETURN_REJECTED", "RETURN", returnId).outlet(r.outletId())
                .change(Map.of("status", r.status()), Map.of("status", after.status())).reason(why));
        return after;
    }

    @Transactional(readOnly = true)
    public ReturnView get(UUID returnId) {
        access.currentUser();
        return repo.find(returnId).orElseThrow(() -> new ApiException(ErrorCode.RETURN_NOT_FOUND));
    }

    @Transactional(readOnly = true)
    public List<ReturnView> list(UUID outletId, LocalDate businessDate, String status) {
        if (!access.has("sale.view", outletId) && !access.has("sale.refund", outletId)) {
            throw ApiException.forbidden();
        }
        if (status != null && !STATUSES.contains(status)) {
            throw ApiException.validation("Status tidak dikenal");
        }
        LocalDate date = businessDate != null ? businessDate
                : jdbc.sql("SELECT pos.business_date(now(), :o)").param("o", outletId).query(LocalDate.class).single();
        return repo.list(outletId, date, status);
    }

    // ------------------------------------------------------------------ helpers

    private ReturnView finish(ReturnView r, UUID approvalId, String refundReference, String auditAction) {
        if (!repo.complete(r.id(), approvalId, refundReference)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        ReturnView after = get(r.id());
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("status", after.status());
        v.put("totalAmount", after.totalAmount());
        v.put("approvedBy", after.approvedByName());
        v.put("refunds", after.refunds().stream().map(f -> Map.of("method", f.refundMethod(),
                "amount", f.refundAmount())).toList());
        audit.record(AuditEvent.of(auditAction, "RETURN", r.id()).outlet(r.outletId())
                .change(Map.of("status", r.status()), v));
        return after;
    }

    private ReturnView pending(UUID returnId) {
        ReturnView r = repo.find(returnId).orElseThrow(() -> new ApiException(ErrorCode.RETURN_NOT_FOUND));
        if (!"PENDING_APPROVAL".equals(r.status())) {
            throw new ApiException(ErrorCode.RETURN_CLOSED);
        }
        return r;
    }

    private UUID createdBy(UUID returnId) {
        return jdbc.sql("SELECT created_by FROM pos.returns WHERE id = :r").param("r", returnId)
                .query(UUID.class).single();
    }

    private CurrentUser requireEmployee() {
        CurrentUser cu = access.currentUser();
        if (cu.employeeId() == null) {
            throw new ApiException(ErrorCode.EMPLOYEE_NOT_LINKED);
        }
        return cu;
    }
}
