package com.pirantisolution.pos.attendance;

import com.pirantisolution.pos.attendance.AttendanceDtos.AttendanceView;
import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.cashier.CashierRepository;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.common.web.RequestContext;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Kehadiran karyawan (§11, §12, §55).
 *
 * <p>Alur: clock in → (break → akhiri break)* → clock out. Attendance terpisah dari cashier
 * session; aturan "tidak boleh clock out selama cashier session aktif" ditegakkan trigger database
 * attendance (V010), sehingga berlaku untuk semua jalur. Mulai istirahat dan force clock out
 * mengunci session kasir yang terbuka (juga oleh trigger); service mencatatnya di audit.
 */
@Service
public class AttendanceService {

    private final AttendanceRepository repo;
    private final AccessService access;
    private final AuditService audit;
    private final JdbcClient jdbc;
    private final CashierRepository cashier;

    public AttendanceService(AttendanceRepository repo, AccessService access, AuditService audit, JdbcClient jdbc,
            CashierRepository cashier) {
        this.repo = repo;
        this.access = access;
        this.audit = audit;
        this.jdbc = jdbc;
        this.cashier = cashier;
    }

    @Transactional(readOnly = true)
    public Optional<AttendanceView> current() {
        CurrentUser cu = access.currentUser();
        if (cu.employeeId() == null) {
            return Optional.empty();
        }
        return repo.findOpenForEmployee(cu.employeeId());
    }

    @Transactional
    public AttendanceView clockIn(UUID outletId) {
        CurrentUser cu = requireEmployee();
        access.requireOutlet("attendance.clock_in", outletId);
        if (!repo.employeeActive(cu.employeeId())) {
            throw new ApiException(ErrorCode.EMPLOYEE_INACTIVE);
        }
        if (repo.findOpenForEmployee(cu.employeeId()).isPresent()) {
            throw new ApiException(ErrorCode.ATTENDANCE_ALREADY_OPEN);
        }
        // unique index tetap menjadi penjaga terakhir untuk request paralel
        UUID id = repo.insert(cu.employeeId(), outletId, cu.userId(), RequestContext.deviceId());
        AttendanceView a = repo.findById(id).orElseThrow();
        audit.record(AuditEvent.of("CLOCK_IN", "ATTENDANCE", id).outlet(outletId)
                .change(null, summary(a)));
        return a;
    }

    @Transactional
    public AttendanceView startBreak(String reason) {
        CurrentUser cu = requireEmployee();
        AttendanceView a = openAttendance(cu);
        if ("ON_BREAK".equals(a.status())) {
            throw new ApiException(ErrorCode.ALREADY_ON_BREAK);
        }
        Boolean enabled = jdbc.sql("SELECT (pos.get_setting('break_enabled', :o))::boolean")
                .param("o", a.outletId()).query(Boolean.class).single();
        if (!Boolean.TRUE.equals(enabled)) {
            throw new ApiException(ErrorCode.BREAK_DISABLED);
        }
        UUID breakId = repo.insertBreak(a.id(), Guards.trimToNull(reason));
        if (!repo.transition(a.id(), "WORKING", "ON_BREAK", null, null)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        AttendanceView after = repo.findById(a.id()).orElseThrow();
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("breakId", breakId);
        v.put("reason", Guards.trimToNull(reason));
        audit.record(AuditEvent.of("BREAK_START", "ATTENDANCE", a.id()).outlet(a.outletId()).change(null, v));
        auditSessionLock(cu.employeeId(), "BREAK");
        return after;
    }

    @Transactional
    public AttendanceView endBreak() {
        CurrentUser cu = requireEmployee();
        AttendanceView a = openAttendance(cu);
        if (!"ON_BREAK".equals(a.status())) {
            throw new ApiException(ErrorCode.NOT_ON_BREAK);
        }
        Integer seconds = repo.endOpenBreak(a.id(), cu.userId())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_ON_BREAK));
        if (!repo.transition(a.id(), "ON_BREAK", "WORKING", null, null)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        AttendanceView after = repo.findById(a.id()).orElseThrow();
        audit.record(AuditEvent.of("BREAK_END", "ATTENDANCE", a.id()).outlet(a.outletId())
                .change(null, Map.of("durationSeconds", seconds)));
        return after;
    }

