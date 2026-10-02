package com.pirantisolution.pos.auth.provider;

import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.db.SystemTx;
import java.util.UUID;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

/**
 * Provider login LOKAL (shim tabel auth.users). Hanya aktif jika pos.auth.provider=LOCAL,
 * yang hanya diizinkan pada profile local/test (lihat LocalProfileGuard).
 */
@Component
@ConditionalOnProperty(name = "pos.auth.provider", havingValue = "LOCAL")
public class LocalAuthAdmin implements AuthProviderAdmin {

    private final JdbcClient jdbc;
    private final SystemTx tx;

    public LocalAuthAdmin(JdbcClient jdbc, SystemTx tx) {
        this.jdbc = jdbc;
        this.tx = tx;
    }

    @Override
    public UUID createUser(String email, String password) {
        try {
            return tx.localAuth(() -> jdbc.sql("SELECT auth.local_create_user(:e, :p)")
                    .param("e", email)
                    .param("p", password)
                    .query(UUID.class)
                    .single());
        } catch (DuplicateKeyException e) {
            throw new ApiException(ErrorCode.AUTH_USER_EXISTS);
        }
    }

    @Override
    public void deleteUser(UUID authUserId) {
        tx.localAuth(() -> jdbc.sql("SELECT auth.local_delete_user(:id)").param("id", authUserId)
                .query((rs, n) -> 1).list());
    }

    @Override
    public void setPassword(UUID authUserId, String password) {
        tx.localAuth(() -> jdbc.sql("SELECT auth.local_set_password(:id, :p)")
                .param("id", authUserId).param("p", password)
                .query((rs, n) -> 1).list());
    }

    @Override
    public void setBanned(UUID authUserId, boolean banned) {
        tx.localAuth(() -> jdbc.sql("SELECT auth.local_set_banned(:id, :b)")
                .param("id", authUserId).param("b", banned)
                .query((rs, n) -> 1).list());
    }

    @Override
    public UUID verifyPassword(String email, String password) {
        return verify(email, password);
    }

    /** Verifikasi password untuk endpoint token lokal. */
    public UUID verify(String email, String password) {
        java.util.List<UUID> result = tx.localAuth(() -> jdbc.sql("SELECT auth.local_verify_password(:e, :p)")
                .param("e", email)
                .param("p", password)
                .query(UUID.class)
                .list());
        return result.isEmpty() ? null : result.get(0);
    }
}
