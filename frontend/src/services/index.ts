import { createApiClient, type ApiClient } from '@/services/apiClient'
import { createAuthProvider, type AuthProvider } from '@/services/authProvider'

/**
 * Wiring service singleton. Store memanggil api/auth dari sini; test dapat mengganti
 * keduanya lewat configureServices().
 */
let authProvider: AuthProvider | null = null
let apiClient: ApiClient | null = null

let contextGetter: () => { outletId?: string | null; terminalId?: string | null } = () => ({})
let unauthenticatedHandler: () => void = () => {}

export function auth(): AuthProvider {
  if (!authProvider) authProvider = createAuthProvider()
  return authProvider
}

export function api(): ApiClient {
  if (!apiClient) {
    apiClient = createApiClient({
      baseUrl: import.meta.env.VITE_API_BASE_URL ?? '',
      getToken: () => auth().getAccessToken(),
      getContext: () => contextGetter(),
      onUnauthenticated: () => unauthenticatedHandler(),
    })
  }
  return apiClient
}

export function configureServices(opts: {
  auth?: AuthProvider
  api?: ApiClient
  context?: typeof contextGetter
  onUnauthenticated?: () => void
}) {
  if (opts.auth) authProvider = opts.auth
  if (opts.api) apiClient = opts.api
  if (opts.context) contextGetter = opts.context
  if (opts.onUnauthenticated) unauthenticatedHandler = opts.onUnauthenticated
}
