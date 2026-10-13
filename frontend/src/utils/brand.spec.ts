import { describe, expect, it } from 'vitest'
import { applyBrandColor, buildPalette, contrastWithWhite, isReadableBrand } from './brand'

describe('brand', () => {
  it('palet: 500 = warna utama, makin gelap ke 900', () => {
    const p = buildPalette('#0F7A6B')
    expect(p[500]).toBe('#0F7A6B')
    expect(contrastWithWhite(p[900]!)).toBeGreaterThan(contrastWithWhite(p[500]!))
    expect(p[50]).toMatch(/^#[0-9A-F]{6}$/)
  })
  it('menolak warna terlalu terang atau format salah', () => {
    expect(isReadableBrand('#FFFF99')).toBe(false)
    expect(isReadableBrand('biru')).toBe(false)
    expect(isReadableBrand('#3F6A9E')).toBe(true)
  })
  it('menerapkan dan mengembalikan ke bawaan', () => {
    const el = document.createElement('div')
    applyBrandColor('#0F7A6B', el)
    expect(el.style.getPropertyValue('--brand-500')).toBe('15 122 107')
    expect(el.style.getPropertyValue('--p-primary-500')).toBe('#0F7A6B')
    applyBrandColor(null, el)
    expect(el.style.getPropertyValue('--brand-500')).toBe('')
  })
})
