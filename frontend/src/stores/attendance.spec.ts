import { describe, expect, it } from 'vitest'
import { formatDuration, workedSeconds } from './attendance'
import type { Attendance } from '@/types/api'

function att(partial: Partial<Attendance>): Attendance {
  return {
    id: 'a', employeeId: 'e', employeeCode: 'EMP005', employeeName: 'Dewi', outletId: 'o', outletCode: 'JKT01',
    businessDate: '2026-10-02', clockIn: '2026-10-02T01:00:00Z', status: 'WORKING', breakSeconds: 0, version: 0,
    breaks: [], ...partial,
  }
}

describe('attendance durations', () => {
  it('subtracts finished breaks from worked time', () => {
    const a = att({
      clockOut: '2026-10-02T10:00:00Z',
      status: 'COMPLETED',
      breaks: [{ id: 'b', breakStart: '2026-10-02T05:00:00Z', breakEnd: '2026-10-02T06:00:00Z', durationSeconds: 3600 }],
    })
    expect(workedSeconds(a, new Date('2026-10-02T12:00:00Z'))).toBe(8 * 3600)
  })

  it('counts a running break up to now', () => {
    const a = att({ status: 'ON_BREAK', breaks: [{ id: 'b', breakStart: '2026-10-02T03:00:00Z' }] })
    expect(workedSeconds(a, new Date('2026-10-02T03:30:00Z'))).toBe(2 * 3600)
  })

  it('never returns negative values', () => {
    expect(workedSeconds(att({}), new Date('2026-10-02T00:00:00Z'))).toBe(0)
  })

  it('formats hours and minutes', () => {
    expect(formatDuration(8 * 3600 + 5 * 60)).toBe('8 j 05 m')
    expect(formatDuration(59)).toBe('0 j 00 m')
  })
})
