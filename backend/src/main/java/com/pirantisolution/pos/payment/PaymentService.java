package com.pirantisolution.pos.payment;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.db.SystemTx;
import com.pirantisolution.pos.payment.PaymentDtos.AddPaymentRequest;
import com.pirantisolution.pos.payment.PaymentDtos.PaymentMethodView;
import com.pirantisolution.pos.payment.PaymentDtos.PaymentResult;
import com.pirantisolution.pos.payment.PaymentDtos.PaymentView;
import com.pirantisolution.pos.payment.PaymentDtos.UpdatePaymentMethodRequest;
import com.pirantisolution.pos.payment.PaymentRepository.GatewayPayment;
import com.pirantisolution.pos.payment.gateway.PaymentGateway;
import com.pirantisolution.pos.payment.gateway.PaymentGateway.CallbackEvent;
import com.pirantisolution.pos.payment.gateway.PaymentGateway.GatewayStatus;
import com.pirantisolution.pos.sale.SaleDtos.SaleView;
import com.pirantisolution.pos.sale.SaleRepository;
import com.pirantisolution.pos.sale.SaleRepository.UsedApproval;
import com.pirantisolution.pos.sale.SaleService;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Pembayaran (§22–§24, §63, §64).
 *
 * <p>Database menghitung jumlah diterapkan & kembalian, menurunkan status sale (PAID hanya bila
 * Σ pembayaran sukses ≥ total), dan mencatat cash movement tunai — dalam transaksi yang sama.
 * Pembayaran gateway hanya menjadi PAID lewat penyedia (callback bertanda tangan / polling server)
 * yang diproses dalam konteks sistem, atau konfirmasi manual dengan approval supervisor bila metode
 * mengizinkan.
 */
@Service
public class PaymentService {

    private static final Logger log = LoggerFactory.getLogger(PaymentService.class);
    private static final String EXPIRED_REASON = "Kedaluwarsa: batas waktu pembayaran habis";

    private final PaymentRepository repo;
    private final SaleRepository sales;
    private final SaleService saleService;
    private final PaymentGateway gateway;
    private final AccessService access;
    private final AuditService audit;
    private final SystemTx tx;

    public PaymentService(PaymentRepository repo, SaleRepository sales, SaleService saleService,
            PaymentGateway gateway, AccessService access, AuditService audit, SystemTx tx) {
        this.repo = repo;
        this.sales = sales;
        this.saleService = saleService;
        this.gateway = gateway;
        this.access = access;
        this.audit = audit;
        this.tx = tx;
    }

    // ------------------------------------------------------------------ metode

    @Transactional(readOnly = true)
    public List<PaymentMethodView> methods() {
        access.currentUser();
        return repo.methods(true).stream().map(m -> m.withAvailable(available(m))).toList();
    }

    @Transactional(readOnly = true)
    public List<PaymentMethodView> allMethods() {
        access.requireOrg("configuration.manage");
        return repo.methods(false).stream().map(m -> m.withAvailable(available(m))).toList();
    }

    @Transactional
    public PaymentMethodView updateMethod(UUID id, UpdatePaymentMethodRequest req) {
        CurrentUser cu = access.currentUser();
        access.requireOrg("configuration.manage");
        PaymentMethodView before = repo.method(id).orElseThrow(() -> ApiException.notFound("Metode pembayaran"));
        if ("CASH".equals(before.kind()) && !req.active()) {
            throw ApiException.validation("Metode tunai tidak bisa dinonaktifkan");
        }
        if (!repo.updateMethod(id, req.version(), req.name().trim(), req.active(), req.requiresReference(),
                req.requiresApproval(), req.manualConfirmAllowed(), req.sortOrder(),
                Guards.trimToNull(req.openbravoPaymentMethodId()), cu.userId())) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        PaymentMethodView after = repo.method(id).orElseThrow();
        audit.record(AuditEvent.of("PAYMENT_METHOD_UPDATED", "PAYMENT_METHOD", id)
                .change(methodSummary(before), methodSummary(after)));
        return after.withAvailable(available(after));
    }

    private boolean available(PaymentMethodView m) {
        return !"GATEWAY".equals(m.confirmation()) || gateway.configured() || m.manualConfirmAllowed();
    }

