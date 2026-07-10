const CACHE_NAME = "nexlab-v26-4-shell-r1";
const RUNTIME_CACHE = "nexlab-v26-4-runtime-r1";
const IMAGE_CACHE = "nexlab-v26-4-images-r1";
const MAX_RUNTIME_ENTRIES = 60;
const MAX_IMAGE_ENTRIES = 40;

async function trimCache(cacheName, maxEntries) {
  const cache = await caches.open(cacheName);
  const keys = await cache.keys();
  const excess = keys.length - maxEntries;
  if (excess <= 0) return;
  await Promise.all(keys.slice(0, excess).map((request) => cache.delete(request)));
}
const SHELL_FILES = [
  "./",
  "./index.html",
  "./offline.html",
  "./manifest.webmanifest?v=brand-r34",
  "./assets/index-CKPsxFpP.js?v=brand-r34",
  "./assets/index-B1u8eynw.css?v=brand-r34",
  "./assets/nexlab-bootstrap-v26-4.js?v=brand-r34",
  "./assets/nexlab-visual-v26-4.css?v=brand-r34",
  "./assets/nexlab-visual-v26-4.js?v=brand-r34",
  "./icons/nexlab-192.png?v=brand-r34",
  "./icons/nexlab-512.png?v=brand-r34",
  "./icons/nexlab-maskable-192.png?v=brand-r34",
  "./icons/nexlab-maskable-512.png?v=brand-r34",
  "./icons/apple-touch-icon.png?v=brand-r34",
  "./icons/nexlab-favicon-rounded.png?v=brand-r34",
  "./brand/nexlab-logo-light.webp?v=brand-r34",
  "./brand/nexlab-logo-dark.webp?v=brand-r34",
  "./brand/nexlab-icon.webp?v=brand-r34"
];

const ALLOWED_TABS = new Set([
  "dashboard", "pendencias", "agenda", "notificacoes", "participantes",
  "permissoes", "equipes", "perfil", "projetos", "patrimonio", "reserva",
  "marketing", "eventos", "mural", "feedback", "relatorios", "saude-sistema", "logs"
]);

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.allSettled(SHELL_FILES.map((file) => cache.add(file)))
    )
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => ![CACHE_NAME, RUNTIME_CACHE, IMAGE_CACHE].includes(key))
          .map((key) => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;

  const response = await fetch(request);
  if (response && response.status === 200 && response.type === "basic") {
    const cacheName = request.destination === "image" ? IMAGE_CACHE : RUNTIME_CACHE;
    const cache = await caches.open(cacheName);
    cache.put(request, response.clone())
      .then(() => trimCache(
        cacheName,
        cacheName === IMAGE_CACHE ? MAX_IMAGE_ENTRIES : MAX_RUNTIME_ENTRIES
      ))
      .catch(() => undefined);
  }
  return response;
}

async function networkFirstNavigation(request) {
  try {
    const response = await fetch(request);
    if (!response || response.status >= 500) throw new Error("NEXLAB navigation unavailable");
    const cache = await caches.open(RUNTIME_CACHE);
    cache.put("./index.html", response.clone()).catch(() => undefined);
    return response;
  } catch {
    return (
      await caches.match("./index.html")
      || await caches.match("./")
      || await caches.match("./offline.html")
      || new Response("NEXLAB offline", {
        status: 503,
        headers: { "Content-Type": "text/plain; charset=utf-8" }
      })
    );
  }
}

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  if (event.request.mode === "navigate") {
    event.respondWith(networkFirstNavigation(event.request));
    return;
  }

  if (["script", "style", "image", "font", "manifest"].includes(event.request.destination)) {
    event.respondWith(cacheFirst(event.request));
    return;
  }

  event.respondWith(
    fetch(event.request).catch(() => caches.match(event.request))
  );
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "NEXLAB_SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    payload = { body: event.data ? event.data.text() : "Nova notificação do NEXLAB." };
  }

  const requestedTab = String(payload?.data?.targetTab || "notificacoes");
  const targetTab = ALLOWED_TABS.has(requestedTab) ? requestedTab : "notificacoes";

  event.waitUntil(
    self.registration.showNotification(
      String(payload.title || "NEXLAB").slice(0, 120),
      {
        body: String(payload.body || "Você recebeu uma nova notificação.").slice(0, 500),
        icon: "./icons/nexlab-192.png?v=brand-r34",
        badge: "./icons/nexlab-192.png?v=brand-r34",
        tag: String(payload.tag || `nexlab-${Date.now()}`).slice(0, 160),
        renotify: false,
        data: { targetTab },
        actions: [{ action: "open", title: "Abrir NEXLAB" }]
      }
    )
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const requestedTab = String(event.notification?.data?.targetTab || "notificacoes");
  const targetTab = ALLOWED_TABS.has(requestedTab) ? requestedTab : "notificacoes";
  const targetUrl = new URL("./", self.location.href);
  targetUrl.searchParams.set("nexlabTab", targetTab);

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(async (clients) => {
      for (const client of clients) {
        if ("focus" in client) {
          client.postMessage({ type: "NEXLAB_NAVIGATE", tab: targetTab });
          await client.focus();
          return;
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl.toString());
    })
  );
});

self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      clients.forEach((client) =>
        client.postMessage({ type: "NEXLAB_PUSH_SUBSCRIPTION_CHANGED" })
      );
    })
  );
});