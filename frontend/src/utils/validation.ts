import { z } from 'zod'

// Validasi form di client = UX. Backend memvalidasi ulang dengan aturan yang sama.

const code = z.string().trim().regex(/^[A-Z0-9_-]{2,32}$/, 'Kode 2-32 karakter: huruf besar, angka, - atau _')

export const outletCreateSchema = z.object({
  code,
  name: z.string().trim().min(1, 'Nama wajib diisi').max(120),
  address: z.string().max(500).optional(),
  phone: z.string().max(40).optional(),
  timezone: z.string().max(64).optional(),
})

export const terminalSchema = z.object({
  outletId: z.string().uuid('Pilih outlet'),
  code,
  name: z.string().trim().min(1, 'Nama wajib diisi').max(80),
})

export const deviceSchema = z.object({
  outletId: z.string().uuid('Pilih outlet'),
  deviceType: z.enum(['BROWSER', 'PRINTER', 'CASH_DRAWER', 'SCANNER', 'CUSTOMER_DISPLAY']),
  code,
  name: z.string().trim().min(1, 'Nama wajib diisi').max(80),
  identifier: z.string().max(200).optional(),
})

export const employeeSchema = z.object({
  employeeCode: code,
  fullName: z.string().trim().min(1, 'Nama wajib diisi').max(120),
  email: z.union([z.literal(''), z.string().email('Email tidak valid')]).optional(),
  phone: z.string().max(40).optional(),
  position: z.string().max(80).optional(),
})

export const passwordSchema = z
  .string()
  .min(10, 'Minimal 10 karakter')
  .max(72, 'Maksimal 72 karakter')
  .refine((p) => /\p{L}/u.test(p) && /\d/.test(p), 'Harus mengandung huruf dan angka')

export const userCreateSchema = z.object({
  username: z.string().trim().regex(/^[a-z0-9._-]{3,64}$/, 'Username 3-64 karakter: huruf kecil, angka, titik, - atau _'),
  email: z.string().trim().email('Email tidak valid'),
  displayName: z.string().trim().min(1, 'Nama tampilan wajib diisi').max(120),
  password: passwordSchema,
})

export const loginSchema = z.object({
  email: z.string().trim().email('Masukkan email akun Anda'),
  password: z.string().min(1, 'Masukkan password'),
})

/** Ubah hasil zod menjadi map field -> pesan pertama. */
export function fieldErrorsOf(result: { success: boolean; error?: z.ZodError }): Record<string, string> {
  if (result.success || !result.error) return {}
  const errors: Record<string, string> = {}
  for (const issue of result.error.issues) {
    const key = issue.path.join('.')
    if (!errors[key]) errors[key] = issue.message
  }
  return errors
}
