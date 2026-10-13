package com.pirantisolution.pos.finance;

import com.pirantisolution.pos.audit.AuditEvent;
import com.pirantisolution.pos.audit.AuditService;
import com.pirantisolution.pos.finance.FinanceDtos.BalanceView;
import com.pirantisolution.pos.finance.FinanceDtos.BankAccountView;
import com.pirantisolution.pos.finance.FinanceDtos.LedgerRow;
import com.pirantisolution.pos.finance.FinanceDtos.MerchantBalanceRow;
import com.pirantisolution.pos.finance.FinanceDtos.PayoutRow;
import com.pirantisolution.pos.finance.FinanceDtos.PlatformBankAccountRow;
import com.pirantisolution.pos.finance.FinanceDtos.PlatformPayoutRow;
import com.pirantisolution.pos.finance.FinanceDtos.SaveBankAccountRequest;
import com.pirantisolution.pos.finance.FinanceDtos.TermsRequest;
import com.pirantisolution.pos.security.AccessService;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Saldo, rekening, dan pencairan. Aturan uang (biaya, masa tahan, saldo cukup, rekening terverifikasi) ada di
 * fungsi database agar tidak bisa dilewati; service ini menambah audit.
 *
 * <p>Titik sambung otomasi: ketika penyedia disbursement dipilih, pemrosesan pencairan
 * ({@link #processPayout}) dipanggil oleh job yang mengirim transfer lewat API penyedia; kontrak datanya sama
 * dengan proses manual operator hari ini.
 */
@Service
public class FinanceService {

    private final FinanceRepository repo;
    private final AccessService access;
    private final AuditService audit;

    public FinanceService(FinanceRepository repo, AccessService access, AuditService audit) {
        this.repo = repo;
        this.access = access;
        this.audit = audit;
    }

    // ------------------------------------------------------------ merchant
    @Transactional(readOnly = true)
    public BalanceView balance() {
        access.currentUser();
        return repo.balance();
    }

    @Transactional(readOnly = true)
    public List<LedgerRow> ledger(Integer limit) {
        access.currentUser();
        return repo.ledger(limit == null ? 100 : Math.max(1, Math.min(limit, 500)));
    }

    @Transactional(readOnly = true)
    public Optional<BankAccountView> bankAccount() {
        access.currentUser();
        return repo.bankAccount();
    }

    @Transactional
    public Optional<BankAccountView> saveBankAccount(SaveBankAccountRequest req) {
        var me = access.currentUser();
        repo.saveBankAccount(req.bankCode(), req.accountNumber(), req.accountName());
        // nomor rekening tidak ditulis utuh ke audit
        String n = req.accountNumber().replaceAll("[^0-9]", "");
        audit.record(AuditEvent.of("BANK_ACCOUNT_CHANGED", "ORGANIZATION", me.organizationId())
                .change(null, Map.of("bank", req.bankCode().toUpperCase(), "last4", n.substring(Math.max(0, n.length() - 4)))));
        return repo.bankAccount();
    }

    @Transactional(readOnly = true)
    public List<PayoutRow> payouts() {
        access.currentUser();
        return repo.payouts();
    }

    @Transactional
    public List<PayoutRow> requestPayout(BigDecimal amount) {
        access.currentUser();
        UUID id = repo.requestPayout(amount);
        audit.record(AuditEvent.of("PAYOUT_REQUESTED", "PAYOUT", id).change(null, Map.of("amount", amount)));
        return repo.payouts();
    }

    // ------------------------------------------------------------ operator platform
    @Transactional(readOnly = true)
    public List<PlatformPayoutRow> platformPayouts(String status) {
        access.requireOrg("platform.manage");
        return repo.platformPayouts(status);
    }

    @Transactional
    public void processPayout(UUID id, String status, String reference, String note) {
        access.requireOrg("platform.manage");
        repo.processPayout(id, status, reference, note);
    }

    @Transactional(readOnly = true)
    public List<PlatformBankAccountRow> platformBankAccounts(boolean pendingOnly) {
        access.requireOrg("platform.manage");
        return repo.platformBankAccounts(pendingOnly);
    }

    @Transactional
    public void verifyBankAccount(UUID org, boolean verified) {
        access.requireOrg("platform.manage");
        repo.verifyBankAccount(org, verified);
    }

    @Transactional
    public void setTerms(UUID org, TermsRequest req) {
        access.requireOrg("platform.manage");
        repo.setTerms(org, req.feePercent(), req.feeFlat(), req.holdDays(), req.minPayout());
    }

    @Transactional(readOnly = true)
    public List<MerchantBalanceRow> platformBalances() {
        access.requireOrg("platform.manage");
        return repo.platformBalances();
    }
}
