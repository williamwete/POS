import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { ApiError } from '@/services/apiClient'
import { messageFor } from '@/utils/errorMessages'

/**
 * Penyedia login.
 *  - supabase: login langsung ke Supabase Auth (staging/production). Hanya anon key di browser.
 *  - local   : endpoint token dev backend (profile local). Tidak tersedia di production.
 * Token disimpan di sessionStorage: menutup tab = keluar (aman untuk terminal bersama).
 * Password tidak pernah disimpan.
 */
export interface AuthProvider {
  signIn(email: string, password: string): Promise<void>
  getAccessToken(): Promise<string | null>
  signOut(): Promise<void>
}

const LOCAL_KEY = 'pos.localSession'

interface LocalSession {
  accessToken: string
  expiresAt: number
}

export function createLocalAuthProvider(baseUrl: string): AuthProvider {
  function read(): LocalSession | null {
    try {
      const raw = sessionStorage.getItem(LOCAL_KEY)
      if (!raw) return null
      const s = JSON.parse(raw) as LocalSession
      return s.expiresAt > Date.now() + 5_000 ? s : null
    } catch {
      return null
    }
  }

  return {
    async signIn(email, password) {
      let res: Response
      try {
        res = await fetch(`${baseUrl}/api/dev-auth/token`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email, password }),
        })
      } catch {
        throw new ApiError('NETWORK_ERROR', messageFor('NETWORK_ERROR'), 0)
      }
      const body = await res.json().catch(() => null)
      if (!res.ok || !body?.success) {
        const code = body?.errorCode ?? 'INVALID_CREDENTIALS'
        throw new ApiError(code, messageFor(code, body?.message), res.status, body?.details ?? [])
      }
      const session: LocalSession = {
        accessToken: body.data.accessToken,
        expiresAt: Date.now() + body.data.expiresIn * 1000,
      }
      sessionStorage.setItem(LOCAL_KEY, JSON.stringify(session))
    },
    async getAccessToken() {
      return read()?.accessToken ?? null
    },
    async signOut() {
      sessionStorage.removeItem(LOCAL_KEY)
    },
  }
}

export function createSupabaseAuthProvider(url: string, anonKey: string): AuthProvider {
  const client: SupabaseClient = createClient(url, anonKey, {
    auth: {
      storage: window.sessionStorage,
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  })
  return {
    async signIn(email, password) {
      const { error } = await client.auth.signInWithPassword({ email, password })
      if (error) {
        const code = error.status === 400 ? 'INVALID_CREDENTIALS' : 'NETWORK_ERROR'
        throw new ApiError(code, messageFor(code), error.status ?? 0)
      }
    },
    async getAccessToken() {
      const { data } = await client.auth.getSession()
      return data.session?.access_token ?? null
    },
    async signOut() {
      await client.auth.signOut()
    },
  }
}

export function createAuthProvider(): AuthProvider {
  const baseUrl = import.meta.env.VITE_API_BASE_URL ?? ''
  if ((import.meta.env.VITE_AUTH_MODE ?? 'local') === 'supabase') {
    const url = import.meta.env.VITE_SUPABASE_URL
    const key = import.meta.env.VITE_SUPABASE_ANON_KEY
    if (!url || !key) throw new Error('VITE_SUPABASE_URL dan VITE_SUPABASE_ANON_KEY wajib untuk mode supabase')
    return createSupabaseAuthProvider(url, key)
  }
  return createLocalAuthProvider(baseUrl)
}
