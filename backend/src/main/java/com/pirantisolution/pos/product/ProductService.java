package com.pirantisolution.pos.product;

import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.security.AccessService;
import java.util.List;
import java.util.UUID;
import java.util.regex.Pattern;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Pencarian produk untuk kasir. Data produk adalah cache Openbravo (read-only di POS). */
@Service
public class ProductService {

    private static final Pattern BARCODE = Pattern.compile("^[A-Za-z0-9._-]{1,64}$");

    private final ProductRepository repo;
    private final AccessService access;

    public ProductService(ProductRepository repo, AccessService access) {
        this.repo = repo;
        this.access = access;
    }

    @Transactional(readOnly = true)
    public List<ProductView> search(UUID outletId, String query, Integer limit) {
        access.requireOutletAccess(outletId);
        if (query != null && query.length() > 80) {
            throw ApiException.validation("Kata kunci terlalu panjang");
        }
        int n = limit == null ? 20 : Math.max(1, Math.min(limit, 50));
        return repo.search(outletId, query, n);
    }

    @Transactional(readOnly = true)
    public ProductView byBarcode(UUID outletId, String barcode) {
        access.requireOutletAccess(outletId);
        if (barcode == null || !BARCODE.matcher(barcode).matches()) {
            throw new ApiException(ErrorCode.PRODUCT_NOT_FOUND);
        }
        return repo.byBarcode(outletId, barcode).orElseThrow(() -> new ApiException(ErrorCode.PRODUCT_NOT_FOUND,
                "Barcode " + barcode + " tidak terdaftar"));
    }
}
