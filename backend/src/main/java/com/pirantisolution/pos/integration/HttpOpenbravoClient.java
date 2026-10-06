package com.pirantisolution.pos.integration;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.pirantisolution.pos.config.PosProperties;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;

/**
 * Konektor HTTP ke Openbravo sungguhan.
 *
 * <ul>
 *   <li>Master data dibaca dari JSON REST Openbravo ({@code org.openbravo.service.json.jsonrest}) dengan paging
 *       {@code _startRow/_endRow}; field diterjemahkan ke format ternormalisasi di {@link #normalize}.</li>
 *   <li>Dokumen (penjualan, retur, cash-up) dikirim sebagai JSON ke endpoint integrasi di sisi Openbravo
 *       (modul/web service yang mengimpor dokumen POS, path dapat dikonfigurasi). Kontrak payload & respons:
 *       docs/OPENBRAVO.md. Endpoint wajib idempotent berdasarkan {@code externalId}.</li>
 * </ul>
 * HTTP 4xx (selain 408/429) = ditolak permanen (manual review); 5xx/timeout = sementara (retry).
 */
public class HttpOpenbravoClient implements OpenbravoClient {

    private static final int PAGE = 500;

    private final PosProperties.Openbravo cfg;
    private final ObjectMapper json;
    private final HttpClient http;
    private final String authorization;

    public HttpOpenbravoClient(PosProperties.Openbravo cfg, ObjectMapper json) {
        if (cfg.baseUrl() == null || cfg.baseUrl().isBlank() || cfg.username() == null || cfg.password() == null) {
            throw new IllegalStateException("POS_OPENBRAVO_BASE_URL, POS_OPENBRAVO_USERNAME dan POS_OPENBRAVO_PASSWORD wajib diisi");
        }
        if (!cfg.baseUrl().startsWith("https://") && !cfg.baseUrl().startsWith("http://localhost")) {
            throw new IllegalStateException("POS_OPENBRAVO_BASE_URL harus https://");
        }
        this.cfg = cfg;
        this.json = json;
        this.http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(cfg.timeoutSeconds())).build();
        this.authorization = "Basic " + Base64.getEncoder()
                .encodeToString((cfg.username() + ":" + cfg.password()).getBytes(StandardCharsets.UTF_8));
    }

    @Override
    public String mode() {
        return "HTTP";
    }

    @Override
    public boolean enabled() {
        return true;
    }

    @Override
    public List<JsonNode> fetch(MasterType type) {
        String path = switch (type) {
            case PRODUCT -> cfg.paths().products();
            case PRICE -> cfg.paths().prices();
            case STOCK -> cfg.paths().stock();
            case CUSTOMER -> cfg.paths().customers() + (cfg.paths().customers().contains("?") ? "&" : "?")
                    + "_where=customer%3Dtrue";
        };
        List<JsonNode> out = new ArrayList<>();
        for (int start = 0; ; start += PAGE) {
            String sep = path.contains("?") ? "&" : "?";
            JsonNode body = send(HttpRequest.newBuilder(URI.create(cfg.baseUrl() + path + sep + "_startRow=" + start
                    + "&_endRow=" + (start + PAGE))).GET());
            JsonNode data = body.path("response").path("data");
            if (!data.isArray()) {
                throw new OpenbravoException("Respons Openbravo tidak dikenal untuk " + type, true);
            }
            data.forEach(n -> out.add(normalize(type, n)));
            if (data.size() < PAGE) {
                return out;
            }
        }
    }

    @Override
    public DocumentRef post(String documentType, JsonNode payload) {
        String path = switch (documentType) {
            case "SALE" -> cfg.paths().sales();
            case "RETURN" -> cfg.paths().returns();
            case "CASHUP" -> cfg.paths().cashups();
            default -> throw new OpenbravoException("Jenis dokumen tidak dikenal: " + documentType, true);
        };
        try {
            JsonNode body = send(HttpRequest.newBuilder(URI.create(cfg.baseUrl() + path))
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(json.writeValueAsString(payload))));
            String id = body.path("documentId").asText(null);
            if (id == null || id.isBlank()) {
                throw new OpenbravoException("Openbravo tidak mengembalikan documentId", false);
            }
            return new DocumentRef(id, body.path("documentNo").asText(null));
        } catch (IOException e) {
            throw new OpenbravoException("Payload tidak bisa dikirim: " + e.getMessage(), true, e);
        }
    }

    /** Terjemahan field Openbravo → format ternormalisasi (satu-satunya tempat yang tahu nama field Openbravo). */
    ObjectNode normalize(MasterType type, JsonNode n) {
        ObjectNode o = json.createObjectNode();
        switch (type) {
            case PRODUCT -> {
                o.put("id", n.path("id").asText()).put("sku", n.path("searchKey").asText())
                        .put("name", n.path("name").asText()).put("uom", n.path("uOM$_identifier").asText("PCS"))
                        .put("categoryId", n.path("productCategory").asText(null))
                        .put("categoryCode", n.path("productCategory$_identifier").asText(null))
                        .put("categoryName", n.path("productCategory$_identifier").asText(null))
                        .put("taxId", n.path("taxCategory").asText(null))
                        .put("active", n.path("active").asBoolean(true));
                if (n.hasNonNull("uPCEAN") && !n.path("uPCEAN").asText().isBlank()) {
                    o.putArray("barcodes").add(n.path("uPCEAN").asText());
                }
            }
            case PRICE -> o.put("productId", n.path("product").asText())
                    .put("price", n.path("listPrice").decimalValue());
            case STOCK -> o.put("productId", n.path("product").asText())
                    .put("warehouseId", n.path("warehouse").asText(n.path("storageBin$warehouse").asText()))
                    .put("quantity", n.path("quantityOnHand").decimalValue())
                    .put("available", n.path("quantityOnHand").decimalValue()
                            .subtract(n.path("reservedQty").decimalValue()));
            case CUSTOMER -> o.put("id", n.path("id").asText()).put("code", n.path("searchKey").asText())
                    .put("name", n.path("name").asText()).put("taxId", n.path("taxID").asText(null))
                    .put("active", n.path("active").asBoolean(true));
            default -> throw new IllegalArgumentException(type.name());
        }
        return o;
    }

    private JsonNode send(HttpRequest.Builder builder) {
        HttpRequest request = builder.header("Authorization", authorization).header("Accept", "application/json")
                .timeout(Duration.ofSeconds(cfg.timeoutSeconds())).build();
        try {
            HttpResponse<String> res = http.send(request, HttpResponse.BodyHandlers.ofString());
            int code = res.statusCode();
            if (code >= 200 && code < 300) {
                return json.readTree(res.body());
            }
            boolean permanent = code >= 400 && code < 500 && code != 408 && code != 429;
            throw new OpenbravoException("Openbravo HTTP " + code + ": " + abbreviate(res.body()), permanent);
        } catch (IOException e) {
            throw new OpenbravoException("Openbravo tidak dapat dihubungi: " + e.getMessage(), false, e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new OpenbravoException("Dibatalkan", false, e);
        }
    }

    private static String abbreviate(String s) {
        if (s == null) {
            return "";
        }
        String t = s.replaceAll("\\s+", " ");
        return t.length() > 300 ? t.substring(0, 300) + "…" : t;
    }
}
