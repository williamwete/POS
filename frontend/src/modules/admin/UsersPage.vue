<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import Drawer from 'primevue/drawer'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Select from 'primevue/select'
import MultiSelect from 'primevue/multiselect'
import ToggleSwitch from 'primevue/toggleswitch'
import IconField from 'primevue/iconfield'
import InputIcon from 'primevue/inputicon'
import Message from 'primevue/message'
import { useConfirm } from 'primevue/useconfirm'
import PageHeader from '@/components/PageHeader.vue'
import FormField from '@/components/FormField.vue'
import StatusBadge from '@/components/StatusBadge.vue'
import RoleGrantEditor, { type GrantDraft } from './RoleGrantEditor.vue'
import { api } from '@/services'
import { useApiAction } from '@/composables/useApiAction'
import { useSessionStore } from '@/stores/session'
import type { Employee, Role, UserAccount } from '@/types/api'
import { fieldErrorsOf, passwordSchema, userCreateSchema } from '@/utils/validation'
import { formatDateTime } from '@/utils/format'

const session = useSessionStore()
const confirm = useConfirm()
const { busy, run } = useApiAction()

const users = ref<UserAccount[]>([])
const roles = ref<Role[]>([])
const employees = ref<Employee[]>([])
const loading = ref(false)
const q = ref('')

const canManage = computed(() => session.can('user.manage', 'org'))
const allOutlets = computed(() => session.outlets.map((o) => ({ id: o.id, code: o.code, name: o.name })))
const myMaxRank = computed(() => {
  const orgWide = (session.me?.roles ?? []).filter((r) => !r.outletId)
  return Math.max(0, ...orgWide.map((r) => roles.value.find((x) => x.id === r.roleId)?.rank ?? 0))
})

function userRank(u: UserAccount) {
  return Math.max(0, ...u.roles.map((r) => r.rank))
}
function manageable(u: UserAccount) {
  return canManage.value && u.id !== session.me?.user.id && userRank(u) < myMaxRank.value
}

async function load() {
  loading.value = true
  await run(async () => {
    const [u, r] = await Promise.all([
      api().get<UserAccount[]>('/api/users', { query: { q: q.value || undefined } }),
      api().get<Role[]>('/api/roles'),
    ])
    users.value = u.data
    roles.value = r.data
  })
  loading.value = false
}
let t: number | undefined
watch(q, () => { window.clearTimeout(t); t = window.setTimeout(load, 300) })
onMounted(async () => {
  await load()
  if (canManage.value) {
    try {
      employees.value = (await api().get<Employee[]>('/api/employees', { query: { active: true, limit: 500 } })).data
    } catch {
      employees.value = []
    }
  }
})

function employeeOptions(currentEmployeeId?: string) {
  return [
    { label: 'Tidak terhubung', value: null as string | null },
    ...employees.value
      .filter((e) => !e.linkedUserId || e.id === currentEmployeeId)
      .map((e) => ({ label: `${e.employeeCode} ${e.fullName}`, value: e.id as string | null })),
  ]
}

function validGrants(grants: GrantDraft[], outletIds: string[]): string | null {
  if (grants.some((g) => !g.roleId)) return 'Pilih role untuk setiap baris.'
  if (grants.some((g) => g.outletId && !outletIds.includes(g.outletId))) {
    return 'Role untuk outlet tertentu membutuhkan akses ke outlet tersebut.'
  }
  const keys = grants.map((g) => `${g.roleId}|${g.outletId}`)
  if (new Set(keys).size !== keys.length) return 'Ada role yang sama dua kali pada scope yang sama.'
  return null
}

// ---------------------------------------------------------------- create
const createOpen = ref(false)
const createForm = reactive({
  username: '', email: '', displayName: '', password: '',
  employeeId: null as string | null, outletIds: [] as string[], roles: [] as GrantDraft[],
})
const createErrors = ref<Record<string, string>>({})
const createOutlets = computed(() => allOutlets.value.filter((o) => createForm.outletIds.includes(o.id)))

