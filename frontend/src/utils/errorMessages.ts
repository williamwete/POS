// Pesan human readable untuk kode error backend (§99).
// Jika kode tidak dikenal, pesan dari server dipakai (server tidak pernah mengirim detail teknis).
const MESSAGES: Record<string, string> = {
  UNAUTHENTICATED: 'Sesi login berakhir. Silakan masuk lagi.',
  INVALID_CREDENTIALS: 'Email atau password salah.',
  USER_NOT_PROVISIONED: 'Akun ini belum terdaftar atau sudah dinonaktifkan di POS. Hubungi admin.',
  USER_NOT_AUTHORIZED: 'Anda tidak memiliki izin untuk aksi ini.',
  OUTLET_ACCESS_DENIED: 'Anda tidak memiliki akses ke outlet ini.',
  ROLE_ASSIGNMENT_NOT_ALLOWED: 'Anda tidak dapat mengelola user atau role dengan tingkat setara atau di atas Anda.',
  SELF_MODIFICATION_NOT_ALLOWED: 'Akses akun sendiri harus diubah oleh admin lain.',
  CONCURRENT_MODIFICATION: 'Data ini baru saja diubah orang lain. Muat ulang lalu ulangi perubahan Anda.',
  RATE_LIMITED: 'Terlalu banyak permintaan. Tunggu sebentar lalu coba lagi.',
  NETWORK_ERROR: 'Server tidak dapat dihubungi. Periksa koneksi jaringan.',
  INTERNAL_ERROR: 'Terjadi kesalahan pada server. Coba lagi; jika berulang, laporkan kode request.',
  TERMINAL_ALREADY_OPEN: 'Terminal ini sedang dipakai kasir lain. Pilih terminal lain.',
  TERMINAL_MISMATCH: 'Cashier session Anda masih terbuka di terminal lain. Lanjutkan di terminal tersebut.',
  CASHIER_SESSION_OPEN: 'Tutup atau batalkan kasir terlebih dahulu sebelum clock out.',
  REAUTH_REQUIRED: 'Masukkan password Anda untuk membuka kunci terminal.',
  IDEMPOTENCY_KEY_REUSED: 'Permintaan ganda dengan isi berbeda terdeteksi. Muat ulang halaman.',
}

export function messageFor(code: string | undefined, serverMessage?: string): string {
  if (code && MESSAGES[code]) return MESSAGES[code]
  return serverMessage || 'Permintaan gagal diproses.'
}
