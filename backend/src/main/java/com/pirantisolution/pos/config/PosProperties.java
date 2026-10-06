package com.pirantisolution.pos.config;

import java.util.List;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

/**
 * Konfigurasi aplikasi POS. Semua secret dibaca dari environment, tidak pernah di-hardcode.
 */
@ConfigurationProperties(prefix = "pos")
public record PosProperties(
        Jwt jwt,
        Auth auth,
        @DefaultValue Cors cors,
        @DefaultValue RateLimit rateLimit,
        @DefaultValue Payment payment,
        @DefaultValue Openbravo openbravo) {

    /**
     * Validasi JWT Supabase. Isi salah satu: {@code jwkSetUri} (signing key asimetris,
     * direkomendasikan) atau {@code hs256Secret} (legacy JWT secret / lokal).
     */
    public record Jwt(
            String jwkSetUri,
            String hs256Secret,
            String issuer,
            @DefaultValue("authenticated") String audience) {
    }

    public record Auth(
            @DefaultValue("SUPABASE") AuthProvider provider,
            String supabaseUrl,
            String supabaseServiceRoleKey,
            @DefaultValue("3600") long localTokenTtlSeconds) {
    }

    public enum AuthProvider { SUPABASE, LOCAL }

    /**
     * Payment gateway untuk QRIS/e-wallet. NONE = belum ada penyedia (metode gateway hanya bisa
     * dipakai bila dikonfigurasi konfirmasi manual). SIMULATOR hanya untuk profile local/test.
     * {@code callbackSecret} = kunci HMAC callback; wajib bila gateway bukan NONE.
     */
    public record Payment(
            @DefaultValue("NONE") GatewayType gateway,
            String callbackSecret,
            @DefaultValue("10") int timeoutSeconds) {
    }

    public enum GatewayType { NONE, SIMULATOR }

    /**
     * Integrasi Openbravo (§38). Kredensial HANYA dari environment server, tidak pernah ke frontend.
     * DISABLED = antrean tetap terkumpul tetapi tidak dikirim; SIMULATOR hanya profile local/test;
     * HTTP = Openbravo sungguhan lewat {@code baseUrl} + akun integrasi.
     */
    public record Openbravo(
            @DefaultValue("DISABLED") OpenbravoMode mode,
            String baseUrl,
            String username,
            String password,
            @DefaultValue("30") int timeoutSeconds,
            @DefaultValue("true") boolean workerEnabled,
            @DefaultValue("20") int batchSize,
            @DefaultValue Paths paths) {
    }

    public enum OpenbravoMode { DISABLED, SIMULATOR, HTTP }

    /** Path endpoint Openbravo (relatif terhadap baseUrl) — dapat disesuaikan tanpa ubah kode. */
    public record Paths(
            @DefaultValue("/org.openbravo.service.json.jsonrest/Product") String products,
            @DefaultValue("/org.openbravo.service.json.jsonrest/PricingProductPrice") String prices,
            @DefaultValue("/org.openbravo.service.json.jsonrest/MaterialMgmtStorageDetail") String stock,
            @DefaultValue("/org.openbravo.service.json.jsonrest/BusinessPartner") String customers,
            @DefaultValue("/ws/pos-integration/sales") String sales,
            @DefaultValue("/ws/pos-integration/returns") String returns,
            @DefaultValue("/ws/pos-integration/cashups") String cashups) {
    }

    public record Cors(@DefaultValue({}) List<String> allowedOrigins) {
    }

    /**
     * TEMPORARY IMPLEMENTATION: limit in-memory per instance (lihat docs/ASSUMPTIONS.md B11).
     */
    public record RateLimit(
            @DefaultValue("true") boolean enabled,
            @DefaultValue("300") int requestsPerMinute,
            @DefaultValue("10") int authRequestsPerMinute) {
    }
}
