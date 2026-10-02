package com.pirantisolution.pos.cashier;

import com.pirantisolution.pos.attendance.AttendanceDtos.AttendanceView;
import com.pirantisolution.pos.attendance.AttendanceRepository;
import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.cashier.CashierDtos.CashCountView;
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
