package com.pirantisolution.pos.finance;

import com.pirantisolution.pos.finance.FinanceDtos.BalanceView;
import com.pirantisolution.pos.finance.FinanceDtos.BankAccountView;
import com.pirantisolution.pos.finance.FinanceDtos.LedgerRow;
import com.pirantisolution.pos.finance.FinanceDtos.MerchantBalanceRow;
import com.pirantisolution.pos.finance.FinanceDtos.PayoutRow;
import com.pirantisolution.pos.finance.FinanceDtos.PlatformBankAccountRow;
import com.pirantisolution.pos.finance.FinanceDtos.PlatformPayoutRow;
import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** Semua tulis lewat fungsi database (pos.*) yang memeriksa izin; baca tunduk pada RLS. */
@Repository
public class FinanceRepository {

    private final JdbcClient jdbc;

    public FinanceRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    BalanceView balance() {
        return jdbc.sql("SELECT * FROM pos.my_balance()").query(BalanceView.class).single();
    }

    List<LedgerRow> ledger(int limit) {
        return jdbc.sql("""
                SELECT id, entry_type, amount, available_at, provider, description, created_at
                FROM pos.merchant_ledger ORDER BY seq DESC LIMIT :limit
                """).param("limit", limit).query(LedgerRow.class).list();
    }

    Optional<BankAccountView> bankAccount() {
        return jdbc.sql("SELECT bank_code, account_number, account_name, status, updated_at FROM pos.merchant_bank_accounts")
                .query(BankAccountView.class).optional();
    }

    void saveBankAccount(String bank, String number, String name) {
        jdbc.sql("SELECT pos.save_bank_account(:b, :n, :a)").param("b", bank).param("n", number).param("a", name)
                .query().singleRow();
    }

    List<PayoutRow> payouts() {
        return jdbc.sql("""
                SELECT id, amount, status, bank_code, account_number, account_name, requested_at, processed_at,
                       provider_ref, note
                FROM pos.payouts ORDER BY requested_at DESC LIMIT 100
                """).query(PayoutRow.class).list();
    }

    UUID requestPayout(BigDecimal amount) {
        return jdbc.sql("SELECT pos.request_payout(:a)").param("a", amount).query(UUID.class).single();
    }

    // ------------------------------------------------------------ operator platform
    List<PlatformPayoutRow> platformPayouts(String status) {
        return jdbc.sql("SELECT * FROM pos.platform_payouts(CAST(:s AS text))").param("s", status)
                .query(PlatformPayoutRow.class).list();
    }

    void processPayout(UUID id, String status, String ref, String note) {
        jdbc.sql("SELECT pos.platform_process_payout(:id, :s, :r, :n)").param("id", id).param("s", status)
                .param("r", ref).param("n", note).query().singleRow();
    }

    List<PlatformBankAccountRow> platformBankAccounts(boolean pendingOnly) {
        return jdbc.sql("SELECT * FROM pos.platform_bank_accounts(:p)").param("p", pendingOnly)
                .query(PlatformBankAccountRow.class).list();
    }

    void verifyBankAccount(UUID org, boolean verified) {
        jdbc.sql("SELECT pos.platform_verify_bank_account(:o, :v)").param("o", org).param("v", verified)
                .query().singleRow();
    }

    void setTerms(UUID org, BigDecimal feePercent, BigDecimal feeFlat, int holdDays, BigDecimal minPayout) {
        jdbc.sql("SELECT pos.platform_set_terms(:o, :p, :f, :h, :m)").param("o", org).param("p", feePercent)
                .param("f", feeFlat).param("h", holdDays).param("m", minPayout).query().singleRow();
    }

    List<MerchantBalanceRow> platformBalances() {
        return jdbc.sql("SELECT * FROM pos.platform_balances()").query(MerchantBalanceRow.class).list();
    }
}
