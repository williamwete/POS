package com.pirantisolution.pos.cashier;

import com.pirantisolution.pos.auth.provider.AuthProviderAdmin;
import com.pirantisolution.pos.cashier.CashierDtos.CashApprovalRequest;
import com.pirantisolution.pos.cashier.CashierDtos.CashApprovalView;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Approval supervisor untuk kas keluar di atas ambang dan selisih kas (§25, §51). Sama seperti
 * approval penjualan: password diverifikasi ke penyedia login TANPA transaksi database terbuka,
 * approval sekali pakai (2 menit) dibuat di transaksi terpisah. Password tidak pernah disimpan/di-log.
 */
@Service
public class CashApprovalService {

    private static final Logger log = LoggerFactory.getLogger(CashApprovalService.class);

    private final AuthProviderAdmin authProvider;
    private final CashierService cashier;

    public CashApprovalService(AuthProviderAdmin authProvider, CashierService cashier) {
        this.authProvider = authProvider;
        this.cashier = cashier;
    }

    public CashApprovalView request(CashApprovalRequest req) {
        UUID authUserId = authProvider.verifyPassword(req.email().trim().toLowerCase(), req.password());
        if (authUserId == null) {
            log.info("Cash approval credential rejected for session {}", req.sessionId());
            throw new ApiException(ErrorCode.APPROVER_INVALID);
        }
        return cashier.createApproval(authUserId, req);
    }
}
