import { onBeforeUnmount, onMounted, watch } from 'vue'
import { useCashierStore } from '@/stores/cashier'

const EVENTS = ['pointerdown', 'keydown', 'wheel', 'touchstart'] as const

/**
 * Kunci terminal otomatis setelah tidak ada aktivitas selama `idleLockMinutes` (setting outlet
 * terminal_idle_lock_minutes; 0 = nonaktif). Penguncian dilakukan server (status ON_BREAK).
 */
export function useIdleLock() {
  const cashier = useCashierStore()
  let last = Date.now()
  let timer: number | undefined
  let locking = false

  const touch = () => (last = Date.now())

  async function tick() {
    const s = cashier.current
    if (!s || s.status !== 'OPEN' || !s.idleLockMinutes || locking) return
    if (Date.now() - last < s.idleLockMinutes * 60_000) return
    locking = true
    try {
      await cashier.lock('IDLE', `idle-${s.id}-${s.version}`)
    } catch {
      // gagal jaringan: coba lagi pada tick berikutnya
    } finally {
      locking = false
    }
  }

  onMounted(() => {
    EVENTS.forEach((e) => window.addEventListener(e, touch, { passive: true }))
    timer = window.setInterval(() => void tick(), 15_000)
  })
  onBeforeUnmount(() => {
    EVENTS.forEach((e) => window.removeEventListener(e, touch))
    window.clearInterval(timer)
  })
  // Setelah dibuka kembali, hitung ulang dari sekarang.
  watch(() => cashier.current?.status, (st) => st === 'OPEN' && touch())
}
