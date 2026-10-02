import { ref } from 'vue'
import { useToast } from 'primevue/usetoast'
import { ApiError } from '@/services/apiClient'
import { newIdempotencyKey } from '@/utils/device'

/**
 * Menjalankan aksi API dengan status loading, toast error, dan idempotency key yang
 * BERTAHAN saat retry (key baru hanya dibuat setelah aksi sukses atau di-reset).
 * Mencegah data ganda saat pengguna menekan tombol berulang karena jaringan lambat.
 */
export function useApiAction() {
  const toast = useToast()
  const busy = ref(false)
  const fieldErrors = ref<Record<string, string>>({})
  let pendingKey: string | null = null

  function idempotencyKey(): string {
    if (!pendingKey) pendingKey = newIdempotencyKey()
    return pendingKey
  }

  function resetKey() {
    pendingKey = null
  }

  async function run<T>(action: (key: string) => Promise<T>, successMessage?: string): Promise<T | null> {
    if (busy.value) return null
    busy.value = true
    fieldErrors.value = {}
    try {
      const result = await action(idempotencyKey())
      resetKey()
      if (successMessage) toast.add({ severity: 'success', summary: successMessage, life: 2500 })
      return result
    } catch (e) {
      notifyError(e)
      // Error bisnis 4xx => isi request harus diubah, pakai key baru. Error jaringan/5xx atau
      // "masih diproses" => pertahankan key agar retry tidak membuat data ganda.
      if (e instanceof ApiError && e.status >= 400 && e.status < 500 && e.code !== 'DUPLICATE_TRANSACTION') {
        resetKey()
      }
      return null
    } finally {
      busy.value = false
    }
  }

  function notifyError(e: unknown) {
    if (e instanceof ApiError) {
      for (const d of e.details) {
        if (d.field) fieldErrors.value[d.field] = d.message
      }
      toast.add({
        severity: 'error',
        summary: e.message,
        detail: e.requestId ? `Kode request: ${e.requestId}` : undefined,
        life: 6000,
      })
    } else {
      toast.add({ severity: 'error', summary: 'Terjadi kesalahan tak terduga.', life: 6000 })
    }
  }

  return { busy, fieldErrors, run, notifyError, resetKey }
}
