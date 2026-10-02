import { definePreset } from '@primeuix/themes'
import Aura from '@primeuix/themes/aura'

/** Preset PrimeVue dengan palet jade POS (lihat tailwind.config.ts). */
export const PosPreset = definePreset(Aura, {
  semantic: {
    primary: {
      50: '#E8F3F0',
      100: '#CDE6DF',
      200: '#A3D2C5',
      300: '#6FB8A6',
      400: '#3C9D86',
      500: '#16876F',
      600: '#0F6E5A',
      700: '#0B5747',
      800: '#094538',
      900: '#08352C',
      950: '#04201A',
    },
    colorScheme: {
      light: {
        surface: {
          0: '#ffffff',
          50: '#F6F8F7',
          100: '#EEF2F0',
          200: '#D5DEDA',
          300: '#B7C4BF',
          400: '#8A9B97',
          500: '#6A7D78',
          600: '#4A5F5A',
          700: '#344944',
          800: '#233833',
          900: '#15302B',
          950: '#0C1E1A',
        },
      },
    },
    focusRing: { width: '2px', style: 'solid', color: '{primary.500}', offset: '2px' },
  },
})
