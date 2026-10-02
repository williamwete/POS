package com.pirantisolution.pos.sale;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Menghitung nilai diskon dan alokasi diskon transaksi ke baris (§20).
 *
 * <p>Aturan identik dengan validasi database ({@code pos.sale_discount_check}):
 * <ul>
 *   <li>diskon persen = round(basis × persen / 100), diskon nominal = min(nilai, basis);</li>
 *   <li>basis diskon baris = gross baris; basis diskon transaksi = Σ(gross − diskon baris);</li>
 *   <li>diskon transaksi dialokasikan proporsional ke baris dengan metode sisa terbesar sehingga
 *       jumlah alokasi selalu tepat sama dengan nilai diskon (pajak per baris tetap konsisten).</li>
 * </ul>
 * Pembulatan ke rupiah penuh, HALF_UP (= round() PostgreSQL untuk nilai positif).
 */
public final class CartCalculator {

    public enum Type { PERCENTAGE, AMOUNT }

    public record Line(UUID id, BigDecimal gross) {
    }

    public record Discount(UUID id, UUID lineId, Type type, BigDecimal value) {
    }

    public record LineResult(UUID id, BigDecimal itemDiscount, BigDecimal cartDiscount) {
    }

    public record Result(List<LineResult> lines, Map<UUID, BigDecimal> discountAmounts) {
    }

    private CartCalculator() {
    }

    public static BigDecimal round(BigDecimal v) {
        return v.setScale(0, RoundingMode.HALF_UP);
    }

    /** Nilai diskon terhadap basis tertentu. */
    public static BigDecimal amount(Type type, BigDecimal value, BigDecimal base) {
        if (base.signum() <= 0) {
            return BigDecimal.ZERO;
        }
        return type == Type.PERCENTAGE
                ? round(base.multiply(value).divide(BigDecimal.valueOf(100)))
                : value.min(base);
    }

    /** Persentase efektif (dibulatkan ke atas, 3 desimal) — dipakai meminta approval. */
    public static BigDecimal percentOf(BigDecimal amount, BigDecimal base) {
        if (base.signum() <= 0) {
            return BigDecimal.ZERO;
        }
        return amount.multiply(BigDecimal.valueOf(100)).divide(base, 3, RoundingMode.UP);
    }

    /** Apakah diskon sebesar {@code amount} masih dalam batas {@code maxPercent} untuk basis tsb. */
    public static boolean withinLimit(BigDecimal amount, BigDecimal base, BigDecimal maxPercent) {
        return amount.compareTo(round(base.multiply(maxPercent).divide(BigDecimal.valueOf(100)))) <= 0;
    }

    public static Result calculate(List<Line> lines, List<Discount> discounts) {
        Map<UUID, BigDecimal> discountAmounts = new HashMap<>();
        Map<UUID, BigDecimal> itemDisc = new HashMap<>();
        Discount cart = null;
        for (Discount d : discounts) {
            if (d.lineId() == null) {
                cart = d;
                continue;
            }
            Line line = lines.stream().filter(l -> l.id().equals(d.lineId())).findFirst().orElse(null);
            BigDecimal amt = line == null ? BigDecimal.ZERO : amount(d.type(), d.value(), line.gross());
            discountAmounts.put(d.id(), amt);
            if (line != null) {
                itemDisc.merge(line.id(), amt, BigDecimal::add);
            }
        }

        BigDecimal base = BigDecimal.ZERO;
        List<BigDecimal> weights = new ArrayList<>();
        for (Line l : lines) {
            BigDecimal w = l.gross().subtract(itemDisc.getOrDefault(l.id(), BigDecimal.ZERO)).max(BigDecimal.ZERO);
            weights.add(w);
            base = base.add(w);
        }

        BigDecimal[] alloc = new BigDecimal[lines.size()];
        java.util.Arrays.fill(alloc, BigDecimal.ZERO);
        if (cart != null) {
            BigDecimal cartAmt = amount(cart.type(), cart.value(), base);
            discountAmounts.put(cart.id(), cartAmt);
            if (cartAmt.signum() > 0) {
                allocate(cartAmt, base, weights, alloc);
            }
        }

        List<LineResult> out = new ArrayList<>();
        for (int i = 0; i < lines.size(); i++) {
            Line l = lines.get(i);
            out.add(new LineResult(l.id(), itemDisc.getOrDefault(l.id(), BigDecimal.ZERO), alloc[i]));
        }
        return new Result(out, discountAmounts);
    }

    /** Alokasi proporsional, sisa pembulatan ke pecahan terbesar (urutan baris bila sama). */
    static void allocate(BigDecimal total, BigDecimal base, List<BigDecimal> weights, BigDecimal[] out) {
        record Part(int index, BigDecimal fraction) {
        }
        BigDecimal assigned = BigDecimal.ZERO;
        List<Part> parts = new ArrayList<>();
        for (int i = 0; i < weights.size(); i++) {
            BigDecimal exact = total.multiply(weights.get(i)).divide(base, 24, RoundingMode.DOWN);
            BigDecimal floor = exact.setScale(0, RoundingMode.DOWN);
            out[i] = floor;
            assigned = assigned.add(floor);
            parts.add(new Part(i, exact.subtract(floor)));
        }
        int remainder = total.subtract(assigned).intValueExact();
        parts.sort(Comparator.comparing(Part::fraction).reversed().thenComparing(Part::index));
        for (int k = 0; k < remainder; k++) {
            int idx = parts.get(k % parts.size()).index();
            out[idx] = out[idx].add(BigDecimal.ONE);
        }
    }
}
