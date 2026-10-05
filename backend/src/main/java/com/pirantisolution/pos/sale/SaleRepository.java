package com.pirantisolution.pos.sale;

import com.pirantisolution.pos.sale.CartCalculator.Discount;
import com.pirantisolution.pos.sale.CartCalculator.Line;
import com.pirantisolution.pos.sale.SaleDtos.DiscountView;
import com.pirantisolution.pos.sale.SaleDtos.ReceiptLine;
import com.pirantisolution.pos.sale.SaleDtos.ReceiptPayment;
import com.pirantisolution.pos.sale.SaleDtos.ReceiptView;
import com.pirantisolution.pos.sale.SaleDtos.SaleItemView;
import com.pirantisolution.pos.sale.SaleDtos.SaleView;
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
 * Akses data penjualan di bawah RLS. Harga, pajak, gross/net per baris, total header dan nomor
 * struk diisi trigger database; repository hanya menulis input kasir dan hasil alokasi diskon.
 */
@Repository
public class SaleRepository {

    private static final String SELECT = """
            SELECT s.id, s.client_transaction_id, s.receipt_no, s.status, s.sync_status, s.outlet_id,
                   o.code AS outlet_code, s.terminal_id, t.code AS terminal_code, s.cashier_session_id,
                   s.employee_id, e.full_name AS employee_name, s.business_date, s.prices_include_tax,
                   s.line_count, s.item_count, s.subtotal, s.item_discount_total, s.cart_discount_total,
                   s.discount_total, s.tax_total, s.grand_total, s.paid_amount, s.change_amount, s.paid_at,
                   s.note, s.held_at, s.checked_out_at,
                   s.voided_at, s.void_reason, s.created_at, s.version
            FROM pos.sales s
            JOIN pos.outlets o ON o.id = s.outlet_id
            JOIN pos.terminals t ON t.id = s.terminal_id
            JOIN pos.employees e ON e.id = s.employee_id
            """;

    /** Data minimal approval yang baru saja dipakai. */
    public record UsedApproval(UUID id, String action, UUID saleId, UUID saleItemId, BigDecimal maxPercent,
            BigDecimal price, UUID approvedBy) {
    }

    public record Availability(BigDecimal available, boolean allowNegative, String sku) {
    }

    public record SaleSettings(BigDecimal cashierMax, BigDecimal supervisorMax, BigDecimal managerMax,
            boolean requireOverrideApproval, boolean requireVoidApproval) {
    }

    private final JdbcClient jdbc;

    public SaleRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    private static SaleView map(ResultSet rs, int n) throws SQLException {
        return new SaleView(
                rs.getObject("id", UUID.class),
                rs.getString("client_transaction_id"),
                rs.getString("receipt_no"),
                rs.getString("status"),
                rs.getString("sync_status"),
                rs.getObject("outlet_id", UUID.class),
                rs.getString("outlet_code"),
                rs.getObject("terminal_id", UUID.class),
                rs.getString("terminal_code"),
                rs.getObject("cashier_session_id", UUID.class),
                rs.getObject("employee_id", UUID.class),
                rs.getString("employee_name"),
                rs.getObject("business_date", LocalDate.class),
                rs.getBoolean("prices_include_tax"),
                rs.getInt("line_count"),
                rs.getBigDecimal("item_count"),
                rs.getBigDecimal("subtotal"),
                rs.getBigDecimal("item_discount_total"),
                rs.getBigDecimal("cart_discount_total"),
                rs.getBigDecimal("discount_total"),
                rs.getBigDecimal("tax_total"),
                rs.getBigDecimal("grand_total"),
                rs.getBigDecimal("paid_amount"),
                rs.getBigDecimal("change_amount"),
                rs.getObject("paid_at", OffsetDateTime.class),
                rs.getString("note"),
                rs.getObject("held_at", OffsetDateTime.class),
                rs.getObject("checked_out_at", OffsetDateTime.class),
                rs.getObject("voided_at", OffsetDateTime.class),
                rs.getString("void_reason"),
                rs.getObject("created_at", OffsetDateTime.class),
                rs.getInt("version"),
                List.of(),
                List.of());
    }

    private SaleView full(SaleView s) {
        return s.with(items(s.id()), discounts(s.id()));
    }

    public Optional<SaleView> findById(UUID id) {
        return jdbc.sql(SELECT + " WHERE s.id = :id").param("id", id)
                .query(SaleRepository::map).optional().map(this::full);
    }