function openCreate() {
  Object.assign(createForm, { username: '', email: '', displayName: '', password: '', employeeId: null, outletIds: [], roles: [] })
  createErrors.value = {}
  createOpen.value = true
}

watch(() => createForm.employeeId, (id) => {
  const e = employees.value.find((x) => x.id === id)
  if (e) {
    if (!createForm.displayName) createForm.displayName = e.fullName
    if (!createForm.email && e.email) createForm.email = e.email
    if (e.homeOutletId && !createForm.outletIds.includes(e.homeOutletId)) createForm.outletIds.push(e.homeOutletId)
  }
})

async function submitCreate() {
  const parsed = userCreateSchema.safeParse(createForm)
  createErrors.value = fieldErrorsOf(parsed)
  const grantError = validGrants(createForm.roles, createForm.outletIds)
  if (grantError) createErrors.value.roles = grantError
  if (!parsed.success || grantError) return
  const ok = await run((key) => api().post<UserAccount>('/api/users', {
    username: parsed.data.username,
    email: parsed.data.email.toLowerCase(),
    displayName: parsed.data.displayName,
    password: parsed.data.password,
    employeeId: createForm.employeeId,
    outletIds: createForm.outletIds,
    roles: createForm.roles.map((g) => ({ roleId: g.roleId, outletId: g.outletId })),
  }, { idempotencyKey: key }), 'User dibuat')
  createForm.password = ''
  if (ok) { createOpen.value = false; await load() }
}

// ---------------------------------------------------------------- detail drawer
const selected = ref<UserAccount | null>(null)
const detail = reactive({
  displayName: '', employeeId: null as string | null, active: true,
  outletIds: [] as string[], roles: [] as GrantDraft[], newPassword: '',
})
const detailError = ref<string | null>(null)
const editable = computed(() => !!selected.value && manageable(selected.value))
const detailOutlets = computed(() => allOutlets.value.filter((o) => (selected.value?.outlets ?? []).some((x) => x.outletId === o.id)))

async function openDetail(u: UserAccount) {
  const fresh = (await api().get<UserAccount>(`/api/users/${u.id}`)).data
  setSelected(fresh)
}
function setSelected(u: UserAccount) {
  selected.value = u
  Object.assign(detail, {
    displayName: u.displayName, employeeId: u.employeeId ?? null, active: u.active,
    outletIds: u.outlets.map((o) => o.outletId),
    roles: u.roles.map((r) => ({ roleId: r.roleId, outletId: r.outletId ?? null })),
    newPassword: '',
  })
  detailError.value = null
}

async function saveProfile() {
  if (!selected.value) return
  const u = selected.value
  const doSave = async () => {
    const res = await run(() => api().put<UserAccount>(`/api/users/${u.id}`, {
      displayName: detail.displayName.trim(), employeeId: detail.employeeId, active: detail.active, version: u.version,
    }), detail.active ? 'Profil user disimpan' : 'User dinonaktifkan')
    if (res) { setSelected(res.data); await load() }
  }
  if (u.active && !detail.active) {
    confirm.require({
      header: `Nonaktifkan ${u.username}?`,
      message: 'User langsung tidak dapat memakai POS dan tidak dapat login lagi sampai diaktifkan kembali.',
      acceptLabel: 'Nonaktifkan', rejectLabel: 'Batal', acceptProps: { severity: 'danger' },
      accept: () => void doSave(),
    })
  } else {
    await doSave()
  }
}

async function saveOutlets() {
  if (!selected.value) return
  const res = await run(() => api().put<UserAccount>(`/api/users/${selected.value!.id}/outlets`, { outletIds: detail.outletIds }), 'Akses outlet disimpan')
  if (res) { setSelected(res.data); await load() }
}

async function saveRoles() {
  if (!selected.value) return
  const err = validGrants(detail.roles, selected.value.outlets.map((o) => o.outletId))
  detailError.value = err
  if (err) return
  const res = await run(() => api().put<UserAccount>(`/api/users/${selected.value!.id}/roles`, {
    roles: detail.roles.map((g) => ({ roleId: g.roleId, outletId: g.outletId })),
  }), 'Role disimpan')
  if (res) { setSelected(res.data); await load() }
}

