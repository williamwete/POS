package com.pirantisolution.pos.cashier;

import com.pirantisolution.pos.cashier.CashierDtos.CashCountView;
import com.pirantisolution.pos.cashier.CashierDtos.CountItemView;
import com.pirantisolution.pos.cashier.CashierDtos.DenominationView;
import com.pirantisolution.pos.cashier.CashierDtos.SessionView;
import com.pirantisolution.pos.cashier.CashierDtos.TerminalInfo;
import java.math.BigDecimal;
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
 * Akses data cashier session di bawah RLS. Waktu, business date, nilai denominasi, total hitungan,
 * expected dan selisih dihitung database — repository tidak pernah mengirim angka hasil hitungan client.
 *
 * <p>Expected cash dan selisih hitungan hanya ditampilkan kepada pemegang {@code cashier.view}
 * (blind count untuk kasir, ASSUMPTIONS B21).
 */
@Repository
public class CashierRepository {

    private static final String SELECT = """
            SELECT s.id, s.employee_id, e.employee_code, e.full_name AS employee_name, s.outlet_id,
                   o.code AS outlet_code, s.terminal_id, t.code AS terminal_code, t.name AS terminal_name,
                   s.business_date, s.opened_at, s.closed_at, s.opening_cash,
                   CASE WHEN pos.has_permission('cashier.view', s.outlet_id)
                        THEN pos.session_expected_cash(s.id) END AS expected_cash,
                   s.status, s.locked_at, s.lock_reason, s.cancel_reason, s.version,
                   round((pos.get_setting('terminal_idle_lock_minutes', s.outlet_id))::numeric)::integer AS idle_lock_minutes
            FROM pos.cashier_sessions s
            JOIN pos.employees e ON e.id = s.employee_id
            JOIN pos.outlets o ON o.id = s.outlet_id
            JOIN pos.terminals t ON t.id = s.terminal_id
            """;

    private static final String ACTIVE = "('OPEN', 'ON_BREAK', 'CLOSING')";

    private final JdbcClient jdbc;

    public CashierRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    private static SessionView map(ResultSet rs, int n) throws SQLException {
        return new SessionView(
                rs.getObject("id", UUID.class),
                rs.getObject("employee_id", UUID.class),
                rs.getString("employee_code"),
                rs.getString("employee_name"),
                rs.getObject("outlet_id", UUID.class),
                rs.getString("outlet_code"),
                rs.getObject("terminal_id", UUID.class),
                rs.getString("terminal_code"),
                rs.getString("terminal_name"),
                rs.getObject("business_date", LocalDate.class),
                rs.getObject("opened_at", OffsetDateTime.class),
                rs.getObject("closed_at", OffsetDateTime.class),
                rs.getBigDecimal("opening_cash"),
                rs.getBigDecimal("expected_cash"),
                rs.getString("status"),
                rs.getObject("locked_at", OffsetDateTime.class),
                rs.getString("lock_reason"),
                rs.getString("cancel_reason"),
                rs.getInt("version"),
                rs.getInt("idle_lock_minutes"),
                List.of());
    }

    public List<DenominationView> denominations() {
        return jdbc.sql("""
                SELECT id, currency, value, kind, sort_order
                FROM pos.cash_denominations
                WHERE active AND organization_id = pos.current_org_id()
                ORDER BY sort_order, value DESC
                """)
                .query(DenominationView.class).list();
    }

    public Optional<TerminalInfo> terminal(UUID terminalId) {
        return jdbc.sql("SELECT id, outlet_id, code, active FROM pos.terminals WHERE id = :id")
                .param("id", terminalId).query(TerminalInfo.class).optional();
    }

    public Optional<SessionView> findActiveForEmployee(UUID employeeId) {
        return jdbc.sql(SELECT + " WHERE s.employee_id = :e AND s.status IN " + ACTIVE)
                .param("e", employeeId)
                .query(CashierRepository::map).optional()
                .map(s -> s.withCounts(counts(s.id())));
    }

    public Optional<SessionView> findById(UUID id) {
        return jdbc.sql(SELECT + " WHERE s.id = :id")
                .param("id", id)
                .query(CashierRepository::map).optional()
                .map(s -> s.withCounts(counts(s.id())));
    }

    public List<SessionView> findForOutlet(UUID outletId, LocalDate businessDate, String status) {
        return jdbc.sql(SELECT + """
                WHERE s.outlet_id = :o
                  AND (s.business_date = :d OR (CAST(:status AS text) IS NULL AND s.status IN ('OPEN', 'ON_BREAK', 'CLOSING')))
                  AND (CAST(:status AS text) IS NULL OR s.status = CAST(:status AS text))
                ORDER BY s.opened_at
                """)
                .param("o", outletId).param("d", businessDate).param("status", status)
                .query(CashierRepository::map).list();
    }

