package com.pirantisolution.pos.platform;

import com.pirantisolution.pos.auth.provider.AuthProviderAdmin;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.platform.PlatformDtos.CreateMerchantRequest;
import com.pirantisolution.pos.platform.PlatformDtos.CreatedMerchant;
import com.pirantisolution.pos.platform.PlatformDtos.MerchantRow;
import com.pirantisolution.pos.platform.PlatformDtos.MerchantUserRow;
import com.pirantisolution.pos.platform.PlatformDtos.PlanRow;
import com.pirantisolution.pos.security.AccessService;
import java.util.List;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Konsol operator platform: membuat merchant (organisasi + outlet + terminal + akun pemilik), mengganti paket,
 * dan menangguhkan. Izin platform.manage diperiksa di sini dan di setiap fungsi database.
 */
@Service
public class PlatformService {

    private static final Logger log = LoggerFactory.getLogger(PlatformService.class);
    private static final String PERM = "platform.manage";

    private final PlatformRepository repo;
    private final AccessService access;
    private final AuthProviderAdmin authProvider;

    public PlatformService(PlatformRepository repo, AccessService access, AuthProviderAdmin authProvider) {
        this.repo = repo;
        this.access = access;
        this.authProvider = authProvider;
    }

    @Transactional(readOnly = true)
    public List<PlanRow> plans() {
        access.requireOrg(PERM);
        return repo.plans();
    }

    @Transactional(readOnly = true)
    public List<MerchantRow> merchants() {
        access.requireOrg(PERM);
        return repo.merchants();
    }

    @Transactional(readOnly = true)
    public List<MerchantUserRow> users(UUID org) {
        access.requireOrg(PERM);
        return repo.users(org);
    }

    @Transactional
    public CreatedMerchant create(CreateMerchantRequest req) {
        access.requireOrg(PERM);
        validatePassword(req.ownerPassword());
        String email = req.ownerEmail().trim().toLowerCase();

        // 1) akun login pemilik di penyedia auth; 2) dihapus lagi bila transaksi database gagal.
        UUID authUserId = authProvider.createUser(email, req.ownerPassword());
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCompletion(int status) {
                if (status != STATUS_COMMITTED) {
                    try {
                        authProvider.deleteUser(authUserId);
                    } catch (RuntimeException e) {
                        log.error("Compensation failed: delete auth user {} — manual action required", authUserId, e);
                    }
                }
            }
        });

        UUID org = repo.provision(req, req.code().toUpperCase(), req.outletCode().toUpperCase(), email, authUserId);
        repo.applyPreset(org);
        MerchantRow row = repo.merchant(org).orElseThrow();
        return new CreatedMerchant(row, req.code().toLowerCase() + ".owner");
    }

    @Transactional
    public MerchantRow setPlan(UUID org, String plan) {
        access.requireOrg(PERM);
        repo.setPlan(org, plan);
        return repo.merchant(org).orElseThrow(() -> ApiException.notFound("Merchant"));
    }

    /** Menangguhkan menutup akses via RLS (organisasi nonaktif); login juga diblokir di penyedia auth. */
    @Transactional
    public MerchantRow setActive(UUID org, boolean active, String reason) {
        access.requireOrg(PERM);
        repo.setActive(org, active, reason);
        for (MerchantUserRow u : repo.users(org)) {
            try {
                authProvider.setBanned(u.authUserId(), !active || !u.active());
            } catch (RuntimeException e) {
                log.warn("Gagal mengubah blokir login user {}: {}", u.username(), e.getMessage());
            }
        }
        return repo.merchant(org).orElseThrow(() -> ApiException.notFound("Merchant"));
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
}
