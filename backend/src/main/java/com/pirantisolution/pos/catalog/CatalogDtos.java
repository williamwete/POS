package com.pirantisolution.pos.catalog;

import com.fasterxml.jackson.annotation.JsonRawValue;
import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** DTO katalog lokal (produk, kategori, pajak, opsi, diskon, struk). */
public final class CatalogDtos {

    private CatalogDtos() {
    }

    // ------------------------------------------------------------ views

    public record ProductRow(UUID id, String sku, String name, UUID categoryId, String categoryName, String uom,
            boolean allowDecimalQty, UUID taxRateId, String taxName, BigDecimal taxRate, boolean trackStock,
            boolean active, String source, String imageUrl, String barcode, BigDecimal price,
            BigDecimal available, @JsonRawValue String optionGroupIds) {
    }

    public record CategoryRow(UUID id, String code, String name, boolean active, String source, int productCount) {
    }

    public record TaxRow(UUID id, String code, String name, BigDecimal rate, boolean active, String source) {
    }

    public record OptionGroupRow(UUID id, String name, int minSelect, int maxSelect, int sortOrder, boolean active,
            @JsonRawValue String options) {
    }

    public record DiscountPresetRow(UUID id, UUID outletId, String name, String discountType,
            BigDecimal discountValue, boolean active) {
    }

    public record ReceiptProfileRow(UUID id, UUID outletId, String businessName, String address, String phone,
            String headerText, String footerText, String taxId, boolean showTaxDetail, boolean showCashier,
            int paperWidthMm) {
    }

    // ------------------------------------------------------------ requests

    public record SaveProductRequest(
            @NotBlank @Size(max = 40) String sku,
            @NotBlank @Size(max = 120) String name,
            UUID categoryId,
            @NotBlank @Size(max = 12) String uom,
            Boolean allowDecimalQty,
            UUID taxRateId,
            Boolean trackStock,
            Boolean active,
            @Size(max = 60000) String imageUrl,
            /** null = tidak diubah, "" = hapus barcode utama */
            @Size(max = 64) String barcode,
            /** null = tidak diubah (wajib untuk produk baru) */
            @DecimalMin("0") @DecimalMax("1000000000") BigDecimal price) {
    }

    public record ImportProductRow(
            @Size(max = 40) String sku, @Size(max = 120) String name, @Size(max = 60) String category,
            @Size(max = 12) String uom, @Size(max = 20) String price, @Size(max = 64) String barcode,
            @Size(max = 20) String stock) {
    }

    public record ImportProductsRequest(
            @jakarta.validation.constraints.NotEmpty @Size(max = 500) @jakarta.validation.Valid List<ImportProductRow> rows,
            UUID outletId) {
    }

    public record ImportResult(int created, int updated, int categoriesCreated) {
    }

    public record StockRequest(@NotNull UUID outletId, @NotNull @DecimalMin("0") @DecimalMax("100000000") BigDecimal quantity) {
    }

    public record ProductOptionsRequest(@Size(max = 20) List<UUID> groupIds) {
    }

    public record SaveCategoryRequest(@NotBlank @Size(max = 30) String code, @NotBlank @Size(max = 60) String name,
            Boolean active) {
    }

    public record SaveTaxRequest(@NotBlank @Size(max = 30) String code, @NotBlank @Size(max = 60) String name,
            @NotNull @DecimalMin("0") @DecimalMax("100") BigDecimal rate, Boolean active) {
    }

    public record SaveOptionGroupRequest(@NotBlank @Size(max = 60) String name, Integer minSelect, Integer maxSelect,
            Integer sortOrder, Boolean active) {
    }

    public record SaveOptionRequest(@NotBlank @Size(max = 60) String name,
            @NotNull @DecimalMin("0") @DecimalMax("100000000") BigDecimal priceDelta, Integer sortOrder,
            Boolean active) {
    }

    public record SaveDiscountPresetRequest(UUID outletId, @NotBlank @Size(max = 60) String name,
            @NotBlank String discountType, @NotNull @DecimalMin("0.01") @DecimalMax("1000000000") BigDecimal discountValue,
            Boolean active) {
    }

    public record SaveReceiptProfileRequest(UUID outletId, @Size(max = 80) String businessName,
            @Size(max = 200) String address, @Size(max = 30) String phone, @Size(max = 200) String headerText,
            @Size(max = 200) String footerText, @Size(max = 40) String taxId, Boolean showTaxDetail,
            Boolean showCashier, Integer paperWidthMm) {
    }

    public record IdResponse(UUID id) {
    }
}
