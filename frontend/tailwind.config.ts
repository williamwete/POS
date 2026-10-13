import type { Config } from 'tailwindcss'

// Token desain: lihat docs/FRONTEND.md
export default {
  content: ['./index.html', './src/**/*.{vue,ts}'],
  theme: {
    extend: {
      colors: {
        field: '#F7FAFC',
        surface: '#FFFFFF',
        ink: { DEFAULT: '#111111', soft: '#4B5563', faint: '#9CA3AF' },
        // warna utama merchant: nilai bawaan ada di styles.css, ditimpa saat branding diterapkan (utils/brand.ts)
        jade: {
          50: 'rgb(var(--brand-50) / <alpha-value>)', 100: 'rgb(var(--brand-100) / <alpha-value>)',
          500: 'rgb(var(--brand-500) / <alpha-value>)', 600: 'rgb(var(--brand-600) / <alpha-value>)',
          700: 'rgb(var(--brand-700) / <alpha-value>)', 900: 'rgb(var(--brand-900) / <alpha-value>)',
        },
        amber: { 100: '#FBEBCF', 500: '#E8A33D', 700: '#9A6414' },
        alert: { 50: '#FDECEC', 600: '#E5392D' },
        teal: { 100: '#DDF0EE', 500: '#338C84', 700: '#0F7A6B' },
        line: '#D4DEE8',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
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
