import { describe, expect, it } from 'vitest'
import { toCountLines } from './cashier'

describe('toCountLines', () => {
  it('keeps zero lines, drops empty or negative ones and floors quantities', () => {
    expect(toCountLines({ a: 2, b: 0, c: null, d: undefined, e: -1, f: 3.9 })).toEqual([
      { denominationId: 'a', quantity: 2 },
      { denominationId: 'b', quantity: 0 },
      { denominationId: 'f', quantity: 3 },
    ])
  })
})
