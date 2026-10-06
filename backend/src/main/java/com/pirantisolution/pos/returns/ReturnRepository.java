package com.pirantisolution.pos.returns;

import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.returns.ReturnDtos.RefundView;
import com.pirantisolution.pos.returns.ReturnDtos.ReturnItemView;
import com.pirantisolution.pos.returns.ReturnDtos.ReturnView;
import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Retur & refund di bawah RLS. Nomor retur, outlet/terminal/session, nilai baris, total, alokasi refund, dan
 * cash movement diisi trigger database — repository tidak pernah mengirim angka uang.
 */
@Repository
public class ReturnRepository {

    private static final String SELECT = """
            SELECT r.id, r.return_no, r.status, r.original_sale_id, s.receipt_no AS original_receipt_no, r.outlet_id,
                   t.code AS terminal_code, r.cashier_session_id, r.business_date, r.reason, r.refund_mode,
                   r.refund_reference, r.item_count, r.total_amount, r.tax_amount,
                   pos.approver_name(r.created_by) AS created_by_name, pos.approver_name(r.approved_by) AS approved_by_name,
                   r.approved_at, r.reject_reason, pos.approver_name(r.rejected_by) AS rejected_by_name, r.created_at,
                   r.version
            FROM pos.returns r
            JOIN pos.terminals t ON t.id = r.terminal_id
            LEFT JOIN pos.sales s ON s.id = r.original_sale_id
            """;

    private final JdbcClient jdbc;

    private static ReturnView map(ResultSet rs, int n) throws SQLException {
        return new ReturnView(
                rs.getObject("id", UUID.class),
                rs.getString("return_no"),
                rs.getString("status"),
                rs.getObject("original_sale_id", UUID.class),
                rs.getString("original_receipt_no"),
                rs.getObject("outlet_id", UUID.class),
                rs.getString("terminal_code"),
                rs.getObject("cashier_session_id", UUID.class),
                rs.getObject("business_date", LocalDate.class),
                rs.getString("reason"),
                rs.getString("refund_mode"),
                rs.getString("refund_reference"),
                rs.getBigDecimal("item_count"),
                rs.getBigDecimal("total_amount"),
                rs.getBigDecimal("tax_amount"),
                rs.getString("created_by_name"),
                rs.getString("approved_by_name"),
                rs.getObject("approved_at", OffsetDateTime.class),
                rs.getString("reject_reason"),
                rs.getString("rejected_by_name"),
                rs.getObject("created_at", OffsetDateTime.class),
                rs.getInt("version"),
                List.of(),
                List.of());
    }

    public ReturnRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Data struk untuk retur (fungsi database; hanya outlet tempat pemanggil bertransaksi). */
    public String lookup(String receiptNo) {
        return jdbc.sql("SELECT CAST(pos.return_lookup(:r) AS text)").param("r", receiptNo).query(String.class).single();
    }

    public Optional<ReturnView> find(UUID id) {
        return jdbc.sql(SELECT + " WHERE r.id = :id").param("id", id).query(ReturnRepository::map).optional()
                .map(r -> r.with(items(id), refunds(id)));
    }

    public Optional<UUID> findByClientId(String clientReturnId) {
        return jdbc.sql("""
                SELECT id FROM pos.returns
                WHERE organization_id = pos.current_org_id() AND client_return_id = :c AND created_by = pos.current_app_user_id()
                """)
                .param("c", clientReturnId).query(UUID.class).optional();
    }

    public List<ReturnView> list(UUID outletId, LocalDate businessDate, String status) {
        return jdbc.sql(SELECT + """
                WHERE r.outlet_id = :o
                  AND (r.business_date = :d OR (CAST(:status AS text) IS NULL AND r.status = 'PENDING_APPROVAL'))
                  AND (CAST(:status AS text) IS NULL OR r.status = CAST(:status AS text))
                ORDER BY r.created_at DESC
                LIMIT 500
                """)
                .param("o", outletId).param("d", businessDate).param("status", status)
                .query(ReturnRepository::map).list();
    }

    public List<ReturnItemView> items(UUID returnId) {
        return jdbc.sql("""
                SELECT sale_item_id, sku, product_name, uom, quantity, unit_price, amount, tax_amount, return_to_stock
                FROM pos.return_items WHERE return_id = :r ORDER BY created_at, sku
                """)
                .param("r", returnId).query(ReturnItemView.class).list();
    }

