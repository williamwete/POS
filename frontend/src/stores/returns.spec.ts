import { describe, expect, it } from 'vitest'
import { toReturnLines } from './returns'

describe('toReturnLines', () => {
  it('drops zero/empty lines, unknown lines and caps at remaining quantity', () => {
    expect(toReturnLines({ a: 2, b: 0, c: null, d: 5, x: 1 }, { a: 10, b: 3, c: 1, d: 3 })).toEqual([
      { saleItemId: 'a', quantity: 2 },
      { saleItemId: 'd', quantity: 3 },
    ])
  })
})
