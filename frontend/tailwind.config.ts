import type { Config } from 'tailwindcss'

// Token desain: lihat docs/FRONTEND.md
export default {
  content: ['./index.html', './src/**/*.{vue,ts}'],
  theme: {
    extend: {
      colors: {
        field: '#F4F6F5',
        surface: '#FFFFFF',
        ink: { DEFAULT: '#15302B', soft: '#4A5F5A', faint: '#8A9B97' },
        jade: { 50: '#E8F3F0', 100: '#CDE6DF', 500: '#16876F', 600: '#0F6E5A', 700: '#0B5747', 900: '#08352C' },
        amber: { 100: '#FBEBCF', 500: '#E8A33D', 700: '#9A6414' },
        alert: { 50: '#FBEAE6', 600: '#C2412D' },
        line: '#D5DEDA',
      },
      fontFamily: {
        sans: ['"Plus Jakarta Sans"', 'system-ui', 'sans-serif'],
      },
      fontSize: {
        // skala modular 1.2
        xs: ['0.75rem', { lineHeight: '1rem' }],
        sm: ['0.875rem', { lineHeight: '1.3rem' }],
        base: ['1rem', { lineHeight: '1.5rem' }],
        lg: ['1.2rem', { lineHeight: '1.7rem' }],
        xl: ['1.44rem', { lineHeight: '1.9rem' }],
        '2xl': ['1.728rem', { lineHeight: '2.2rem' }],
        '3xl': ['2.074rem', { lineHeight: '2.5rem' }],
        '4xl': ['2.986rem', { lineHeight: '3.2rem' }],
      },
    },
  },
  plugins: [],
} satisfies Config
