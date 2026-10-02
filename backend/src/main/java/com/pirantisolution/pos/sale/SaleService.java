package com.pirantisolution.pos.sale;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.cashier.CashierDtos.SessionView;
import com.pirantisolution.pos.cashier.CashierRepository;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.common.web.RequestContext;
import com.pirantisolution.pos.product.ProductRepository;
import com.pirantisolution.pos.product.ProductView;
import com.pirantisolution.pos.sale.CartCalculator.Discount;
import com.pirantisolution.pos.sale.CartCalculator.Line;
import com.pirantisolution.pos.sale.SaleDtos.AddItemRequest;
import com.pirantisolution.pos.sale.SaleDtos.ApprovalRequest;
import com.pirantisolution.pos.sale.SaleDtos.ApprovalView;
import com.pirantisolution.pos.sale.SaleDtos.DiscountRequest;
import com.pirantisolution.pos.sale.SaleDtos.PrintResult;
import com.pirantisolution.pos.sale.SaleDtos.ReceiptView;
import com.pirantisolution.pos.sale.SaleDtos.SaleItemView;
import com.pirantisolution.pos.sale.SaleDtos.SaleView;
import com.pirantisolution.pos.sale.SaleRepository.SaleSettings;
import com.pirantisolution.pos.sale.SaleRepository.UsedApproval;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Transaksi penjualan (§15, §18, §20, §26, §27, §30, §31).
 *
 * <p>Service memeriksa aturan lebih dulu untuk pesan yang jelas, menghitung alokasi diskon
 * ({@link CartCalculator}), dan mencatat audit. Database menghitung harga/pajak/total, memberi
 * nomor struk, serta memvalidasi ulang diskon, approval, dan stok saat checkout — sehingga
 * aturan tetap berlaku walaupun service keliru.
 */
@Service
public class SaleService {

    private static final List<String> STATUSES = List.of("DRAFT", "HELD", "CHECKOUT", "PAYMENT_PENDING", "PAID",
            "POSTING", "POSTED", "VOID", "RETURNED", "CANCELLED");

    private final SaleRepository repo;
    private final ProductRepository products;
    private final CashierRepository cashier;
    private final AccessService access;
    private final AuditService audit;

    public SaleService(SaleRepository repo, ProductRepository products, CashierRepository cashier,
            AccessService access, AuditService audit) {
        this.repo = repo;
        this.products = products;
        this.cashier = cashier;
        this.access = access;
        this.audit = audit;
    }

    // ------------------------------------------------------------------ baca

    @Transactional(readOnly = true)
    public Optional<SaleView> current() {
        CurrentUser cu = access.currentUser();
        if (cu.employeeId() == null) {
            return Optional.empty();
        }
        return cashier.findActiveForEmployee(cu.employeeId()).flatMap(s -> repo.findOpenForSession(s.id()));
    }

    @Transactional(readOnly = true)
    public List<SaleView> held() {
        CurrentUser cu = access.currentUser();
        if (cu.employeeId() == null) {
            return List.of();
        }
        return cashier.findActiveForEmployee(cu.employeeId()).map(s -> repo.findHeld(s.id())).orElse(List.of());
    }

    @Transactional(readOnly = true)
    public SaleView get(UUID saleId) {
        access.currentUser();
        return repo.findById(saleId).orElseThrow(() -> new ApiException(ErrorCode.SALE_NOT_FOUND));
    }

    @Transactional(readOnly = true)
    public List<SaleView> outletSales(UUID outletId, LocalDate businessDate, String status) {
        access.requireOutlet("sale.view", outletId);
        if (status != null && !STATUSES.contains(status)) {
            throw ApiException.validation("Status tidak dikenal");
        }
        return repo.findForOutlet(outletId, businessDate != null ? businessDate : repo.businessDate(outletId),
                status, 500);
    }

    // ------------------------------------------------------------------ keranjang

