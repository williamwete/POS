# Header keamanan. Di-include di setiap location karena add_header di dalam location
# MENGGANTI header yang diwarisi dari server — tanpa ini halaman SPA (location /) tidak membawa header keamanan.
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header Referrer-Policy strict-origin-when-cross-origin always;
add_header Permissions-Policy "camera=(self), microphone=(), geolocation=(), payment=()" always;
# connect-src: API same-origin + Supabase Auth. Bila memakai domain kustom Supabase, tambahkan di sini.
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' https://*.supabase.co; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'" always;
