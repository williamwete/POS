package com.pirantisolution.pos.cashier;

import com.pirantisolution.pos.attendance.AttendanceDtos.AttendanceView;
import com.pirantisolution.pos.attendance.AttendanceRepository;
import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.cashier.CashierDtos.CashApprovalRequest;
import com.pirantisolution.pos.cashier.CashierDtos.CashApprovalView;
import com.pirantisolution.pos.cashier.CashierDtos.CashCountView;
import com.pirantisolution.pos.cashier.CashierDtos.ClosePreview;
import com.pirantisolution.pos.cashier.CashierDtos.CloseRequest;
import com.pirantisolution.pos.cashier.CashierDtos.MovementView;
import com.pirantisolution.pos.cashier.CashierRepository.CloseBlockers;
import com.pirantisolution.pos.cashier.CashierRepository.UsedCashApproval;
import com.pirantisolution.pos.cashier.CashierDtos.CountLine;
import com.pirantisolution.pos.cashier.CashierDtos.DenominationView;
import com.pirantisolution.pos.cashier.CashierDtos.SessionView;
import com.pirantisolution.pos.cashier.CashierDtos.TerminalInfo;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.common.web.RequestContext;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Cashier session (§13, §14, §55, §74, §76): tanggung jawab karyawan atas satu terminal/laci kas.
 *
 * <p>Semua aturan inti (satu session aktif per terminal & karyawan, wajib WORKING di outlet yang
 * sama, modal awal = hitungan denominasi, unlock wajib login ulang, clock out ditolak selama session
 * aktif) ditegakkan database. Service melakukan pemeriksaan yang sama lebih dulu hanya untuk pesan
 * error yang jelas.
 */
@Service
public class CashierService {

    private static final List<String> STATUSES = List.of("OPEN", "ON_BREAK", "CLOSING", "CLOSED", "CANCELLED");

    private final CashierRepository repo;
    private final AttendanceRepository attendance;
    private final AccessService access;
    private final AuditService audit;

    public CashierService(CashierRepository repo, AttendanceRepository attendance, AccessService access,
            AuditService audit) {
        this.repo = repo;
        this.attendance = attendance;
        this.access = access;
        this.audit = audit;
    }

    @Transactional(readOnly = true)
    public List<DenominationView> denominations() {
        access.currentUser();
        return repo.denominations();
    }

    @Transactional(readOnly = true)
    public Optional<SessionView> current() {
        CurrentUser cu = access.currentUser();
        if (cu.employeeId() == null) {
            return Optional.empty();
        }
        return repo.findActiveForEmployee(cu.employeeId());
    }

