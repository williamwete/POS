package com.pirantisolution.pos.product;

import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
public class ProductRepository {

    private static final String SELECT = """
            SELECT p.id, p.sku, p.name, c.name AS category_name, p.uom, p.allow_decimal_qty,
                   (SELECT b.barcode FROM pos.product_barcodes b
                    WHERE b.product_id = p.id AND b.active ORDER BY b.is_primary DESC, b.barcode LIMIT 1) AS barcode,
                   pr.price, pr.version AS price_version, coalesce(t.rate, 0) AS tax_rate,
                   pos.available_to_sell(p.id, :outlet) AS available,
                   coalesce(p.allow_negative_stock, (pos.get_setting('allow_negative_stock', :outlet))::boolean, false)
                       AS allow_negative_stock
            FROM pos.products p
            LEFT JOIN pos.product_categories c ON c.id = p.category_id
            LEFT JOIN pos.tax_rates t ON t.id = p.tax_rate_id AND t.active
            LEFT JOIN LATERAL pos.product_price(p.id, :outlet, now()) pr ON true
            """;

    private final JdbcClient jdbc;

    public ProductRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Cari berdasarkan SKU/barcode persis atau awal nama/SKU (tanpa wildcard dari user). */
    public List<ProductView> search(UUID outletId, String query, int limit) {
        String q = query == null ? "" : query.trim().toLowerCase();
        String prefix = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%";
        return jdbc.sql(SELECT + """
                WHERE p.active AND p.organization_id = pos.current_org_id()
                  AND (:q = ''
                       OR lower(p.sku) = :q
                       OR EXISTS (SELECT 1 FROM pos.product_barcodes b WHERE b.product_id = p.id AND b.active
                                  AND b.barcode = :raw)
                       OR lower(p.name) LIKE :prefix
                       OR lower(p.name) LIKE '% ' || :prefix
                       OR lower(p.sku) LIKE :prefix)
                ORDER BY (lower(p.sku) = :q) DESC, p.name
                LIMIT :limit
                """)
                .param("outlet", outletId).param("q", q).param("raw", query == null ? "" : query.trim())
                .param("prefix", prefix).param("limit", limit)
                .query(ProductView.class).list();
    }

    public Optional<ProductView> byBarcode(UUID outletId, String barcode) {
        return jdbc.sql(SELECT + """
                JOIN pos.product_barcodes b ON b.product_id = p.id AND b.active AND b.barcode = :barcode
                WHERE p.organization_id = pos.current_org_id()
                """)
                .param("outlet", outletId).param("barcode", barcode)
                .query(ProductView.class).optional();
    }

    public Optional<ProductView> byId(UUID outletId, UUID productId) {
        return jdbc.sql(SELECT + " WHERE p.id = :id AND p.organization_id = pos.current_org_id()")
                .param("outlet", outletId).param("id", productId)
                .query(ProductView.class).optional();
    }
}
