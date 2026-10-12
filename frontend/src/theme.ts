import { definePreset } from '@primeuix/themes'
import Aura from '@primeuix/themes/aura'

/** Preset PrimeVue dengan palet biru CuanRena (lihat tailwind.config.ts). */
export const PosPreset = definePreset(Aura, {
  semantic: {
    primary: {
      50: '#EAF2FA', 100: '#D6E6F2', 200: '#B5D3EA', 300: '#97BADD', 400: '#86AAD6',
      500: '#78A0CF', 600: '#5E8BC0', 700: '#3F6A9E', 800: '#2E5282', 900: '#1F3B5E', 950: '#142A45',
    },
    colorScheme: {
      light: {
        surface: {
          0: '#ffffff',
          50: '#F7FAFC',
          100: '#EDF2F7',
          200: '#D4DEE8',
          300: '#B5C3D1',
          400: '#9CA3AF',
          500: '#6B7280',
          600: '#4B5563',
          700: '#374151',
          800: '#1F2937',
          900: '#111111',
          950: '#0A0A0A',
        },
      },
    },
    focusRing: { width: '2px', style: 'solid', color: '{primary.500}', offset: '2px' },
  },
})
