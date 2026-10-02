package com.pirantisolution.pos.user;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.auth.provider.AuthProviderAdmin;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.common.error.Guards;
import com.pirantisolution.pos.security.AccessService;
import com.pirantisolution.pos.security.CurrentUser;
import com.pirantisolution.pos.user.UserDtos.CreateUserRequest;
import com.pirantisolution.pos.user.UserDtos.RoleGrant;
import com.pirantisolution.pos.user.UserDtos.RoleGrantRequest;
import com.pirantisolution.pos.user.UserDtos.UpdateUserRequest;
import com.pirantisolution.pos.user.UserDtos.UserView;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Manajemen user & akses (role + outlet scope).
 *
 * <p>Aturan (ASSUMPTIONS A7), ditegakkan di service DAN RLS:
 * <ul>
 *   <li>butuh user.manage org-wide;</li>
 *   <li>tidak boleh mengubah akun/akses diri sendiri;</li>
 *   <li>hanya boleh mengelola user dan memberi role dengan rank di bawah rank sendiri;</li>
 *   <li>role outlet-scoped wajib disertai akses outlet tersebut.</li>
 * </ul>
 */
@Service
public class UserService {

    private static final Logger log = LoggerFactory.getLogger(UserService.class);
    static final String PERM_VIEW = "user.view";
    static final String PERM_MANAGE = "user.manage";

    private final UserRepository repo;
    private final AccessService access;
    private final AuditService audit;
    private final AuthProviderAdmin authProvider;

    public UserService(UserRepository repo, AccessService access, AuditService audit,
            AuthProviderAdmin authProvider) {
        this.repo = repo;
        this.access = access;
        this.audit = audit;
        this.authProvider = authProvider;
    }

    /** RLS menentukan user mana yang terlihat (pos.can_view_user). */
    @Transactional(readOnly = true)
    public List<UserView> list(String q, Boolean active) {
        access.currentUser();
        return repo.findAll(q, active);
    }

    @Transactional(readOnly = true)
    public UserView get(UUID id) {
        access.currentUser();
        return repo.findById(id).orElseThrow(() -> ApiException.notFound("User"));
    }

    @Transactional
    public UserView create(CreateUserRequest req) {
        access.requireOrg(PERM_MANAGE);
        CurrentUser actor = access.currentUser();
        validatePassword(req.password());

        String username = req.username().trim().toLowerCase();
        String email = req.email().trim().toLowerCase();
        if (repo.usernameOrEmailTaken(username, email)) {
            throw new ApiException(ErrorCode.DUPLICATE_VALUE, "Username atau email sudah dipakai");
        }
        if (req.employeeId() != null && repo.employeeLinked(req.employeeId(), null)) {
            throw new ApiException(ErrorCode.EMPLOYEE_ALREADY_LINKED);
        }
        Set<UUID> outletIds = new LinkedHashSet<>(req.outletIds());
        for (UUID outletId : outletIds) {
            if (!access.canAccessOutlet(outletId)) {
                throw new ApiException(ErrorCode.OUTLET_ACCESS_DENIED);
            }
        }
        Set<RoleGrantRequest> roles = new LinkedHashSet<>(req.roles());
        for (RoleGrantRequest g : roles) {
            requireGrantable(g);
            if (g.outletId() != null && !outletIds.contains(g.outletId())) {
                throw ApiException.validation("Role outlet-scoped membutuhkan akses ke outlet tersebut");
            }
        }

        // 1) Akun login di penyedia auth (di luar database POS).
        UUID authUserId = authProvider.createUser(email, req.password());
        // 2) Jika transaksi database gagal di titik mana pun (termasuk saat commit),
        //    akun login dihapus kembali agar tidak ada akun yatim.
        registerCompensation(() -> authProvider.deleteUser(authUserId), "delete auth user " + authUserId);

        UUID userId = repo.insert(authUserId, username, email, req.displayName().trim(), req.employeeId(),
                actor.userId());
        for (UUID outletId : outletIds) {
            repo.grantOutlet(userId, outletId, actor.userId());
        }
        for (RoleGrantRequest g : roles) {
            repo.grantRole(userId, g.roleId(), g.outletId(), actor.userId());
        }

        UserView created = repo.findById(userId).orElseThrow();
        audit.record(AuditEvent.of("USER_CREATED", "USER", userId).change(null, created));
        for (UUID outletId : outletIds) {
            audit.record(AuditEvent.of("USER_OUTLET_GRANTED", "USER", userId).outlet(outletId)
                    .change(null, Map.of("outletId", outletId)));
        }
        for (RoleGrant g : created.roles()) {
            audit.record(roleAudit("USER_ROLE_GRANTED", userId, g));
        }
        return created;
    }