    @Transactional
    public SaleView create(String clientTransactionId, String note) {
        CurrentUser cu = requireEmployee();
        // permintaan ulang dengan client_transaction_id yang sama mengembalikan transaksi yang sama (§66)
        Optional<SaleView> existing = repo.findByClientTransactionId(clientTransactionId);
        if (existing.isPresent()) {
            if (!existing.get().employeeId().equals(cu.employeeId())) {
                throw new ApiException(ErrorCode.DUPLICATE_TRANSACTION);
            }
            return existing.get();
        }
        SessionView session = openSession(cu);
        access.requireOutlet("sale.create", session.outletId());
        UUID id = repo.insertSale(session.id(), session.outletId(), session.terminalId(), cu.employeeId(), cu.userId(),
                clientTransactionId, Guards.trimToNull(note), RequestContext.deviceId());
        SaleView s = repo.findById(id).orElseThrow();
        audit.record(AuditEvent.of("SALE_CREATED", "SALE", id).outlet(s.outletId())
                .change(null, Map.of("clientTransactionId", clientTransactionId, "terminalCode", s.terminalCode())));
        return s;
    }

    @Transactional
    public SaleView addItem(UUID saleId, AddItemRequest req) {
        CurrentUser cu = requireEmployee();
        SaleView sale = editable(cu, saleId);
        ProductView product;
        if (req.productId() != null) {
            product = products.byId(sale.outletId(), req.productId())
                    .orElseThrow(() -> new ApiException(ErrorCode.PRODUCT_NOT_FOUND));
        } else if (req.barcode() != null) {
            product = products.byBarcode(sale.outletId(), req.barcode())
                    .orElseThrow(() -> new ApiException(ErrorCode.PRODUCT_NOT_FOUND,
                            "Barcode " + req.barcode() + " tidak terdaftar"));
        } else {
            throw ApiException.validation("Pilih produk atau pindai barcode");
        }
        if (product.price() == null) {
            throw new ApiException(ErrorCode.PRICE_NOT_FOUND);
        }
        checkQuantity(product.allowDecimalQty(), req.quantity());
        checkStock(sale, product.id(), repo.quantityInCart(saleId, product.id()).add(req.quantity()));

        Optional<UUID> merge = repo.findMergeableLine(saleId, product.id());
        if (merge.isPresent()) {
            repo.addQuantity(merge.get(), req.quantity());
        } else {
            repo.insertItem(saleId, product.id(), req.barcode(), req.quantity(), cu.userId());
        }
        recalc(saleId);
        return repo.findById(saleId).orElseThrow();
    }

    @Transactional
    public SaleView setQuantity(UUID saleId, UUID itemId, BigDecimal quantity) {
        CurrentUser cu = requireEmployee();
        SaleView sale = editable(cu, saleId);
        SaleItemView item = activeItem(saleId, itemId);
        if (item.quantity().compareTo(quantity) == 0) {
            return sale;
        }
        ProductView product = products.byId(sale.outletId(), item.productId())
                .orElseThrow(() -> new ApiException(ErrorCode.PRODUCT_NOT_FOUND));
        checkQuantity(product.allowDecimalQty(), quantity);
        if (quantity.compareTo(item.quantity()) > 0) {
            checkStock(sale, item.productId(),
                    repo.quantityInCart(saleId, item.productId()).subtract(item.quantity()).add(quantity));
        }
        repo.setQuantity(itemId, quantity);
        recalc(saleId);
        audit.record(AuditEvent.of("ITEM_QTY_CHANGED", "SALE", saleId).outlet(sale.outletId())
                .change(Map.of("line", item.lineNo(), "sku", item.sku(), "quantity", item.quantity()),
                        Map.of("line", item.lineNo(), "sku", item.sku(), "quantity", quantity)));
        return repo.findById(saleId).orElseThrow();
    }

