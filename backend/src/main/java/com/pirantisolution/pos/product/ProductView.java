package com.pirantisolution.pos.product;

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
        String categoryName,
        String uom,
        boolean allowDecimalQty,
        String barcode,
        BigDecimal price,
        Integer priceVersion,
        BigDecimal taxRate,
        BigDecimal available,
        boolean allowNegativeStock) {
}
