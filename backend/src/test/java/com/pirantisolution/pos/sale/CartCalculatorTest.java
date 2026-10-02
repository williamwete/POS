package com.pirantisolution.pos.sale;

import static org.assertj.core.api.Assertions.assertThat;

import com.pirantisolution.pos.sale.CartCalculator.Discount;
import com.pirantisolution.pos.sale.CartCalculator.Line;
import com.pirantisolution.pos.sale.CartCalculator.LineResult;
import com.pirantisolution.pos.sale.CartCalculator.Result;
import com.pirantisolution.pos.sale.CartCalculator.Type;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class CartCalculatorTest {

    private static final UUID A = UUID.randomUUID();
    private static final UUID B = UUID.randomUUID();
    private static final UUID C = UUID.randomUUID();

    private static BigDecimal n(long v) {
        return BigDecimal.valueOf(v);
    }

    private static BigDecimal cartTotal(Result r) {
        return r.lines().stream().map(LineResult::cartDiscount).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    @Test
    void percentageItemDiscountRoundsHalfUp() {
        UUID d = UUID.randomUUID();
        Result r = CartCalculator.calculate(List.of(new Line(A, n(78_000)), new Line(B, n(4_990))),
                List.of(new Discount(d, B, Type.PERCENTAGE, new BigDecimal("10"))));
        // 4.990 × 10% = 499 ; baris A tanpa diskon
        assertThat(r.discountAmounts().get(d)).isEqualByComparingTo("499");
        assertThat(r.lines().get(0).itemDiscount()).isEqualByComparingTo("0");
        assertThat(r.lines().get(1).itemDiscount()).isEqualByComparingTo("499");
        assertThat(CartCalculator.round(new BigDecimal("2.5"))).isEqualByComparingTo("3");
    }

    @Test
    void amountDiscountNeverExceedsBase() {
        UUID d = UUID.randomUUID();
        Result r = CartCalculator.calculate(List.of(new Line(A, n(5_000))),
                List.of(new Discount(d, A, Type.AMOUNT, n(8_000))));
        assertThat(r.discountAmounts().get(d)).isEqualByComparingTo("5000");
    }

    @Test
    void cartDiscountAllocationSumsExactly() {
        UUID cart = UUID.randomUUID();
        // basis 10.000 + 10.000 + 10.000, diskon 10.000 → 3.334/3.333/3.333 (sisa ke pecahan terbesar, lalu urutan)
        Result r = CartCalculator.calculate(List.of(new Line(A, n(10_000)), new Line(B, n(10_000)), new Line(C, n(10_000))),
                List.of(new Discount(cart, null, Type.AMOUNT, n(10_000))));
        assertThat(cartTotal(r)).isEqualByComparingTo("10000");
        assertThat(r.lines().get(0).cartDiscount()).isEqualByComparingTo("3334");
        assertThat(r.lines().get(1).cartDiscount()).isEqualByComparingTo("3333");
    }

    @Test
    void cartDiscountUsesBaseAfterItemDiscounts() {
        UUID item = UUID.randomUUID();
        UUID cart = UUID.randomUUID();
        Result r = CartCalculator.calculate(List.of(new Line(A, n(100_000)), new Line(B, n(50_000))),
                List.of(new Discount(item, A, Type.PERCENTAGE, n(10)),
                        new Discount(cart, null, Type.PERCENTAGE, n(5))));
        // basis transaksi = 90.000 + 50.000 = 140.000 ; 5% = 7.000 → 4.500 / 2.500
        assertThat(r.discountAmounts().get(cart)).isEqualByComparingTo("7000");
        assertThat(r.lines().get(0).cartDiscount()).isEqualByComparingTo("4500");
        assertThat(r.lines().get(1).cartDiscount()).isEqualByComparingTo("2500");
        for (LineResult l : r.lines()) {
            BigDecimal gross = l.id().equals(A) ? n(100_000) : n(50_000);
            assertThat(gross.subtract(l.itemDiscount()).subtract(l.cartDiscount()).signum()).isGreaterThanOrEqualTo(0);
        }
    }

    @Test
    void approvalLimitAndPercent() {
        assertThat(CartCalculator.withinLimit(n(3_900), n(78_000), n(5))).isTrue();
        assertThat(CartCalculator.withinLimit(n(3_901), n(78_000), n(5))).isFalse();
        assertThat(CartCalculator.percentOf(n(10_000), n(30_000))).isEqualByComparingTo("33.334");
    }

    @Test
    void emptyCartGivesZero() {
        UUID cart = UUID.randomUUID();
        Result r = CartCalculator.calculate(List.of(), List.of(new Discount(cart, null, Type.PERCENTAGE, n(10))));
        assertThat(r.discountAmounts().get(cart)).isEqualByComparingTo("0");
    }
}
