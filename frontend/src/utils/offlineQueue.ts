/**
 * Penyimpanan lokal untuk mode offline: antrean transaksi tunai dan cache katalog.
 * Memakai IndexedDB; bila tidak tersedia (mode privat tertentu, tes) jatuh ke memori.
 */
export interface OfflineLine {
  productId: string
  sku: string
  name: string
  quantity: number
  /** harga satuan menurut cache saat transaksi (hanya untuk tampilan & pembanding server) */
  unitPrice: number
}

export interface OfflineSale {
  /** = clientTransactionId, kunci idempotensi di server */
  id: string
  outletId: string
  terminalId: string
  offlineAt: string
  lines: OfflineLine[]
  clientTotal: number
  amountReceived: number
  note?: string
  status: 'PENDING' | 'FAILED'
  /** pesan dari server bila FAILED (butuh tindakan manusia) */
  error?: string
  attempts: number
  /** nomor struk dari server setelah terkirim (tidak disimpan di antrean; hanya untuk hasil) */
}

export interface KeyValueStore {
  get<T>(key: string): Promise<T | undefined>
  set<T>(key: string, value: T): Promise<void>
  delete(key: string): Promise<void>
  keys(prefix: string): Promise<string[]>
}

export function createMemoryStore(): KeyValueStore {
  const m = new Map<string, unknown>()
  return {
    async get<T>(k: string) { return m.get(k) as T | undefined },
    async set<T>(k: string, v: T) { m.set(k, plain(v)) },
    async delete(k: string) { m.delete(k) },
    async keys(prefix: string) { return [...m.keys()].filter((k) => k.startsWith(prefix)) },
  }
}

const DB = 'pos-offline'
const STORE = 'kv'

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1)
    req.onupgradeneeded = () => req.result.createObjectStore(STORE)
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

function wrap<T>(db: IDBDatabase, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    const req = fn(db.transaction(STORE, mode).objectStore(STORE))
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

export function createIndexedDbStore(): KeyValueStore {
  let dbp: Promise<IDBDatabase> | null = null
  const db = () => (dbp ??= openDb())
  return {
    async get<T>(k: string) { return (await wrap(await db(), 'readonly', (s) => s.get(k))) as T | undefined },
    async set<T>(k: string, v: T) { await wrap(await db(), 'readwrite', (s) => s.put(v, k)) },
    async delete(k: string) { await wrap(await db(), 'readwrite', (s) => s.delete(k)) },
    async keys(prefix: string) {
      const all = (await wrap(await db(), 'readonly', (s) => s.getAllKeys())) as string[]
      return all.filter((k) => typeof k === 'string' && k.startsWith(prefix))
    },
  }
}

export function defaultStore(): KeyValueStore {
  return typeof indexedDB !== 'undefined' ? createIndexedDbStore() : createMemoryStore()
}

const QUEUE = 'queue:'

/** Salinan polos (objek reaktif Vue tidak bisa disimpan di IndexedDB). */
export function plain<T>(v: T): T {
  return JSON.parse(JSON.stringify(v)) as T
}

export function createQueue(store: KeyValueStore) {
  return {
    async add(sale: OfflineSale) { await store.set(QUEUE + sale.id, plain(sale)) },
    async update(sale: OfflineSale) { await store.set(QUEUE + sale.id, plain(sale)) },
    async remove(id: string) { await store.delete(QUEUE + id) },
    async list(): Promise<OfflineSale[]> {
      const out: OfflineSale[] = []
      for (const k of await store.keys(QUEUE)) {
        const v = await store.get<OfflineSale>(k)
        if (v) out.push(v)
      }
      return out.sort((a, b) => a.offlineAt.localeCompare(b.offlineAt))
    },
  }
}

/** Total tampilan: harga sudah termasuk pajak, dibulatkan ke rupiah (selaras server untuk harga bulat). */
export function offlineTotal(lines: Pick<OfflineLine, 'quantity' | 'unitPrice'>[]): number {
  return lines.reduce((sum, l) => sum + Math.round(l.quantity * l.unitPrice), 0)
}