    // ------------------------------------------------------------------ pembayaran kasir

    @Transactional(readOnly = true)
    public List<PaymentView> forSale(UUID saleId) {
        access.currentUser();
        sales.findById(saleId).orElseThrow(() -> new ApiException(ErrorCode.SALE_NOT_FOUND));
        return repo.forSale(saleId);
    }

    @Transactional
    public PaymentResult add(UUID saleId, AddPaymentRequest req) {
        CurrentUser cu = requireEmployee();
        // ID pembayaran dari client: kirim ulang = hasil yang sama (anti pembayaran ganda, §66)
        var existing = repo.findByClientPaymentId(req.clientPaymentId());
        if (existing.isPresent()) {
            if (!existing.get().saleId().equals(saleId)) {
                throw new ApiException(ErrorCode.DUPLICATE_TRANSACTION);
            }
            return result(existing.get());
        }
        SaleView sale = ownSale(cu, saleId);
        if ("PAID".equals(sale.status())) {
            throw new ApiException(ErrorCode.SALE_ALREADY_PAID);
        }
        if (!List.of("CHECKOUT", "PAYMENT_PENDING").contains(sale.status())) {
            throw new ApiException(ErrorCode.SALE_NOT_PAYABLE);
        }
        PaymentMethodView method = repo.methodByCode(req.methodCode())
                .filter(PaymentMethodView::active)
                .orElseThrow(() -> new ApiException(ErrorCode.PAYMENT_METHOD_INVALID));
        boolean cash = "CASH".equals(method.kind());
        BigDecimal amount = cash ? null : req.amount();
        BigDecimal received = cash ? req.amountReceived() : null;
        if ((cash && received == null) || (!cash && amount == null)) {
            throw new ApiException(ErrorCode.PAYMENT_AMOUNT_INVALID,
                    cash ? "Isi jumlah uang yang diterima" : "Isi jumlah pembayaran");
        }
        requireWhole(cash ? received : amount);
        String reference = Guards.trimToNull(req.referenceNumber());
        if (method.requiresReference() && (reference == null || reference.length() < 3)) {
            throw new ApiException(ErrorCode.PAYMENT_REFERENCE_REQUIRED);
        }
        boolean isGateway = "GATEWAY".equals(method.confirmation());
        if (isGateway && !gateway.configured() && !method.manualConfirmAllowed()) {
            throw new ApiException(ErrorCode.PAYMENT_GATEWAY_UNAVAILABLE,
                    method.name() + " belum terhubung ke penyedia pembayaran");
        }
        UUID approvalId = null;
        if ("MANUAL".equals(method.confirmation()) && method.requiresApproval()) {
            UsedApproval a = saleService.consumeApproval(req.approvalId(), "PAYMENT_CONFIRM", saleId);
            if (a.price() == null || a.price().compareTo(amount) != 0) {
                throw new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan untuk jumlah yang berbeda");
            }
            approvalId = a.id();
        }

        UUID id = repo.insert(saleId, method.id(), req.clientPaymentId(), amount, received, reference, approvalId,
                cu.userId());
        if (isGateway && gateway.configured()) {
            PaymentView p = repo.findById(id).orElseThrow();
            try {
                PaymentGateway.Charge charge = gateway.create(new PaymentGateway.ChargeRequest(id,
                        req.clientPaymentId(), method.code(), p.amount(), sale.receiptNo(), p.expiresAt()));
                repo.setGatewayData(id, gateway.provider(), charge.externalTransactionId(), charge.qrPayload());
            } catch (PaymentGateway.GatewayUnavailableException e) {
                log.warn("Payment gateway create failed for payment {}: {}", id, e.getMessage());
                throw new ApiException(ErrorCode.PAYMENT_GATEWAY_UNAVAILABLE);
            }
        }
        PaymentView payment = repo.findById(id).orElseThrow();
        Map<String, Object> v = paymentSummary(payment);
        audit.record(AuditEvent.of("PAYMENT_ADDED", "SALE", saleId).outlet(sale.outletId()).change(null, v));
        return paidAudit(result(payment), sale);
    }

