package com.pirantisolution.pos.cashier;

import com.pirantisolution.pos.cashier.CashierDtos.CashCountView;
import com.pirantisolution.pos.cashier.CashierDtos.CountItemView;
import com.pirantisolution.pos.cashier.CashierDtos.DenominationView;
import com.pirantisolution.pos.cashier.CashierDtos.MovementView;
import com.pirantisolution.pos.cashier.CashierDtos.SessionView;
import com.pirantisolution.pos.cashier.CashierDtos.TerminalInfo;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
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
                   CASE WHEN s.status = 'CLOSED' THEN s.expected_cash
                        WHEN pos.has_permission('cashier.view', s.outlet_id)
                        THEN pos.session_expected_cash(s.id) END AS expected_cash,
                   s.status, s.locked_at, s.lock_reason, s.cancel_reason, s.version,
                   round((pos.get_setting('terminal_idle_lock_minutes', s.outlet_id))::numeric)::integer AS idle_lock_minutes,
                   s.closing_cash, s.difference, s.difference_reason, s.difference_note,
                   pos.approver_name(s.closed_by) AS closed_by_name,
                   pos.approver_name(s.difference_approved_by) AS difference_approved_by_name
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
                rs.getBigDecimal("closing_cash"),
                rs.getBigDecimal("difference"),
                rs.getString("difference_reason"),
                rs.getString("difference_note"),
                rs.getString("closed_by_name"),
                rs.getString("difference_approved_by_name"),
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

    // ------------------------------------------------------------------ Phase 6: kas & tutup kasir

    /**
     * Mutasi kas session. {@code ownerView}: kasir hanya melihat mutasi manual (modal, kas masuk/keluar,
     * penyesuaian) — total penjualan tunai tidak dijumlahkan untuknya (blind count, B21).
     */
    public List<MovementView> movements(UUID sessionId, boolean ownerView) {
        return jdbc.sql("""
                SELECT m.id, m.movement_type, m.amount, m.reason, m.reference_type, m.created_at,
                       pos.approver_name(m.created_by) AS created_by_name,
                       pos.approver_name(m.approved_by) AS approved_by_name
                FROM pos.cash_movements m
                WHERE m.cashier_session_id = :s
                  AND (NOT :owner OR m.movement_type IN ('OPENING_CASH', 'CASH_IN', 'CASH_OUT', 'PETTY_CASH',
                                                        'CASH_ADJUSTMENT', 'CLOSING_CASH'))
                ORDER BY m.created_at, m.id
                LIMIT 2000
                """)
                .param("s", sessionId).param("owner", ownerView)
                .query(MovementView.class).list();
    }

    /** Catat kas masuk/keluar/penyesuaian; outlet, business date & approver diisi trigger dari session. */
    public UUID insertMovement(UUID sessionId, String type, BigDecimal signedAmount, String reason, UUID approvalId,
            UUID actor) {
        return jdbc.sql("""
                INSERT INTO pos.cash_movements (organization_id, outlet_id, cashier_session_id, business_date,
                                                movement_type, amount, reason, approval_id, created_by)
                SELECT s.organization_id, s.outlet_id, s.id, s.business_date, :type, :amt, :reason,
                       CAST(:approval AS uuid), :actor
                FROM pos.cashier_sessions s WHERE s.id = :s
                RETURNING id
                """)
                .param("type", type).param("amt", signedAmount).param("reason", reason).param("approval", approvalId)
                .param("actor", actor).param("s", sessionId)
                .query(UUID.class).single();
    }

    public Optional<MovementView> movement(UUID id) {
        return jdbc.sql("""
                SELECT m.id, m.movement_type, m.amount, m.reason, m.reference_type, m.created_at,
                       pos.approver_name(m.created_by) AS created_by_name,
                       pos.approver_name(m.approved_by) AS approved_by_name
                FROM pos.cash_movements m WHERE m.id = :id
                """)
                .param("id", id).query(MovementView.class).optional();
    }

    /**
     * Isi laci menurut catatan (tanpa RLS kasir yang membatasi: fungsi SECURITY INVOKER membaca movement
     * session yang memang terlihat oleh pemanggil — pemilik atau pemegang cashier.view).
     */
    public BigDecimal balance(UUID sessionId) {
        return jdbc.sql("SELECT pos.session_expected_cash(:s)").param("s", sessionId).query(BigDecimal.class).single();
    }

    /** Total uang dari daftar denominasi master (tanpa menulis apa pun). */
    public BigDecimal countTotal(List<UUID> denominationIds, List<Integer> quantities) {
        if (denominationIds.isEmpty()) {
            return BigDecimal.ZERO;
        }
        return jdbc.sql("""
                SELECT coalesce(sum(d.value * q.qty), 0)
                FROM unnest(CAST(:ids AS uuid[]), CAST(:qty AS integer[])) AS q(id, qty)
                JOIN pos.cash_denominations d ON d.id = q.id AND d.active AND d.organization_id = pos.current_org_id()
                """)
                .param("ids", pgArray(denominationIds))
                .param("qty", pgArray(quantities))
                .query(BigDecimal.class).single();
    }

    public long validDenominations(List<UUID> denominationIds) {
        if (denominationIds.isEmpty()) {
            return 0;
        }
        return jdbc.sql("""
                SELECT count(*) FROM pos.cash_denominations
                WHERE id = ANY(CAST(:ids AS uuid[])) AND active AND organization_id = pos.current_org_id()
                """)
                .param("ids", pgArray(denominationIds)).query(Long.class).single();
    }

    /** Literal array PostgreSQL ("{a,b}") untuk parameter teks yang di-CAST di SQL (nilai UUID/angka saja). */
    private static String pgArray(List<?> values) {
        return values.stream().map(String::valueOf).collect(java.util.stream.Collectors.joining(",", "{", "}"));
    }

    public record CloseBlockers(int openOrders, int pendingPayments, boolean allowOpenOrders,
            BigDecimal differenceThreshold) {
    }

    public CloseBlockers closeBlockers(UUID sessionId, UUID outletId) {
        return jdbc.sql("""
                SELECT pos.session_open_orders(:s) AS open_orders,
                       pos.session_pending_payments(:s) AS pending_payments,
                       coalesce((pos.get_setting('allow_close_with_open_orders', :o))::boolean, false) AS allow_open_orders,
                       coalesce((pos.get_setting('cash_difference_approval_threshold', :o))::numeric, 0) AS difference_threshold
                """)
                .param("s", sessionId).param("o", outletId)
                .query(CloseBlockers.class).single();
    }

    public BigDecimal cashOutThreshold(UUID outletId) {
        return jdbc.sql("SELECT coalesce((pos.get_setting('cash_out_approval_threshold', :o))::numeric, 0)")
                .param("o", outletId).query(BigDecimal.class).single();
    }

    /** Batalkan transaksi DRAFT kosong milik session (sisa layar kasir) sebelum tutup. */
    public int cancelEmptyDrafts(UUID sessionId) {
        return jdbc.sql("""
                UPDATE pos.sales sa SET status = 'CANCELLED'
                WHERE sa.cashier_session_id = :s AND sa.status = 'DRAFT'
                  AND NOT EXISTS (SELECT 1 FROM pos.sale_items i WHERE i.sale_id = sa.id)
                """)
                .param("s", sessionId).update();
    }

    public void close(UUID sessionId, String fromStatus, UUID actor, UUID countId, String reason, String note,
            UUID approvalId) {
        int n = jdbc.sql("""
                UPDATE pos.cashier_sessions
                SET status = 'CLOSED', closed_by = :actor, closing_count_id = :count,
                    difference_reason = CAST(:reason AS text), difference_note = CAST(:note AS text),
                    difference_approval_id = CAST(:approval AS uuid)
                WHERE id = :id AND status = :from
                """)
                .param("actor", actor).param("count", countId).param("reason", reason).param("note", note)
                .param("approval", approvalId).param("id", sessionId).param("from", fromStatus)
                .update();
        if (n != 1) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
    }

    // ------------------------------------------------------------------ approval kas

    public record Approver(UUID userId, String username, String displayName) {
    }

    public Optional<Approver> approver(UUID authUserId) {
        return jdbc.sql("SELECT user_id, username, display_name FROM pos.approver_lookup(:a)")
                .param("a", authUserId).query(Approver.class).optional();
    }

    public UUID insertApproval(UUID sessionId, String action, BigDecimal amount, UUID approvedBy) {
        // organisasi, outlet, peminta, kedaluwarsa & izin approver: trigger database
        return jdbc.sql("""
                INSERT INTO pos.approvals (organization_id, outlet_id, cashier_session_id, action, price,
                                           requested_by, approved_by, expires_at)
                SELECT s.organization_id, s.outlet_id, s.id, :action, :amt, pos.current_app_user_id(), :by, now()
                FROM pos.cashier_sessions s WHERE s.id = :s
                RETURNING id
                """)
                .param("action", action).param("amt", amount).param("by", approvedBy).param("s", sessionId)
                .query(UUID.class).single();
    }

    public Optional<OffsetDateTime> approvalExpiry(UUID approvalId) {
        return jdbc.sql("SELECT expires_at FROM pos.approvals WHERE id = :id")
                .param("id", approvalId).query(OffsetDateTime.class).optional();
    }

    public record UsedCashApproval(UUID id, String action, UUID cashierSessionId, BigDecimal price, UUID approvedBy) {
    }

    /** Pakai approval kas sekali. Kosong bila tidak ada, sudah dipakai, kedaluwarsa, atau bukan milik peminta. */
    public Optional<UsedCashApproval> useApproval(UUID approvalId) {
        return jdbc.sql("""
                UPDATE pos.approvals SET used_at = now()
                WHERE id = :id AND requested_by = pos.current_app_user_id() AND used_at IS NULL
                RETURNING id, action, cashier_session_id, price, approved_by
                """)
                .param("id", approvalId).query(UsedCashApproval.class).optional();
    }

    public LocalDate businessDate(UUID outletId) {
        return jdbc.sql("SELECT pos.business_date(now(), :o)").param("o", outletId).query(LocalDate.class).single();
    }
}
