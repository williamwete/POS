package com.pirantisolution.pos.catalog;

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
import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Akses katalog lokal. Semua tulis memanggil fungsi database (pos.save_*) yang memeriksa permission
 * dan organisasi; pembacaan tunduk pada RLS.
 */
@Repository
public class CatalogRepository {

    private static final String PRODUCT_SELECT = """
            SELECT p.id, p.sku, p.name, p.category_id, c.name AS category_name, p.uom, p.allow_decimal_qty,
                   p.tax_rate_id, t.name AS tax_name, t.rate AS tax_rate, p.track_stock, p.active, p.source, p.image_url,
                   (SELECT b.barcode FROM pos.product_barcodes b
                    WHERE b.product_id = p.id AND b.active ORDER BY b.is_primary DESC, b.barcode LIMIT 1) AS barcode,
                   pr.price,
                   CASE WHEN CAST(:outlet AS uuid) IS NULL OR NOT p.track_stock THEN NULL
                        ELSE pos.available_to_sell(p.id, CAST(:outlet AS uuid)) END AS available,
                   (SELECT coalesce(jsonb_agg(l.group_id ORDER BY l.sort_order), '[]'::jsonb)
                    FROM pos.product_option_links l WHERE l.product_id = p.id)::text AS option_group_ids
            FROM pos.products p
            LEFT JOIN pos.product_categories c ON c.id = p.category_id
            LEFT JOIN pos.tax_rates t ON t.id = p.tax_rate_id
            LEFT JOIN LATERAL pos.product_price(p.id, CAST(NULL AS uuid), now()) pr ON true
            """;

    private final JdbcClient jdbc;

    public CatalogRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    // ------------------------------------------------------------ produk
    public List<ProductRow> products(String q, UUID categoryId, boolean includeInactive, UUID outletId, int limit) {
        String term = q == null ? "" : q.trim().toLowerCase();
        String like = "%" + term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%";
        return jdbc.sql(PRODUCT_SELECT + """
                WHERE p.organization_id = pos.current_org_id()
                  AND (:inactive OR p.active)
                  AND (CAST(:cat AS uuid) IS NULL OR p.category_id = CAST(:cat AS uuid))
                  AND (:q = '' OR lower(p.name) LIKE :like OR lower(p.sku) LIKE :like
                       OR EXISTS (SELECT 1 FROM pos.product_barcodes b WHERE b.product_id = p.id AND b.active
                                  AND b.barcode = :raw))
                ORDER BY p.name
                LIMIT :limit
                """)
                .param("outlet", outletId).param("inactive", includeInactive).param("cat", categoryId)
                .param("q", term).param("like", like).param("raw", q == null ? "" : q.trim()).param("limit", limit)
                .query(ProductRow.class).list();
    }

    public Optional<ProductRow> product(UUID id, UUID outletId) {
        return jdbc.sql(PRODUCT_SELECT + " WHERE p.id = :id AND p.organization_id = pos.current_org_id()")
                .param("outlet", outletId).param("id", id).query(ProductRow.class).optional();
    }

    public UUID saveProduct(UUID id, SaveProductRequest r) {
        return jdbc.sql("""
                SELECT pos.save_product(CAST(:id AS uuid), :sku, :name, CAST(:cat AS uuid), :uom,
                       CAST(:dec AS boolean), CAST(:tax AS uuid), CAST(:track AS boolean), CAST(:active AS boolean),
                       CAST(:img AS text), CAST(:bc AS text), CAST(:price AS numeric))
                """)
                .param("id", id).param("sku", r.sku().trim()).param("name", r.name()).param("cat", r.categoryId())
                .param("uom", r.uom()).param("dec", r.allowDecimalQty()).param("tax", r.taxRateId())
                .param("track", r.trackStock()).param("active", r.active()).param("img", r.imageUrl())
                .param("bc", r.barcode()).param("price", r.price())
                .query(UUID.class).single();
    }

    public String importProducts(String rowsJson, UUID outletId) {
        return jdbc.sql("SELECT pos.import_products(CAST(:rows AS jsonb), CAST(:o AS uuid))::text")
                .param("rows", rowsJson).param("o", outletId).query(String.class).single();
    }

    public void setStock(UUID productId, UUID outletId, BigDecimal qty) {
        jdbc.sql("SELECT pos.set_local_stock(:p, :o, :q)").param("p", productId).param("o", outletId)
                .param("q", qty).query().singleRow();
    }

    public void setProductOptions(UUID productId, List<UUID> groupIds) {
        String ids = groupIds == null ? "" : groupIds.stream().map(UUID::toString)
                .collect(java.util.stream.Collectors.joining(","));
        jdbc.sql("SELECT pos.set_product_options(:p, string_to_array(:ids, ',')::uuid[])")
                .param("p", productId).param("ids", ids).query().singleRow();
    }

    // ------------------------------------------------------------ kategori & pajak
    public List<CategoryRow> categories() {
        return jdbc.sql("""
                SELECT c.id, c.code, c.name, c.active, c.source,
                       (SELECT count(*) FROM pos.products p WHERE p.category_id = c.id AND p.active)::integer AS product_count
                FROM pos.product_categories c WHERE c.organization_id = pos.current_org_id() ORDER BY c.name
                """).query(CategoryRow.class).list();
    }

    public UUID saveCategory(UUID id, SaveCategoryRequest r) {
        return jdbc.sql("SELECT pos.save_category(CAST(:id AS uuid), :code, :name, CAST(:active AS boolean))")
                .param("id", id).param("code", r.code().trim()).param("name", r.name()).param("active", r.active())
                .query(UUID.class).single();
    }

