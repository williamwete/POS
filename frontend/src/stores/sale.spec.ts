import { describe, expect, it } from 'vitest'
import { newClientTransactionId } from './sale'

describe('newClientTransactionId', () => {
  it('is traceable to the terminal and matches the server pattern', () => {
    const id = newClientTransactionId('POS-JKT-01')
    expect(id.startsWith('POS-JKT-01-')).toBe(true)
    expect(id).toMatch(/^[A-Za-z0-9._:-]{8,80}$/)
    expect(newClientTransactionId('POS-JKT-01')).not.toBe(id)
  })

  it('strips unsafe characters from the terminal code', () => {
    expect(newClientTransactionId('POS JKT/01')).toMatch(/^POSJKT01-\d{8}-[0-9a-f]{16}$/)
  })
})
