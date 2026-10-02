import { reactive } from 'vue'
import type { ApprovalPayload } from '@/types/api'

/**
 * Satu dialog approval untuk seluruh layar kasir. Aksi yang ditolak dengan APPROVAL_REQUIRED
 * memanggil ask(); dialog meminta email+password supervisor, lalu mengembalikan approvalId
 * (atau null bila dibatalkan). Password tidak pernah disimpan di state.
 */
const state = reactive({
  visible: false,
  message: '',
  payload: null as ApprovalPayload | null,
})
let resolver: ((id: string | null) => void) | null = null

export function useApprovalPrompt() {
  function ask(payload: ApprovalPayload, message: string): Promise<string | null> {
    resolver?.(null)
    state.payload = payload
    state.message = message
    state.visible = true
    return new Promise((resolve) => (resolver = resolve))
  }

  function finish(id: string | null) {
    state.visible = false
    state.payload = null
    const r = resolver
    resolver = null
    r?.(id)
  }

  return { state, ask, finish }
}
