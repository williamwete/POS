package com.pirantisolution.pos.report;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** Laporan shift. Semua angka dihitung database ({@code pos.compute_shift_report}); repository hanya membaca. */
@Repository
public class ReportRepository {

    private final JdbcClient jdbc;

    public ReportRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public record SessionRef(UUID id, UUID outletId, UUID employeeId, String status) {
    }

    public Optional<SessionRef> session(UUID sessionId) {
        return jdbc.sql("SELECT id, outlet_id, employee_id, status FROM pos.cashier_sessions WHERE id = :s")
                .param("s", sessionId).query(SessionRef.class).optional();
    }

    /** X report (JSON) — database memeriksa izin cashier.view dan status session. */
    public String xReport(UUID sessionId) {
        return jdbc.sql("SELECT CAST(pos.x_report(:s) AS text)").param("s", sessionId).query(String.class).single();
    }

    public record Cashup(UUID id, int zNumber, String report, OffsetDateTime createdAt) {
    }

    public Optional<Cashup> cashup(UUID sessionId) {
        return jdbc.sql("""
                SELECT id, z_number, CAST(report AS text) AS report, created_at
                FROM pos.cashups WHERE cashier_session_id = :s
                """)
                .param("s", sessionId).query(Cashup.class).optional();
    }

    public record TransactionRow(UUID id, String receiptNo, String status, OffsetDateTime time, BigDecimal itemCount,
            BigDecimal grandTotal, String paymentMethods, String voidReason) {
    }

    /** §54 detail transaksi satu session (tanpa DRAFT/batal kosong). */
    public List<TransactionRow> transactions(UUID sessionId) {
        return jdbc.sql("""
                SELECT s.id, s.receipt_no, s.status,
                       coalesce(s.paid_at, s.voided_at, s.checked_out_at, s.created_at) AS time,
                       s.item_count, s.grand_total,
                       (SELECT string_agg(DISTINCT m.name, ', ')
                        FROM pos.payments p JOIN pos.payment_methods m ON m.id = p.payment_method_id
                        WHERE p.sale_id = s.id AND p.status = 'PAID') AS payment_methods,
                       s.void_reason
                FROM pos.sales s
                WHERE s.cashier_session_id = :s AND s.status NOT IN ('DRAFT', 'CANCELLED')
                ORDER BY coalesce(s.paid_at, s.voided_at, s.checked_out_at, s.created_at), s.id
                LIMIT 5000
                """)
                .param("s", sessionId).query(TransactionRow.class).list();
    }
}
