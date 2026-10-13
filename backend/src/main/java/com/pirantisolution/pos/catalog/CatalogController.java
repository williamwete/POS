package com.pirantisolution.pos.catalog;

import com.pirantisolution.pos.catalog.CatalogDtos.CategoryRow;
import com.pirantisolution.pos.catalog.CatalogDtos.DiscountPresetRow;
import com.pirantisolution.pos.catalog.CatalogDtos.OptionGroupRow;
import com.pirantisolution.pos.catalog.CatalogDtos.ProductOptionsRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.ProductRow;
import com.pirantisolution.pos.catalog.CatalogDtos.ReceiptProfileRow;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveCategoryRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveDiscountPresetRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveOptionGroupRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveOptionRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveProductRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveReceiptProfileRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveTaxRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.StockRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.TaxRow;
import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class CatalogController {

    private final CatalogService service;

    public CatalogController(CatalogService service) {
        this.service = service;
    }

    // ------------------------------------------------------------ produk
    @GetMapping("/api/catalog/products")
    public ResponseEntity<ApiResponse<List<ProductRow>>> products(@RequestParam(required = false) String q,
            @RequestParam(required = false) UUID categoryId, @RequestParam(defaultValue = "false") boolean includeInactive,
            @RequestParam(required = false) UUID outletId, @RequestParam(required = false) Integer limit) {
        return Responses.ok(service.products(q, categoryId, includeInactive, outletId, limit));
    }

    @PostMapping("/api/catalog/products")
    public ResponseEntity<ApiResponse<ProductRow>> createProduct(@Valid @RequestBody SaveProductRequest req) {
        return Responses.created(service.saveProduct(null, req), "Produk dibuat");
    }

    @PutMapping("/api/catalog/products/{id}")
    public ResponseEntity<ApiResponse<ProductRow>> updateProduct(@PathVariable UUID id,
            @Valid @RequestBody SaveProductRequest req) {
        return Responses.ok(service.saveProduct(id, req), "Produk disimpan");
    }

    @PostMapping("/api/catalog/products/import")
    public ResponseEntity<ApiResponse<CatalogDtos.ImportResult>> importProducts(
            @Valid @RequestBody CatalogDtos.ImportProductsRequest req) {
        return Responses.ok(service.importProducts(req), "Impor selesai");
    }

    @PutMapping("/api/catalog/products/{id}/stock")
    public ResponseEntity<ApiResponse<ProductRow>> setStock(@PathVariable UUID id, @Valid @RequestBody StockRequest req) {
        return Responses.ok(service.setStock(id, req.outletId(), req.quantity()), "Stok disimpan");
    }

    @PutMapping("/api/catalog/products/{id}/options")
    public ResponseEntity<ApiResponse<ProductRow>> setOptions(@PathVariable UUID id,
            @Valid @RequestBody ProductOptionsRequest req) {
        return Responses.ok(service.setOptions(id, req.groupIds()), "Opsi produk disimpan");
    }

    // ------------------------------------------------------------ kategori & pajak
    @GetMapping("/api/catalog/categories")
    public ResponseEntity<ApiResponse<List<CategoryRow>>> categories() {
        return Responses.ok(service.categories());
    }

    @PostMapping("/api/catalog/categories")
    public ResponseEntity<ApiResponse<CategoryRow>> createCategory(@Valid @RequestBody SaveCategoryRequest req) {
        return Responses.created(service.saveCategory(null, req), "Kategori dibuat");
    }

    @PutMapping("/api/catalog/categories/{id}")
    public ResponseEntity<ApiResponse<CategoryRow>> updateCategory(@PathVariable UUID id,
            @Valid @RequestBody SaveCategoryRequest req) {
        return Responses.ok(service.saveCategory(id, req), "Kategori disimpan");
    }

    @GetMapping("/api/catalog/tax-rates")
    public ResponseEntity<ApiResponse<List<TaxRow>>> taxRates() {
        return Responses.ok(service.taxRates());
    }

    @PostMapping("/api/catalog/tax-rates")
    public ResponseEntity<ApiResponse<TaxRow>> createTax(@Valid @RequestBody SaveTaxRequest req) {
        return Responses.created(service.saveTax(null, req), "Pajak dibuat");
    }

    @PutMapping("/api/catalog/tax-rates/{id}")
    public ResponseEntity<ApiResponse<TaxRow>> updateTax(@PathVariable UUID id, @Valid @RequestBody SaveTaxRequest req) {
        return Responses.ok(service.saveTax(id, req), "Pajak disimpan");
    }

    // ------------------------------------------------------------ opsi produk
    @GetMapping("/api/catalog/option-groups")
    public ResponseEntity<ApiResponse<List<OptionGroupRow>>> optionGroups() {
        return Responses.ok(service.optionGroups());
    }

    @PostMapping("/api/catalog/option-groups")
    public ResponseEntity<ApiResponse<List<OptionGroupRow>>> createGroup(@Valid @RequestBody SaveOptionGroupRequest req) {
        return Responses.created(service.saveOptionGroup(null, req), "Grup opsi dibuat");
    }

    @PutMapping("/api/catalog/option-groups/{id}")
    public ResponseEntity<ApiResponse<List<OptionGroupRow>>> updateGroup(@PathVariable UUID id,
            @Valid @RequestBody SaveOptionGroupRequest req) {
        return Responses.ok(service.saveOptionGroup(id, req), "Grup opsi disimpan");
    }

    @PostMapping("/api/catalog/option-groups/{groupId}/options")
    public ResponseEntity<ApiResponse<List<OptionGroupRow>>> createOption(@PathVariable UUID groupId,
            @Valid @RequestBody SaveOptionRequest req) {
        return Responses.created(service.saveOption(null, groupId, req), "Opsi dibuat");
    }

    @PutMapping("/api/catalog/option-groups/{groupId}/options/{id}")
    public ResponseEntity<ApiResponse<List<OptionGroupRow>>> updateOption(@PathVariable UUID groupId,
            @PathVariable UUID id, @Valid @RequestBody SaveOptionRequest req) {
        return Responses.ok(service.saveOption(id, groupId, req), "Opsi disimpan");
    }

    // ------------------------------------------------------------ diskon & struk
    @GetMapping("/api/discount-presets")
    public ResponseEntity<ApiResponse<List<DiscountPresetRow>>> discountPresets(@RequestParam(required = false) UUID outletId,
            @RequestParam(defaultValue = "false") boolean includeInactive) {
        return Responses.ok(service.discountPresets(outletId, includeInactive));
    }

    @PostMapping("/api/discount-presets")
    public ResponseEntity<ApiResponse<DiscountPresetRow>> createPreset(@Valid @RequestBody SaveDiscountPresetRequest req) {
        return Responses.created(service.saveDiscountPreset(null, req), "Diskon dibuat");
    }

    @PutMapping("/api/discount-presets/{id}")
    public ResponseEntity<ApiResponse<DiscountPresetRow>> updatePreset(@PathVariable UUID id,
            @Valid @RequestBody SaveDiscountPresetRequest req) {
        return Responses.ok(service.saveDiscountPreset(id, req), "Diskon disimpan");
    }

    @GetMapping("/api/receipt-profile")
    public ResponseEntity<ApiResponse<ReceiptProfileRow>> receiptProfile(@RequestParam UUID outletId) {
        return Responses.ok(service.effectiveReceiptProfile(outletId));
    }

    @GetMapping("/api/catalog/receipt-profiles")
    public ResponseEntity<ApiResponse<List<ReceiptProfileRow>>> receiptProfiles() {
        return Responses.ok(service.receiptProfiles());
    }

    @PutMapping("/api/catalog/receipt-profiles")
    public ResponseEntity<ApiResponse<List<ReceiptProfileRow>>> saveReceiptProfile(
            @Valid @RequestBody SaveReceiptProfileRequest req) {
        return Responses.ok(service.saveReceiptProfile(req), "Pengaturan struk disimpan");
    }
}
