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
        @DefaultValue Payment payment) {

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