    public Optional<SaleView> findByClientTransactionId(String clientTxId) {
        return jdbc.sql(SELECT + " WHERE s.organization_id = pos.current_org_id() AND s.client_transaction_id = :c")
                .param("c", clientTxId).query(SaleRepository::map).optional().map(this::full);
    }

    /** Transaksi aktif (DRAFT, CHECKOUT atau menunggu pembayaran) di cashier session. */
    public Optional<SaleView> findOpenForSession(UUID sessionId) {
        return jdbc.sql(SELECT + """
                 WHERE s.cashier_session_id = :s AND s.status IN ('DRAFT', 'CHECKOUT', 'PAYMENT_PENDING')
                 ORDER BY (s.status = 'DRAFT') DESC, s.created_at DESC LIMIT 1
                """)
                .param("s", sessionId).query(SaleRepository::map).optional().map(this::full);
    }

    public List<SaleView> findHeld(UUID sessionId) {
        return jdbc.sql(SELECT + " WHERE s.cashier_session_id = :s AND s.status = 'HELD' ORDER BY s.held_at")
                .param("s", sessionId).query(SaleRepository::map).list();
    }

    public List<SaleView> findForOutlet(UUID outletId, LocalDate businessDate, String status, int limit) {
        return jdbc.sql(SELECT + """
                 WHERE s.outlet_id = :o AND s.business_date = :d
                   AND (CAST(:status AS text) IS NULL OR s.status = CAST(:status AS text))
                 ORDER BY s.created_at DESC LIMIT :limit
                """)
                .param("o", outletId).param("d", businessDate).param("status", status).param("limit", limit)
                .query(SaleRepository::map).list();
    }

    public List<SaleItemView> items(UUID saleId) {
        return jdbc.sql("""
                SELECT id, line_no, product_id, sku, product_name, barcode, uom, quantity, list_price, unit_price,
                       price_override_reason, tax_rate, gross_amount, item_discount_amount, cart_discount_amount,
                       net_amount, tax_amount, status, void_reason
                FROM pos.sale_items WHERE sale_id = :s ORDER BY line_no
                """)
                .param("s", saleId).query(SaleItemView.class).list();
    }

    public List<DiscountView> discounts(UUID saleId) {
        return jdbc.sql("""
                SELECT d.id, d.sale_item_id, d.discount_type, d.discount_value, d.amount, d.reason,
                       pos.approver_name(d.approved_by) AS approved_by_username, d.status
                FROM pos.sale_discounts d WHERE d.sale_id = :s AND d.status = 'ACTIVE' ORDER BY d.created_at
                """)
                .param("s", saleId).query(DiscountView.class).list();
    }

    // ---------------------------------------------------------------- tulis

    public UUID insertSale(UUID sessionId, UUID outletId, UUID terminalId, UUID employeeId, UUID userId,
            String clientTxId, String note, String deviceId) {
        // organisasi/outlet/terminal/business date ditetapkan ulang trigger dari cashier session
        return jdbc.sql("""
                INSERT INTO pos.sales (organization_id, outlet_id, terminal_id, cashier_session_id, employee_id,
                                       created_by, business_date, client_transaction_id, note, device_id)
                VALUES (pos.current_org_id(), :o, :t, :s, :e, :u, CURRENT_DATE, :c, :note, :device)
                RETURNING id
                """)
                .param("o", outletId).param("t", terminalId).param("s", sessionId).param("e", employeeId)
                .param("u", userId).param("c", clientTxId).param("note", note).param("device", deviceId)
                .query(UUID.class).single();
    }

    public UUID insertItem(UUID saleId, UUID productId, String barcode, BigDecimal qty, UUID userId) {
        // harga, pajak & snapshot produk diisi trigger dari cache harga database
        return jdbc.sql("""
                INSERT INTO pos.sale_items (sale_id, product_id, sku, product_name, barcode, uom, quantity,
                                            list_price, unit_price, created_by)
                VALUES (:s, :p, '-', '-', :b, '-', :q, 0, 0, :u)
                RETURNING id
                """)
                .param("s", saleId).param("p", productId).param("b", barcode).param("q", qty).param("u", userId)
                .query(UUID.class).single();
    }