    @Transactional
    public SaleView voidItem(UUID saleId, UUID itemId, String reason) {
        CurrentUser cu = requireEmployee();
        SaleView sale = editable(cu, saleId);
        SaleItemView item = activeItem(saleId, itemId);
        String why = reason.trim();
        repo.voidItem(itemId, why);
        recalc(saleId);
        audit.record(AuditEvent.of("ITEM_VOIDED", "SALE", saleId).outlet(sale.outletId())
                .change(lineSummary(item), Map.of("line", item.lineNo(), "status", "VOID")).reason(why));
        return repo.findById(saleId).orElseThrow();
    }

    /** Ubah harga baris (§18). Selalu tercatat; approval sesuai setting/izin (§20 tidak boleh silent). */
    @Transactional
    public SaleView overridePrice(UUID saleId, UUID itemId, BigDecimal price, String reason, UUID approvalId) {
        CurrentUser cu = requireEmployee();
        SaleView sale = editable(cu, saleId);
        SaleItemView item = activeItem(saleId, itemId);
        requireWholeRupiah(price);
        String why = reason.trim();
        UUID approvedBy = null;
        UUID usedApproval = null;
        if (price.compareTo(item.listPrice()) != 0 && repo.settings(sale.outletId()).requireOverrideApproval()) {
            UsedApproval a = useApproval(approvalId, "PRICE_OVERRIDE", saleId);
            if (!itemId.equals(a.saleItemId()) || a.price() == null || a.price().compareTo(price) != 0) {
                throw new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan tidak sesuai dengan harga baru");
            }
            approvedBy = a.approvedBy();
            usedApproval = a.id();
        }
        repo.setPrice(itemId, price, why, usedApproval, approvedBy);
        recalc(saleId);
        Map<String, Object> after = new LinkedHashMap<>();
        after.put("line", item.lineNo());
        after.put("sku", item.sku());
        after.put("unitPrice", price);
        after.put("approvedBy", approvedBy);
        audit.record(AuditEvent.of("PRICE_OVERRIDE", "SALE", saleId).outlet(sale.outletId())
                .change(Map.of("line", item.lineNo(), "sku", item.sku(), "unitPrice", item.unitPrice(),
                        "listPrice", item.listPrice()), after).reason(why));
        return repo.findById(saleId).orElseThrow();
    }

    @Transactional
    public SaleView addDiscount(UUID saleId, DiscountRequest req) {
        CurrentUser cu = requireEmployee();
        SaleView sale = editable(cu, saleId);
        access.requireOutlet("sale.discount", sale.outletId());
        validateDiscountValue(req.type(), req.value());
        if (req.saleItemId() != null) {
            activeItem(saleId, req.saleItemId());
        }
        boolean exists = sale.discounts().stream().anyMatch(d -> java.util.Objects.equals(d.saleItemId(), req.saleItemId()));
        if (exists) {
            throw new ApiException(ErrorCode.DISCOUNT_INVALID, "Hapus diskon yang ada sebelum menambah diskon baru");
        }
        Proposed p = propose(saleId, req.saleItemId(), req.type(), req.value());
        SaleSettings settings = repo.settings(sale.outletId());
        UUID approval = null;
        UUID approvedBy = null;
        if (!CartCalculator.withinLimit(p.amount(), p.base(), settings.cashierMax())) {
            if (!CartCalculator.withinLimit(p.amount(), p.base(), settings.managerMax())) {
                throw new ApiException(ErrorCode.DISCOUNT_LIMIT_EXCEEDED,
                        "Diskon " + p.percent().stripTrailingZeros().toPlainString() + "% melebihi batas maksimum "
                                + settings.managerMax().stripTrailingZeros().toPlainString() + "%");
            }
            if (req.approvalId() == null) {
                throw new ApiException(ErrorCode.APPROVAL_REQUIRED, "Diskon "
                        + p.percent().stripTrailingZeros().toPlainString() + "% memerlukan persetujuan supervisor");
            }
            UsedApproval a = useApproval(req.approvalId(), "DISCOUNT", saleId);
            if (!CartCalculator.withinLimit(p.amount(), p.base(), a.maxPercent())) {
                throw new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan tidak mencakup diskon sebesar ini");
            }
            approval = a.id();
            approvedBy = a.approvedBy();
        }
        String why = req.reason().trim();
        UUID discountId = repo.insertDiscount(saleId, req.saleItemId(), req.type().name(), req.value(), why,
                cu.userId(), approval);
        recalc(saleId);
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("discountId", discountId);
        v.put("scope", req.saleItemId() == null ? "CART" : "ITEM");
        v.put("discountType", req.type().name());
        v.put("discountValue", req.value());
        v.put("amount", p.amount());
        v.put("percent", p.percent());
        v.put("approvedBy", approvedBy);
        audit.record(AuditEvent.of("DISCOUNT", "SALE", saleId).outlet(sale.outletId()).change(null, v).reason(why));
        return repo.findById(saleId).orElseThrow();
    }

