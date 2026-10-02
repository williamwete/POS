const dateTime = new Intl.DateTimeFormat('id-ID', {
  day: '2-digit',
  month: 'short',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  timeZone: 'Asia/Jakarta',
})

const longDate = new Intl.DateTimeFormat('id-ID', {
  weekday: 'long',
  day: 'numeric',
  month: 'long',
  year: 'numeric',
  timeZone: 'UTC',
})

export function formatDateTime(iso?: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? '—' : dateTime.format(d)
}

/** Business date "2026-10-02" -> "Jumat, 2 Oktober 2026" (tanpa geser timezone). */
export function formatBusinessDate(ymd?: string | null): string {
  if (!ymd || !/^\d{4}-\d{2}-\d{2}$/.test(ymd)) return '—'
  return longDate.format(new Date(`${ymd}T00:00:00Z`))
}
