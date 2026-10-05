package com.pirantisolution.pos.payment;

import com.pirantisolution.pos.payment.PaymentDtos.PaymentMethodView;
import com.pirantisolution.pos.payment.PaymentDtos.PaymentView;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Akses data pembayaran. Jumlah diterapkan, kembalian, status awal, dan status sale dihitung
 * trigger database; repository hanya mengirim input kasir / hasil penyedia pembayaran.
 */
@Repository
public class PaymentRepository {

    private static final String METHOD = """
            SELECT id, code, name, kind, confirmation, requires_reference, requires_approval,
                   manual_confirm_allowed, active, sort_order, openbravo_payment_method_id, version,
                   true AS available
            FROM pos.payment_methods
            """;

    private static final String PAYMENT = """
            SELECT p.id, p.sale_id, p.method_code, m.name AS method_name, p.method_kind, p.confirmation, p.amount,
                   p.amount_received, p.change_amount, p.status, p.reference_number, p.provider,
                   p.external_transaction_id, p.qr_payload, p.expires_at, p.paid_at, p.failed_reason,
                   p.cancel_reason, u.username AS approved_by_username, m.manual_confirm_allowed,
                   p.created_at, p.version
            FROM pos.payments p
            JOIN pos.payment_methods m ON m.id = p.payment_method_id
            LEFT JOIN pos.users u ON u.id = p.approved_by
            """;

    private final JdbcClient jdbc;

    public PaymentRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    // ---------------------------------------------------------------- metode

    public List<PaymentMethodView> methods(boolean activeOnly) {
        return jdbc.sql(METHOD + """
                WHERE organization_id = pos.current_org_id() AND (active OR NOT :activeOnly)
                ORDER BY sort_order, code
                """)
                .param("activeOnly", activeOnly).query(PaymentMethodView.class).list();
    }

    public Optional<PaymentMethodView> methodByCode(String code) {
        return jdbc.sql(METHOD + " WHERE organization_id = pos.current_org_id() AND code = :c")
                .param("c", code).query(PaymentMethodView.class).optional();
    }

    public Optional<PaymentMethodView> method(UUID id) {
        return jdbc.sql(METHOD + " WHERE id = :id").param("id", id).query(PaymentMethodView.class).optional();
    }

    public boolean updateMethod(UUID id, int version, String name, boolean active, boolean requiresReference,
            boolean requiresApproval, boolean manualConfirmAllowed, int sortOrder, String openbravoId, UUID actor) {
        return jdbc.sql("""
                UPDATE pos.payment_methods
                SET name = :name, active = :active, requires_reference = :ref, requires_approval = :appr,
                    manual_confirm_allowed = :manual, sort_order = :sort,
                    openbravo_payment_method_id = CAST(:ob AS text), updated_by = :actor
                WHERE id = :id AND version = :v
                RETURNING id
                """)
                .param("name", name).param("active", active).param("ref", requiresReference)
                .param("appr", requiresApproval).param("manual", manualConfirmAllowed).param("sort", sortOrder)
                .param("ob", openbravoId).param("actor", actor).param("id", id).param("v", version)
                .query(UUID.class).optional().isPresent();
    }

    // ---------------------------------------------------------------- pembayaran

    public Optional<PaymentView> findById(UUID id) {
        return jdbc.sql(PAYMENT + " WHERE p.id = :id").param("id", id).query(PaymentView.class).optional();
    }

    public Optional<PaymentView> findByClientPaymentId(String clientPaymentId) {
        return jdbc.sql(PAYMENT + " WHERE p.organization_id = pos.current_org_id() AND p.client_payment_id = :c")
                .param("c", clientPaymentId).query(PaymentView.class).optional();
    }

    public List<PaymentView> forSale(UUID saleId) {
        return jdbc.sql(PAYMENT + " WHERE p.sale_id = :s ORDER BY p.created_at")
                .param("s", saleId).query(PaymentView.class).list();
    }

