<script setup lang="ts">
import { reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Button from 'primevue/button'
import Message from 'primevue/message'
import { useSessionStore } from '@/stores/session'
import { ApiError } from '@/services/apiClient'
import { fieldErrorsOf, loginSchema } from '@/utils/validation'
import { autoSelectContext } from '@/utils/autoContext'

const session = useSessionStore()
const router = useRouter()
const route = useRoute()

const form = reactive({ email: '', password: '' })
const errors = ref<Record<string, string>>({})
const formError = ref<string | null>(route.query.expired ? 'Sesi Anda berakhir. Silakan masuk lagi.' : null)
const busy = ref(false)
const isLocal = (import.meta.env.VITE_AUTH_MODE ?? 'local') === 'local'

const demoAccounts = [
  ['cashier.jkt@demo.local', 'Kasir Jakarta'],
  ['supervisor.jkt@demo.local', 'Supervisor Jakarta'],
  ['manager@demo.local', 'Store manager JKT & BDG'],
  ['admin@demo.local', 'Admin sistem'],
  ['platform@demo.local', 'Operator platform (konsol merchant)'],
  ['auditor@demo.local', 'Auditor (read-only)'],
]

async function submit() {
  formError.value = null
  const parsed = loginSchema.safeParse(form)
  errors.value = fieldErrorsOf(parsed)
  if (!parsed.success) return
  busy.value = true
  try {
    await session.login(parsed.data.email, parsed.data.password)
    form.password = ''
    const redirect = typeof route.query.redirect === 'string' && route.query.redirect.startsWith('/')
      ? route.query.redirect : null
    // Alur Figma: login langsung masuk ke kasir; outlet/terminal dipilih otomatis bila hanya satu pilihan.
    // Operator platform tidak punya outlet/terminal: langsung ke konsol merchant.
    const ready = session.can('platform.manage', 'org') || await autoSelectContext()
    await router.replace(redirect ?? (ready ? { name: 'home' } : { name: 'context' }))
  } catch (e) {
    form.password = ''
    formError.value = e instanceof ApiError ? e.message : 'Login gagal. Coba lagi.'
  } finally {
    busy.value = false
  }
}

function useDemo(email: string) {
  form.email = email
  form.password = 'Demo#12345'
}
</script>

<template>
  <div class="grid min-h-screen place-items-center bg-jade-100 p-6">
    <form class="w-full max-w-lg rounded-2xl border-2 border-[#B5D3EA] bg-field px-12 py-10" novalidate @submit.prevent="submit">
      <h1 class="text-center text-2xl font-bold">CuanRena</h1>
      <p class="mt-1 text-center text-lg">Login</p>

      <Message v-if="formError" severity="error" class="mt-6" :closable="false">{{ formError }}</Message>

      <div class="mt-6 space-y-4">
        <div>
          <label for="email" class="mb-1 block text-sm">Email</label>
          <InputText id="email" v-model="form.email" type="email" autocomplete="username" class="w-full"
            placeholder="Input your email" :invalid="!!errors.email" autofocus />
          <small v-if="errors.email" class="text-alert-600">{{ errors.email }}</small>
        </div>
        <div>
          <label for="password" class="mb-1 block text-sm">Password</label>
          <Password v-model="form.password" input-id="password" :feedback="false" toggle-mask class="w-full"
            input-class="w-full" placeholder="Input your password" :invalid="!!errors.password"
            autocomplete="current-password" />
          <small v-if="errors.password" class="text-alert-600">{{ errors.password }}</small>
        </div>
        <div class="flex justify-center pt-3">
          <Button type="submit" label="Login" class="!w-40" :loading="busy" />
        </div>
      </div>

      <details v-if="isLocal" class="mt-8 rounded-md border border-line bg-white p-4 text-sm">
        <summary class="cursor-pointer font-medium">Akun demo (mode lokal)</summary>
        <ul class="mt-3 space-y-1">
          <li v-for="[email, label] in demoAccounts" :key="email">
            <button type="button" class="w-full rounded px-2 py-1 text-left hover:bg-field" @click="useDemo(email!)">
              <span class="font-medium">{{ label }}</span>
              <span class="block text-xs text-ink-soft">{{ email }}</span>
            </button>
          </li>
        </ul>
      </details>
    </form>
  </div>
</template>
