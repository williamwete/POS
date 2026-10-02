package com.pirantisolution.pos.db;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import javax.sql.DataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.transaction.TransactionDefinition;

/**
 * Transaction manager yang menerapkan konteks RLS di awal setiap transaksi
 * (docs/ASSUMPTIONS.md A2):
 *
 * <pre>
 *   SET LOCAL ROLE pos_app_user;
 *   SELECT set_config('request.jwt.claims', '{"sub": ..., "role": "authenticated"}', true);
 * </pre>
 *
 * Keduanya bersifat LOCAL sehingga otomatis hilang saat commit/rollback dan tidak bocor
 * ke request lain yang memakai koneksi pool yang sama.
 */
public class RlsTransactionManager extends DataSourceTransactionManager {

    private static final long serialVersionUID = 1L;

    private final transient ObjectMapper objectMapper;

    public RlsTransactionManager(DataSource dataSource, ObjectMapper objectMapper) {
        super(dataSource);
        this.objectMapper = objectMapper;
        setEnforceReadOnly(true);
    }

    @Override
    protected void prepareTransactionalConnection(Connection con, TransactionDefinition definition)
            throws SQLException {
        super.prepareTransactionalConnection(con, definition);
        switch (DbContext.currentMode()) {
            case SYSTEM -> execute(con, "SET LOCAL ROLE pos_system");
            case LOCAL_AUTH -> execute(con, "SET LOCAL ROLE pos_local_auth");
            case USER -> applyUserContext(con);
        }
    }

    private void applyUserContext(Connection con) throws SQLException {
        String claims = currentClaimsJson();
        if (claims == null) {
            // Tidak ada user terautentikasi: biarkan sebagai pos_api (tanpa privilege tabel).
            return;
        }
        execute(con, "SET LOCAL ROLE pos_app_user");
        try (PreparedStatement ps = con.prepareStatement("SELECT set_config('request.jwt.claims', ?, true)")) {
            ps.setString(1, claims);
            ps.execute();
        }
    }

    private String currentClaimsJson() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (!(auth instanceof JwtAuthenticationToken token)) {
            return null;
        }
        Jwt jwt = token.getToken();
        Map<String, Object> claims = new LinkedHashMap<>();
        claims.put("sub", jwt.getSubject());
        claims.put("role", jwt.getClaimAsString("role"));
        List<String> aud = jwt.getAudience();
        if (aud != null && !aud.isEmpty()) {
            claims.put("aud", aud.get(0));
        }
        claims.put("email", jwt.getClaimAsString("email"));
        Long authTime = authTime(jwt);
        if (authTime != null) {
            claims.put("auth_time", authTime);
        }
        try {
            return objectMapper.writeValueAsString(claims);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Cannot serialize JWT claims", e);
        }
    }

    /**
     * Waktu (epoch detik) user terakhir membuktikan identitasnya (password/OTP/SSO), diambil dari
     * klaim {@code amr} Supabase. Refresh token tidak mengubah nilai ini, sehingga database dapat
     * mensyaratkan "login ulang setelah terminal dikunci" (ASSUMPTIONS B20).
     */
    static Long authTime(Jwt jwt) {
        Object amr = jwt.getClaims().get("amr");
        if (!(amr instanceof List<?> entries)) {
            return null;
        }
        Long latest = null;
        for (Object e : entries) {
            if (e instanceof Map<?, ?> m && m.get("timestamp") instanceof Number n) {
                String method = String.valueOf(m.get("method"));
                if (method.contains("refresh") || method.equals("anonymous")) {
                    continue;
                }
                long ts = n.longValue();
                latest = latest == null ? ts : Math.max(latest, ts);
            }
        }
        return latest;
    }

    private static void execute(Connection con, String sql) throws SQLException {
        try (Statement st = con.createStatement()) {
            st.execute(sql);
        }
    }
}