    @Transactional
    public SaleView removeDiscount(UUID saleId, UUID discountId) {
        CurrentUser cu = requireEmployee();
        SaleView sale = editable(cu, saleId);
        if (!repo.removeDiscount(saleId, discountId)) {
            throw new ApiException(ErrorCode.DISCOUNT_INVALID, "Diskon tidak ditemukan");
        }
        recalc(saleId);
        audit.record(AuditEvent.of("DISCOUNT_REMOVED", "SALE", saleId).outlet(sale.outletId())
                .change(Map.of("discountId", discountId), null));
        return repo.findById(saleId).orElseThrow();
    }

    // ------------------------------------------------------------------ status

    @Transactional
    public SaleView hold(UUID saleId) {
        return move(saleId, "DRAFT", "HELD", "SALE_HELD");
    }

    @Transactional
    public SaleView resume(UUID saleId) {
        CurrentUser cu = requireEmployee();
        SaleView sale = own(cu, saleId);
        SessionView session = openSession(cu);
        if (!sale.cashierSessionId().equals(session.id())) {
            throw new ApiException(ErrorCode.SALE_NOT_EDITABLE, "Transaksi ini milik cashier session lain");
        }
        return move(saleId, "HELD", "DRAFT", "SALE_RESUMED");
    }

    /** Kunci keranjang, validasi diskon/approval/stok di database, dan beri nomor struk (§15, §31). */
    @Transactional
    public SaleView checkout(UUID saleId) {
        CurrentUser cu = requireEmployee();
        SaleView sale = editable(cu, saleId);
        if (sale.lineCount() == 0) {
            throw new ApiException(ErrorCode.SALE_EMPTY);
        }
        recalc(saleId);
        if (!repo.transition(saleId, "DRAFT", "CHECKOUT")) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        SaleView after = repo.findById(saleId).orElseThrow();
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("status", after.status());
        v.put("receiptNo", after.receiptNo());
        v.put("grandTotal", after.grandTotal());
        v.put("discountTotal", after.discountTotal());
        v.put("lineCount", after.lineCount());
        audit.record(AuditEvent.of("SALE_CHECKOUT", "SALE", saleId).outlet(after.outletId())
                .change(Map.of("status", sale.status()), v));
        return after;
    }

    /** Kembali ke keranjang sebelum pembayaran (nomor struk tetap milik transaksi ini). */
    @Transactional
    public SaleView reopen(UUID saleId) {
        return move(saleId, "CHECKOUT", "DRAFT", "SALE_REOPENED");
    }

    @Transactional
    public SaleView cancel(UUID saleId) {
        CurrentUser cu = requireEmployee();
        SaleView sale = own(cu, saleId);
        if (sale.lineCount() > 0) {
            throw new ApiException(ErrorCode.SALE_NOT_EMPTY);
        }
        return move(saleId, sale.status(), "CANCELLED", "SALE_CANCELLED");
    }

