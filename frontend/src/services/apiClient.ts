import type { ApiEnvelope, ApiFieldError } from '@/types/api'
import { messageFor } from '@/utils/errorMessages'
import { deviceId } from '@/utils/device'

export class ApiError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly status: number,
    public readonly details: ApiFieldError[] = [],
    public readonly requestId?: string,
  ) {
    super(message)
    this.name = 'ApiError'
  }
}

export interface ApiClientDeps {
  baseUrl: string
  getToken: () => Promise<string | null>
  getContext: () => { outletId?: string | null; terminalId?: string | null }
  onUnauthenticated: () => void
  fetchImpl?: typeof fetch
}

export interface RequestOptions {
  idempotencyKey?: string
  query?: Record<string, string | number | boolean | null | undefined>
  /** Jangan picu logout otomatis saat 401 (mis. saat login). */
  skipAuthRedirect?: boolean
}

export interface ApiResult<T> {
  data: T
  message?: string
  replayed: boolean
}

export function createApiClient(deps: ApiClientDeps) {
  const doFetch = deps.fetchImpl ?? fetch.bind(globalThis)

  async function request<T>(
    method: string,
    path: string,
    body?: unknown,
    opts: RequestOptions = {},
  ): Promise<ApiResult<T>> {
    const url = new URL(deps.baseUrl + path, window.location.origin)
    for (const [k, v] of Object.entries(opts.query ?? {})) {
      if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v))
    }

    const headers: Record<string, string> = {
      Accept: 'application/json',
      'X-Request-Id': crypto.randomUUID(),
      'X-Device-Id': deviceId(),
    }
    const ctx = deps.getContext()
    if (ctx.outletId) headers['X-Outlet-Id'] = ctx.outletId
    if (ctx.terminalId) headers['X-Terminal-Id'] = ctx.terminalId
    if (body !== undefined) headers['Content-Type'] = 'application/json'
    if (opts.idempotencyKey) headers['Idempotency-Key'] = opts.idempotencyKey
    const token = await deps.getToken()
    if (token) headers.Authorization = `Bearer ${token}`

    let res: Response
    try {
      res = await doFetch(url.toString(), {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      })
    } catch {
      throw new ApiError('NETWORK_ERROR', messageFor('NETWORK_ERROR'), 0)
    }

    let envelope: ApiEnvelope<T> | null = null
    const text = await res.text()
    if (text) {
      try {
        envelope = JSON.parse(text) as ApiEnvelope<T>
      } catch {
        envelope = null
      }
    }

    if (!res.ok || !envelope || envelope.success === false) {
      const code = envelope?.errorCode ?? (res.status === 401 ? 'UNAUTHENTICATED' : 'INTERNAL_ERROR')
      if (res.status === 401 && !opts.skipAuthRedirect) deps.onUnauthenticated()
      throw new ApiError(code, messageFor(code, envelope?.message), res.status, envelope?.details ?? [],
        envelope?.requestId ?? res.headers.get('X-Request-Id') ?? undefined)
    }

    return {
      data: envelope.data as T,
      message: envelope.message,
      replayed: res.headers.get('Idempotent-Replayed') === 'true',
    }
  }

  return {
    get: <T>(path: string, opts?: RequestOptions) => request<T>('GET', path, undefined, opts),
    post: <T>(path: string, body?: unknown, opts?: RequestOptions) => request<T>('POST', path, body ?? {}, opts),
    put: <T>(path: string, body: unknown, opts?: RequestOptions) => request<T>('PUT', path, body, opts),
  }
}

export type ApiClient = ReturnType<typeof createApiClient>
