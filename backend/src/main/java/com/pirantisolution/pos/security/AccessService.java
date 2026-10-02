package com.pirantisolution.pos.security;

import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Cek otorisasi di service. Memanggil fungsi SQL yang SAMA dengan policy RLS
 * (pos.has_permission / pos.can_access_outlet) sehingga service dan database tidak pernah
 * berbeda pendapat. RLS tetap menjadi lapisan kedua jika service lupa memanggil cek ini.
 *
 * <p>Semua method wajib dipanggil di dalam transaksi (MANDATORY), karena konteks user
 * database dipasang saat transaksi dimulai.
 */
@Service
@Transactional(propagation = Propagation.MANDATORY)
public class AccessService {

    private final JdbcClient jdbc;

    public AccessService(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public CurrentUser currentUser() {
        return findCurrentUser().orElseThrow(() -> new ApiException(ErrorCode.USER_NOT_PROVISIONED));
    }

    public Optional<CurrentUser> findCurrentUser() {
        return jdbc.sql("""
                SELECT u.id AS user_id, u.organization_id, u.employee_id, u.username
                FROM pos.users u
                WHERE u.id = pos.current_app_user_id()
                """)
                .query(CurrentUser.class)
                .optional();
    }

    public boolean has(String permission, UUID outletId) {
        Boolean ok = jdbc.sql("SELECT pos.has_permission(:p, CAST(:o AS uuid))")
                .param("p", permission)
                .param("o", outletId)
                .query(Boolean.class)
                .single();
        return Boolean.TRUE.equals(ok);
    }

    public boolean canAccessOutlet(UUID outletId) {
        Boolean ok = jdbc.sql("SELECT pos.can_access_outlet(CAST(:o AS uuid))")
                .param("o", outletId)
                .query(Boolean.class)
                .single();
        return Boolean.TRUE.equals(ok);
    }

    /** Permission pada scope organisasi (hanya role org-wide). */
    public void requireOrg(String permission) {
        currentUser();
        if (!has(permission, null)) {
            throw new ApiException(ErrorCode.USER_NOT_AUTHORIZED);
        }
    }

    /** Permission pada outlet tertentu. */
    public void requireOutlet(String permission, UUID outletId) {
        currentUser();
        if (outletId == null) {
            throw ApiException.validation("outletId wajib diisi");
        }
        if (!canAccessOutlet(outletId)) {
            throw new ApiException(ErrorCode.OUTLET_ACCESS_DENIED);
        }
        if (!has(permission, outletId)) {
            throw new ApiException(ErrorCode.USER_NOT_AUTHORIZED);
        }
    }

    /** outletId NULL berarti scope organisasi (mis. karyawan kantor pusat). */
    public void requireScope(String permission, UUID outletIdOrNull) {
        if (outletIdOrNull == null) {
            requireOrg(permission);
        } else {
            requireOutlet(permission, outletIdOrNull);
        }
    }

    public void requireOutletAccess(UUID outletId) {
        currentUser();
        if (outletId == null || !canAccessOutlet(outletId)) {
            throw new ApiException(ErrorCode.OUTLET_ACCESS_DENIED);
        }
    }

    public List<UUID> accessibleOutletIds() {
        return jdbc.sql("SELECT a FROM pos.accessible_outlet_ids() a")
                .query(UUID.class)
                .list();
    }

    public List<String> effectivePermissions(UUID outletId) {
        return jdbc.sql("SELECT p FROM pos.effective_permissions(CAST(:o AS uuid)) p")
                .param("o", outletId)
                .query(String.class)
                .list();
    }

    public boolean canGrantRole(UUID roleId, UUID outletId) {
        Boolean ok = jdbc.sql("SELECT pos.can_grant_role(CAST(:r AS uuid), CAST(:o AS uuid))")
                .param("r", roleId)
                .param("o", outletId)
                .query(Boolean.class)
                .single();
        return Boolean.TRUE.equals(ok);
    }

    public boolean canManageUser(UUID userId) {
        Boolean ok = jdbc.sql("SELECT pos.can_manage_user(CAST(:u AS uuid))")
                .param("u", userId)
                .query(Boolean.class)
                .single();
        return Boolean.TRUE.equals(ok);
    }
}