    @Transactional
    public SessionView open(UUID terminalId, List<CountLine> counts, String note) {
        CurrentUser cu = requireEmployee();
        TerminalInfo terminal = repo.terminal(terminalId).orElseThrow(() -> ApiException.notFound("Terminal"));
        access.requireOutlet("cashier.open", terminal.outletId());
        if (!terminal.active()) {
            throw new ApiException(ErrorCode.TERMINAL_INACTIVE);
        }
        Optional<SessionView> mine = repo.findActiveForEmployee(cu.employeeId());
        if (mine.isPresent()) {
            throw new ApiException(mine.get().terminalId().equals(terminalId)
                    ? ErrorCode.CASHIER_SESSION_ALREADY_OPEN : ErrorCode.TERMINAL_MISMATCH);
        }
        AttendanceView att = attendance.findOpenForEmployee(cu.employeeId())
                .orElseThrow(() -> new ApiException(ErrorCode.ATTENDANCE_REQUIRED, "Clock in terlebih dahulu"));
        if (!"WORKING".equals(att.status())) {
            throw new ApiException(ErrorCode.ATTENDANCE_REQUIRED, "Selesaikan istirahat terlebih dahulu");
        }
        if (!att.outletId().equals(terminal.outletId())) {
            throw new ApiException(ErrorCode.ATTENDANCE_REQUIRED,
                    "Anda clock in di outlet " + att.outletCode() + ", bukan outlet terminal ini");
        }
        validateLines(counts);

        // Terminal yang sudah dipakai kasir lain ditolak unique index (TERMINAL_ALREADY_OPEN).
        UUID sessionId = repo.insertSession(terminal.outletId(), terminalId, cu.employeeId(), att.id(),
                cu.userId(), RequestContext.deviceId());
        String why = Guards.trimToNull(note);
        UUID countId = repo.insertCount(sessionId, "OPENING", cu.userId(), why);
        for (CountLine line : counts) {
            repo.insertCountItem(countId, line.denominationId(), line.quantity());
        }
        BigDecimal total = repo.finalizeCount(countId);
        repo.setOpeningCash(sessionId, total);
        repo.insertOpeningMovement(sessionId, total, countId, cu.userId());

        SessionView s = repo.findById(sessionId).orElseThrow();
        Map<String, Object> v = summary(s);
        v.put("openingCash", total);
        v.put("denominations", breakdown(s.counts().isEmpty() ? null : s.counts().get(0)));
        audit.record(AuditEvent.of("OPEN_CASHIER", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(null, v).reason(why));
        return s;
    }

    /** Hitung kas di tengah shift (blind count). Session tetap OPEN. */
    @Transactional
    public CashCountView cashCount(UUID sessionId, List<CountLine> counts, String note) {
        CurrentUser cu = requireEmployee();
        SessionView s = ownActive(cu, sessionId);
        if (!"OPEN".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_LOCKED);
        }
        validateLines(counts);
        String why = Guards.trimToNull(note);
        UUID countId = repo.insertCount(sessionId, "MID", cu.userId(), why);
        for (CountLine line : counts) {
            repo.insertCountItem(countId, line.denominationId(), line.quantity());
        }
        repo.finalizeCount(countId);
        CashCountView count = repo.counts(sessionId).stream().filter(c -> c.id().equals(countId)).findFirst()
                .orElseThrow();
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("countId", countId);
        v.put("countType", "MID");
        v.put("totalAmount", count.totalAmount());
        v.put("denominations", breakdown(count));
        audit.record(AuditEvent.of("CASH_COUNT", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(null, v).reason(why));
        return count;
    }

    @Transactional
    public SessionView lock(UUID sessionId, String reason) {
        CurrentUser cu = requireEmployee();
        SessionView s = ownActive(cu, sessionId);
        if ("ON_BREAK".equals(s.status())) {
            return s; // sudah terkunci: idempoten
        }
        if (!repo.transition(sessionId, "OPEN", "ON_BREAK", reason, null, null)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        SessionView after = repo.findById(sessionId).orElseThrow();
        audit.record(AuditEvent.of("CASHIER_LOCK", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(Map.of("status", s.status()), Map.of("status", after.status(), "lockReason", reason)));
        return after;
    }

    /** Buka kunci: database mensyaratkan token hasil login ulang setelah waktu kunci. */
    @Transactional
    public SessionView unlock(UUID sessionId) {
        CurrentUser cu = requireEmployee();
        SessionView s = ownActive(cu, sessionId);
        if (!"ON_BREAK".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_NOT_LOCKED);
        }
        Optional<AttendanceView> att = attendance.findOpenForEmployee(cu.employeeId());
        if (att.isEmpty() || !"WORKING".equals(att.get().status()) || !att.get().outletId().equals(s.outletId())) {
            throw new ApiException(ErrorCode.ATTENDANCE_REQUIRED,
                    att.isEmpty() ? "Clock in terlebih dahulu" : "Selesaikan istirahat terlebih dahulu");
        }
        if (!repo.transition(sessionId, "ON_BREAK", "OPEN", null, null, null)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        SessionView after = repo.findById(sessionId).orElseThrow();
        audit.record(AuditEvent.of("CASHIER_UNLOCK", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(Map.of("status", s.status(), "lockReason", s.lockReason()), Map.of("status", after.status())));
        return after;
    }

    /** Batal buka kasir (mis. salah hitung modal / salah terminal) selama belum ada aktivitas kas. */
    @Transactional
    public SessionView cancel(UUID sessionId, String reason) {
        CurrentUser cu = requireEmployee();
        SessionView s = ownActive(cu, sessionId);
        access.requireOutlet("cashier.open", s.outletId());
        String why = reason.trim();
        if (!repo.transition(sessionId, s.status(), "CANCELLED", null, cu.userId(), why)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        SessionView after = repo.findById(sessionId).orElseThrow();
        audit.record(AuditEvent.of("CANCEL_CASHIER", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(summary(s), summary(after)).reason(why));
        return after;
    }

    @Transactional(readOnly = true)
    public SessionView get(UUID sessionId) {
        access.currentUser();
        return repo.findById(sessionId).orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_NOT_FOUND));
    }

    @Transactional(readOnly = true)
    public List<SessionView> outletSessions(UUID outletId, LocalDate businessDate, String status) {
        access.requireOutlet("cashier.view", outletId);
        if (status != null && !STATUSES.contains(status)) {
            throw ApiException.validation("Status tidak dikenal");
        }
        LocalDate date = businessDate != null ? businessDate : repo.businessDate(outletId);
        return repo.findForOutlet(outletId, date, status);
    }

    // ------------------------------------------------------------------ Phase 6: manajemen kas

    /** Mutasi kas: pemilik melihat mutasi manual (blind count), pemegang cashier.view melihat semua. */
    @Transactional(readOnly = true)
    public List<MovementView> movements(UUID sessionId) {
        CurrentUser cu = access.currentUser();
        SessionView s = repo.findById(sessionId).orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_NOT_FOUND));
        boolean supervisor = access.has("cashier.view", s.outletId());
        if (!supervisor && !s.employeeId().equals(cu.employeeId())) {
            throw ApiException.forbidden();
        }
        return repo.movements(sessionId, !supervisor);
    }

    /** §25 kas masuk / kas keluar / petty cash oleh pemegang laci. */
    @Transactional
    public MovementView cashMovement(UUID sessionId, String type, BigDecimal amount, String reason, UUID approvalId) {
        CurrentUser cu = requireEmployee();
        SessionView s = ownActive(cu, sessionId);
        if (!"OPEN".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_LOCKED);
        }
        boolean in = "CASH_IN".equals(type);
        access.requireOutlet(in ? "cash.cash_in" : "cash.cash_out", s.outletId());
        requireWholeRupiah(amount);
        String why = reason.trim();
        if (why.length() < 3) {
            throw new ApiException(ErrorCode.CASH_MOVEMENT_REASON_REQUIRED);
        }
        UUID usedApproval = null;
        if (!in) {
            if (repo.balance(sessionId).compareTo(amount) < 0) {
                throw new ApiException(ErrorCode.CASH_INSUFFICIENT);
            }
            BigDecimal threshold = repo.cashOutThreshold(s.outletId());
            if (amount.compareTo(threshold) > 0) {
                usedApproval = useCashApproval(approvalId, "CASH_OUT", sessionId, amount).id();
            }
        }
        // database memeriksa ulang: pemilik, status, saldo, ambang & approval
        UUID id = repo.insertMovement(sessionId, type, in ? amount : amount.negate(), why, usedApproval, cu.userId());
        MovementView m = repo.movement(id).orElseThrow();
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("movementId", id);
        v.put("type", type);
        v.put("amount", m.amount());
        v.put("approvedBy", m.approvedByName());
        audit.record(AuditEvent.of(type, "CASHIER_SESSION", sessionId).outlet(s.outletId()).change(null, v).reason(why));
        return m;
    }

    /** Penyesuaian kas (restricted): atasan dengan cash.cash_adjustment, bukan untuk laci sendiri. */
    @Transactional
    public MovementView adjustment(UUID sessionId, BigDecimal amount, String reason) {
        CurrentUser cu = access.currentUser();
        SessionView s = repo.findById(sessionId).orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_NOT_FOUND));
        access.requireOutlet("cash.cash_adjustment", s.outletId());
        if (s.employeeId().equals(cu.employeeId())) {
            throw new ApiException(ErrorCode.SELF_MODIFICATION_NOT_ALLOWED, "Penyesuaian laci sendiri harus oleh atasan lain");
        }
        if (!"OPEN".equals(s.status()) && !"ON_BREAK".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_CLOSED);
        }
        if (amount.signum() == 0) {
            throw ApiException.validation("Nominal penyesuaian tidak boleh nol");
        }
        requireWholeRupiah(amount.abs());
        String why = reason.trim();
        UUID id = repo.insertMovement(sessionId, "CASH_ADJUSTMENT", amount, why, null, cu.userId());
        MovementView m = repo.movement(id).orElseThrow();
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("movementId", id);
        v.put("amount", amount);
        v.put("employeeCode", s.employeeCode());
        audit.record(AuditEvent.of("CASH_ADJUSTMENT", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(null, v).reason(why));
        return m;
    }

    // ------------------------------------------------------------------ tutup kasir (§48–§51)

    /**
     * Ringkasan tutup kasir dari hitungan fisik yang dimasukkan. Tidak menulis data kas; setiap pratinjau
     * dicatat di audit (total hitungan) sehingga hitung ulang berulang demi "mencocokkan" terlihat auditor.
     */
    @Transactional
    public ClosePreview closePreview(UUID sessionId, List<CountLine> counts) {
        CurrentUser cu = access.currentUser();
        SessionView s = closable(cu, sessionId);
        validateLines(counts);
        BigDecimal counted = countTotal(counts);
        BigDecimal expected = repo.balance(sessionId);
        BigDecimal diff = counted.subtract(expected);
        CloseBlockers b = repo.closeBlockers(sessionId, s.outletId());
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("countedCash", counted);
        v.put("difference", diff);
        audit.record(AuditEvent.of("CLOSE_PREVIEW", "CASHIER_SESSION", sessionId).outlet(s.outletId()).change(null, v));
        return new ClosePreview(counted, expected, diff, b.differenceThreshold(), diff.signum() != 0,
                diff.abs().compareTo(b.differenceThreshold()) > 0, b.openOrders(), b.pendingPayments(),
                b.pendingReturns(), b.allowOpenOrders());
    }

    /** Tutup kasir: hitungan fisik per pecahan, selisih dihitung database, alasan & approval sesuai ambang. */
    @Transactional
    public SessionView close(UUID sessionId, CloseRequest req) {
        CurrentUser cu = access.currentUser();
        SessionView s = closable(cu, sessionId);
        boolean owner = s.employeeId().equals(cu.employeeId());
        validateLines(req.counts());
        if (owner) {
            repo.cancelEmptyDrafts(sessionId);   // keranjang kosong sisa layar kasir
        }
        CloseBlockers b = repo.closeBlockers(sessionId, s.outletId());
        if (b.openOrders() > 0 && !b.allowOpenOrders()) {
            throw new ApiException(ErrorCode.OPEN_ORDER_EXISTS, "Masih ada " + b.openOrders()
                    + " transaksi terbuka/ditahan. Selesaikan, void, atau batalkan sebelum tutup kasir");
        }
        if (b.pendingPayments() > 0) {
            throw new ApiException(ErrorCode.PAYMENT_PENDING);
        }
        if (b.pendingReturns() > 0) {
            throw new ApiException(ErrorCode.RETURN_PENDING);
        }
        BigDecimal counted = countTotal(req.counts());
        BigDecimal diff = counted.subtract(repo.balance(sessionId));
        String reason = diff.signum() == 0 ? null : req.differenceReason();
        String diffNote = diff.signum() == 0 ? null : Guards.trimToNull(req.differenceNote());
        if (diff.signum() != 0) {
            if (reason == null || ("OTHER".equals(reason) && (diffNote == null || diffNote.length() < 5))) {
                throw new ApiException(ErrorCode.CASH_DIFFERENCE_REASON_REQUIRED);
            }
        }
        UUID usedApproval = null;
        if (diff.abs().compareTo(b.differenceThreshold()) > 0) {
            if (req.approvalId() == null) {
                throw new ApiException(ErrorCode.CASH_DIFFERENCE_REQUIRES_APPROVAL);
            }
            usedApproval = useCashApproval(req.approvalId(), "CASH_DIFFERENCE", sessionId, diff.abs()).id();
        }
        String note = Guards.trimToNull(req.note());
        UUID countId = repo.insertCount(sessionId, "CLOSING", cu.userId(), note);
        for (CountLine line : req.counts()) {
            repo.insertCountItem(countId, line.denominationId(), line.quantity());
        }
        repo.finalizeCount(countId);
        // database menghitung ulang expected & selisih dan menegakkan semua aturan penutupan
        repo.close(sessionId, s.status(), cu.userId(), countId, reason, diffNote, usedApproval);

        SessionView after = repo.findById(sessionId).orElseThrow();
        Map<String, Object> v = summary(after);
        v.put("closingCash", after.closingCash());
        v.put("expectedCash", after.expectedCash());
        v.put("difference", after.difference());
        v.put("differenceReason", after.differenceReason());
        v.put("differenceApprovedBy", after.differenceApprovedByName());
        v.put("closedByOwner", owner);
        v.put("denominations", breakdown(after.counts().stream().filter(c -> c.id().equals(countId)).findFirst()
                .orElse(null)));
        audit.record(AuditEvent.of("CLOSE_CASHIER", "CASHIER_SESSION", sessionId).outlet(s.outletId())
                .change(summary(s), v).reason(diffNote != null ? diffNote : note));
        return after;
    }

    /**
     * Approval kas (dipanggil setelah password approver diverifikasi di luar transaksi). Database
     * memvalidasi izin cash.approve_difference & tingkat approver di outlet session.
     */
    @Transactional
    public CashApprovalView createApproval(UUID authUserId, CashApprovalRequest req) {
        CurrentUser cu = access.currentUser();
        SessionView s = repo.findById(req.sessionId())
                .orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_NOT_FOUND));
        boolean owner = s.employeeId().equals(cu.employeeId());
        if (!owner && !("CASH_DIFFERENCE".equals(req.action()) && canCloseOthers(s.outletId()))) {
            throw ApiException.forbidden();
        }
        if ("CLOSED".equals(s.status()) || "CANCELLED".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_CLOSED);
        }
        requireWholeRupiah(req.amount());
        CashierRepository.Approver approver = repo.approver(authUserId)
                .orElseThrow(() -> new ApiException(ErrorCode.APPROVER_INVALID));
        if (approver.userId().equals(cu.userId())) {
            throw new ApiException(ErrorCode.APPROVER_INVALID, "Persetujuan harus dari user lain (bukan Anda sendiri)");
        }
        UUID id = repo.insertApproval(s.id(), req.action(), req.amount(), approver.userId());
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("approvalId", id);
        v.put("action", req.action());
        v.put("approver", approver.username());
        v.put("amount", req.amount());
        audit.record(AuditEvent.of("APPROVAL", "CASHIER_SESSION", s.id()).outlet(s.outletId()).change(null, v));
        return new CashApprovalView(id, req.action(), approver.displayName(), req.amount(),
                repo.approvalExpiry(id).orElse(null));
    }

    private UsedCashApproval useCashApproval(UUID approvalId, String action, UUID sessionId, BigDecimal amount) {
        if (approvalId == null) {
            throw new ApiException("CASH_DIFFERENCE".equals(action) ? ErrorCode.CASH_DIFFERENCE_REQUIRES_APPROVAL
                    : ErrorCode.APPROVAL_REQUIRED);
        }
        UsedCashApproval a = repo.useApproval(approvalId).orElseThrow(
                () -> new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan tidak valid atau sudah dipakai"));
        if (!action.equals(a.action()) || !sessionId.equals(a.cashierSessionId())) {
            throw new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan untuk tindakan lain");
        }
        if (a.price() == null || a.price().compareTo(amount) != 0) {
            throw new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan untuk nominal lain; minta persetujuan lagi");
        }
        return a;
    }

    /** Session yang boleh ditutup pemanggil: miliknya (cashier.close) atau kasir lain (cashier.close + cash.approve_difference). */
    private SessionView closable(CurrentUser cu, UUID sessionId) {
        SessionView s = repo.findById(sessionId).orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_NOT_FOUND));
        boolean owner = cu.employeeId() != null && s.employeeId().equals(cu.employeeId());
        if (owner) {
            access.requireOutlet("cashier.close", s.outletId());
        } else if (!canCloseOthers(s.outletId())) {
            throw ApiException.forbidden();
        }
        if ("CLOSED".equals(s.status()) || "CANCELLED".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_CLOSED);
        }
        if (owner && "ON_BREAK".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_LOCKED, "Buka kunci terminal sebelum tutup kasir");
        }
        return s;
    }

    private boolean canCloseOthers(UUID outletId) {
        return access.has("cashier.close", outletId) && access.has("cash.approve_difference", outletId);
    }

    private BigDecimal countTotal(List<CountLine> counts) {
        List<UUID> ids = counts.stream().map(CountLine::denominationId).toList();
        if (repo.validDenominations(ids) != ids.size()) {
            throw new ApiException(ErrorCode.DENOMINATION_INVALID);
        }
        return repo.countTotal(ids, counts.stream().map(CountLine::quantity).toList());
    }

    private static void requireWholeRupiah(BigDecimal amount) {
        if (amount.signum() <= 0 || amount.stripTrailingZeros().scale() > 0) {
            throw ApiException.validation("Nominal harus rupiah bulat lebih dari 0");
        }
    }

    // ------------------------------------------------------------------ helpers

    private CurrentUser requireEmployee() {
        CurrentUser cu = access.currentUser();
        if (cu.employeeId() == null) {
            throw new ApiException(ErrorCode.EMPLOYEE_NOT_LINKED);
        }
        return cu;
    }

    private SessionView ownActive(CurrentUser cu, UUID sessionId) {
        SessionView s = repo.findById(sessionId)
                .orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_NOT_FOUND));
        if (!s.employeeId().equals(cu.employeeId())) {
            throw ApiException.forbidden();
        }
        if ("CLOSED".equals(s.status()) || "CANCELLED".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_CLOSED);
        }
        return s;
    }

    private static void validateLines(List<CountLine> counts) {
        Set<UUID> seen = new HashSet<>();
        for (CountLine line : counts) {
            if (!seen.add(line.denominationId())) {
                throw ApiException.validation("Denominasi yang sama dikirim lebih dari sekali");
            }
        }
    }

    private static List<Map<String, Object>> breakdown(CashCountView count) {
        if (count == null) {
            return List.of();
        }
        return count.items().stream().filter(i -> i.quantity() > 0).map(i -> {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("value", i.value());
            m.put("kind", i.kind());
            m.put("quantity", i.quantity());
            return m;
        }).toList();
    }

    private static Map<String, Object> summary(SessionView s) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("status", s.status());
        m.put("employeeCode", s.employeeCode());
        m.put("terminalCode", s.terminalCode());
        m.put("businessDate", s.businessDate() == null ? null : s.businessDate().toString());
        return m;
    }
}
