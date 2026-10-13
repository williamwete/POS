import { describe, expect, it } from 'vitest'
import { createScanBuffer, looksLikeBarcode } from './scanner'

function type(buf: ReturnType<typeof createScanBuffer>, text: string, gap: number, start = 1000) {
  let t = start
  for (const ch of text) {
    buf.push(ch, t)
    t += gap
  }
  return buf.push('Enter', t)
}

describe('createScanBuffer', () => {
  it('mengenali ketikan cepat sebagai scan', () => {
    expect(type(createScanBuffer(), '8990000000012', 10)).toBe('8990000000012')
  })
  it('mengabaikan ketikan manusia yang lambat', () => {
    expect(type(createScanBuffer(), '8990000000012', 200)).toBeNull()
  })
  it('mengabaikan rangkaian terlalu pendek', () => {
    expect(type(createScanBuffer(), '12', 10)).toBeNull()
  })
  it('tidak membawa sisa buffer ke scan berikutnya', () => {
    const b = createScanBuffer()
    b.push('x', 1000)
    expect(type(b, 'ALF-001', 10, 5000)).toBe('ALF-001')
  })
  it('tombol modifier tidak merusak buffer', () => {
    const b = createScanBuffer()
    b.push('1', 1000)
    b.push('Shift', 1005)
    for (const [i, c] of ['2', '3', '4'].entries()) b.push(c, 1010 + i * 10)
    expect(b.push('Enter', 1050)).toBe('1234')
  })
})

describe('looksLikeBarcode', () => {
  it.each([['8990000000012', true], ['ALF-001', true], ['roti tawar', false], ['Teh', false], ['12', false]])('%s → %s', (t, ok) => {
    expect(looksLikeBarcode(t)).toBe(ok)
  })
})
