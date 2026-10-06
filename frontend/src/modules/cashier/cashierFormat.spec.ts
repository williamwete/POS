import { describe, expect, it } from 'vitest'
import { signedRupiah } from './cashierFormat'

const norm = (s: string) => s.replace(/\s/g, ' ')

describe('signedRupiah', () => {
  it('shows sign for shortage and overage, plain for zero and dash for missing', () => {
    expect(norm(signedRupiah(-50000))).toBe('−Rp 50.000')
    expect(norm(signedRupiah(12500))).toBe('+Rp 12.500')
    expect(norm(signedRupiah(0))).toBe('Rp 0')
    expect(signedRupiah(null)).toBe('—')
  })
})