    public List<CashCountView> counts(UUID sessionId) {
        List<CashCountView> counts = jdbc.sql("""
                SELECT c.id, c.count_type, c.total_amount,
                       CASE WHEN pos.has_permission('cashier.view', s.outlet_id) THEN c.expected_amount END
                           AS expected_amount,
                       CASE WHEN pos.has_permission('cashier.view', s.outlet_id) THEN c.difference END AS difference,
                       c.note, c.counted_at, pos.approver_name(c.counted_by) AS counted_by_username
                FROM pos.cash_counts c
                JOIN pos.cashier_sessions s ON s.id = c.cashier_session_id
                WHERE c.cashier_session_id = :s
                ORDER BY c.counted_at
                """)
                .param("s", sessionId)
                .query((rs, n) -> new CashCountView(
                        rs.getObject("id", UUID.class),
                        rs.getString("count_type"),
                        rs.getBigDecimal("total_amount"),
                        rs.getBigDecimal("expected_amount"),
                        rs.getBigDecimal("difference"),
                        rs.getString("note"),
                        rs.getObject("counted_at", OffsetDateTime.class),
                        rs.getString("counted_by_username"),
                        List.of()))
                .list();
        return counts.stream().map(c -> c.withItems(items(c.id()))).toList();
    }

    public List<CountItemView> items(UUID countId) {
        return jdbc.sql("""
                SELECT value, kind, quantity, subtotal
                FROM pos.cash_count_items WHERE cash_count_id = :c
                ORDER BY kind DESC, value DESC
                """)
                .param("c", countId).query(CountItemView.class).list();
    }

    public UUID insertSession(UUID outletId, UUID terminalId, UUID employeeId, UUID attendanceId, UUID actor,
            String deviceId) {
        return jdbc.sql("""
                INSERT INTO pos.cashier_sessions
                    (organization_id, outlet_id, terminal_id, employee_id, attendance_id, opened_by, device_id)
                VALUES (pos.current_org_id(), :o, :t, :e, :a, :actor, :device)
                RETURNING id
                """)
                .param("o", outletId).param("t", terminalId).param("e", employeeId).param("a", attendanceId)
                .param("actor", actor).param("device", deviceId)
                .query(UUID.class).single();
    }

    public UUID insertCount(UUID sessionId, String type, UUID actor, String note) {
        return jdbc.sql("""
                INSERT INTO pos.cash_counts (cashier_session_id, count_type, counted_by, note)
                VALUES (:s, :type, :actor, :note)
                RETURNING id
                """)
                .param("s", sessionId).param("type", type).param("actor", actor).param("note", note)
                .query(UUID.class).single();
    }

    public void insertCountItem(UUID countId, UUID denominationId, int quantity) {
        // value/kind diisi trigger dari master denominasi
        jdbc.sql("""
                INSERT INTO pos.cash_count_items (cash_count_id, denomination_id, value, kind, quantity)
                VALUES (:c, :d, 0, 'NOTE', :q)
                """)
                .param("c", countId).param("d", denominationId).param("q", quantity)
                .update();
    }

    /** Mengisi expected & selisih hitungan di database, mengembalikan total hitungan. */
    public BigDecimal finalizeCount(UUID countId) {
        return jdbc.sql("SELECT total_amount FROM pos.finalize_cash_count(:c)")
                .param("c", countId).query(BigDecimal.class).single();
    }

    public void setOpeningCash(UUID sessionId, BigDecimal amount) {
        jdbc.sql("UPDATE pos.cashier_sessions SET opening_cash = :amt WHERE id = :id")
                .param("amt", amount).param("id", sessionId).update();
    }

    public void insertOpeningMovement(UUID sessionId, BigDecimal amount, UUID countId, UUID actor) {
        // organisasi, outlet & business date diisi trigger dari session
        jdbc.sql("""
                INSERT INTO pos.cash_movements (organization_id, outlet_id, cashier_session_id, business_date,
                                                movement_type, amount, reference_type, reference_id, created_by)
                SELECT s.organization_id, s.outlet_id, s.id, s.business_date, 'OPENING_CASH', :amt,
                       'CASH_COUNT', :count, :actor
                FROM pos.cashier_sessions s WHERE s.id = :s
                """)
                .param("amt", amount).param("count", countId).param("actor", actor).param("s", sessionId)
                .update();
    }

    /** Ubah status hanya jika status & versi sesuai harapan (aman terhadap request ganda). */
    public boolean transition(UUID id, String fromStatus, String toStatus, String lockReason, UUID closedBy,
            String cancelReason) {
        return jdbc.sql("""
                UPDATE pos.cashier_sessions
                SET status = :to, lock_reason = CAST(:lock AS text), locked_at = NULL,
                    closed_by = CAST(:by AS uuid), cancel_reason = CAST(:reason AS text)
                WHERE id = :id AND status = :from
                RETURNING id
                """)
                .param("to", toStatus).param("lock", lockReason).param("by", closedBy).param("reason", cancelReason)
                .param("id", id).param("from", fromStatus)
                .query(UUID.class).optional().isPresent();
    }

    /** Session milik karyawan yang baru saja dikunci dalam transaksi ini (oleh trigger attendance). */
    public Optional<SessionView> lockedNowForEmployee(UUID employeeId) {
        return jdbc.sql(SELECT + " WHERE s.employee_id = :e AND s.status = 'ON_BREAK' AND s.locked_at = now()")
                .param("e", employeeId)
                .query(CashierRepository::map).optional();
    }

    public LocalDate businessDate(UUID outletId) {
        return jdbc.sql("SELECT pos.business_date(now(), :o)").param("o", outletId).query(LocalDate.class).single();
    }
}
