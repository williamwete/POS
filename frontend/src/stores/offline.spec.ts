import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { ApiError } from '@/services/apiClient'
import { createMemoryStore, offlineTotal } from '@/utils/offlineQueue'

const post = vi.fn()
vi.mock('@/services', () => ({ api: () => ({ post }) }))

import { useOfflineStore } from './offline'

const line = { productId: 'p1', sku: 'A', name: 'Aqua', quantity: 2, unitPrice: 5000 }
const draft = { id: 'OFF-0001-abcdef', outletId: 'o', terminalId: 't', lines: [line], amountReceived: 20000 }

describe('offline store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    post.mockReset()
  })

  it('totals lines in whole rupiah', () => {
    expect(offlineTotal([{ quantity: 3, unitPrice: 3333 }, { quantity: 0.5, unitPrice: 1001 }])).toBe(9999 + 501)
  })

  it('refuses empty carts and short cash', async () => {
    const s = useOfflineStore(); s.useStore(createMemoryStore())
    await expect(s.enqueue({ ...draft, lines: [] })).rejects.toThrow()
    await expect(s.enqueue({ ...draft, amountReceived: 5000 })).rejects.toThrow()
  })

  it('keeps the sale queued while the network is down and removes it once sent', async () => {
    const s = useOfflineStore(); s.useStore(createMemoryStore())
    await s.enqueue(draft)
    post.mockRejectedValueOnce(new ApiError('NETWORK_ERROR', 'x', 0))
    expect(await s.syncAll()).toBe(0)
    expect(s.pending).toHaveLength(1)
    expect(s.online).toBe(false)

    post.mockResolvedValueOnce({ data: { sale: { id: 's1', grandTotal: 10000 }, duplicate: false, reviewReasons: [] } })
    expect(await s.syncAll()).toBe(1)
    expect(s.queue).toHaveLength(0)
    expect(s.online).toBe(true)
    expect(post.mock.calls[1]![1]).toMatchObject({ clientTransactionId: draft.id, clientTotal: 10000, amountReceived: 20000 })
  })

  it('marks server rejections FAILED with the message and keeps them for a human', async () => {
    const s = useOfflineStore(); s.useStore(createMemoryStore())
    await s.enqueue(draft)
    post.mockRejectedValueOnce(new ApiError('STOCK_INSUFFICIENT', 'Stok tidak cukup', 409))
    await s.syncAll()
    expect(s.failed).toHaveLength(1)
    expect(s.failed[0]!.error).toBe('Stok tidak cukup')
    await s.discard(draft.id)
    expect(s.queue).toHaveLength(0)
  })

  it('does not drop a sale on server errors or expired sessions', async () => {
    const s = useOfflineStore(); s.useStore(createMemoryStore())
    await s.enqueue(draft)
    post.mockRejectedValueOnce(new ApiError('INTERNAL', 'boom', 500))
    await s.syncAll()
    expect(s.pending).toHaveLength(1)
    post.mockRejectedValueOnce(new ApiError('AUTH', 'expired', 401))
    await s.syncAll()
    expect(s.pending).toHaveLength(1)
  })

  it('caches only sellable products without option groups', async () => {
    const s = useOfflineStore(); s.useStore(createMemoryStore())
    const base = { sku: 'x', uom: 'PCS', allowDecimalQty: false, taxRate: 0, allowNegativeStock: false }
    await s.cacheCatalog('o', [
      { ...base, id: '1', name: 'A', price: 1000 },
      { ...base, id: '2', name: 'B' },
      { ...base, id: '3', name: 'C', price: 500, optionGroups: [{ id: 'g' } as never] },
    ])
    expect((await s.loadCatalog('o')).map((p) => p.id)).toEqual(['1'])
  })
})
