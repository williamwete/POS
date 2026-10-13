package com.pirantisolution.pos.catalog;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.catalog.CatalogDtos.CategoryRow;
import com.pirantisolution.pos.catalog.CatalogDtos.DiscountPresetRow;
import com.pirantisolution.pos.catalog.CatalogDtos.OptionGroupRow;
import com.pirantisolution.pos.catalog.CatalogDtos.ProductRow;
import com.pirantisolution.pos.catalog.CatalogDtos.ReceiptProfileRow;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveCategoryRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveDiscountPresetRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveOptionGroupRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveOptionRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveProductRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveReceiptProfileRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.SaveTaxRequest;
import com.pirantisolution.pos.catalog.CatalogDtos.TaxRow;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.security.AccessService;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Katalog lokal untuk merchant tanpa ERP. Izin diperiksa oleh fungsi database (product.manage,
 * category.manage, discount.manage, receipt.manage); service ini menambah audit dan validasi bentuk.
 */
@Service
public class CatalogService {

    private final CatalogRepository repo;
    private final AccessService access;
    private final AuditService audit;
    private final com.fasterxml.jackson.databind.ObjectMapper mapper;

    public CatalogService(CatalogRepository repo, AccessService access, AuditService audit,
            com.fasterxml.jackson.databind.ObjectMapper mapper) {
        this.mapper = mapper;
        this.repo = repo;
        this.access = access;
        this.audit = audit;
    }

    // ------------------------------------------------------------ produk
    @Transactional(readOnly = true)
    public List<ProductRow> products(String q, UUID categoryId, boolean includeInactive, UUID outletId, Integer limit) {
        access.currentUser();
        if (outletId != null) {
            access.requireOutletAccess(outletId);
        }
        if (q != null && q.length() > 80) {
            throw ApiException.validation("Kata kunci terlalu panjang");
        }
        return repo.products(q, categoryId, includeInactive, outletId, limit == null ? 200 : Math.max(1, Math.min(limit, 500)));
    }

    @Transactional
    public ProductRow saveProduct(UUID id, SaveProductRequest req) {
        access.currentUser();
        ProductRow before = id == null ? null : repo.product(id, null).orElse(null);
        UUID savedId = repo.saveProduct(id, req);
        ProductRow after = repo.product(savedId, null).orElseThrow();
        audit.record(AuditEvent.of(id == null ? "PRODUCT_CREATED" : "PRODUCT_UPDATED", "PRODUCT", savedId)
                .change(before, after));
        return after;
    }

    /** Impor massal (semua-atau-tidak-sama-sekali). Validasi per baris dilakukan database. */
    @Transactional
    public CatalogDtos.ImportResult importProducts(CatalogDtos.ImportProductsRequest req) {
        access.currentUser();
        try {
            String json = repo.importProducts(mapper.writeValueAsString(req.rows()), req.outletId());
            return mapper.readValue(json, CatalogDtos.ImportResult.class);
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            throw new IllegalStateException("Impor produk gagal diproses", e);
        }
    }

    @Transactional
    public ProductRow setStock(UUID productId, UUID outletId, BigDecimal quantity) {
        access.currentUser();
        access.requireOutletAccess(outletId);
        repo.setStock(productId, outletId, quantity);
        audit.record(AuditEvent.of("PRODUCT_STOCK_SET", "PRODUCT", productId).outlet(outletId)
                .change(null, Map.of("quantity", quantity)));
        return repo.product(productId, outletId).orElseThrow();
    }

    @Transactional
    public ProductRow setOptions(UUID productId, List<UUID> groupIds) {
        access.currentUser();
        repo.setProductOptions(productId, groupIds);
        audit.record(AuditEvent.of("PRODUCT_OPTIONS_SET", "PRODUCT", productId)
                .change(null, Map.of("groupIds", groupIds == null ? List.of() : groupIds)));
        return repo.product(productId, null).orElseThrow();
    }

    // ------------------------------------------------------------ kategori & pajak
    @Transactional(readOnly = true)
    public List<CategoryRow> categories() {
        access.currentUser();
        return repo.categories();
    }