    @Transactional
    public UserView update(UUID id, UpdateUserRequest req) {
        requireManageable(id);
        CurrentUser actor = access.currentUser();
        UserView before = repo.findById(id).orElseThrow(() -> ApiException.notFound("User"));
        if (req.employeeId() != null && !Objects.equals(req.employeeId(), before.employeeId())
                && repo.employeeLinked(req.employeeId(), id)) {
            throw new ApiException(ErrorCode.EMPLOYEE_ALREADY_LINKED);
        }
        Guards.requireUpdated(repo.update(id, req.displayName().trim(), req.employeeId(), req.active(),
                req.version(), actor.userId()));

        // Sinkronkan status login di penyedia auth agar user nonaktif tidak bisa mendapat token baru.
        if (before.active() != req.active()) {
            UUID authUserId = repo.findAuthUserId(id).orElseThrow();
            boolean ban = !req.active();
            authProvider.setBanned(authUserId, ban);
            registerCompensation(() -> authProvider.setBanned(authUserId, !ban),
                    "revert ban state of " + authUserId);
        }

        UserView after = repo.findById(id).orElseThrow();
        String action = before.active() && !after.active() ? "USER_DEACTIVATED"
                : !before.active() && after.active() ? "USER_REACTIVATED" : "USER_UPDATED";
        audit.record(AuditEvent.of(action, "USER", id).change(stripAccess(before), stripAccess(after)));
        return after;
    }

    /** Mengganti seluruh set role user (diff: cabut yang hilang, beri yang baru). */
    @Transactional
    public UserView setRoles(UUID id, List<RoleGrantRequest> requested) {
        requireManageable(id);
        CurrentUser actor = access.currentUser();
        UserView before = repo.findById(id).orElseThrow(() -> ApiException.notFound("User"));
        Set<UUID> userOutlets = before.outlets().stream().map(UserDtos.OutletRef::outletId)
                .collect(Collectors.toSet());

        Set<RoleGrantRequest> target = new LinkedHashSet<>(requested);
        Set<RoleGrantRequest> current = before.roles().stream()
                .map(g -> new RoleGrantRequest(g.roleId(), g.outletId()))
                .collect(Collectors.toCollection(LinkedHashSet::new));

        Set<RoleGrantRequest> toRevoke = new HashSet<>(current);
        toRevoke.removeAll(target);
        Set<RoleGrantRequest> toGrant = new LinkedHashSet<>(target);
        toGrant.removeAll(current);

        for (RoleGrantRequest g : toRevoke) {
            requireGrantable(g);
        }
        for (RoleGrantRequest g : toGrant) {
            requireGrantable(g);
            if (g.outletId() != null && !userOutlets.contains(g.outletId())) {
                throw ApiException.validation("Berikan akses outlet terlebih dahulu sebelum role outlet-scoped");
            }
        }

        for (RoleGrantRequest g : toRevoke) {
            repo.revokeRole(id, g.roleId(), g.outletId());
        }
        for (RoleGrantRequest g : toGrant) {
            repo.grantRole(id, g.roleId(), g.outletId(), actor.userId());
        }

        UserView after = repo.findById(id).orElseThrow();
        for (RoleGrant g : before.roles()) {
            if (toRevoke.contains(new RoleGrantRequest(g.roleId(), g.outletId()))) {
                audit.record(roleAudit("USER_ROLE_REVOKED", id, g));
            }
        }
        for (RoleGrant g : after.roles()) {
            if (toGrant.contains(new RoleGrantRequest(g.roleId(), g.outletId()))) {
                audit.record(roleAudit("USER_ROLE_GRANTED", id, g));
            }
        }
        return after;
    }

