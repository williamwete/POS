package com.pirantisolution.pos.sale;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.idempotency.IdempotencyService;
import com.pirantisolution.pos.sale.SaleDtos.AddItemRequest;
import com.pirantisolution.pos.sale.SaleDtos.ApprovalRequest;
import com.pirantisolution.pos.sale.SaleDtos.ApprovalView;
import com.pirantisolution.pos.sale.SaleDtos.CreateSaleRequest;
import com.pirantisolution.pos.sale.SaleDtos.DiscountRequest;
import com.pirantisolution.pos.sale.SaleDtos.PriceRequest;
import com.pirantisolution.pos.sale.SaleDtos.QuantityRequest;
import com.pirantisolution.pos.sale.SaleDtos.ReceiptView;
import com.pirantisolution.pos.sale.SaleDtos.SaleView;
import com.pirantisolution.pos.sale.SaleDtos.VoidItemRequest;
import com.pirantisolution.pos.sale.SaleDtos.VoidSaleRequest;
import jakarta.validation.Valid;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Penjualan (§61). Semua POST yang mengubah transaksi mendukung Idempotency-Key (§62). */
@RestController
public class SaleController {

    private static final String BASE = "/api/sales";

    private final SaleService service;
    private final ApprovalService approvals;
    private final IdempotencyService idempotency;

    public SaleController(SaleService service, ApprovalService approvals, IdempotencyService idempotency) {
        this.service = service;
        this.approvals = approvals;
        this.idempotency = idempotency;
    }

    private ResponseEntity<?> idem(String key, String path, Object body, Supplier<? extends ResponseEntity<?>> action) {
        return idempotency.execute(key, "POST", path, body == null ? Map.of() : body, action);
    }

    /** Transaksi aktif (DRAFT/CHECKOUT) di cashier session milik user; null bila tidak ada. */
    @GetMapping(BASE + "/current")
    public ResponseEntity<ApiResponse<SaleView>> current() {
        return Responses.ok(service.current().orElse(null));
    }

    @GetMapping(BASE + "/held")
    public ResponseEntity<ApiResponse<List<SaleView>>> held() {
        return Responses.ok(service.held());
    }

    @GetMapping(BASE)
    public ResponseEntity<ApiResponse<List<SaleView>>> outlet(@RequestParam UUID outletId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate businessDate,
            @RequestParam(required = false) String status) {
        return Responses.ok(service.outletSales(outletId, businessDate, status));
    }

    @PostMapping(BASE)
    public ResponseEntity<?> create(@Valid @RequestBody CreateSaleRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE, req, () -> Responses.created(service.create(req.clientTransactionId(), req.note()),
                "Transaksi dibuat"));
    }

    @GetMapping(BASE + "/{id}")
    public ResponseEntity<ApiResponse<SaleView>> get(@PathVariable UUID id) {
        return Responses.ok(service.get(id));
    }

    @PostMapping(BASE + "/{id}/items")
    public ResponseEntity<?> addItem(@PathVariable UUID id, @Valid @RequestBody AddItemRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/items", req, () -> Responses.ok(service.addItem(id, req)));
    }

    @PostMapping(BASE + "/{id}/items/{itemId}/quantity")
    public ResponseEntity<?> quantity(@PathVariable UUID id, @PathVariable UUID itemId,
            @Valid @RequestBody QuantityRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/items/" + itemId + "/quantity", req,
                () -> Responses.ok(service.setQuantity(id, itemId, req.quantity())));
    }

    @PostMapping(BASE + "/{id}/items/{itemId}/void")
    public ResponseEntity<?> voidItem(@PathVariable UUID id, @PathVariable UUID itemId,
            @Valid @RequestBody VoidItemRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/items/" + itemId + "/void", req,
                () -> Responses.ok(service.voidItem(id, itemId, req.reason()), "Barang dibatalkan"));
    }

    @PostMapping(BASE + "/{id}/items/{itemId}/price")
    public ResponseEntity<?> price(@PathVariable UUID id, @PathVariable UUID itemId,
            @Valid @RequestBody PriceRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/items/" + itemId + "/price", req,
                () -> Responses.ok(service.overridePrice(id, itemId, req.unitPrice(), req.reason(), req.approvalId()),
                        "Harga diubah"));
    }

    @PostMapping(BASE + "/{id}/discounts")
    public ResponseEntity<?> discount(@PathVariable UUID id, @Valid @RequestBody DiscountRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/discounts", req,
                () -> Responses.ok(service.addDiscount(id, req), "Diskon diterapkan"));
    }

    @PostMapping(BASE + "/{id}/discounts/{discountId}/remove")
    public ResponseEntity<?> removeDiscount(@PathVariable UUID id, @PathVariable UUID discountId,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/discounts/" + discountId + "/remove", null,
                () -> Responses.ok(service.removeDiscount(id, discountId), "Diskon dihapus"));
    }

    @PostMapping(BASE + "/{id}/hold")
    public ResponseEntity<?> hold(@PathVariable UUID id,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/hold", null, () -> Responses.ok(service.hold(id), "Transaksi ditahan"));
    }

    @PostMapping(BASE + "/{id}/resume")
    public ResponseEntity<?> resume(@PathVariable UUID id,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/resume", null,
                () -> Responses.ok(service.resume(id), "Transaksi dilanjutkan"));
    }

    @PostMapping(BASE + "/{id}/checkout")
    public ResponseEntity<?> checkout(@PathVariable UUID id,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/checkout", null,
                () -> Responses.ok(service.checkout(id), "Checkout berhasil"));
    }

    @PostMapping(BASE + "/{id}/reopen")
    public ResponseEntity<?> reopen(@PathVariable UUID id,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/reopen", null,
                () -> Responses.ok(service.reopen(id), "Kembali ke keranjang"));
    }

    @PostMapping(BASE + "/{id}/cancel")
    public ResponseEntity<?> cancel(@PathVariable UUID id,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/cancel", null,
                () -> Responses.ok(service.cancel(id), "Transaksi dibatalkan"));
    }

    @PostMapping(BASE + "/{id}/void")
    public ResponseEntity<?> voidSale(@PathVariable UUID id, @Valid @RequestBody VoidSaleRequest req,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/void", req,
                () -> Responses.ok(service.voidSale(id, req.reason(), req.approvalId()), "Transaksi di-void"));
    }

    @GetMapping(BASE + "/{id}/receipt")
    public ResponseEntity<ApiResponse<ReceiptView>> receipt(@PathVariable UUID id) {
        return Responses.ok(service.receipt(id));
    }

    @PostMapping(BASE + "/{id}/receipt/print")
    public ResponseEntity<?> print(@PathVariable UUID id,
            @RequestHeader(name = IdempotencyService.HEADER, required = false) String key) {
        return idem(key, BASE + "/" + id + "/receipt/print", null, () -> Responses.ok(service.recordPrint(id)));
    }

    /** Approval supervisor (rate limit seperti login). Tidak memakai idempotency: password tidak di-hash/disimpan. */
    @PostMapping("/api/approvals")
    public ResponseEntity<ApiResponse<ApprovalView>> approve(@Valid @RequestBody ApprovalRequest req) {
        return Responses.created(approvals.request(req), "Disetujui");
    }
}
