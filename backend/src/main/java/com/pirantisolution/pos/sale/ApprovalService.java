package com.pirantisolution.pos.sale;

import com.pirantisolution.pos.auth.provider.AuthProviderAdmin;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.sale.SaleDtos.ApprovalRequest;
import com.pirantisolution.pos.sale.SaleDtos.ApprovalView;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Approval supervisor di terminal kasir (§20, §27): supervisor memasukkan email + password di layar
 * kasir. Password diverifikasi ke penyedia login TANPA transaksi database terbuka, lalu approval
 * sekali pakai dibuat di transaksi terpisah. Password tidak pernah disimpan atau di-log.
 * Endpoint ini dibatasi rate limit seperti endpoint login.
 */
@Service
public class ApprovalService {

    private static final Logger log = LoggerFactory.getLogger(ApprovalService.class);

    private final AuthProviderAdmin authProvider;
    private final SaleService sales;

    public ApprovalService(AuthProviderAdmin authProvider, SaleService sales) {
        this.authProvider = authProvider;
        this.sales = sales;
    }

    public ApprovalView request(ApprovalRequest req) {
        UUID authUserId = authProvider.verifyPassword(req.email().trim().toLowerCase(), req.password());
        if (authUserId == null) {
            log.info("Approval credential rejected for sale {}", req.saleId());
            throw new ApiException(ErrorCode.APPROVER_INVALID);
        }
        return sales.createApproval(authUserId, req);
    }
}
