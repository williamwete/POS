package com.pirantisolution.pos.idempotency;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.security.AccessService;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Optional;
import java.util.function.Supplier;
import java.util.regex.Pattern;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Idempotency (§37, §62).
 *
 * <p>Key disimpan di transaksi YANG SAMA dengan aksi bisnis:
 * <ul>
 *   <li>aksi sukses &rarr; key + response tersimpan atomik bersama data;</li>
 *   <li>aksi gagal &rarr; rollback, key ikut hilang sehingga client boleh retry;</li>
 *   <li>dua request bersamaan dengan key sama &rarr; INSERT kedua menunggu yang pertama commit
 *       (primary key), lalu me-replay response yang tersimpan. Hasilnya tetap satu.</li>
 * </ul>
 * Key yang sama dengan payload berbeda ditolak (IDEMPOTENCY_KEY_REUSED).
 */
@Service
public class IdempotencyService {

    public static final String HEADER = "Idempotency-Key";
    public static final String REPLAYED_HEADER = "Idempotent-Replayed";

    private static final Pattern KEY_PATTERN = Pattern.compile("^[A-Za-z0-9._:-]{8,128}$");

    private final JdbcClient jdbc;
    private final ObjectMapper objectMapper;
    private final AccessService access;

    public IdempotencyService(JdbcClient jdbc, ObjectMapper objectMapper, AccessService access) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
        this.access = access;
    }

    private record Stored(String method, String path, String requestHash, String status,
            Integer responseStatus, String responseBody) {
    }

    @Transactional
    public ResponseEntity<?> execute(String key, String method, String path, Object requestBody,
            Supplier<? extends ResponseEntity<?>> action) {
        if (key == null || key.isBlank()) {
            return action.get();
        }
        if (!KEY_PATTERN.matcher(key).matches()) {
            throw new ApiException(ErrorCode.IDEMPOTENCY_KEY_INVALID,
                    "Idempotency-Key harus 8-128 karakter [A-Za-z0-9._:-]");
        }
        access.currentUser();
        String hash = requestHash(method, path, requestBody);

        int inserted = jdbc.sql("""
                INSERT INTO pos.idempotency_keys (user_id, idempotency_key, method, path, request_hash)
                VALUES (pos.current_app_user_id(), :key, :method, :path, :hash)
                ON CONFLICT (user_id, idempotency_key) DO NOTHING
                """)
                .param("key", key)
                .param("method", method)
                .param("path", path)
                .param("hash", hash)
                .update();

        if (inserted == 0) {
            Stored stored = find(key).orElseThrow(() -> new ApiException(ErrorCode.DUPLICATE_TRANSACTION));
            if (!stored.requestHash().equals(hash) || !stored.method().equals(method)
                    || !stored.path().equals(path)) {
                throw new ApiException(ErrorCode.IDEMPOTENCY_KEY_REUSED);
            }
            if (!"COMPLETED".equals(stored.status()) || stored.responseStatus() == null) {
                throw new ApiException(ErrorCode.DUPLICATE_TRANSACTION,
                        "Request dengan Idempotency-Key ini masih diproses");
            }
            return ResponseEntity.status(stored.responseStatus())
                    .header(REPLAYED_HEADER, "true")
                    .body(parse(stored.responseBody()));
        }

        ResponseEntity<?> response = action.get();
        jdbc.sql("""
                UPDATE pos.idempotency_keys
                SET status = 'COMPLETED', response_status = :status,
                    response_body = CAST(:body AS jsonb), completed_at = now()
                WHERE user_id = pos.current_app_user_id() AND idempotency_key = :key
                """)
                .param("status", response.getStatusCode().value())
                .param("body", write(response.getBody()))
                .param("key", key)
                .update();
        return response;
    }

    private Optional<Stored> find(String key) {
        return jdbc.sql("""
                SELECT method, path, request_hash, status, response_status, response_body::text AS response_body
                FROM pos.idempotency_keys
                WHERE user_id = pos.current_app_user_id() AND idempotency_key = :key
                """)
                .param("key", key)
                .query(Stored.class)
                .optional();
    }

    private String requestHash(String method, String path, Object body) {
        try {
            // Serialisasi ulang lewat JsonNode agar urutan field tidak memengaruhi hash.
            JsonNode node = objectMapper.valueToTree(body);
            String canonical = method + " " + path + "\n" + objectMapper.writer()
                    .with(com.fasterxml.jackson.databind.SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS)
                    .writeValueAsString(objectMapper.treeToValue(node, Object.class));
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(canonical.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (JsonProcessingException | NoSuchAlgorithmException e) {
            throw new IllegalStateException("Cannot hash request", e);
        }
    }

    private String write(Object body) {
        try {
            return objectMapper.writeValueAsString(body);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Cannot serialize response", e);
        }
    }

    private JsonNode parse(String body) {
        try {
            return body == null ? null : objectMapper.readTree(body);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Stored idempotent response is corrupt", e);
        }
    }
}
