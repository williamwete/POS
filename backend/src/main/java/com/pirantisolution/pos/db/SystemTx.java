package com.pirantisolution.pos.db;

import java.util.function.Supplier;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Menjalankan kode dalam transaksi BARU dengan role database tertentu.
 *
 * <p>Pemakaian {@link #system} harus seminimal mungkin dan selalu disertai audit log,
 * karena pos_system tidak dibatasi RLS.
 */
@Component
public class SystemTx {

    private final TransactionTemplate requiresNew;

    public SystemTx(PlatformTransactionManager transactionManager) {
        this.requiresNew = new TransactionTemplate(transactionManager);
        this.requiresNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    public <T> T system(Supplier<T> action) {
        return DbContext.callAs(DbContext.Mode.SYSTEM, () -> requiresNew.execute(status -> action.get()));
    }

    public void systemRun(Runnable action) {
        system(() -> {
            action.run();
            return null;
        });
    }

    /** Hanya untuk profile local (shim auth). */
    public <T> T localAuth(Supplier<T> action) {
        return DbContext.callAs(DbContext.Mode.LOCAL_AUTH, () -> requiresNew.execute(status -> action.get()));
    }

    /** Transaksi baru sebagai user request saat ini (mis. memisahkan langkah dari panggilan eksternal). */
    public <T> T user(Supplier<T> action) {
        return DbContext.callAs(DbContext.Mode.USER, () -> requiresNew.execute(status -> action.get()));
    }
}
