import { describe, expect, it } from 'vitest'
import { normalizeNumber, parseCsv, toCsv, toImportRows, validateRows } from './csv'

describe('parseCsv', () => {
  it('membaca koma, kutip, dan CRLF', () => {
    expect(parseCsv('a,b\r\n"x, y","say ""hi"""\r\n')).toEqual([['a', 'b'], ['x, y', 'say "hi"']])
  })
  it('mendeteksi titik koma dan BOM', () => {
    expect(parseCsv('﻿sku;nama\nA1;Roti')).toEqual([['sku', 'nama'], ['A1', 'Roti']])
  })
  it('melewati baris kosong', () => {
    expect(parseCsv('a,b\n\n1,2\n')).toEqual([['a', 'b'], ['1', '2']])
  })
})

describe('normalizeNumber', () => {
  it.each([['Rp 18.000', '18000'], ['18.000,50', '18000.50'], ['18000.5', '18000.5'], ['2,5', '2.5'], ['', '']])('%s → %s', (a, b) => {
    expect(normalizeNumber(a)).toBe(b)
  })
})

describe('toImportRows', () => {
  it('memetakan judul kolom Indonesia', () => {
    const { rows, missing } = toImportRows(parseCsv('Kode,Nama Produk,Kategori,Harga,Stok\nA1,Roti,Makanan,"Rp 5.000",10'))
    expect(missing).toEqual([])
    expect(rows[0]).toMatchObject({ sku: 'A1', name: 'Roti', category: 'Makanan', price: '5000', stock: '10' })
  })
  it('melaporkan kolom wajib yang hilang', () => {
    expect(toImportRows(parseCsv('sku,nama\nA1,Roti')).missing).toEqual(['price'])
  })
})

describe('validateRows', () => {
  it('menandai galat per baris', () => {
    const errs = validateRows([{ sku: '', name: 'x', category: '', uom: '', price: '1', barcode: '', stock: '' }, { sku: 'A B', name: '', category: '', uom: '', price: '-2', barcode: '', stock: '' }])
    expect(errs.length).toBe(4)
  })
})

describe('toCsv', () => {
  it('menulis header, angka, dan mengutip sel berisi koma atau tanda kutip', () => {
    const out = toCsv(['Nama', 'Jumlah'], [['Kopi, susu', 3], ['Es "teh"', 2]])
    expect(out).toBe('﻿Nama,Jumlah\r\n"Kopi, susu",3\r\n"Es ""teh""",2\r\n')
  })
  it('menetralkan sel yang diawali karakter rumus', () => {
    expect(toCsv(['x'], [['=SUM(A1)'], ['-5 hari'], [null]])).toContain("'=SUM(A1)")
    expect(toCsv(['x'], [['@cmd']])).toContain("'@cmd")
  })
  it('hasilnya bisa dibaca lagi oleh parseCsv', () => {
    const rows = parseCsv(toCsv(['a', 'b'], [['x, y', 1]]))
    expect(rows[1]).toEqual(['x, y', '1'])
  })
})
