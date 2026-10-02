package com.pirantisolution.pos.attendance;

import com.pirantisolution.pos.attendance.AttendanceDtos.AttendanceView;
import com.pirantisolution.pos.attendance.AttendanceDtos.BreakView;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Akses data attendance di bawah RLS. Waktu (clock in/out, break) selalu diisi database (trigger),
 * sehingga repository tidak pernah mengirim timestamp dari aplikasi.
 */
@Repository
public class AttendanceRepository {

    private static final String SELECT = """
            SELECT a.id, a.employee_id, e.employee_code, e.full_name AS employee_name, a.outlet_id,
                   o.code AS outlet_code, a.business_date, a.clock_in, a.clock_out, a.status, a.device_id,
                   a.forced_reason, u.username AS clock_out_by_username, a.version
            FROM pos.attendance a
            JOIN pos.employees e ON e.id = a.employee_id
            JOIN pos.outlets o ON o.id = a.outlet_id
            LEFT JOIN pos.users u ON u.id = a.clock_out_by
            """;

    private final JdbcClient jdbc;

    public AttendanceRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    private static AttendanceView map(ResultSet rs, int n) throws SQLException {
        return new AttendanceView(
                rs.getObject("id", UUID.class),
                rs.getObject("employee_id", UUID.class),
                rs.getString("employee_code"),
                rs.getString("employee_name"),
                rs.getObject("outlet_id", UUID.class),
                rs.getString("outlet_code"),
                rs.getObject("business_date", LocalDate.class),
                rs.getObject("clock_in", OffsetDateTime.class),
                rs.getObject("clock_out", OffsetDateTime.class),
                rs.getString("status"),
                rs.getString("device_id"),
                rs.getString("forced_reason"),
                rs.getString("clock_out_by_username"),
                0L,
                rs.getInt("version"),
                List.of());
    }

    public Optional<AttendanceView> findOpenForEmployee(UUID employeeId) {
        return jdbc.sql(SELECT + " WHERE a.employee_id = :e AND a.status IN ('WORKING', 'ON_BREAK')")
                .param("e", employeeId)
                .query(AttendanceRepository::map).optional()
                .map(a -> a.withBreaks(breaks(a.id())));
    }

    public Optional<AttendanceView> findById(UUID id) {
        return jdbc.sql(SELECT + " WHERE a.id = :id")
                .param("id", id)
                .query(AttendanceRepository::map).optional()
                .map(a -> a.withBreaks(breaks(a.id())));
    }

    /** Riwayat milik karyawan tertentu (RLS tetap membatasi). */
    public List<AttendanceView> findForEmployee(UUID employeeId, LocalDate from, LocalDate to, int limit) {
        return jdbc.sql(SELECT + """
                WHERE a.employee_id = :e AND a.business_date BETWEEN :from AND :to
                ORDER BY a.clock_in DESC LIMIT :limit
                """)
                .param("e", employeeId).param("from", from).param("to", to).param("limit", limit)
                .query(AttendanceRepository::map).list()
                .stream().map(a -> a.withBreaks(breaks(a.id()))).toList();
    }

    public List<AttendanceView> findForOutlet(UUID outletId, LocalDate businessDate, String status) {
        return jdbc.sql(SELECT + """
                WHERE a.outlet_id = :o AND a.business_date = :d
                  AND (CAST(:status AS text) IS NULL OR a.status = CAST(:status AS text))
                ORDER BY a.clock_in
                """)
                .param("o", outletId).param("d", businessDate).param("status", status)
                .query(AttendanceRepository::map).list()
                .stream().map(a -> a.withBreaks(breaks(a.id()))).toList();
    }

    public List<BreakView> breaks(UUID attendanceId) {
        return jdbc.sql("""
                SELECT id, break_start, break_end, duration_seconds, reason
                FROM pos.attendance_breaks WHERE attendance_id = :a ORDER BY break_start
                """)
                .param("a", attendanceId).query(BreakView.class).list();
    }

    public UUID insert(UUID employeeId, UUID outletId, UUID actorUserId, String deviceId) {
        return jdbc.sql("""
                INSERT INTO pos.attendance (organization_id, employee_id, outlet_id, clock_in_by, device_id)
                VALUES (pos.current_org_id(), :e, :o, :actor, :device)
                RETURNING id
                """)
                .param("e", employeeId).param("o", outletId).param("actor", actorUserId).param("device", deviceId)
                .query(UUID.class).single();
    }

    /** Ubah status hanya jika status saat ini sesuai harapan (aman terhadap request ganda). */
    public boolean transition(UUID id, String fromStatus, String toStatus, UUID clockOutBy, String forcedReason) {
        return jdbc.sql("""
                UPDATE pos.attendance
                SET status = :to, clock_out_by = CAST(:by AS uuid), forced_reason = CAST(:reason AS text)
                WHERE id = :id AND status = :from
                RETURNING id
                """)
                .param("to", toStatus).param("by", clockOutBy).param("reason", forcedReason)
                .param("id", id).param("from", fromStatus)
                .query(UUID.class).optional().isPresent();
    }

    public UUID insertBreak(UUID attendanceId, String reason) {
        return jdbc.sql("""
                INSERT INTO pos.attendance_breaks (attendance_id, reason) VALUES (:a, :reason) RETURNING id
                """)
                .param("a", attendanceId).param("reason", reason)
                .query(UUID.class).single();
    }

    /** Menutup break yang terbuka; mengembalikan durasi detik, kosong jika tidak ada break terbuka. */
    public Optional<Integer> endOpenBreak(UUID attendanceId, UUID endedBy) {
        return jdbc.sql("""
                UPDATE pos.attendance_breaks SET break_end = now(), ended_by = :by
                WHERE attendance_id = :a AND break_end IS NULL
                RETURNING duration_seconds
                """)
                .param("by", endedBy).param("a", attendanceId)
                .query(Integer.class).optional();
    }

    public boolean employeeActive(UUID employeeId) {
        return jdbc.sql("SELECT active FROM pos.employees WHERE id = :e")
                .param("e", employeeId).query(Boolean.class).optional().orElse(false);
    }
}