    @Transactional
    public AttendanceView clockOut() {
        CurrentUser cu = requireEmployee();
        AttendanceView a = openAttendance(cu);
        if ("ON_BREAK".equals(a.status())) {
            throw new ApiException(ErrorCode.BREAK_IN_PROGRESS);
        }
        access.requireOutlet("attendance.clock_out", a.outletId());
        if (cashier.findActiveForEmployee(cu.employeeId()).isPresent()) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_OPEN);
        }
        if (!repo.transition(a.id(), "WORKING", "COMPLETED", cu.userId(), null)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        AttendanceView after = repo.findById(a.id()).orElseThrow();
        audit.record(AuditEvent.of("CLOCK_OUT", "ATTENDANCE", a.id()).outlet(a.outletId())
                .change(summary(a), summary(after)));
        return after;
    }

    /** Supervisor menutup kehadiran karyawan lain yang lupa clock out (§55). */
    @Transactional
    public AttendanceView forceClockOut(UUID attendanceId, String reason) {
        CurrentUser cu = access.currentUser();
        // Tanpa izin force di outlet mana pun → 403 (bukan 404 karena RLS menyembunyikan baris).
        if (access.accessibleOutletIds().stream().noneMatch(o -> access.has("attendance.force_clock_out", o))) {
            throw ApiException.forbidden();
        }
        AttendanceView a = repo.findById(attendanceId).orElseThrow(() -> ApiException.notFound("Kehadiran"));
        access.requireOutlet("attendance.force_clock_out", a.outletId());
        if (a.employeeId().equals(cu.employeeId())) {
            throw new ApiException(ErrorCode.SELF_MODIFICATION_NOT_ALLOWED,
                    "Clock out diri sendiri dilakukan dengan tombol clock out biasa");
        }
        if (!"WORKING".equals(a.status()) && !"ON_BREAK".equals(a.status())) {
            throw new ApiException(ErrorCode.ATTENDANCE_CLOSED);
        }
        String why = reason.trim();
        Optional<Integer> closedBreak = repo.endOpenBreak(a.id(), cu.userId());
        if (!repo.transition(a.id(), a.status(), "FORCED_CLOSED", cu.userId(), why)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        AttendanceView after = repo.findById(a.id()).orElseThrow();
        Map<String, Object> v = summary(after);
        closedBreak.ifPresent(s -> v.put("closedBreakSeconds", s));
        audit.record(AuditEvent.of("FORCE_CLOCK_OUT", "ATTENDANCE", a.id()).outlet(a.outletId())
                .change(summary(a), v).reason(why));
        auditSessionLock(a.employeeId(), "FORCED_CLOCK_OUT");
        return after;
    }

    @Transactional(readOnly = true)
    public List<AttendanceView> myHistory(LocalDate from, LocalDate to) {
        CurrentUser cu = requireEmployee();
        LocalDate end = to != null ? to : LocalDate.now().plusDays(1);
        LocalDate start = from != null ? from : end.minusDays(31);
        if (start.isAfter(end) || start.plusDays(366).isBefore(end)) {
            throw ApiException.validation("Rentang tanggal maksimal 1 tahun");
        }
        return repo.findForEmployee(cu.employeeId(), start, end, 400);
    }

    @Transactional(readOnly = true)
    public List<AttendanceView> outletAttendance(UUID outletId, LocalDate businessDate, String status) {
        access.requireOutlet("attendance.view", outletId);
        if (status != null && !List.of("WORKING", "ON_BREAK", "COMPLETED", "FORCED_CLOSED").contains(status)) {
            throw ApiException.validation("Status tidak dikenal");
        }
        LocalDate date = businessDate != null ? businessDate
                : jdbc.sql("SELECT pos.business_date(now(), :o)").param("o", outletId).query(LocalDate.class).single();
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

    /** Catat penguncian session kasir yang dilakukan trigger attendance dalam transaksi ini. */
    private void auditSessionLock(UUID employeeId, String reason) {
        cashier.lockedNowForEmployee(employeeId).ifPresent(s ->
                audit.record(AuditEvent.of("CASHIER_LOCK", "CASHIER_SESSION", s.id()).outlet(s.outletId())
                        .change(Map.of("status", "OPEN"), Map.of("status", s.status(), "lockReason", reason))));
    }

    private AttendanceView openAttendance(CurrentUser cu) {
        return repo.findOpenForEmployee(cu.employeeId())
                .orElseThrow(() -> new ApiException(ErrorCode.NO_ACTIVE_ATTENDANCE));
    }

    private static Map<String, Object> summary(AttendanceView a) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("status", a.status());
        m.put("employeeCode", a.employeeCode());
        m.put("outletCode", a.outletCode());
        m.put("businessDate", a.businessDate() == null ? null : a.businessDate().toString());
        m.put("clockIn", a.clockIn() == null ? null : a.clockIn().toString());
        m.put("clockOut", a.clockOut() == null ? null : a.clockOut().toString());
        return m;
    }
}