    @Transactional
    public SaleView voidSale(UUID saleId, String reason, UUID approvalId) {
        CurrentUser cu = requireEmployee();
        SaleView sale = own(cu, saleId);
        if (!List.of("DRAFT", "HELD", "CHECKOUT").contains(sale.status())) {
            throw new ApiException(ErrorCode.SALE_NOT_EDITABLE);
        }
        openSession(cu);
        UUID approvedBy = null;
        UUID used = null;
        if ("CHECKOUT".equals(sale.status()) && repo.settings(sale.outletId()).requireVoidApproval()) {
            UsedApproval a = useApproval(approvalId, "VOID_SALE", saleId);
            approvedBy = a.approvedBy();
            used = a.id();
        }
        String why = reason.trim();
        if (!repo.voidSale(saleId, sale.status(), why, used, approvedBy)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        SaleView after = repo.findById(saleId).orElseThrow();
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("status", "VOID");
        v.put("receiptNo", after.receiptNo());
        v.put("grandTotal", after.grandTotal());
        v.put("approvedBy", approvedBy);
        audit.record(AuditEvent.of("SALE_VOIDED", "SALE", saleId).outlet(sale.outletId())
                .change(Map.of("status", sale.status()), v).reason(why));
        return after;
    }

    // ------------------------------------------------------------------ approval

    /**
     * Membuat approval sekali pakai setelah backend memverifikasi password approver
     * ({@code authUserId}). Database memvalidasi izin & tingkat approver di outlet transaksi.
     */
    @Transactional
    public ApprovalView createApproval(UUID authUserId, ApprovalRequest req) {
        CurrentUser cu = requireEmployee();
        SaleView sale = own(cu, req.saleId());
        SaleRepository.Approver approver = repo.approver(authUserId)
                .orElseThrow(() -> new ApiException(ErrorCode.APPROVER_INVALID));
        if (approver.userId().equals(cu.userId())) {
            throw new ApiException(ErrorCode.APPROVER_INVALID, "Persetujuan harus dari user lain (bukan Anda sendiri)");
        }
        BigDecimal percent = null;
        BigDecimal price = null;
        UUID itemId = req.saleItemId();
        switch (req.action()) {
            case DISCOUNT -> {
                if (req.discountType() == null || req.discountValue() == null) {
                    throw ApiException.validation("Jenis dan nilai diskon wajib diisi");
                }
                validateDiscountValue(req.discountType(), req.discountValue());
                Proposed p = propose(sale.id(), itemId, req.discountType(), req.discountValue());
                percent = p.percent().max(new BigDecimal("0.001"));
                itemId = null;  // approval diskon berlaku untuk transaksi; batasnya persen
            }
            case PRICE_OVERRIDE -> {
                if (itemId == null || req.price() == null) {
                    throw ApiException.validation("Baris dan harga baru wajib diisi");
                }
                requireWholeRupiah(req.price());
                activeItem(sale.id(), itemId);
                price = req.price();
            }
            case VOID_SALE -> itemId = null;
            default -> throw ApiException.validation("Jenis approval tidak dikenal");
        }
        UUID id = repo.insertApproval(sale.id(), itemId, req.action().name(), percent, price, approver.userId());
        Map<String, Object> v = new LinkedHashMap<>();
        v.put("approvalId", id);
        v.put("action", req.action().name());
        v.put("approver", approver.username());
        v.put("percent", percent);
        v.put("price", price);
        audit.record(AuditEvent.of("APPROVAL", "SALE", sale.id()).outlet(sale.outletId()).change(null, v));
        return new ApprovalView(id, req.action().name(), approver.displayName(), percent,
                repo.approvalExpiry(id).orElse(null));
    }

    // ------------------------------------------------------------------ struk

    @Transactional(readOnly = true)
    public ReceiptView receipt(UUID saleId) {
        access.currentUser();
        ReceiptView r = repo.receipt(saleId).orElseThrow(() -> new ApiException(ErrorCode.SALE_NOT_FOUND));
        if (r.receiptNo() == null) {
            throw new ApiException(ErrorCode.RECEIPT_NOT_AVAILABLE);
        }
        return r;
    }

    /** Catat cetak struk. Cetak ulang tidak membuat transaksi baru (§30), hanya menambah hitungan & audit. */
    @Transactional
    public PrintResult recordPrint(UUID saleId) {
        access.currentUser();
        SaleView sale = repo.findById(saleId).orElseThrow(() -> new ApiException(ErrorCode.SALE_NOT_FOUND));
        int count = repo.recordPrint(saleId);
        boolean reprint = count > 1;
        audit.record(AuditEvent.of(reprint ? "RECEIPT_REPRINT" : "RECEIPT_PRINT", "SALE", saleId)
                .outlet(sale.outletId()).change(null, Map.of("receiptNo", sale.receiptNo(), "printCount", count)));
        return new PrintResult(count, reprint);
    }

    // ------------------------------------------------------------------ helpers

    private record Proposed(BigDecimal amount, BigDecimal base, BigDecimal percent) {
    }

    /** Nilai & persentase diskon yang diusulkan terhadap isi keranjang saat ini. */
    private Proposed propose(UUID saleId, UUID itemId, CartCalculator.Type type, BigDecimal value) {
        List<Line> lines = repo.activeLines(saleId);
        List<Discount> discounts = new ArrayList<>(repo.activeDiscounts(saleId).stream()
                .filter(d -> !java.util.Objects.equals(d.lineId(), itemId)).toList());
        UUID probe = UUID.randomUUID();
        discounts.add(new Discount(probe, itemId, type, value));
        CartCalculator.Result r = CartCalculator.calculate(lines, discounts);
        BigDecimal amount = r.discountAmounts().getOrDefault(probe, BigDecimal.ZERO);
        BigDecimal base;
        if (itemId != null) {
            base = lines.stream().filter(l -> l.id().equals(itemId)).map(Line::gross).findFirst()
                    .orElseThrow(() -> new ApiException(ErrorCode.SALE_NOT_EDITABLE, "Baris tidak aktif"));
        } else {
            base = BigDecimal.ZERO;
            for (CartCalculator.LineResult lr : r.lines()) {
                BigDecimal gross = lines.stream().filter(l -> l.id().equals(lr.id())).findFirst().orElseThrow().gross();
                base = base.add(gross.subtract(lr.itemDiscount()));
            }
        }
        BigDecimal percent = type == CartCalculator.Type.PERCENTAGE ? value : CartCalculator.percentOf(amount, base);
        return new Proposed(amount, base, percent);
    }

    private void recalc(UUID saleId) {
        repo.writeAllocation(CartCalculator.calculate(repo.activeLines(saleId), repo.activeDiscounts(saleId)));
    }

    private SaleView move(UUID saleId, String from, String to, String auditAction) {
        CurrentUser cu = requireEmployee();
        SaleView sale = own(cu, saleId);
        if (!from.equals(sale.status())) {
            throw new ApiException(ErrorCode.SALE_NOT_EDITABLE,
                    "Transaksi berstatus " + sale.status() + ", tidak bisa diproses");
        }
        openSession(cu);
        if (!repo.transition(saleId, from, to)) {
            throw new ApiException(ErrorCode.CONCURRENT_MODIFICATION);
        }
        SaleView after = repo.findById(saleId).orElseThrow();
        audit.record(AuditEvent.of(auditAction, "SALE", saleId).outlet(sale.outletId())
                .change(Map.of("status", from), Map.of("status", to)));
        return after;
    }

    private UsedApproval useApproval(UUID approvalId, String action, UUID saleId) {
        if (approvalId == null) {
            throw new ApiException(ErrorCode.APPROVAL_REQUIRED);
        }
        UsedApproval a = repo.useApproval(approvalId)
                .orElseThrow(() -> new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan tidak valid atau sudah dipakai"));
        if (!action.equals(a.action()) || !saleId.equals(a.saleId())) {
            throw new ApiException(ErrorCode.APPROVAL_REQUIRED, "Persetujuan untuk tindakan lain");
        }
        return a;
    }

    private CurrentUser requireEmployee() {
        CurrentUser cu = access.currentUser();
        if (cu.employeeId() == null) {
            throw new ApiException(ErrorCode.EMPLOYEE_NOT_LINKED);
        }
        return cu;
    }

    private SessionView openSession(CurrentUser cu) {
        SessionView s = cashier.findActiveForEmployee(cu.employeeId())
                .orElseThrow(() -> new ApiException(ErrorCode.CASHIER_SESSION_REQUIRED));
        if ("ON_BREAK".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_LOCKED);
        }
        if (!"OPEN".equals(s.status())) {
            throw new ApiException(ErrorCode.CASHIER_SESSION_REQUIRED);
        }
        return s;
    }

    private SaleView own(CurrentUser cu, UUID saleId) {
        SaleView s = repo.findById(saleId).orElseThrow(() -> new ApiException(ErrorCode.SALE_NOT_FOUND));
        if (!s.employeeId().equals(cu.employeeId())) {
            throw ApiException.forbidden();
        }
        if ("VOID".equals(s.status()) || "CANCELLED".equals(s.status())) {
            throw new ApiException(ErrorCode.SALE_CLOSED);
        }
        return s;
    }

    private SaleView editable(CurrentUser cu, UUID saleId) {
        SaleView s = own(cu, saleId);
        if (!"DRAFT".equals(s.status())) {
            throw new ApiException(ErrorCode.SALE_NOT_EDITABLE,
                    "HELD".equals(s.status()) ? "Lanjutkan transaksi yang ditahan terlebih dahulu"
                            : "Transaksi sudah checkout; kembali ke keranjang untuk mengubah");
        }
        openSession(cu);
        return s;
    }

    private SaleItemView activeItem(UUID saleId, UUID itemId) {
        return repo.item(saleId, itemId).filter(i -> "ACTIVE".equals(i.status()))
                .orElseThrow(() -> new ApiException(ErrorCode.SALE_NOT_EDITABLE, "Baris tidak ditemukan atau sudah di-void"));
    }

    private void checkStock(SaleView sale, UUID productId, BigDecimal totalQty) {
        SaleRepository.Availability a = repo.availability(productId, sale.outletId());
        if (a.allowNegative()) {
            return;
        }
        if (a.available() == null || a.available().compareTo(totalQty) < 0) {
            throw new ApiException(ErrorCode.STOCK_UNAVAILABLE, "Stok " + a.sku() + " tidak mencukupi (tersedia "
                    + (a.available() == null ? "tidak diketahui" : a.available().stripTrailingZeros().toPlainString())
                    + ")");
        }
    }

    private static void checkQuantity(boolean allowDecimal, BigDecimal qty) {
        if (!allowDecimal && qty.stripTrailingZeros().scale() > 0) {
            throw new ApiException(ErrorCode.QUANTITY_INVALID, "Produk ini dijual per satuan utuh");
        }
        if (qty.stripTrailingZeros().scale() > 3) {
            throw new ApiException(ErrorCode.QUANTITY_INVALID, "Maksimal 3 angka desimal");
        }
    }

    private static void requireWholeRupiah(BigDecimal amount) {
        if (amount.stripTrailingZeros().scale() > 0) {
            throw ApiException.validation("Nilai harus rupiah bulat");
        }
    }

    private static void validateDiscountValue(CartCalculator.Type type, BigDecimal value) {
        if (type == CartCalculator.Type.PERCENTAGE && value.compareTo(BigDecimal.valueOf(100)) > 0) {
            throw ApiException.validation("Diskon persen maksimal 100");
        }
        if (type == CartCalculator.Type.PERCENTAGE && value.stripTrailingZeros().scale() > 2) {
            throw ApiException.validation("Diskon persen maksimal 2 angka desimal");
        }
        if (type == CartCalculator.Type.AMOUNT) {
            requireWholeRupiah(value);
        }
    }

    private static Map<String, Object> lineSummary(SaleItemView i) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("line", i.lineNo());
        m.put("sku", i.sku());
        m.put("quantity", i.quantity());
        m.put("unitPrice", i.unitPrice());
        m.put("netAmount", i.netAmount());
        return m;
    }
}
