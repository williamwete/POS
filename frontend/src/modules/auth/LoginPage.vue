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
    await router.replace(redirect ?? { name: 'context' })
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
  <div class="grid min-h-screen lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
    <section class="hidden flex-col justify-between bg-jade-700 p-12 text-white lg:flex">
      <div class="flex items-center gap-3">
        <span class="grid h-10 w-10 place-items-center rounded-lg bg-white/10 text-lg font-bold">P</span>
        <span class="text-lg font-semibold">POS Outlet</span>
      </div>
      <div class="max-w-md">
        <p class="text-4xl font-bold leading-tight">Setiap shift dimulai dengan kas yang terhitung.</p>
        <p class="mt-4 text-jade-100">
          Masuk, clock in, lalu buka kasir di terminal Anda. Semua transaksi tercatat atas nama Anda.
        </p>
      </div>
      <p class="text-sm text-jade-100">Gunakan akun yang diberikan admin toko. Jangan berbagi password.</p>
    </section>

    <section class="flex items-center justify-center p-6">
      <form class="w-full max-w-sm" novalidate @submit.prevent="submit">
        <h1 class="text-2xl font-bold">Masuk</h1>
        <p class="mt-1 text-sm text-ink-soft">Gunakan email dan password akun POS Anda.</p>

        <Message v-if="formError" severity="error" class="mt-6" :closable="false">{{ formError }}</Message>

        <div class="mt-6 space-y-5">
          <div>
            <label for="email" class="mb-1 block text-sm font-medium">Email</label>
            <InputText
              id="email"
              v-model="form.email"
              type="email"
              autocomplete="username"
              class="w-full"
              :invalid="!!errors.email"
              aria-describedby="email-error"
              autofocus
            />
            <small v-if="errors.email" id="email-error" class="text-alert-600">{{ errors.email }}</small>
          </div>
          <div>
            <label for="password" class="mb-1 block text-sm font-medium">Password</label>
            <Password
              v-model="form.password"
              input-id="password"
              :feedback="false"
              toggle-mask
              class="w-full"
              input-class="w-full"
              :invalid="!!errors.password"
              autocomplete="current-password"
            />
            <small v-if="errors.password" class="text-alert-600">{{ errors.password }}</small>
          </div>
          <Button type="submit" label="Masuk" class="w-full" :loading="busy" />
        </div>

        <details v-if="isLocal" class="mt-8 rounded-md border border-line bg-surface p-4 text-sm">
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
    </section>
  </div>
</template>
