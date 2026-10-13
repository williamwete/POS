/**
 * Pemindai barcode USB/Bluetooth bekerja seperti keyboard: mengetik kode sangat cepat lalu Enter.
 * Buffer ini mengenali pola itu (jeda antar-tombol kecil) sehingga ketikan manusia tidak salah dianggap scan.
 */
export function createScanBuffer(maxGapMs = 60, minLength = 4) {
  let buf = ''
  let last = 0
  return {
    /** Mengembalikan kode bila `Enter` mengakhiri rangkaian cepat sepanjang minimal `minLength`. */
    push(key: string, at: number): string | null {
      if (key === 'Enter') {
        const out = buf.length >= minLength ? buf : null
        buf = ''
        return out
      }
      if (key.length !== 1) return null
      if (at - last > maxGapMs) buf = ''
      buf += key
      last = at
      return null
    },
    reset() {
      buf = ''
    },
  }
}

/** Kode yang masuk akal sebagai barcode (angka 6-14, atau kode alfanumerik tanpa spasi yang memuat angka). */
export function looksLikeBarcode(text: string): boolean {
  return /^[0-9]{6,14}$/.test(text) || (/^[A-Za-z0-9._-]{4,64}$/.test(text) && /[0-9]/.test(text))
}
