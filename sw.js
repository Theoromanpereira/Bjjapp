// Tatame · service worker
// - A página (index.html) usa "rede primeiro": quando há internet você sempre recebe a versão mais nova;
//   sem internet o app abre a última versão guardada.
// - Fontes e a biblioteca do Supabase (CDN) ficam em cache para o app abrir offline.
// - NUNCA guarda chamadas ao Supabase (login, dados, comunidades): só o site em si.
const CACHE = 'tatame-v1';
const SHELL = ['/', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png', '/icons/icon-maskable-512.png', '/icons/apple-touch-icon.png', '/icons/favicon-32.png'];
const CDN_PRECACHE = ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js'];
const CDN_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com', 'cdn.jsdelivr.net', 'unpkg.com'];

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // um item que falhe não impede a instalação
    await Promise.all(SHELL.map(u => cache.add(u).catch(() => {})));
    await Promise.all(CDN_PRECACHE.map(u => cache.add(new Request(u, { mode: 'cors' })).catch(() => {})));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timeout')), ms);
    promise.then(v => { clearTimeout(t); resolve(v); }, e => { clearTimeout(t); reject(e); });
  });
}

async function networkFirstPage(request) {
  const cache = await caches.open(CACHE);
  try {
    const res = await withTimeout(fetch(request), 5000);
    if (res && res.ok) cache.put('/', res.clone());
    return res;
  } catch {
    return (await cache.match('/')) || new Response('Você está sem internet e o app ainda não foi guardado neste aparelho.', { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  }
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(request);
  const update = fetch(request).then(res => { if (res && (res.ok || res.type === 'opaque')) cache.put(request, res.clone()); return res; }).catch(() => null);
  return cached || (await update) || Response.error();
}

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co')) return;          // login, dados e comunidades: sempre direto na rede
  if (url.pathname.startsWith('/_vercel')) return;            // análise da Vercel
  if (req.mode === 'navigate' && url.origin === self.location.origin) {
    event.respondWith(networkFirstPage(req));
  } else if (url.origin === self.location.origin && (url.pathname.startsWith('/icons/') || url.pathname === '/manifest.webmanifest')) {
    event.respondWith(staleWhileRevalidate(req));
  } else if (CDN_HOSTS.includes(url.hostname)) {
    event.respondWith(staleWhileRevalidate(req));
  }
});
