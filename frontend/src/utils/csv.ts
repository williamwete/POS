/** Pembaca CSV sederhana: pemisah koma/titik koma/tab otomatis, tanda kutip ganda, BOM, CRLF. */
export function parseCsv(text: string): string[][] {
  const src = text.replace(/^﻿/, '')
  const firstLine = src.split(/\r?\n/, 1)[0] ?? ''
  const delim = [',', ';', '\t'].map((d) => [d, firstLine.split(d).length] as const).sort((a, b) => b[1] - a[1])[0]![0]
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false
  for (let i = 0; i < src.length; i++) {
    const ch = src[i]!
    if (quoted) {
      if (ch === '"' && src[i + 1] === '"') { cell += '"'; i++ } else if (ch === '"') quoted = false
      else cell += ch
    } else if (ch === '"') quoted = true
    else if (ch === delim) { row.push(cell); cell = '' }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && src[i + 1] === '\n') i++
      row.push(cell); cell = ''
      if (row.some((c) => c.trim() !== '')) rows.push(row)
      row = []
    } else cell += ch
  }
  row.push(cell)
  if (row.some((c) => c.trim() !== '')) rows.push(row)
  return rows
}

export interface ImportRow { sku: string; name: string; category: string; uom: string; price: string; barcode: string; stock: string }

const ALIASES: Record<keyof ImportRow, string[]> = {
  sku: ['sku', 'kode', 'kodeproduk', 'kodebarang'],
  name: ['name', 'nama', 'namaproduk', 'namabarang', 'produk'],
  category: ['category', 'kategori'],
  uom: ['uom', 'satuan', 'unit'],
  price: ['price', 'harga', 'hargajual'],
  barcode: ['barcode', 'kodebarcode', 'ean'],
  stock: ['stock', 'stok', 'jumlahstok'],
}

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '')

/** Mengubah hasil parseCsv (baris pertama = judul kolom) menjadi baris impor. Kolom tak dikenal diabaikan. */
export function toImportRows(table: string[][]): { rows: ImportRow[]; missing: string[] } {
  const header = (table[0] ?? []).map(norm)
  const idx = {} as Record<keyof ImportRow, number>
  for (const key of Object.keys(ALIASES) as (keyof ImportRow)[]) {
    idx[key] = header.findIndex((h) => ALIASES[key].includes(h))
  }
  const missing = (['sku', 'name', 'price'] as const).filter((k) => idx[k] < 0)
  const get = (r: string[], k: keyof ImportRow) => (idx[k] >= 0 ? (r[idx[k]] ?? '').trim() : '')
  const rows = table.slice(1).map((r) => ({
    sku: get(r, 'sku'), name: get(r, 'name'), category: get(r, 'category'), uom: get(r, 'uom'),
    price: normalizeNumber(get(r, 'price')), barcode: get(r, 'barcode'), stock: normalizeNumber(get(r, 'stock')),
  }))
  return { rows, missing }
}

/** "Rp 18.000" / "18.000,50" / "18000.5" → "18000" / "18000.50" / "18000.5". */
export function normalizeNumber(v: string): string {
  let s = v.replace(/rp/gi, '').replace(/\s/g, '')
  if (!s) return ''
  if (s.includes(',') && s.includes('.')) s = s.replace(/\./g, '').replace(',', '.')
  else if (s.includes(',')) s = s.replace(',', '.')
  else if (/^\d{1,3}(\.\d{3})+$/.test(s)) s = s.replace(/\./g, '')
  return s
}

/** Galat yang pasti ditolak server, agar pengguna memperbaikinya sebelum mengirim. */
export function validateRows(rows: ImportRow[]): string[] {
  const errors: string[] = []
  rows.forEach((r, i) => {
    const n = i + 1
    if (!r.sku) errors.push(`Baris ${n}: SKU kosong`)
    else if (!/^[A-Za-z0-9._-]{1,40}$/.test(r.sku)) errors.push(`Baris ${n}: SKU hanya huruf, angka, titik, strip, garis bawah`)
    if (!r.name) errors.push(`Baris ${n}: nama kosong`)
    if (r.price && !(Number(r.price) >= 0)) errors.push(`Baris ${n}: harga tidak valid`)
    if (r.stock && !(Number(r.stock) >= 0)) errors.push(`Baris ${n}: stok tidak valid`)
  })
  return errors
}

export const IMPORT_TEMPLATE = 'sku,nama,kategori,satuan,harga,barcode,stok\nBRG-001,Contoh Produk,Makanan,PCS,15000,8991234567890,20\n'