    /**
     * Status terbaru pembayaran. Untuk gateway yang masih PENDING, server menanyakan penyedia (polling)
     * dan menerapkan hasilnya dalam konteks sistem.
     */
    public PaymentResult refresh(UUID paymentId) {
        PaymentView p = tx.user(() -> {
            access.currentUser();
            return repo.findById(paymentId).orElseThrow(() -> new ApiException(ErrorCode.PAYMENT_NOT_FOUND));
        });
        if ("PENDING".equals(p.status()) && p.externalTransactionId() != null
                && gateway.provider().equals(p.provider())) {
            GatewayStatus st;
            try {
                st = gateway.status(p.externalTransactionId());
            } catch (RuntimeException e) {
                log.warn("Payment gateway status failed for payment {}: {}", paymentId, e.getMessage());
                st = GatewayStatus.PENDING;
            }
            if (st != GatewayStatus.PENDING) {
                applyProviderResult(p.provider(), p.externalTransactionId(), st, p.amount(), null, "POLLING");
            }
        }
        if ("PENDING".equals(p.status()) && p.expiresAt() != null && p.expiresAt().isBefore(OffsetDateTime.now())) {
            expire(paymentId);
        }
        return tx.user(() -> result(repo.findById(paymentId).orElseThrow()));
    }