    public UUID insert(UUID saleId, UUID methodId, String clientPaymentId, BigDecimal amount, BigDecimal received,
            String reference, UUID approvalId, UUID actor) {
        // organisasi/outlet/session, jumlah diterapkan, kembalian, status awal: trigger database
        return jdbc.sql("""
                INSERT INTO pos.payments (organization_id, outlet_id, sale_id, cashier_session_id, payment_method_id,
                                          method_code, method_kind, confirmation, client_payment_id, amount,
                                          amount_received, reference_number, approval_id, created_by)
                SELECT s.organization_id, s.outlet_id, s.id, s.cashier_session_id, :m, '-', '-', '-', :c,
                       coalesce(CAST(:amount AS numeric), 1), coalesce(CAST(:received AS numeric), 0),
                       CAST(:ref AS text), CAST(:appr AS uuid), :actor
                FROM pos.sales s WHERE s.id = :s
                RETURNING id
                """)
                .param("m", methodId).param("c", clientPaymentId).param("amount", amount).param("received", received)
                .param("ref", reference).param("appr", approvalId).param("actor", actor).param("s", saleId)
                .query(UUID.class).single();
    }

    public void setGatewayData(UUID paymentId, String provider, String externalId, String qrPayload) {
        jdbc.sql("""
                UPDATE pos.payments SET provider = :p, external_transaction_id = CAST(:e AS text),
                                        qr_payload = CAST(:q AS text)
                WHERE id = :id
                """)
                .param("p", provider).param("e", externalId).param("q", qrPayload).param("id", paymentId).update();
    }

    /** Transisi status dengan kondisi status saat ini (aman terhadap callback/klik ganda). */
    public boolean transition(UUID paymentId, String from, String to, String reason, String reference,
            UUID approvalId) {
        return jdbc.sql("""
                UPDATE pos.payments
                SET status = :to,
                    cancel_reason = CASE WHEN :to = 'CANCELLED' THEN CAST(:reason AS text) ELSE cancel_reason END,
                    failed_reason = CASE WHEN :to = 'FAILED' THEN CAST(:reason AS text) ELSE failed_reason END,
                    reference_number = coalesce(CAST(:ref AS text), reference_number),
                    approval_id = coalesce(CAST(:appr AS uuid), approval_id)
                WHERE id = :id AND status = :from
                RETURNING id
                """)
                .param("to", to).param("reason", reason).param("ref", reference).param("appr", approvalId)
                .param("id", paymentId).param("from", from)
                .query(UUID.class).optional().isPresent();
    }

    // ---------------------------------------------------------------- konteks sistem (callback/job)

    public record GatewayPayment(UUID id, UUID organizationId, UUID outletId, UUID saleId, String status,
            BigDecimal amount, String provider, String externalTransactionId, OffsetDateTime expiresAt) {
    }

    public Optional<GatewayPayment> findByExternal(String provider, String externalId) {
        return jdbc.sql("""
                SELECT id, organization_id, outlet_id, sale_id, status, amount, provider, external_transaction_id,
                       expires_at
                FROM pos.payments WHERE provider = :p AND external_transaction_id = :e
                """)
                .param("p", provider).param("e", externalId).query(GatewayPayment.class).optional();
    }

    public Optional<GatewayPayment> gatewayPayment(UUID id) {
        return jdbc.sql("""
                SELECT id, organization_id, outlet_id, sale_id, status, amount, provider, external_transaction_id,
                       expires_at
                FROM pos.payments WHERE id = :id
                """)
                .param("id", id).query(GatewayPayment.class).optional();
    }

    public List<GatewayPayment> expiredPending(int limit) {
        return jdbc.sql("""
                SELECT id, organization_id, outlet_id, sale_id, status, amount, provider, external_transaction_id,
                       expires_at
                FROM pos.payments WHERE status = 'PENDING' AND expires_at < now()
                ORDER BY expires_at LIMIT :limit
                """)
                .param("limit", limit).query(GatewayPayment.class).list();
    }

    public String saleStatus(UUID saleId) {
        return jdbc.sql("SELECT status FROM pos.sales WHERE id = :s").param("s", saleId)
                .query(String.class).optional().orElse(null);
    }
}