    /** Baris yang bisa ditambah jumlahnya saat produk yang sama dipindai lagi (harga normal, tanpa diskon baris). */
    public Optional<UUID> findMergeableLine(UUID saleId, UUID productId) {
        return jdbc.sql("""
                SELECT si.id FROM pos.sale_items si
                WHERE si.sale_id = :s AND si.product_id = :p AND si.status = 'ACTIVE'
                  AND si.unit_price = si.list_price
                  AND NOT EXISTS (SELECT 1 FROM pos.sale_discounts d WHERE d.sale_item_id = si.id AND d.status = 'ACTIVE')
                ORDER BY si.line_no DESC LIMIT 1
                """)
                .param("s", saleId).param("p", productId).query(UUID.class).optional();
    }

    public Optional<SaleItemView> item(UUID saleId, UUID itemId) {
        return items(saleId).stream().filter(i -> i.id().equals(itemId)).findFirst();
    }

    public void addQuantity(UUID itemId, BigDecimal delta) {
        jdbc.sql("UPDATE pos.sale_items SET quantity = quantity + :d WHERE id = :id")
                .param("d", delta).param("id", itemId).update();
    }

    public void setQuantity(UUID itemId, BigDecimal qty) {
        jdbc.sql("UPDATE pos.sale_items SET quantity = :q WHERE id = :id").param("q", qty).param("id", itemId).update();
    }

    public void voidItem(UUID itemId, String reason) {
        jdbc.sql("UPDATE pos.sale_items SET status = 'VOID', void_reason = :r WHERE id = :id AND status = 'ACTIVE'")
                .param("r", reason).param("id", itemId).update();
        // diskon pada baris yang di-void ikut dihapus
        jdbc.sql("UPDATE pos.sale_discounts SET status = 'REMOVED' WHERE sale_item_id = :id AND status = 'ACTIVE'")
                .param("id", itemId).update();
    }

    public void setPrice(UUID itemId, BigDecimal price, String reason, UUID approvalId, UUID approvedBy) {
        jdbc.sql("""
                UPDATE pos.sale_items
                SET unit_price = :p, price_override_reason = :r, price_override_approval_id = CAST(:a AS uuid),
                    price_override_approved_by = CAST(:by AS uuid), item_discount_amount = 0, cart_discount_amount = 0
                WHERE id = :id
                """)
                .param("p", price).param("r", reason).param("a", approvalId).param("by", approvedBy)
                .param("id", itemId).update();
    }

    public UUID insertDiscount(UUID saleId, UUID itemId, String type, BigDecimal value, String reason, UUID userId,
            UUID approvalId) {
        return jdbc.sql("""
                INSERT INTO pos.sale_discounts (sale_id, sale_item_id, discount_type, discount_value, reason,
                                                created_by, approval_id)
                VALUES (:s, CAST(:i AS uuid), :t, :v, :r, :u, CAST(:a AS uuid))
                RETURNING id
                """)
                .param("s", saleId).param("i", itemId).param("t", type).param("v", value).param("r", reason)
                .param("u", userId).param("a", approvalId)
                .query(UUID.class).single();
    }

    public boolean removeDiscount(UUID saleId, UUID discountId) {
        return jdbc.sql("""
                UPDATE pos.sale_discounts SET status = 'REMOVED'
                WHERE id = :id AND sale_id = :s AND status = 'ACTIVE'
                """)
                .param("id", discountId).param("s", saleId).update() == 1;
    }

    public List<Line> activeLines(UUID saleId) {
        return jdbc.sql("""
                SELECT id, gross_amount FROM pos.sale_items WHERE sale_id = :s AND status = 'ACTIVE' ORDER BY line_no
                """)
                .param("s", saleId)
                .query((rs, n) -> new Line(rs.getObject("id", UUID.class), rs.getBigDecimal("gross_amount")))
                .list();
    }

    public List<Discount> activeDiscounts(UUID saleId) {
        return jdbc.sql("""
                SELECT id, sale_item_id, discount_type, discount_value
                FROM pos.sale_discounts WHERE sale_id = :s AND status = 'ACTIVE' ORDER BY created_at
                """)
                .param("s", saleId)
                .query((rs, n) -> new Discount(rs.getObject("id", UUID.class),
                        rs.getObject("sale_item_id", UUID.class),
                        CartCalculator.Type.valueOf(rs.getString("discount_type")),
                        rs.getBigDecimal("discount_value")))
                .list();
    }

