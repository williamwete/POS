package com.pirantisolution.pos.product;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class ProductController {

    private final ProductService service;

    public ProductController(ProductService service) {
        this.service = service;
    }

    @GetMapping("/api/products")
    public ResponseEntity<ApiResponse<List<ProductView>>> search(@RequestParam UUID outletId,
            @RequestParam(required = false) String q, @RequestParam(required = false) Integer limit) {
        return Responses.ok(service.search(outletId, q, limit));
    }

    @GetMapping("/api/products/barcode/{barcode}")
    public ResponseEntity<ApiResponse<ProductView>> byBarcode(@RequestParam UUID outletId,
            @PathVariable String barcode) {
        return Responses.ok(service.byBarcode(outletId, barcode));
    }
}
