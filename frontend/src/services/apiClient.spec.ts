import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createApiClient, ApiError } from './apiClient'

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } })
}

describe('apiClient', () => {
  const onUnauthenticated = vi.fn()
  let fetchImpl: ReturnType<typeof vi.fn>

  beforeEach(() => {
    onUnauthenticated.mockReset()
    fetchImpl = vi.fn()
  })

  function client(token: string | null = 'tok') {
    return createApiClient({
      baseUrl: '',
      getToken: async () => token,
      getContext: () => ({ outletId: 'outlet-1', terminalId: 'terminal-1' }),
      onUnauthenticated,
      fetchImpl: fetchImpl as unknown as typeof fetch,
    })
  }

  it('sends auth, context, device and idempotency headers', async () => {
    fetchImpl.mockResolvedValue(jsonResponse(201, { success: true, data: { id: 'x' } }))
    await client().post('/api/terminals', { a: 1 }, { idempotencyKey: 'web-abc12345' })
    const [, init] = fetchImpl.mock.calls[0]!
    const headers = init.headers as Record<string, string>
    expect(headers.Authorization).toBe('Bearer tok')
    expect(headers['Idempotency-Key']).toBe('web-abc12345')
    expect(headers['X-Outlet-Id']).toBe('outlet-1')
    expect(headers['X-Terminal-Id']).toBe('terminal-1')
    expect(headers['X-Device-Id']).toMatch(/^web-/)
    expect(headers['X-Request-Id']).toBeTruthy()
    expect(init.body).toBe('{"a":1}')
  })

  it('unwraps envelope and reports idempotent replay', async () => {
    fetchImpl.mockResolvedValue(jsonResponse(201, { success: true, data: { id: 'x' } }, { 'Idempotent-Replayed': 'true' }))
    const res = await client().post<{ id: string }>('/api/x', {})
    expect(res.data.id).toBe('x')
    expect(res.replayed).toBe(true)
  })

  it('maps error codes to human readable messages', async () => {
    fetchImpl.mockResolvedValue(jsonResponse(403, {
      success: false, errorCode: 'OUTLET_ACCESS_DENIED', message: 'x', requestId: 'req-1',
    }))
    const err = await client().get('/api/outlets/1').catch((e) => e)
    expect(err).toBeInstanceOf(ApiError)
    expect(err.code).toBe('OUTLET_ACCESS_DENIED')
    expect(err.message).toBe('Anda tidak memiliki akses ke outlet ini.')
    expect(err.requestId).toBe('req-1')
    expect(onUnauthenticated).not.toHaveBeenCalled()
  })

  it('triggers unauthenticated handler on 401', async () => {
    fetchImpl.mockResolvedValue(jsonResponse(401, { success: false, errorCode: 'UNAUTHENTICATED' }))
    await expect(client().get('/api/auth/me')).rejects.toBeInstanceOf(ApiError)
    expect(onUnauthenticated).toHaveBeenCalledOnce()
  })

  it('reports network failure without leaking details', async () => {
    fetchImpl.mockRejectedValue(new TypeError('Failed to fetch'))
    const err = await client().get('/api/outlets').catch((e) => e)
    expect(err.code).toBe('NETWORK_ERROR')
    expect(err.status).toBe(0)
  })

  it('serializes query params and drops empty values', async () => {
    fetchImpl.mockResolvedValue(jsonResponse(200, { success: true, data: [] }))
    await client().get('/api/employees', { query: { outletId: 'o1', q: '', active: true, x: undefined } })
    const url = new URL(fetchImpl.mock.calls[0]![0] as string)
    expect(url.searchParams.get('outletId')).toBe('o1')
    expect(url.searchParams.get('active')).toBe('true')
    expect(url.searchParams.has('q')).toBe(false)
  })
})
