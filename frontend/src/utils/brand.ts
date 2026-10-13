/** Utilitas branding merchant: palet dari satu warna utama, kontras, dan pengecilan logo. */

export const DEFAULT_BRAND = '#78A0CF'
/** Selaras dengan batas di database: teks putih pada tombol harus tetap terbaca. */
export const MIN_CONTRAST = 2.5

type RGB = [number, number, number]

export function hexToRgb(hex: string): RGB {
  const h = hex.replace('#', '')
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]
}

export const rgbToHex = (c: RGB) => '#' + c.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('').toUpperCase()

export const isHexColor = (v: string) => /^#[0-9A-Fa-f]{6}$/.test(v)

function mix(c: RGB, target: RGB, amount: number): RGB {
  return [0, 1, 2].map((i) => c[i]! + (target[i]! - c[i]!) * amount) as RGB
}

export function contrastWithWhite(hex: string): number {
  const lum = hexToRgb(hex)
    .map((v) => v / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)))
    .reduce((sum, c, i) => sum + c * [0.2126, 0.7152, 0.0722][i]!, 0)
  return 1.05 / (lum + 0.05)
}

export const isReadableBrand = (hex: string) => isHexColor(hex) && contrastWithWhite(hex) >= MIN_CONTRAST

const WHITE: RGB = [255, 255, 255]
const BLACK: RGB = [0, 0, 0]
const STEPS: [number, 'white' | 'black', number][] = [
  [50, 'white', 0.9], [100, 'white', 0.8], [200, 'white', 0.6], [300, 'white', 0.4], [400, 'white', 0.2],
  [500, 'white', 0], [600, 'black', 0.15], [700, 'black', 0.3], [800, 'black', 0.42], [900, 'black', 0.55], [950, 'black', 0.68],
]

/** Palet 50–950 dari warna utama (= tingkat 500). */
export function buildPalette(hex: string): Record<number, string> {
  const base = hexToRgb(hex)
  const out: Record<number, string> = {}
  for (const [step, toward, amount] of STEPS) out[step] = rgbToHex(mix(base, toward === 'white' ? WHITE : BLACK, amount))
  return out
}

const TAILWIND_STEPS = [50, 100, 500, 600, 700, 900]
const PRIME_STEPS = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]

/** Menerapkan warna ke Tailwind (--brand-*) dan PrimeVue (--p-primary-*); null = kembali ke bawaan. */
export function applyBrandColor(hex: string | null, root: HTMLElement = document.documentElement) {
  const props = [...TAILWIND_STEPS.map((s) => `--brand-${s}`), ...PRIME_STEPS.map((s) => `--p-primary-${s}`)]
  if (!hex || !isReadableBrand(hex)) {
    props.forEach((p) => root.style.removeProperty(p))
    return
  }
  const palette = buildPalette(hex)
  for (const s of TAILWIND_STEPS) root.style.setProperty(`--brand-${s}`, hexToRgb(palette[s]!).join(' '))
  for (const s of PRIME_STEPS) root.style.setProperty(`--p-primary-${s}`, palette[s]!)
}

const MAX_LOGO_CHARS = 90000

/** Mengecilkan gambar ke maks 256 px dan mengubahnya jadi data URL kecil (PNG, lalu WebP/JPEG bila perlu). */
export async function fileToLogo(file: File): Promise<string> {
  if (!/^image\/(png|jpeg|webp)$/.test(file.type)) throw new Error('Gunakan gambar PNG, JPEG, atau WebP')
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, 256 / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(bitmap.width * scale))
  canvas.height = Math.max(1, Math.round(bitmap.height * scale))
  canvas.getContext('2d')!.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  for (const [type, quality] of [['image/png'], ['image/webp', 0.85], ['image/webp', 0.6], ['image/jpeg', 0.7]] as [string, number?][]) {
    const url = canvas.toDataURL(type, quality)
    if (url.startsWith(`data:${type}`) && url.length <= MAX_LOGO_CHARS) return url
  }
  throw new Error('Logo terlalu besar, gunakan gambar yang lebih sederhana')
}