    /** Batalkan pembayaran PENDING, atau balikkan pembayaran PAID sebelum transaksi lunas. */
    @Transactional
    public PaymentResult cancel(UUID paymentId, String reason) {
        CurrentUser cu = requireEmployee();
        PaymentView p = repo.findById(paymentId).orElseThrow(() -> new ApiException(ErrorCode.PAYMENT_NOT_FOUND));
        SaleView sale = ownSale(cu, p.saleId());
        String why = reason.trim();
        if (!"PENDING".equals(p.status()) && !"PAID".equals(p.status())) {
            throw new ApiException(ErrorCode.PAYMENT_INVALID_TRANSITION);
        }
        if ("PAID".equals(p.status()) && "PAID".equals(sale.status())) {
            throw new ApiException(ErrorCode.PAYMENT_NOT_REVERSIBLE);
        }
        if (!repo.transition(paymentId, p.status(), "CANCELLED", why, null, null)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        if ("PENDING".equals(p.status()) && p.externalTransactionId() != null) {
            cancelAtProvider(p.externalTransactionId());
        }
        PaymentView after = repo.findById(paymentId).orElseThrow();
        audit.record(AuditEvent.of("PAID".equals(p.status()) ? "PAYMENT_REVERSED" : "PAYMENT_CANCELLED", "SALE",
                p.saleId()).outlet(sale.outletId()).change(paymentSummary(p), paymentSummary(after)).reason(why));
        return result(after);
    }

    /** Konfirmasi manual pembayaran gateway (mis. QRIS statis) — wajib approval supervisor & referensi. */
    @Transactional
    public PaymentResult confirm(UUID paymentId, String reference, UUID approvalId) {
        CurrentUser cu = requireEmployee();
        PaymentView p = repo.findById(paymentId).orElseThrow(() -> new ApiException(ErrorCode.PAYMENT_NOT_FOUND));
        SaleView sale = ownSale(cu, p.saleId());
        if (!"PENDING".equals(p.status())) {
            throw new ApiException(ErrorCode.PAYMENT_INVALID_TRANSITION);
        }
        if (!p.manualConfirmAllowed()) {
            throw new ApiException(ErrorCode.PAYMENT_CONFIRMATION_REQUIRED);
        }
        UsedApproval a = saleService.consumeApproval(approvalId, "PAYMENT_CONFIRM", p.saleId());
        if (a.price() == null || a.price().compareTo(p.amount()) != 0) {
            throw new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan untuk jumlah yang berbeda");
        }
        if (!repo.transition(paymentId, "PENDING", "PAID", null, reference.trim(), a.id())) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        PaymentView after = repo.findById(paymentId).orElseThrow();
        audit.record(AuditEvent.of("PAYMENT_CONFIRMED_MANUAL", "SALE", p.saleId()).outlet(sale.outletId())
                .change(paymentSummary(p), paymentSummary(after)));
        return paidAudit(result(after), sale);
    }

    // ------------------------------------------------------------------ penyedia pembayaran (sistem)

    /** Callback penyedia: tanda tangan diverifikasi sebelum menyentuh database. */
    public void handleCallback(String provider, String rawBody, String signature, String timestamp) {
        if (!gateway.configured() || !gateway.provider().equalsIgnoreCase(provider)) {
            throw new ApiException(ErrorCode.PAYMENT_CALLBACK_INVALID);
        }
        CallbackEvent event;
        try {
            event = gateway.verifyCallback(rawBody, signature, timestamp);
        } catch (PaymentGateway.CallbackRejectedException e) {
            log.warn("Payment callback rejected: {}", e.getMessage());
            throw new ApiException(ErrorCode.PAYMENT_CALLBACK_INVALID);
        }
        if (event.externalTransactionId() == null || event.status() == null) {
            throw new ApiException(ErrorCode.PAYMENT_CALLBACK_INVALID);
        }
        applyProviderResult(gateway.provider(), event.externalTransactionId(), event.status(), event.amount(),
                event.reference(), "CALLBACK");
    }

    private void applyProviderResult(String provider, String externalId, GatewayStatus status, BigDecimal amount,
            String reference, String channel) {
        GatewayPayment found = tx.system(() -> repo.findByExternal(provider, externalId).orElse(null));
        if (found == null) {
            throw new ApiException(ErrorCode.PAYMENT_NOT_FOUND);
        }
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("paymentId", found.id());
        v.put("providerStatus", status.name());
        v.put("channel", channel);
        v.put("externalTransactionId", externalId);
        if (amount != null && amount.compareTo(found.amount()) != 0) {
            v.put("expectedAmount", found.amount());
            v.put("providerAmount", amount);
            tx.systemRun(() -> audit.recordSystem(found.organizationId(),
                    AuditEvent.of("PAYMENT_AMOUNT_MISMATCH", "SALE", found.saleId()).outlet(found.outletId())
                            .change(null, v)));
            throw new ApiException(ErrorCode.PAYMENT_CALLBACK_INVALID, "Jumlah dari penyedia tidak sesuai");
        }
        tx.systemRun(() -> {
            // baca ulang di transaksi ini (status bisa berubah sejak dibaca)
            GatewayPayment p = repo.gatewayPayment(found.id()).orElseThrow();
            switch (status) {
                case PAID -> {
                    if ("PENDING".equals(p.status())) {
                        repo.transition(p.id(), "PENDING", "PAID", null, reference, null);
                        audit.recordSystem(p.organizationId(), AuditEvent.of("PAYMENT_PAID", "SALE", p.saleId())
                                .outlet(p.outletId()).change(Map.of("status", "PENDING"), v));
                        if ("PAID".equals(repo.saleStatus(p.saleId()))) {
                            audit.recordSystem(p.organizationId(), AuditEvent.of("SALE_PAID", "SALE", p.saleId())
                                    .outlet(p.outletId()).change(null, Map.of("via", channel)));
                        }
                    } else if (!"PAID".equals(p.status())) {
                        // uang diterima penyedia setelah pembayaran dibatalkan/kedaluwarsa: perlu refund manual
                        audit.recordSystem(p.organizationId(), AuditEvent.of("PAYMENT_LATE_PAID", "SALE", p.saleId())
                                .outlet(p.outletId()).change(Map.of("status", p.status()), v)
                                .reason("Penyedia melaporkan lunas untuk pembayaran yang sudah ditutup; perlu ditinjau"));
                        log.warn("Late PAID for closed payment {} (status {})", p.id(), p.status());
                    }
                }
                case FAILED, EXPIRED -> {
                    if ("PENDING".equals(p.status())) {
                        repo.transition(p.id(), "PENDING", "FAILED", status.name(), null, null);
                        audit.recordSystem(p.organizationId(), AuditEvent.of("PAYMENT_FAILED", "SALE", p.saleId())
                                .outlet(p.outletId()).change(Map.of("status", "PENDING"), v));
                    }
                }
                default -> {
                    // PENDING: tidak ada perubahan
                }
            }
        });
    }

    /** Batalkan pembayaran gateway yang melewati batas waktu (§64). */
    @Scheduled(fixedDelayString = "PT60S", initialDelayString = "PT60S")
    public void expireOverduePayments() {
        List<GatewayPayment> overdue = tx.system(() -> repo.expiredPending(100));
        for (GatewayPayment p : overdue) {
            try {
                expire(p.id());
            } catch (RuntimeException e) {
                log.warn("Could not expire payment {}: {}", p.id(), e.getMessage());
            }
        }
    }

    private void expire(UUID paymentId) {
        GatewayPayment p = tx.system(() -> {
            GatewayPayment g = repo.gatewayPayment(paymentId).orElseThrow();
            if ("PENDING".equals(g.status()) && g.expiresAt() != null && g.expiresAt().isBefore(OffsetDateTime.now())
                    && repo.transition(g.id(), "PENDING", "CANCELLED", EXPIRED_REASON, null, null)) {
                audit.recordSystem(g.organizationId(), AuditEvent.of("PAYMENT_EXPIRED", "SALE", g.saleId())
                        .outlet(g.outletId()).change(Map.of("status", "PENDING"), Map.of("status", "CANCELLED",
                                "paymentId", g.id())).reason(EXPIRED_REASON));
                return g;
            }
            return null;
        });
        if (p != null && p.externalTransactionId() != null && gateway.provider().equals(p.provider())) {
            cancelAtProvider(p.externalTransactionId());
        }
    }

    private void cancelAtProvider(String externalId) {
        try {
            gateway.cancel(externalId);
        } catch (RuntimeException e) {
            log.warn("Payment gateway cancel failed for {}: {}", externalId, e.getMessage());
        }
    }

    // ------------------------------------------------------------------ helpers

    private PaymentResult result(PaymentView p) {
        SaleView sale = sales.findById(p.saleId()).orElseThrow();
        return new PaymentResult(p, sale, gateway.simulated() && gateway.provider().equals(p.provider()));
    }

    private PaymentResult paidAudit(PaymentResult r, SaleView before) {
        if ("PAID".equals(r.sale().status()) && !"PAID".equals(before.status())) {
            Map<String, Object> v = new LinkedHashMap<>();
            v.put("receiptNo", r.sale().receiptNo());
            v.put("grandTotal", r.sale().grandTotal());
            v.put("paidAmount", r.sale().paidAmount());
            v.put("changeAmount", r.sale().changeAmount());
            audit.record(AuditEvent.of("SALE_PAID", "SALE", r.sale().id()).outlet(r.sale().outletId())
                    .change(Map.of("status", before.status()), v));
        }
        return r;
    }

    private CurrentUser requireEmployee() {
        CurrentUser cu = access.currentUser();
        if (cu.employeeId() == null) {
            throw new ApiException(ErrorCode.EMPLOYEE_NOT_LINKED);
        }
        return cu;
    }

    private SaleView ownSale(CurrentUser cu, UUID saleId) {
        SaleView s = sales.findById(saleId).orElseThrow(() -> new ApiException(ErrorCode.SALE_NOT_FOUND));
        if (!s.employeeId().equals(cu.employeeId())) {
            throw ApiException.forbidden();
        }
        if ("VOID".equals(s.status()) || "CANCELLED".equals(s.status())) {
            throw new ApiException(ErrorCode.SALE_CLOSED);
        }
        return s;
    }

    private static void requireWhole(BigDecimal v) {
        if (v.signum() <= 0 || v.stripTrailingZeros().scale() > 0) {
            throw new ApiException(ErrorCode.PAYMENT_AMOUNT_INVALID, "Jumlah harus rupiah bulat dan lebih dari 0");
        }
    }

    private static Map<String, Object> paymentSummary(PaymentView p) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("paymentId", p.id());
        m.put("method", p.methodCode());
        m.put("status", p.status());
        m.put("amount", p.amount());
        m.put("amountReceived", p.amountReceived());
        m.put("changeAmount", p.changeAmount());
        m.put("reference", p.referenceNumber());
        m.put("externalTransactionId", p.externalTransactionId());
        return m;
    }

    private static Map<String, Object> methodSummary(PaymentMethodView m) {
        Map<String, Object> x = new LinkedHashMap<>();
        x.put("name", m.name());
        x.put("active", m.active());
        x.put("requiresReference", m.requiresReference());
        x.put("requiresApproval", m.requiresApproval());
        x.put("manualConfirmAllowed", m.manualConfirmAllowed());
        x.put("sortOrder", m.sortOrder());
        return x;
    }
}
