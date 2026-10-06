package com.pirantisolution.pos.integration;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Openbravo TIRUAN untuk profile local/test: data master demo (sama dengan seed) dan nomor dokumen
 * berurutan. Dokumen dengan externalId yang sama mendapat nomor yang sama (idempotent seperti yang
 * disyaratkan untuk Openbravo sungguhan). Kegagalan dapat disuntikkan untuk menguji retry.
 */
public class SimulatorOpenbravoClient implements OpenbravoClient {

    private static final String[][] PRODUCTS = {
        {"SKU-0001", "Air Mineral 600 ml", "MINUMAN", "DEMO-TAX-PPN11", "5000", "8990000000017"},
        {"SKU-0002", "Teh Melati Botol 350 ml", "MINUMAN", "DEMO-TAX-PPN11", "6500", "8990000000024"},
        {"SKU-0003", "Kopi Susu Kaleng 240 ml", "MINUMAN", "DEMO-TAX-PPN11", "9000", "8990000000031"},
        {"SKU-0004", "Keripik Singkong Balado 150 g", "MAKANAN", "DEMO-TAX-PPN11", "15000", "8990000000048"},
        {"SKU-0005", "Biskuit Kelapa 300 g", "MAKANAN", "DEMO-TAX-PPN11", "22500", "8990000000055"},
        {"SKU-0006", "Cokelat Batang 75 g", "MAKANAN", "DEMO-TAX-PPN11", "12000", "8990000000062"},
        {"SKU-0007", "Beras Premium 5 kg", "SEMBAKO", "DEMO-TAX-EXEMPT", "78000", "8990000000079"},
        {"SKU-0009", "Minyak Goreng 2 L", "SEMBAKO", "DEMO-TAX-PPN11", "36500", "8990000000093"},
        {"SKU-0010", "Gula Pasir 1 kg", "SEMBAKO", "DEMO-TAX-EXEMPT", "17500", "8990000000109"},
        {"SKU-0011", "Sabun Cuci Piring 780 ml", "RUMAH", "DEMO-TAX-PPN11", "18900", "8990000000116"},
        {"SKU-0012", "Tisu Wajah 250 lembar", "RUMAH", "DEMO-TAX-PPN11", "50000", "8990000000123"},
    };

    private static final Map<String, String> CATEGORIES = Map.of("MINUMAN", "Minuman", "MAKANAN", "Makanan ringan",
            "SEMBAKO", "Sembako", "RUMAH", "Kebutuhan rumah");

    private final ObjectMapper json;
    private final AtomicInteger sequence = new AtomicInteger();
    private final Map<String, DocumentRef> posted = new ConcurrentHashMap<>();
    private final AtomicInteger failNext = new AtomicInteger();
    private volatile boolean failPermanently;

    public SimulatorOpenbravoClient(ObjectMapper json) {
        this.json = json;
    }

    @Override
    public String mode() {
        return "SIMULATOR";
    }

    @Override
    public boolean enabled() {
        return true;
    }

    /** Untuk test: {@code count} panggilan berikutnya gagal (sementara atau permanen). */
    public void failNext(int count, boolean permanent) {
        failPermanently = permanent;
        failNext.set(count);
    }

    @Override
    public List<JsonNode> fetch(MasterType type) {
        maybeFail();
        List<JsonNode> out = new ArrayList<>();
        switch (type) {
            case PRODUCT -> {
                for (String[] p : PRODUCTS) {
                    ObjectNode n = json.createObjectNode();
                    n.put("id", "DEMO-" + p[0]).put("sku", p[0]).put("name", p[1]).put("uom", "PCS")
                            .put("categoryId", "DEMO-CAT-" + p[2]).put("categoryCode", p[2])
                            .put("categoryName", CATEGORIES.get(p[2])).put("taxId", p[3])
                            .put("active", true);
                    n.putArray("barcodes").add(p[5]);
                    out.add(n);
                }
            }
            case PRICE -> {
                for (String[] p : PRODUCTS) {
                    out.add(json.createObjectNode().put("productId", "DEMO-" + p[0]).put("price", Long.parseLong(p[4])));
                }
            }
            case STOCK -> {
                for (int i = 0; i < PRODUCTS.length; i++) {
                    String[] p = PRODUCTS[i];
                    for (String wh : new String[] {"DEMO-WH-JKT01", "DEMO-WH-BDG01"}) {
                        int qty = "SKU-0006".equals(p[0]) && wh.endsWith("BDG01") ? 0 : 400 + 7 * i;
                        out.add(json.createObjectNode().put("productId", "DEMO-" + p[0]).put("warehouseId", wh)
                                .put("quantity", qty).put("available", qty));
                    }
                }
            }
            case CUSTOMER -> {
                out.add(json.createObjectNode().put("id", "DEMO-BP-0001").put("code", "C0001")
                        .put("name", "PT Sinar Jaya Abadi").put("phone", "021-5550123").put("taxId", "01.234.567.8-012.000"));
                out.add(json.createObjectNode().put("id", "DEMO-BP-0002").put("code", "C0002")
                        .put("name", "CV Berkah Makmur").put("phone", "022-4440456"));
                out.add(json.createObjectNode().put("id", "DEMO-BP-0003").put("code", "C0003")
                        .put("name", "Ibu Ratna Sari").put("email", "ratna@example.com"));
            }
            default -> throw new IllegalArgumentException(type.name());
        }
        return out;
    }

    @Override
    public DocumentRef post(String documentType, JsonNode payload) {
        maybeFail();
        String externalId = payload.path("externalId").asText();
        if (externalId.isBlank()) {
            throw new OpenbravoException("externalId wajib", true);
        }
        return posted.computeIfAbsent(documentType + ":" + externalId, k -> {
            int n = sequence.incrementAndGet();
            String prefix = switch (documentType) {
                case "SALE" -> "SO";
                case "RETURN" -> "RM";
                default -> "CU";
            };
            return new DocumentRef("SIM-" + documentType + "-" + n, "SIM/" + prefix + "/" + String.format("%06d", n));
        });
    }

    private void maybeFail() {
        if (failNext.getAndUpdate(v -> Math.max(0, v - 1)) > 0) {
            throw new OpenbravoException(failPermanently
                    ? "Simulator: dokumen ditolak Openbravo (validasi)" : "Simulator: Openbravo tidak dapat dihubungi",
                    failPermanently);
        }
    }
}