    @Transactional
    public CategoryRow saveCategory(UUID id, SaveCategoryRequest req) {
        access.currentUser();
        UUID saved = repo.saveCategory(id, req);
        audit.record(AuditEvent.of(id == null ? "CATEGORY_CREATED" : "CATEGORY_UPDATED", "CATEGORY", saved)
                .change(null, req));
        return repo.categories().stream().filter(c -> c.id().equals(saved)).findFirst().orElseThrow();
    }

    @Transactional(readOnly = true)
    public List<TaxRow> taxRates() {
        access.currentUser();
        return repo.taxRates();
    }

    @Transactional
    public TaxRow saveTax(UUID id, SaveTaxRequest req) {
        access.currentUser();
        UUID saved = repo.saveTax(id, req);
        audit.record(AuditEvent.of(id == null ? "TAX_RATE_CREATED" : "TAX_RATE_UPDATED", "TAX_RATE", saved)
                .change(null, req));
        return repo.taxRates().stream().filter(t -> t.id().equals(saved)).findFirst().orElseThrow();
    }

    // ------------------------------------------------------------ opsi
    @Transactional(readOnly = true)
    public List<OptionGroupRow> optionGroups() {
        access.currentUser();
        return repo.optionGroups();
    }

    @Transactional
    public List<OptionGroupRow> saveOptionGroup(UUID id, SaveOptionGroupRequest req) {
        access.currentUser();
        UUID saved = repo.saveOptionGroup(id, req);
        audit.record(AuditEvent.of(id == null ? "OPTION_GROUP_CREATED" : "OPTION_GROUP_UPDATED", "OPTION_GROUP", saved)
                .change(null, req));
        return repo.optionGroups();
    }

    @Transactional
    public List<OptionGroupRow> saveOption(UUID id, UUID groupId, SaveOptionRequest req) {
        access.currentUser();
        UUID saved = repo.saveOption(id, groupId, req);
        audit.record(AuditEvent.of(id == null ? "OPTION_CREATED" : "OPTION_UPDATED", "OPTION", saved)
                .change(null, req));
        return repo.optionGroups();
    }

    // ------------------------------------------------------------ diskon & struk
    @Transactional(readOnly = true)
    public List<DiscountPresetRow> discountPresets(UUID outletId, boolean includeInactive) {
        access.currentUser();
        if (outletId != null) {
            access.requireOutletAccess(outletId);
        }
        return repo.discountPresets(outletId, includeInactive);
    }

    @Transactional
    public DiscountPresetRow saveDiscountPreset(UUID id, SaveDiscountPresetRequest req) {
        access.currentUser();
        UUID saved = repo.saveDiscountPreset(id, req);
        audit.record(AuditEvent.of(id == null ? "DISCOUNT_PRESET_CREATED" : "DISCOUNT_PRESET_UPDATED",
                "DISCOUNT_PRESET", saved).outlet(req.outletId()).change(null, req));
        return repo.discountPresets(null, true).stream().filter(d -> d.id().equals(saved)).findFirst().orElseThrow();
    }

    @Transactional(readOnly = true)
    public List<ReceiptProfileRow> receiptProfiles() {
        access.currentUser();
        return repo.receiptProfiles();
    }

    /** Profil struk yang berlaku untuk outlet (dipakai kasir saat mencetak/menampilkan struk). */
    @Transactional(readOnly = true)
    public ReceiptProfileRow effectiveReceiptProfile(UUID outletId) {
        access.requireOutletAccess(outletId);
        return repo.effectiveReceiptProfile(outletId).orElse(new ReceiptProfileRow(null, null, null, null, null,
                null, null, null, true, true, 80));
    }

    @Transactional
    public List<ReceiptProfileRow> saveReceiptProfile(SaveReceiptProfileRequest req) {
        access.currentUser();
        if (req.paperWidthMm() != null && req.paperWidthMm() != 58 && req.paperWidthMm() != 80) {
            throw new ApiException(ErrorCode.CATALOG_INVALID, "Lebar kertas harus 58 atau 80 mm");
        }
        UUID saved = repo.saveReceiptProfile(req);
        audit.record(AuditEvent.of("RECEIPT_PROFILE_SAVED", "RECEIPT_PROFILE", saved).outlet(req.outletId())
                .change(null, req));
        return repo.receiptProfiles();
    }
}
