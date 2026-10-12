import { describe, expect, it } from 'vitest'
import { countTotal, formatRupiah } from './money'

describe('money', () => {
  it('formats rupiah without decimals', () => {
    expect(formatRupiah(525000)).toBe('Rp 525.000')
    expect(formatRupiah('100000.00')).toBe('Rp 100.000')
    expect(formatRupiah(null)).toBe('—')
  })

  it('sums denomination counts and ignores unknown or invalid lines', () => {
    const values = new Map([['a', 100000], ['b', 50000], ['c', 500]])
    expect(countTotal(values, { a: 2, b: 3, c: 4 })).toBe(352000)
    expect(countTotal(values, { a: -1, x: 10, b: null })).toBe(0)
    expect(countTotal(values, { a: 1.7 })).toBe(100000)
  })
})

describe('splitIntoDenominations', () => {
  const d = [100000, 50000, 20000, 10000, 5000, 2000, 1000, 500, 100].map((value) => ({ id: String(value), value }))
  it('memecah dari pecahan terbesar', async () => {
    const { splitIntoDenominations } = await import('./money')
    expect(splitIntoDenominations(275500, d)).toMatchObject({ '100000': 2, '50000': 1, '20000': 1, '5000': 1, '500': 1 })
  })
  it('menolak nominal yang tidak habis dibagi pecahan terkecil', async () => {
    const { splitIntoDenominations } = await import('./money')
    expect(splitIntoDenominations(150, d)).toBeNull()
    expect(splitIntoDenominations(0, d)).not.toBeNull()
  })
})
