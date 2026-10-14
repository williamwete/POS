package com.pirantisolution.pos.sale;

import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.payment.PaymentDtos.AddPaymentRequest;
import com.pirantisolution.pos.payment.PaymentService;
import com.pirantisolution.pos.sale.SaleDtos.AddItemRequest;
import com.pirantisolution.pos.sale.SaleDtos.SaleView;
import com.pirantisolution.pos.security.AccessService;
import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Menerima satu transaksi tunai yang dibuat saat internet mati (ASSUMPTIONS A3). Transaksi sudah terjadi
 * di toko, jadi server tidak menolaknya karena kebijakan; selisih dan pelanggaran batas dicatat sebagai
 * peninjauan (pos.offline_sales) untuk ditinjau pemilik/manajer. Dikirim ulang = hasil yang sama.
 */
@Service
public class OfflineSaleService {

    public record Line(UUID productId, String barcode, BigDecimal quantity) {
    }

    public record OfflineSaleRequest(String clientTransactionId, UUID outletId, Instant offlineAt, String note,
                                     List<Line> lines, BigDecimal clientTotal, BigDecimal amountReceived) {
    }

    public record OfflineSaleResult(SaleView sale, boolean duplicate, List<String> reviewReasons) {
    }

    private final SaleService sales;
    private final PaymentService payments;
    private final SaleRepository saleRepo;
    private final AccessService access;
    private final JdbcClient jdbc;

    public OfflineSaleService(SaleService sales, PaymentService payments, SaleRepository saleRepo,
                              AccessService access, JdbcClient jdbc) {
        this.sales = sales;
        this.payments = payments;
        this.saleRepo = saleRepo;
        this.access = access;
        this.jdbc = jdbc;
    }

    @Transactional
    public OfflineSaleResult submit(OfflineSaleRequest req) {
        validate(req);
        Optional<SaleView> existing = saleRepo.findByClientTransactionId(req.clientTransactionId());
        if (existing.isPresent()) {
            sales.create(req.clientTransactionId(), req.note()); // memastikan pemiliknya sama
            return new OfflineSaleResult(existing.get(), true, List.of());
        }
        // Satu keranjang aktif per kasir: keranjang kosong dari layar online dibatalkan, yang berisi ditahan.
        sales.current().filter((d) -> "DRAFT".equals(d.status())).ifPresent((d) -> {
            if (d.lineCount() == 0) {
                sales.cancel(d.id());
            } else {
                sales.hold(d.id());
            }
        });
        SaleView sale = sales.create(req.clientTransactionId(), req.note());
        if (req.outletId() != null && !req.outletId().equals(sale.outletId())) {
            // transaksi dibuat di outlet/merchant lain: batalkan seluruhnya (transaksi database ikut dibatalkan)
            throw new ApiException(ErrorCode.OFFLINE_SALE_INVALID, "Transaksi offline ini milik outlet lain");
        }
        for (Line l : req.lines()) {
            sale = sales.addItem(sale.id(), new AddItemRequest(l.productId(), l.barcode(), l.quantity(), null));
        }
        sale = sales.checkout(sale.id());
        BigDecimal serverTotal = sale.grandTotal();
        if (serverTotal.signum() > 0) {
            payments.add(sale.id(), new AddPaymentRequest("P" + req.clientTransactionId(), "CASH", null,
                    req.amountReceived(), null, null));
        }
        sale = saleRepo.findById(sale.id()).orElseThrow();

        List<String> reasons = reasons(req, serverTotal, sale.outletId());
        jdbc.sql("SELECT pos.record_offline_sale(:s, :t, :c, :r)")
                .param("s", sale.id())
                .param("t", java.sql.Timestamp.from(req.offlineAt()))
                .param("c", req.clientTotal())
                .param("r", reasons.isEmpty() ? null : String.join("; ", reasons))
                .query().singleRow();
        return new OfflineSaleResult(sale, false, reasons);
    }

    private List<String> reasons(OfflineSaleRequest req, BigDecimal serverTotal, UUID outletId) {
        List<String> r = new ArrayList<>();
        if (serverTotal.compareTo(req.clientTotal()) != 0) {
            r.add("Total di server Rp " + serverTotal.toBigInteger() + " berbeda dari total kasir offline Rp "
                    + req.clientTotal().toBigInteger());
        }
        if (!settingBool("allow_offline_sale", outletId)) {
            r.add("Penjualan offline tidak diizinkan di pengaturan outlet");
        }
        BigDecimal max = settingNumber("max_offline_sale_amount", outletId);
        if (max.signum() > 0 && req.clientTotal().compareTo(max) > 0) {
            r.add("Melebihi batas nilai transaksi offline Rp " + max.toBigInteger());
        }
        BigDecimal maxMinutes = settingNumber("max_offline_duration_minutes", outletId);
        long delay = Duration.between(req.offlineAt(), Instant.now()).toMinutes();
        if (maxMinutes.signum() > 0 && delay > maxMinutes.longValue()) {
            r.add("Terkirim " + delay + " menit setelah transaksi, melebihi batas " + maxMinutes.toBigInteger()
                    + " menit");
        }
        return r;
    }

    private boolean settingBool(String key, UUID outletId) {
        Boolean v = jdbc.sql("SELECT (pos.get_setting(:k, CAST(:o AS uuid)))::boolean")
                .param("k", key).param("o", outletId).query(Boolean.class).single();
        return Boolean.TRUE.equals(v);
    }

    private BigDecimal settingNumber(String key, UUID outletId) {
        BigDecimal v = jdbc.sql("SELECT (pos.get_setting(:k, CAST(:o AS uuid)))::text::numeric")
                .param("k", key).param("o", outletId).query(BigDecimal.class).single();
        return v == null ? BigDecimal.ZERO : v;
    }

    private void validate(OfflineSaleRequest req) {
        access.currentUser();
        String id = req.clientTransactionId();
        if (id == null || !id.matches("^[A-Za-z0-9._:-]{8,78}$")) {
            throw new ApiException(ErrorCode.OFFLINE_SALE_INVALID, "ID transaksi offline tidak valid");
        }
        if (req.offlineAt() == null || req.offlineAt().isAfter(Instant.now().plusSeconds(300))) {
            throw new ApiException(ErrorCode.OFFLINE_SALE_INVALID, "Waktu transaksi offline tidak valid");
        }
        if (req.lines() == null || req.lines().isEmpty() || req.lines().size() > 200) {
            throw new ApiException(ErrorCode.OFFLINE_SALE_INVALID, "Isi 1 sampai 200 baris barang");
        }
        for (Line l : req.lines()) {
            if (l == null || (l.productId() == null && l.barcode() == null) || l.quantity() == null
                    || l.quantity().signum() <= 0) {
                throw new ApiException(ErrorCode.OFFLINE_SALE_INVALID, "Baris barang tidak valid");
            }
        }
        if (req.clientTotal() == null || req.clientTotal().signum() < 0 || req.amountReceived() == null
                || req.amountReceived().signum() <= 0 && req.clientTotal().signum() > 0) {
            throw new ApiException(ErrorCode.OFFLINE_SALE_INVALID, "Total atau uang diterima tidak valid");
        }
    }
}
