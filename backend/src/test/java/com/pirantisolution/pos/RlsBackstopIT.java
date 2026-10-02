package com.pirantisolution.pos;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.pirantisolution.pos.db.SystemTx;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Membuktikan RLS menjadi lapisan kedua dari jalur Java: walaupun service lupa cek permission,
 * database tetap menolak. Juga membuktikan fail-closed tanpa konteks user.
 */
class RlsBackstopIT extends IntegrationTestBase {

    @Autowired
    private JdbcClient jdbc;
    @Autowired
    private PlatformTransactionManager txManager;
    @Autowired
    private JwtDecoder jwtDecoder;
    @Autowired
    private SystemTx systemTx;

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    private void authenticate(String username) {
        SecurityContextHolder.getContext().setAuthentication(
                new JwtAuthenticationToken(jwtDecoder.decode(token(username))));
    }

    private <T> T inTx(java.util.function.Supplier<T> s) {
        return new TransactionTemplate(txManager).execute(status -> s.get());
    }

    @Test
    void withoutUserContextDatabaseDeniesEverything() {
        assertThatThrownBy(() -> inTx(() -> jdbc.sql("SELECT count(*) FROM pos.outlets").query(Long.class).single()))
                .isInstanceOf(DataAccessException.class)
                .hasMessageContaining("permission denied");
    }

    @Test
    void cashierDirectInsertIsBlockedByRls() {
        authenticate("cashier.jkt");
        assertThatThrownBy(() -> inTx(() -> jdbc.sql("""
                INSERT INTO pos.terminals (outlet_id, code, name) VALUES (:o, :c, 'bypass')
                """).param("o", OUTLET_JKT).param("c", unique("POS-RLS")).update()))
                .isInstanceOf(DataAccessException.class)
                .hasMessageContaining("row-level security");
    }

    @Test
    void cashierDirectSelectSeesOnlyOwnOutlet() {
        authenticate("cashier.jkt");
        List<UUID> ids = inTx(() -> jdbc.sql("SELECT id FROM pos.outlets").query(UUID.class).list());
        assertThat(ids).containsExactly(OUTLET_JKT);
    }

    @Test
    void contextDoesNotLeakBetweenTransactions() {
        authenticate("superadmin");
        assertThat(inTx(() -> jdbc.sql("SELECT count(*) FROM pos.outlets").query(Long.class).single()))
                .isGreaterThanOrEqualTo(2L);
        SecurityContextHolder.clearContext();
        // Koneksi yang sama dari pool tidak boleh membawa role/klaim transaksi sebelumnya.
        assertThatThrownBy(() -> inTx(() -> jdbc.sql("SELECT count(*) FROM pos.outlets").query(Long.class).single()))
                .isInstanceOf(DataAccessException.class);
    }

    @Test
    void systemContextIsExplicit() {
        Long n = systemTx.system(() -> jdbc.sql("SELECT count(*) FROM pos.outlets").query(Long.class).single());
        assertThat(n).isGreaterThanOrEqualTo(2L);
        assertThatThrownBy(() -> systemTx.system(() -> jdbc.sql("UPDATE pos.audit_logs SET reason = 'x'").update()))
                .isInstanceOf(DataAccessException.class);
    }
}
