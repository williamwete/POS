const rupiah = new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 })
const plain = new Intl.NumberFormat('id-ID', { maximumFractionDigits: 0 })

/** 525000 -> "Rp 525.000" (spasi biasa agar konsisten di semua browser). */
export function formatRupiah(value?: number | string | null): string {
  if (value === null || value === undefined || value === '') return '—'
  const n = typeof value === 'string' ? Number(value) : value
  if (!Number.isFinite(n)) return '—'
  return rupiah.format(n).replace(/ /g, ' ')
}

/** 100000 -> "100.000" */
export function formatNumber(value: number): string {
  return plain.format(value)
}

/**
 * Total hitungan dalam satuan rupiah bulat. Hanya untuk tampilan: server menghitung ulang
 * dari master denominasi dan nilai inilah yang tersimpan.
 */
export function countTotal(values: Map<string, number>, quantities: Record<string, number | null | undefined>): number {
  let total = 0
  for (const [id, qty] of Object.entries(quantities)) {
    const v = values.get(id)
    if (v === undefined || !qty || qty < 0) continue
    total += Math.round(v) * Math.floor(qty)
  }
  return total
}

/**
 * Pecah nominal ke jumlah per pecahan (greedy dari yang terbesar). null bila tidak habis dibagi
 * pecahan terkecil. Dipakai agar layar cukup satu kolom nominal sementara server tetap menyimpan rincian.
 */
export function splitIntoDenominations(
  total: number,
  denominations: { id: string; value: number }[],
): Record<string, number> | null {
  const q: Record<string, number> = {}
  let rest = Math.round(total)
  for (const d of [...denominations].sort((a, b) => b.value - a.value)) {
    const n = Math.floor(rest / d.value)
    q[d.id] = n
    rest -= n * d.value
  }
  return rest === 0 ? q : null
}
