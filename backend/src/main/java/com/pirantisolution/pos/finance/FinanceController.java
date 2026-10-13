package com.pirantisolution.pos.finance;

import com.pirantisolution.pos.common.api.ApiResponse;
import com.pirantisolution.pos.common.api.Responses;
import com.pirantisolution.pos.finance.FinanceDtos.BalanceView;
import com.pirantisolution.pos.finance.FinanceDtos.BankAccountView;
import com.pirantisolution.pos.finance.FinanceDtos.LedgerRow;
import com.pirantisolution.pos.finance.FinanceDtos.MerchantBalanceRow;
import com.pirantisolution.pos.finance.FinanceDtos.PayoutRequest;
import com.pirantisolution.pos.finance.FinanceDtos.PayoutRow;
import com.pirantisolution.pos.finance.FinanceDtos.PlatformBankAccountRow;
import com.pirantisolution.pos.finance.FinanceDtos.PlatformPayoutRow;
import com.pirantisolution.pos.finance.FinanceDtos.ProcessPayoutRequest;
import com.pirantisolution.pos.finance.FinanceDtos.SaveBankAccountRequest;
import com.pirantisolution.pos.finance.FinanceDtos.TermsRequest;
import com.pirantisolution.pos.finance.FinanceDtos.VerifyBankRequest;
import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class FinanceController {

    private final FinanceService service;

    public FinanceController(FinanceService service) {
        this.service = service;
    }

    // ------------------------------------------------------------ merchant (izin finance.manage)
    @GetMapping("/api/finance/balance")
    public ResponseEntity<ApiResponse<BalanceView>> balance() {
        return Responses.ok(service.balance());
    }

    @GetMapping("/api/finance/ledger")
    public ResponseEntity<ApiResponse<List<LedgerRow>>> ledger(@RequestParam(required = false) Integer limit) {
        return Responses.ok(service.ledger(limit));
    }

    @GetMapping("/api/finance/bank-account")
    public ResponseEntity<ApiResponse<BankAccountView>> bankAccount() {
        return Responses.ok(service.bankAccount().orElse(null));
    }

    @PutMapping("/api/finance/bank-account")
    public ResponseEntity<ApiResponse<BankAccountView>> saveBankAccount(@Valid @RequestBody SaveBankAccountRequest req) {
        return Responses.ok(service.saveBankAccount(req).orElse(null), "Rekening disimpan");
    }

    @GetMapping("/api/finance/payouts")
    public ResponseEntity<ApiResponse<List<PayoutRow>>> payouts() {
        return Responses.ok(service.payouts());
    }

    @PostMapping("/api/finance/payouts")
    public ResponseEntity<ApiResponse<List<PayoutRow>>> requestPayout(@Valid @RequestBody PayoutRequest req) {
        return Responses.created(service.requestPayout(req.amount()), "Pencairan diajukan");
    }

    // ------------------------------------------------------------ operator platform (izin platform.manage)
    @GetMapping("/api/platform/payouts")
    public ResponseEntity<ApiResponse<List<PlatformPayoutRow>>> platformPayouts(@RequestParam(required = false) String status) {
        return Responses.ok(service.platformPayouts(status));
    }

    @PutMapping("/api/platform/payouts/{id}")
    public ResponseEntity<ApiResponse<List<PlatformPayoutRow>>> processPayout(@PathVariable UUID id,
            @Valid @RequestBody ProcessPayoutRequest req) {
        service.processPayout(id, req.status(), req.reference(), req.note());
        return Responses.ok(service.platformPayouts(null), "Pencairan diperbarui");
    }

    @GetMapping("/api/platform/bank-accounts")
    public ResponseEntity<ApiResponse<List<PlatformBankAccountRow>>> platformBankAccounts(
            @RequestParam(defaultValue = "false") boolean pendingOnly) {
        return Responses.ok(service.platformBankAccounts(pendingOnly));
    }

    @PutMapping("/api/platform/merchants/{id}/bank-account/verify")
    public ResponseEntity<ApiResponse<List<PlatformBankAccountRow>>> verifyBank(@PathVariable UUID id,
            @RequestBody VerifyBankRequest req) {
        service.verifyBankAccount(id, req.verified());
        return Responses.ok(service.platformBankAccounts(false), "Rekening diperbarui");
    }

    @PutMapping("/api/platform/merchants/{id}/terms")
    public ResponseEntity<ApiResponse<List<MerchantBalanceRow>>> terms(@PathVariable UUID id, @Valid @RequestBody TermsRequest req) {
        service.setTerms(id, req);
        return Responses.ok(service.platformBalances(), "Ketentuan disimpan");
    }

    @GetMapping("/api/platform/balances")
    public ResponseEntity<ApiResponse<List<MerchantBalanceRow>>> balances() {
        return Responses.ok(service.platformBalances());
    }
}
