import { createApp } from 'vue'
import { createPinia } from 'pinia'
import PrimeVue from 'primevue/config'
import ToastService from 'primevue/toastservice'
import ConfirmationService from 'primevue/confirmationservice'
import Tooltip from 'primevue/tooltip'
import '@fontsource/plus-jakarta-sans/400.css'
import '@fontsource/plus-jakarta-sans/500.css'
import '@fontsource/plus-jakarta-sans/600.css'
import '@fontsource/plus-jakarta-sans/700.css'
import 'primeicons/primeicons.css'
import './styles.css'
import App from './App.vue'
import { createAppRouter } from './router'
import { PosPreset } from './theme'
import { configureServices } from './services'
import { useSessionStore } from './stores/session'

async function bootstrap() {
  const app = createApp(App)
  const pinia = createPinia()
  app.use(pinia)
  const router = createAppRouter()

  const session = useSessionStore()
  configureServices({
    context: () => ({ outletId: session.outletId, terminalId: session.terminal?.id ?? null }),
    onUnauthenticated: () => {
      void session.expire().then(() => router.push({ name: 'login', query: { expired: '1' } }))
    },
  })
  await session.restore()

  app.use(router)
  app.use(PrimeVue, {
    theme: { preset: PosPreset, options: { darkModeSelector: false, cssLayer: { name: 'primevue', order: 'tailwind-base, primevue, tailwind-utilities' } } },
    locale: {
      accept: 'Ya', reject: 'Batal', emptyMessage: 'Tidak ada data', emptySearchMessage: 'Tidak ditemukan',
      dayNamesMin: ['Mg', 'Sn', 'Sl', 'Rb', 'Km', 'Jm', 'Sb'],
      monthNames: ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'],
      firstDayOfWeek: 1, dateFormat: 'dd/mm/yy',
    },
  })
  app.use(ToastService)
  app.use(ConfirmationService)
  app.directive('tooltip', Tooltip)
  app.mount('#app')
}

void bootstrap()