    public List<RefundView> refunds(UUID returnId) {
        return jdbc.sql("""
                SELECT id, original_payment_id, refund_method, refund_amount, reference_number, created_at
                FROM pos.refunds WHERE return_id = :r ORDER BY created_at, id
                """)
                .param("r", returnId).query(RefundView.class).list();
    }

    public UUID insert(UUID saleId, String clientReturnId, String reason, String refundMode, String refundReference,
            UUID actor) {
        // organisasi, outlet, terminal, session, nomor, business date & status diisi trigger
        return jdbc.sql("""
                INSERT INTO pos.returns (organization_id, outlet_id, terminal_id, cashier_session_id, original_sale_id,
                                         client_return_id, return_no, business_date, reason, refund_mode,
                                         refund_reference, created_by)
                SELECT pos.current_org_id(), s.outlet_id, s.terminal_id, s.id, :sale, :client, '-', CURRENT_DATE,
                       :reason, :mode, CAST(:ref AS text), :actor
                FROM pos.cashier_sessions s
                WHERE s.employee_id = pos.current_employee_id() AND s.status IN ('OPEN', 'ON_BREAK')
                RETURNING id
                """)
                .param("sale", saleId).param("client", clientReturnId).param("reason", reason).param("mode", refundMode)
                .param("ref", refundReference).param("actor", actor)
                .query(UUID.class).optional()
                .orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_REQUIRED));
    }

    public void insertItem(UUID returnId, UUID saleItemId, BigDecimal quantity, boolean returnToStock) {
        // produk, harga, nilai & pajak diisi trigger dari baris transaksi asli
        jdbc.sql("""
                INSERT INTO pos.return_items (return_id, sale_item_id, product_id, sku, product_name, uom, quantity,
                                              unit_price, amount, return_to_stock)
                SELECT :r, i.id, i.product_id, '-', '-', '-', :q, 0, 0, :stock
                FROM pos.sale_items i WHERE i.id = :i
                """)
                .param("r", returnId).param("i", saleItemId).param("q", quantity).param("stock", returnToStock)
                .update();
    }

    public UUID insertApproval(UUID returnId, UUID approvedBy) {
        // izin sale.refund, rank & approver ≠ peminta diperiksa trigger approval
        return jdbc.sql("""
                INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, action, price, requested_by, approved_by,
                                           expires_at)
                SELECT r.organization_id, r.outlet_id, r.original_sale_id, 'REFUND', r.total_amount,
                       pos.current_app_user_id(), :by, now()
                FROM pos.returns r WHERE r.id = :r
                RETURNING id
                """)
                .param("r", returnId).param("by", approvedBy).query(UUID.class).single();
    }

    public void useApproval(UUID approvalId) {
        jdbc.sql("UPDATE pos.approvals SET used_at = now() WHERE id = :id AND requested_by = pos.current_app_user_id()")
                .param("id", approvalId).update();
    }

    /** Selesaikan retur; database memeriksa approval/izin dan membuat refund + cash movement. */
    public boolean complete(UUID returnId, UUID approvalId, String refundReference) {
        return jdbc.sql("""
                UPDATE pos.returns
                SET status = 'COMPLETED', approval_id = CAST(:a AS uuid),
                    refund_reference = coalesce(CAST(:ref AS text), refund_reference)
                WHERE id = :r AND status = 'PENDING_APPROVAL'
                """)
                .param("a", approvalId).param("ref", refundReference).param("r", returnId).update() == 1;
    }

    public boolean reject(UUID returnId, String reason) {
        return jdbc.sql("""
                UPDATE pos.returns SET status = 'REJECTED', reject_reason = :why
                WHERE id = :r AND status = 'PENDING_APPROVAL'
                """)
                .param("why", reason).param("r", returnId).update() == 1;
    }

    public record Approver(UUID userId, String username, String displayName) {
    }

    public Optional<Approver> approver(UUID authUserId) {
        return jdbc.sql("SELECT user_id, username, display_name FROM pos.approver_lookup(:a)")
                .param("a", authUserId).query(Approver.class).optional();
    }

    public boolean selfApprovalAllowed(UUID outletId) {
        return jdbc.sql("""
                SELECT NOT coalesce((pos.get_setting('require_supervisor_for_refund', :o))::boolean, true)
                       AND pos.has_permission('sale.refund', :o)
                """)
                .param("o", outletId).query(Boolean.class).single();
    }
}
