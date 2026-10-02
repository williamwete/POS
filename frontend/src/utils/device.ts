// Identitas device browser ini (jejak audit). BUKAN mekanisme otorisasi.
const KEY = 'pos.deviceId'

function randomId(): string {
  return crypto.randomUUID()
}

export function deviceId(): string {
  try {
    let id = localStorage.getItem(KEY)
    if (!id || !/^[A-Za-z0-9._:-]{1,128}$/.test(id)) {
      id = `web-${randomId()}`
      localStorage.setItem(KEY, id)
    }
    return id
  } catch {
    return 'web-ephemeral'
  }
}

/** Idempotency key baru untuk satu aksi pengguna (dipakai ulang saat retry aksi yang sama). */
export function newIdempotencyKey(prefix = 'web'): string {
  return `${prefix}-${randomId()}`
}