async function resetPassword() {
  if (!selected.value) return
  const parsed = passwordSchema.safeParse(detail.newPassword)
  if (!parsed.success) { detailError.value = parsed.error.issues[0]?.message ?? 'Password tidak valid'; return }
  detailError.value = null
  const res = await run(() => api().post(`/api/users/${selected.value!.id}/reset-password`, { password: parsed.data }), 'Password direset')
  detail.newPassword = ''
  void res
}
</script>

<template>
  <div>
    <PageHeader title="User & akses" description="Akun login, outlet yang boleh diakses, dan role di setiap outlet.">
      <template #actions>
        <Button v-if="canManage" label="Tambah user" icon="pi pi-plus" @click="openCreate" />
      </template>
    </PageHeader>

    <IconField class="mb-4 max-w-md">
      <InputIcon class="pi pi-search" />
      <InputText v-model="q" placeholder="Cari username, nama, atau email" class="w-full" aria-label="Cari user" />
    </IconField>

    <DataTable
      :value="users" :loading="loading" data-key="id" class="rounded-2xl border border-line bg-surface"
      selection-mode="single" paginator :rows="25" @row-click="openDetail($event.data)"
    >
      <template #empty>Tidak ada user yang cocok.</template>
      <Column header="User">
        <template #body="{ data }">
          <div class="font-semibold">{{ data.displayName }}</div>
          <div class="text-xs text-ink-soft">{{ data.username }}</div>
        </template>
      </Column>
      <Column field="email" header="Email" />
      <Column header="Karyawan"><template #body="{ data }"><span class="tabular text-sm">{{ data.employeeCode ?? '—' }}</span></template></Column>
      <Column header="Login terakhir"><template #body="{ data }"><span class="text-sm">{{ formatDateTime(data.lastLoginAt) }}</span></template></Column>
      <Column header="Status"><template #body="{ data }"><StatusBadge :active="data.active" /></template></Column>
      <Column class="w-16"><template #body="{ data }"><Button icon="pi pi-angle-right" text rounded :aria-label="`Detail ${data.username}`" @click.stop="openDetail(data)" /></template></Column>
    </DataTable>

    <!-- Tambah user -->
    <Dialog v-model:visible="createOpen" header="Tambah user" modal class="w-full max-w-2xl">
      <form class="grid gap-4 sm:grid-cols-2" novalidate @submit.prevent="submitCreate">
        <FormField label="Karyawan" for="c-emp" hint="Hubungkan akun ke data karyawan agar kehadiran dan transaksi tertelusuri." class="sm:col-span-2">
          <Select v-model="createForm.employeeId" input-id="c-emp" :options="employeeOptions()" option-label="label" option-value="value" placeholder="Tidak terhubung" filter class="w-full" />
        </FormField>
        <FormField label="Username" for="c-user" :error="createErrors.username" required>
          <InputText id="c-user" v-model="createForm.username" class="w-full" autocomplete="off" />
        </FormField>
        <FormField label="Email login" for="c-email" :error="createErrors.email" required>
          <InputText id="c-email" v-model="createForm.email" type="email" class="w-full" autocomplete="off" />
        </FormField>
        <FormField label="Nama tampilan" for="c-name" :error="createErrors.displayName" required>
          <InputText id="c-name" v-model="createForm.displayName" class="w-full" />
        </FormField>
        <FormField label="Password awal" for="c-pass" :error="createErrors.password" hint="Minimal 10 karakter, huruf dan angka." required>
          <Password v-model="createForm.password" input-id="c-pass" :feedback="false" toggle-mask class="w-full" input-class="w-full" autocomplete="new-password" />
        </FormField>
        <FormField label="Akses outlet" for="c-outlets" class="sm:col-span-2">
          <MultiSelect v-model="createForm.outletIds" input-id="c-outlets" :options="allOutlets" option-label="name" option-value="id" display="chip" placeholder="Pilih outlet" class="w-full" />
        </FormField>
        <div class="sm:col-span-2">
          <p class="mb-1 text-sm font-medium">Role</p>
          <RoleGrantEditor v-model="createForm.roles" :roles="roles" :outlets="createOutlets" :max-rank="myMaxRank" />
          <small v-if="createErrors.roles" class="mt-1 block text-alert-600" role="alert">{{ createErrors.roles }}</small>
        </div>
        <div class="flex justify-end gap-2 pt-2 sm:col-span-2">
          <Button label="Batal" severity="secondary" text type="button" @click="createOpen = false" />
          <Button label="Buat user" type="submit" :loading="busy" />
        </div>
      </form>
    </Dialog>

    <!-- Detail user -->
    <Drawer :visible="!!selected" position="right" :style="{ width: 'min(100vw, 34rem)' }" :header="selected?.displayName" @update:visible="(v) => { if (!v) selected = null }">
      <div v-if="selected" class="space-y-8">
        <Message v-if="!editable" severity="secondary" :closable="false">
          {{ selected.id === session.me?.user.id
            ? 'Ini akun Anda sendiri. Perubahan akses harus dilakukan admin lain.'
            : canManage ? 'User ini memiliki role setara atau di atas Anda sehingga tidak dapat Anda ubah.'
            : 'Anda hanya dapat melihat data user ini.' }}
        </Message>
        <Message v-if="detailError" severity="error" :closable="false">{{ detailError }}</Message>

        <section>
          <h3 class="mb-3 font-semibold">Profil</h3>
          <div class="space-y-4">
            <div class="text-sm"><div class="font-medium">{{ selected.username }}</div><div class="text-ink-soft">{{ selected.email }}</div></div>
            <FormField label="Nama tampilan" for="d-name"><InputText id="d-name" v-model="detail.displayName" class="w-full" :disabled="!editable" /></FormField>
            <FormField label="Karyawan" for="d-emp">
              <Select v-model="detail.employeeId" input-id="d-emp" :options="employeeOptions(selected.employeeId)" option-label="label" option-value="value" placeholder="Tidak terhubung" filter class="w-full" :disabled="!editable" />
            </FormField>
            <div class="flex items-center gap-3">
              <ToggleSwitch v-model="detail.active" input-id="d-active" :disabled="!editable" />
              <label for="d-active" class="text-sm">Akun aktif</label>
            </div>
            <Button v-if="editable" label="Simpan profil" size="small" :loading="busy" @click="saveProfile" />
          </div>
        </section>

        <section>
          <h3 class="mb-3 font-semibold">Akses outlet</h3>
          <MultiSelect v-model="detail.outletIds" :options="allOutlets" option-label="name" option-value="id" display="chip" placeholder="Belum ada akses outlet khusus" class="w-full" :disabled="!editable" aria-label="Akses outlet" />
          <Button v-if="editable" class="mt-3" label="Simpan akses outlet" size="small" :loading="busy" @click="saveOutlets" />
        </section>

        <section>
          <h3 class="mb-3 font-semibold">Role</h3>
          <RoleGrantEditor v-model="detail.roles" :roles="roles" :outlets="detailOutlets" :max-rank="myMaxRank" :disabled="!editable" />
          <Button v-if="editable" class="mt-3" label="Simpan role" size="small" :loading="busy" @click="saveRoles" />
        </section>

        <section v-if="editable">
          <h3 class="mb-3 font-semibold">Reset password</h3>
          <div class="flex flex-wrap items-end gap-2">
            <Password v-model="detail.newPassword" :feedback="false" toggle-mask input-class="w-full" class="flex-1" placeholder="Password baru" autocomplete="new-password" aria-label="Password baru" />
            <Button label="Reset password" severity="secondary" size="small" :loading="busy" @click="resetPassword" />
          </div>
          <p class="mt-1 text-xs text-ink-faint">Sampaikan password baru langsung ke pemilik akun. Password tidak tercatat di audit log.</p>
        </section>
      </div>
    </Drawer>
  </div>
</template>
