package com.pirantisolution.pos.returns;

import com.pirantisolution.pos.auth.provider.AuthProviderAdmin;
import com.pirantisolution.pos.common.error.ApiException;
import com.pirantisolution.pos.common.error.ErrorCode;
import com.pirantisolution.pos.returns.ReturnDtos.ReturnView;
import com.pirantisolution.pos.returns.ReturnDtos.TerminalApprovalRequest;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Approval refund di terminal kasir: password approver diverifikasi ke penyedia login TANPA transaksi
 * database terbuka; approval sekali pakai lalu dibuat & dipakai dalam satu transaksi penyelesaian retur.
 */
@Service
public class ReturnApprovalService {

    private static final Logger log = LoggerFactory.getLogger(ReturnApprovalService.class);

    private final AuthProviderAdmin authProvider;
    private final ReturnService returns;

    public ReturnApprovalService(AuthProviderAdmin authProvider, ReturnService returns) {
        this.authProvider = authProvider;
        this.returns = returns;
    }

    public ReturnView approveAtTerminal(UUID returnId, TerminalApprovalRequest req) {
        UUID authUserId = authProvider.verifyPassword(req.email().trim().toLowerCase(), req.password());
        if (authUserId == null) {
            log.info("Refund approval credential rejected for return {}", returnId);
            throw new ApiException(ErrorCode.APPROVER_INVALID);
        }
        return returns.completeWithApprover(returnId, authUserId, req.refundReference());
    }
}
