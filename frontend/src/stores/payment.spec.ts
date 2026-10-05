import { describe, expect, it } from 'vitest'
import { newClientPaymentId, quickCashAmounts } from './payment'

describe('payment helpers', () => {
  it('suggests exact amount first, then rounded notes above the remaining bill', () => {
    expect(quickCashAmounts(87500)).toEqual([87500, 88000, 90000, 100000])
    expect(quickCashAmounts(50000)).toEqual([50000, 100000])
    expect(quickCashAmounts(12300)).toEqual([12300, 13000, 15000, 20000, 50000])
    expect(quickCashAmounts(0)).toEqual([])
  })

  it('creates client payment ids accepted by the server pattern', () => {
    expect(newClientPaymentId()).toMatch(/^[A-Za-z0-9._:-]{8,80}$/)
  })
})
