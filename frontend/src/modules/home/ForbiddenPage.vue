<template>
  <div class="mx-auto max-w-lg py-16 text-center">
    <i class="pi pi-lock text-4xl text-ink-faint" />
    <h1 class="mt-4 text-2xl font-bold">Halaman ini tidak tersedia untuk akun Anda</h1>
    <p class="mt-2 text-ink-soft">Jika Anda memerlukan akses ini, minta admin menambahkan role yang sesuai.</p>
    <RouterLink :to="{ name: 'home' }" class="mt-6 inline-block font-semibold text-jade-700 underline underline-offset-4">Kembali ke beranda</RouterLink>
  </div>
</template>
