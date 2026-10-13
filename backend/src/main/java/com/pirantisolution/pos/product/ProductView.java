package com.pirantisolution.pos.product;

import com.fasterxml.jackson.annotation.JsonRawValue;
import java.math.BigDecimal;
import java.util.UUID;

/**
 * Produk siap jual di satu outlet: harga berlaku & stok tersedia dihitung database
 * ({@code pos.product_price}, {@code pos.available_to_sell}). {@code available} null = stok tidak diketahui.
 */
public record ProductView(
        UUID id,
        String sku,
        String name,
        UUID categoryId,
        String categoryName,
        String imageUrl,
        String uom,
        boolean allowDecimalQty,
        String barcode,
        BigDecimal price,
        Integer priceVersion,
        BigDecimal taxRate,
        BigDecimal available,
        boolean allowNegativeStock,
        boolean trackStock,
        /** Grup opsi (JSON): [{id,name,minSelect,maxSelect,options:[{id,name,priceDelta}]}] */
        @JsonRawValue String optionGroups) {
}