    public List<TaxRow> taxRates() {
        return jdbc.sql("""
                SELECT id, code, name, rate, active, source FROM pos.tax_rates
                WHERE organization_id = pos.current_org_id() ORDER BY rate, name
                """).query(TaxRow.class).list();
    }

    public UUID saveTax(UUID id, SaveTaxRequest r) {
        return jdbc.sql("SELECT pos.save_tax_rate(CAST(:id AS uuid), :code, :name, :rate, CAST(:active AS boolean))")
                .param("id", id).param("code", r.code().trim()).param("name", r.name()).param("rate", r.rate())
                .param("active", r.active()).query(UUID.class).single();
    }

    // ------------------------------------------------------------ opsi produk
    public List<OptionGroupRow> optionGroups() {
        return jdbc.sql("""
                SELECT g.id, g.name, g.min_select, g.max_select, g.sort_order, g.active,
                       (SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name,
                                'priceDelta', o.price_delta, 'sortOrder', o.sort_order, 'active', o.active)
                                ORDER BY o.sort_order, o.name), '[]'::jsonb)
                        FROM pos.product_options o WHERE o.group_id = g.id)::text AS options
                FROM pos.product_option_groups g WHERE g.organization_id = pos.current_org_id()
                ORDER BY g.sort_order, g.name
                """).query(OptionGroupRow.class).list();
    }

    public UUID saveOptionGroup(UUID id, SaveOptionGroupRequest r) {
        return jdbc.sql("""
                SELECT pos.save_option_group(CAST(:id AS uuid), :name, CAST(:min AS integer), CAST(:max AS integer),
                       CAST(:sort AS integer), CAST(:active AS boolean))
                """)
                .param("id", id).param("name", r.name()).param("min", r.minSelect()).param("max", r.maxSelect())
                .param("sort", r.sortOrder()).param("active", r.active()).query(UUID.class).single();
    }

    public UUID saveOption(UUID id, UUID groupId, SaveOptionRequest r) {
        return jdbc.sql("""
                SELECT pos.save_option(CAST(:id AS uuid), :g, :name, :delta, CAST(:sort AS integer), CAST(:active AS boolean))
                """)
                .param("id", id).param("g", groupId).param("name", r.name()).param("delta", r.priceDelta())
                .param("sort", r.sortOrder()).param("active", r.active()).query(UUID.class).single();
    }

    // ------------------------------------------------------------ diskon & struk
    /** Diskon org-wide + diskon outlet yang dapat diakses; outletId != null membatasi ke org-wide + outlet itu. */
    public List<DiscountPresetRow> discountPresets(UUID outletId, boolean includeInactive) {
        return jdbc.sql("""
                SELECT id, outlet_id, name, discount_type, discount_value, active FROM pos.discount_presets
                WHERE organization_id = pos.current_org_id() AND (:inactive OR active)
                  AND (CAST(:o AS uuid) IS NULL OR outlet_id IS NULL OR outlet_id = CAST(:o AS uuid))
                ORDER BY lower(name)
                """).param("o", outletId).param("inactive", includeInactive).query(DiscountPresetRow.class).list();
    }

    public UUID saveDiscountPreset(UUID id, SaveDiscountPresetRequest r) {
        return jdbc.sql("""
                SELECT pos.save_discount_preset(CAST(:id AS uuid), CAST(:o AS uuid), :name, :type, :value, CAST(:active AS boolean))
                """)
                .param("id", id).param("o", r.outletId()).param("name", r.name()).param("type", r.discountType())
                .param("value", r.discountValue()).param("active", r.active()).query(UUID.class).single();
    }

    public List<ReceiptProfileRow> receiptProfiles() {
        return jdbc.sql("""
                SELECT id, outlet_id, business_name, address, phone, header_text, footer_text, tax_id,
                       show_tax_detail, show_cashier, paper_width_mm
                FROM pos.receipt_profiles WHERE organization_id = pos.current_org_id()
                """).query(ReceiptProfileRow.class).list();
    }

    /** Profil efektif untuk outlet: profil outlet, jika tidak ada profil organisasi. */
    public Optional<ReceiptProfileRow> effectiveReceiptProfile(UUID outletId) {
        return jdbc.sql("""
                SELECT id, outlet_id, business_name, address, phone, header_text, footer_text, tax_id,
                       show_tax_detail, show_cashier, paper_width_mm
                FROM pos.receipt_profiles
                WHERE organization_id = pos.current_org_id() AND (outlet_id = :o OR outlet_id IS NULL)
                ORDER BY outlet_id NULLS LAST LIMIT 1
                """).param("o", outletId).query(ReceiptProfileRow.class).optional();
    }

    public UUID saveReceiptProfile(SaveReceiptProfileRequest r) {
        return jdbc.sql("""
                SELECT pos.save_receipt_profile(CAST(:o AS uuid), :bn, :addr, :ph, :hd, :ft, :tid,
                       CAST(:tax AS boolean), CAST(:cashier AS boolean), CAST(:paper AS integer))
                """)
                .param("o", r.outletId()).param("bn", r.businessName()).param("addr", r.address()).param("ph", r.phone())
                .param("hd", r.headerText()).param("ft", r.footerText()).param("tid", r.taxId())
                .param("tax", r.showTaxDetail()).param("cashier", r.showCashier()).param("paper", r.paperWidthMm())
                .query(UUID.class).single();
    }
}