    /** Tulis alokasi diskon. Dua tahap agar net baris tidak pernah negatif di tengah jalan. */
    public void writeAllocation(CartCalculator.Result result) {
        for (CartCalculator.LineResult l : result.lines()) {
            jdbc.sql("""
                    UPDATE pos.sale_items SET item_discount_amount = :i, cart_discount_amount = 0
                    WHERE id = :id AND (item_discount_amount <> :i OR cart_discount_amount <> 0)
                    """)
                    .param("i", l.itemDiscount()).param("id", l.id()).update();
        }
        for (CartCalculator.LineResult l : result.lines()) {
            if (l.cartDiscount().signum() > 0) {
                jdbc.sql("UPDATE pos.sale_items SET cart_discount_amount = :c WHERE id = :id")
                        .param("c", l.cartDiscount()).param("id", l.id()).update();
            }
        }
        result.discountAmounts().forEach((id, amount) -> jdbc.sql("""
                UPDATE pos.sale_discounts SET amount = :a WHERE id = :id AND amount <> :a
                """)
                .param("a", amount).param("id", id).update());
    }

    public boolean transition(UUID saleId, String from, String to) {
        return jdbc.sql("UPDATE pos.sales SET status = :to WHERE id = :id AND status = :from RETURNING id")
                .param("to", to).param("id", saleId).param("from", from)
                .query(UUID.class).optional().isPresent();
    }

    public boolean voidSale(UUID saleId, String from, String reason, UUID approvalId, UUID approvedBy) {
        return jdbc.sql("""
                UPDATE pos.sales SET status = 'VOID', void_reason = :r, void_approval_id = CAST(:a AS uuid),
                                     void_approved_by = CAST(:by AS uuid)
                WHERE id = :id AND status = :from
                RETURNING id
                """)
                .param("r", reason).param("a", approvalId).param("by", approvedBy).param("id", saleId)
                .param("from", from).query(UUID.class).optional().isPresent();
    }

    // ---------------------------------------------------------------- approval

    public UUID insertApproval(UUID saleId, UUID itemId, String action, BigDecimal maxPercent, BigDecimal price,
            UUID approvedBy) {
        // organisasi, outlet, peminta, waktu kedaluwarsa & validasi izin approver: trigger database
        return jdbc.sql("""
                INSERT INTO pos.approvals (organization_id, outlet_id, sale_id, sale_item_id, action, max_percent,
                                           price, requested_by, approved_by, expires_at)
                SELECT s.organization_id, s.outlet_id, s.id, CAST(:i AS uuid), :action, CAST(:pct AS numeric),
                       CAST(:price AS numeric), pos.current_app_user_id(), :by, now()
                FROM pos.sales s WHERE s.id = :s
                RETURNING id
                """)
                .param("i", itemId).param("action", action).param("pct", maxPercent).param("price", price)
                .param("by", approvedBy).param("s", saleId)
                .query(UUID.class).single();
    }

    public Optional<OffsetDateTime> approvalExpiry(UUID approvalId) {
        return jdbc.sql("SELECT expires_at FROM pos.approvals WHERE id = :id")
                .param("id", approvalId).query(OffsetDateTime.class).optional();
    }

    /** Pakai approval (sekali). Kosong bila tidak ada, sudah dipakai, atau bukan milik peminta ini. */
    public Optional<UsedApproval> useApproval(UUID approvalId) {
        return jdbc.sql("""
                UPDATE pos.approvals SET used_at = now()
                WHERE id = :id AND requested_by = pos.current_app_user_id() AND used_at IS NULL
                RETURNING id, action, sale_id, sale_item_id, max_percent, price, approved_by
                """)
                .param("id", approvalId).query(UsedApproval.class).optional();
    }

    public record Approver(UUID userId, String username, String displayName) {
    }

    public Optional<Approver> approver(UUID authUserId) {
        return jdbc.sql("SELECT user_id, username, display_name FROM pos.approver_lookup(:a)")
                .param("a", authUserId).query(Approver.class).optional();
    }

    // ---------------------------------------------------------------- aturan & stok

    public SaleSettings settings(UUID outletId) {
        return jdbc.sql("""
                SELECT coalesce((pos.get_setting('max_cashier_discount', :o))::numeric, 0) AS cashier_max,
                       coalesce((pos.get_setting('max_supervisor_discount', :o))::numeric, 0) AS supervisor_max,
                       coalesce((pos.get_setting('max_manager_discount', :o))::numeric, 0) AS manager_max,
                       coalesce((pos.get_setting('require_supervisor_for_price_override', :o))::boolean, true)
                           OR NOT pos.has_permission('sale.price_override', :o) AS require_override_approval,
                       coalesce((pos.get_setting('require_supervisor_for_void', :o))::boolean, true)
                           AS require_void_approval
                """)
                .param("o", outletId).query(SaleSettings.class).single();
    }

