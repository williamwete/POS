import { describe, expect, it } from 'vitest'
import { fieldErrorsOf, passwordSchema, terminalSchema, userCreateSchema } from './validation'
import { formatBusinessDate } from './format'

describe('validation', () => {
  it('requires letters and digits in passwords', () => {
    expect(passwordSchema.safeParse('onlyletters!').success).toBe(false)
    expect(passwordSchema.safeParse('1234567890').success).toBe(false)
    expect(passwordSchema.safeParse('short1').success).toBe(false)
    expect(passwordSchema.safeParse('KasirBaru2026').success).toBe(true)
  })

  it('enforces code format matching the database constraint', () => {
    const bad = terminalSchema.safeParse({ outletId: '00000000-0000-4000-8000-000000000101', code: 'pos jkt', name: 'x' })
    expect(fieldErrorsOf(bad).code).toBeTruthy()
    const ok = terminalSchema.safeParse({ outletId: '00000000-0000-4000-8000-000000000101', code: 'POS-JKT-03', name: 'Kasir 3' })
    expect(ok.success).toBe(true)
  })

  it('rejects usernames with uppercase or spaces', () => {
    const r = userCreateSchema.safeParse({ username: 'Bad User', email: 'a@b.co', displayName: 'x', password: 'Password2026' })
    expect(fieldErrorsOf(r).username).toBeTruthy()
  })
})

describe('format', () => {
  it('formats business date without timezone shift', () => {
    expect(formatBusinessDate('2026-10-02')).toContain('2026')
    expect(formatBusinessDate('2026-10-02')).toMatch(/Oktober/)
    expect(formatBusinessDate('invalid')).toBe('—')
  })
})