    /** Mengganti seluruh set akses outlet user. */
    @Transactional
    public UserView setOutlets(UUID id, List<UUID> requested) {
        requireManageable(id);
        CurrentUser actor = access.currentUser();
        UserView before = repo.findById(id).orElseThrow(() -> ApiException.notFound("User"));

        Set<UUID> target = new LinkedHashSet<>(requested);
        Set<UUID> current = before.outlets().stream().map(UserDtos.OutletRef::outletId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        Set<UUID> toRevoke = new HashSet<>(current);
        toRevoke.removeAll(target);
        Set<UUID> toGrant = new LinkedHashSet<>(target);
        toGrant.removeAll(current);

        for (UUID outletId : toGrant) {
            if (!access.canAccessOutlet(outletId)) {
                throw new ApiException(ErrorCode.OUTLET_ACCESS_DENIED);
            }
        }
        for (UUID outletId : toRevoke) {
            boolean scopedRoleRemains = before.roles().stream().anyMatch(r -> outletId.equals(r.outletId()));
            if (scopedRoleRemains) {
                throw ApiException.validation("Cabut role outlet-scoped di outlet tersebut terlebih dahulu");
            }
        }

        for (UUID outletId : toRevoke) {
            repo.revokeOutlet(id, outletId);
            audit.record(AuditEvent.of("USER_OUTLET_REVOKED", "USER", id).outlet(outletId)
                    .change(Map.of("outletId", outletId), null));
        }
        for (UUID outletId : toGrant) {
            repo.grantOutlet(id, outletId, actor.userId());
            audit.record(AuditEvent.of("USER_OUTLET_GRANTED", "USER", id).outlet(outletId)
                    .change(null, Map.of("outletId", outletId)));
        }
        return repo.findById(id).orElseThrow();
    }

    @Transactional
    public void resetPassword(UUID id, String newPassword) {
        requireManageable(id);
        validatePassword(newPassword);
        UUID authUserId = repo.findAuthUserId(id).orElseThrow(() -> ApiException.notFound("User"));
        // Audit dulu: jika penyedia auth gagal, transaksi rollback dan audit ikut batal.
        audit.record(AuditEvent.of("USER_PASSWORD_RESET", "USER", id));
        authProvider.setPassword(authUserId, newPassword);
    }

    // ------------------------------------------------------------------ helpers

    private void requireManageable(UUID targetUserId) {
        CurrentUser actor = access.currentUser();
        if (actor.userId().equals(targetUserId)) {
            throw new ApiException(ErrorCode.SELF_MODIFICATION_NOT_ALLOWED);
        }
        access.requireOrg(PERM_MANAGE);
        if (!access.canManageUser(targetUserId)) {
            // target tidak terlihat, beda organisasi, atau rank-nya >= rank pengelola
            throw new ApiException(ErrorCode.ROLE_ASSIGNMENT_NOT_ALLOWED,
                    "Anda tidak dapat mengelola user ini (role setara atau lebih tinggi)");
        }
    }

    private void requireGrantable(RoleGrantRequest g) {
        if (repo.role(g.roleId()).isEmpty()) {
            throw ApiException.validation("Role tidak ditemukan");
        }
        if (g.outletId() != null && !access.canAccessOutlet(g.outletId())) {
            throw new ApiException(ErrorCode.OUTLET_ACCESS_DENIED);
        }
        if (!access.canGrantRole(g.roleId(), g.outletId())) {
            throw new ApiException(ErrorCode.ROLE_ASSIGNMENT_NOT_ALLOWED);
        }
    }

    static void validatePassword(String password) {
        if (password == null || password.length() < 10 || password.length() > 72) {
            throw ApiException.validation("Password 10-72 karakter");
        }
        boolean letter = password.chars().anyMatch(Character::isLetter);
        boolean digit = password.chars().anyMatch(Character::isDigit);
        if (!letter || !digit) {
            throw ApiException.validation("Password harus mengandung huruf dan angka");
        }
    }

    private static AuditEvent roleAudit(String action, UUID userId, RoleGrant g) {
        Map<String, Object> value = new java.util.LinkedHashMap<>();
        value.put("roleCode", g.roleCode());
        value.put("roleId", g.roleId());
        value.put("outletId", g.outletId());
        value.put("outletCode", g.outletCode());
        AuditEvent e = AuditEvent.of(action, "USER", userId).outlet(g.outletId());
        return action.endsWith("REVOKED") ? e.change(value, null) : e.change(null, value);
    }

    private static UserView stripAccess(UserView u) {
        return u.withAccess(List.of(), List.of());
    }

    /**
     * Kompensasi pada sistem eksternal jika transaksi database tidak ter-commit.
     * Wajib dipanggil di dalam transaksi aktif.
     */
    private static void registerCompensation(Runnable compensation, String description) {
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCompletion(int status) {
                if (status != STATUS_COMMITTED) {
                    log.warn("Transaction not committed, compensating: {}", description);
                    try {
                        compensation.run();
                    } catch (RuntimeException e) {
                        log.error("Compensation failed: {} — manual action required", description, e);
                    }
                }
            }
        });
    }
}
