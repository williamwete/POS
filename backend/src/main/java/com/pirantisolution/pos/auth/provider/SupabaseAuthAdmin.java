package com.pirantisolution.pos.auth.provider;

import com.fasterxml.jackson.databind.JsonNode;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.config.PosProperties;
import java.time.Duration;
import java.util.Map;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

/**
 * Supabase Auth Admin API ({@code /auth/v1/admin/users}) memakai service role key.
 * Service role key HANYA ada di server (environment), tidak pernah dikirim ke frontend.
 */
@Component
@ConditionalOnProperty(name = "pos.auth.provider", havingValue = "SUPABASE", matchIfMissing = true)
public class SupabaseAuthAdmin implements AuthProviderAdmin {

    private static final Logger log = LoggerFactory.getLogger(SupabaseAuthAdmin.class);
    /** Supabase tidak punya "ban permanen"; ~100 tahun. */
    private static final String BAN_FOREVER = "876000h";

    private final RestClient client;
    private final RestClient authClient;

    public SupabaseAuthAdmin(PosProperties properties) {
        PosProperties.Auth cfg = properties.auth();
        if (cfg == null || !StringUtils.hasText(cfg.supabaseUrl())
                || !StringUtils.hasText(cfg.supabaseServiceRoleKey())) {
            throw new IllegalStateException(
                    "pos.auth.supabase-url dan pos.auth.supabase-service-role-key wajib diisi untuk provider SUPABASE");
        }
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(5));
        factory.setReadTimeout(Duration.ofSeconds(15));
        this.client = RestClient.builder()
                .baseUrl(cfg.supabaseUrl().replaceAll("/+$", "") + "/auth/v1/admin")
                .requestFactory(factory)
                .defaultHeader("apikey", cfg.supabaseServiceRoleKey())
                .defaultHeader("Authorization", "Bearer " + cfg.supabaseServiceRoleKey())
                .build();
        this.authClient = RestClient.builder()
                .baseUrl(cfg.supabaseUrl().replaceAll("/+$", "") + "/auth/v1")
                .requestFactory(factory)
                .defaultHeader("apikey", cfg.supabaseServiceRoleKey())
                .build();
    }

    private void revokeQuietly(String accessToken) {
        if (accessToken == null || accessToken.isBlank()) {
            return;
        }
        try {
            authClient.post()
                    .uri("/logout?scope=local")
                    .header("Authorization", "Bearer " + accessToken)
                    .retrieve()
                    .toBodilessEntity();
        } catch (RuntimeException e) {
            // Gagal mencabut tidak membatalkan approval; sesi tetap kedaluwarsa sesuai TTL Supabase.
            log.warn("Could not revoke approver session: {}", e.getClass().getSimpleName());
        }
    }

    @Override
    public UUID verifyPassword(String email, String password) {
        try {
            JsonNode body = authClient.post()
                    .uri("/token?grant_type=password")
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(Map.of("email", email, "password", password))
                    .retrieve()
                    .body(JsonNode.class);
            // Sesi yang terbentuk tidak dipakai/disimpan; hanya identitas approver yang diambil,
            // lalu sesi itu langsung dicabut agar tidak ada refresh token supervisor yang menggantung.
            revokeQuietly(body == null ? null : body.path("access_token").asText(null));
            JsonNode id = body == null ? null : body.path("user").path("id");
            return id == null || id.isMissingNode() || id.isNull() ? null : UUID.fromString(id.asText());
        } catch (HttpClientErrorException e) {
            if (e.getStatusCode().value() == 400 || e.getStatusCode().value() == 401
                    || e.getStatusCode().value() == 422) {
                return null;
            }
            throw unavailable("verify", e.getStatusCode(), e);
        } catch (RestClientResponseException e) {
            throw unavailable("verify", e.getStatusCode(), e);
        } catch (ResourceAccessException e) {
            throw unavailable("verify", null, e);
        }
    }

    @Override
    public UUID createUser(String email, String password) {
        try {
            JsonNode body = client.post()
                    .uri("/users")
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(Map.of("email", email, "password", password, "email_confirm", true))
                    .retrieve()
                    .body(JsonNode.class);
            if (body == null || !body.hasNonNull("id")) {
                throw new ApiException(ErrorCode.AUTH_PROVIDER_UNAVAILABLE);
            }
            return UUID.fromString(body.get("id").asText());
        } catch (HttpClientErrorException e) {
            if (e.getStatusCode().value() == 422 || e.getStatusCode().value() == 409) {
                throw new ApiException(ErrorCode.AUTH_USER_EXISTS);
            }
            if (e.getStatusCode().value() == 400) {
                // mis. password tidak memenuhi kebijakan Supabase
                throw ApiException.validation("Password atau email ditolak oleh layanan login");
            }
            throw unavailable("create", e.getStatusCode(), e);
        } catch (RestClientResponseException e) {
            throw unavailable("create", e.getStatusCode(), e);
        } catch (ResourceAccessException e) {
            throw unavailable("create", null, e);
        }
    }

    @Override
    public void deleteUser(UUID authUserId) {
        try {
            client.delete().uri("/users/{id}", authUserId).retrieve().toBodilessEntity();
        } catch (RestClientResponseException | ResourceAccessException e) {
            // Kompensasi gagal: akun login yatim harus dibersihkan manual. Dicatat sebagai error.
            log.error("Failed to delete orphan auth user {} — manual cleanup required", authUserId, e);
        }
    }

    @Override
    public void setPassword(UUID authUserId, String password) {
        update(authUserId, Map.of("password", password));
    }

    @Override
    public void setBanned(UUID authUserId, boolean banned) {
        update(authUserId, Map.of("ban_duration", banned ? BAN_FOREVER : "none"));
    }

    private void update(UUID authUserId, Map<String, Object> body) {
        try {
            client.put()
                    .uri("/users/{id}", authUserId)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .retrieve()
                    .toBodilessEntity();
        } catch (HttpClientErrorException e) {
            if (e.getStatusCode().value() == 400 || e.getStatusCode().value() == 422) {
                throw ApiException.validation("Perubahan ditolak oleh layanan login");
            }
            throw unavailable("update", e.getStatusCode(), e);
        } catch (RestClientResponseException e) {
            throw unavailable("update", e.getStatusCode(), e);
        } catch (ResourceAccessException e) {
            throw unavailable("update", null, e);
        }
    }

    private static ApiException unavailable(String op, HttpStatusCode status, Exception cause) {
        log.error("Supabase auth admin {} failed (status={})", op, status, cause);
        return new ApiException(ErrorCode.AUTH_PROVIDER_UNAVAILABLE, ErrorCode.AUTH_PROVIDER_UNAVAILABLE.defaultMessage(), cause);
    }
}