    public Availability availability(UUID productId, UUID outletId) {
        return jdbc.sql("""
                SELECT pos.available_to_sell(p.id, :o) AS available,
                       coalesce(p.allow_negative_stock, (pos.get_setting('allow_negative_stock', :o))::boolean, false)
                           AS allow_negative,
                       p.sku
                FROM pos.products p WHERE p.id = :p
                """)
                .param("o", outletId).param("p", productId).query(Availability.class).single();
    }

    public BigDecimal quantityInCart(UUID saleId, UUID productId) {
        return jdbc.sql("""
                SELECT coalesce(sum(quantity), 0) FROM pos.sale_items
                WHERE sale_id = :s AND product_id = :p AND status = 'ACTIVE'
                """)
                .param("s", saleId).param("p", productId).query(BigDecimal.class).single();
    }

    public LocalDate businessDate(UUID outletId) {
        return jdbc.sql("SELECT pos.business_date(now(), :o)").param("o", outletId).query(LocalDate.class).single();
    }

    // ---------------------------------------------------------------- struk

    public Optional<ReceiptView> receipt(UUID saleId) {
        List<ReceiptLine> lines = jdbc.sql("""
                SELECT product_name AS name, sku, quantity, uom, unit_price, list_price,
                       item_discount_amount + cart_discount_amount AS discount, net_amount AS amount, tax_rate
                FROM pos.sale_items WHERE sale_id = :s AND status = 'ACTIVE' ORDER BY line_no
                """)
                .param("s", saleId).query(ReceiptLine.class).list();
        List<ReceiptPayment> payments = jdbc.sql("""
                SELECT m.name AS method_name, p.method_kind, p.amount, p.amount_received, p.change_amount,
                       p.reference_number
                FROM pos.payments p JOIN pos.payment_methods m ON m.id = p.payment_method_id
                WHERE p.sale_id = :s AND p.status = 'PAID' ORDER BY p.created_at
                """)
                .param("s", saleId).query(ReceiptPayment.class).list();
        return jdbc.sql("""
                SELECT s.id AS sale_id, s.receipt_no, s.status, org.name AS organization_name, o.name AS outlet_name,
                       o.address AS outlet_address, o.phone AS outlet_phone, t.code AS terminal_code,
                       e.full_name AS cashier_name, s.business_date, r.issued_at, s.prices_include_tax,
                       s.item_count, s.subtotal, s.discount_total, s.tax_total, s.grand_total,
                       s.paid_amount, s.change_amount, s.paid_at, coalesce(r.print_count, 0) AS print_count
                FROM pos.sales s
                JOIN pos.organizations org ON org.id = s.organization_id
                JOIN pos.outlets o ON o.id = s.outlet_id
                JOIN pos.terminals t ON t.id = s.terminal_id
                JOIN pos.employees e ON e.id = s.employee_id
                LEFT JOIN pos.receipts r ON r.sale_id = s.id
                WHERE s.id = :s
                """)
                .param("s", saleId)
                .query((rs, n) -> new ReceiptView(
                        rs.getObject("sale_id", UUID.class), rs.getString("receipt_no"), rs.getString("status"),
                        rs.getString("organization_name"), rs.getString("outlet_name"),
                        rs.getString("outlet_address"), rs.getString("outlet_phone"), rs.getString("terminal_code"),
                        rs.getString("cashier_name"), rs.getObject("business_date", LocalDate.class),
                        rs.getObject("issued_at", OffsetDateTime.class), rs.getBoolean("prices_include_tax"),
                        lines, rs.getBigDecimal("item_count"), rs.getBigDecimal("subtotal"),
                        rs.getBigDecimal("discount_total"), rs.getBigDecimal("tax_total"),
                        rs.getBigDecimal("grand_total"), payments, rs.getBigDecimal("paid_amount"),
                        rs.getBigDecimal("change_amount"), rs.getObject("paid_at", OffsetDateTime.class),
                        rs.getInt("print_count")))
                .optional();
    }

    public int recordPrint(UUID saleId) {
        return jdbc.sql("SELECT pos.record_receipt_print(:s)").param("s", saleId).query(Integer.class).single();
    }
}
