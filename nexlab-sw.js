const CACHE_NAME = "nexlab-v25-17-11-shell-email-removed-r1";
const RUNTIME_CACHE = "nexlab-v25-17-11-runtime-r1";
const SHELL_FILES = [
  "./",
  "./index.html",
  "./offline.html",
  "./changelog.html",
  "./publicacao.html",
  "./assets/nexlab-bootstrap-v25-17-11.js?v=brand-r24",
  "./manifest.webmanifest?v=brand-r24",
  "./assets/nexlab-visual-v25-17-11.css?v=brand-r24",
  "./assets/nexlab-visual-v25-17-11.js?v=brand-r24",
  "./icons/nexlab-192.png?v=brand-r24",
  "./icons/nexlab-512.png?v=brand-r24",
  "./icons/nexlab-maskable-192.png?v=brand-r24",
  "./icons/nexlab-maskable-512.png?v=brand-r24",
  "./icons/apple-touch-icon.png?v=brand-r24",
  "./icons/nexlab-favicon-rounded.png?v=brand-r24",
  "./brand/nexlab-logo-light.png?v=brand-r24",
  "./brand/nexlab-logo-dark.png?v=brand-r24",
  "./brand/nexlab-icon.png?v=brand-r24"
];
const ALLOWED_TABS = new Set([
  "dashboard", "pendencias", "agenda", "notificacoes", "participantes",
  "permissoes", "equipes", "perfil", "projetos", "patrimonio", "reserva",
  "marketing", "eventos", "mural", "feedback", "relatorios", "saude-sistema", "logs"
]);

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(() => undefined));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => ![CACHE_NAME, RUNTIME_CACHE].includes(key)).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response && response.status === 200 && response.type === "basic") {
    const cache = await caches.open(RUNTIME_CACHE);
    cache.put(request, response.clone()).catch(() => undefined);
  }
  return response;
}

async function networkFirstNavigation(request) {
  try {
    const response = await fetch(request);
    if (!response || response.status >= 500) throw new Error("NEXLAB navigation unavailable");
    const cache = await caches.open(RUNTIME_CACHE);
    cache.put("./", response.clone()).catch(() => undefined);
    return response;
  } catch {
    return (await caches.match("./")) || (await caches.match("./index.html")) || (await caches.match("./offline.html")) || new Response("NEXLAB offline", { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } });
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

  if (["script", "style", "image", "font", "manifest"].includes(event.request.destination) || url.pathname.endsWith(".html")) {
    event.respondWith(cacheFirst(event.request));
    return;
  }

  event.respondWith(
    fetch(event.request)
      .then((response) => response)
      .catch(() => caches.match(event.request))
  );
});

self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "NEXLAB_SKIP_WAITING") self.skipWaiting();
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
  const options = {
    body: String(payload.body || "Você recebeu uma nova notificação.").slice(0, 500),
    icon: "./icons/nexlab-192.png?v=brand-r24",
    badge: "./icons/nexlab-192.png?v=brand-r24",
    tag: String(payload.tag || `nexlab-${Date.now()}`).slice(0, 160),
    renotify: false,
    data: { targetTab },
    actions: [{ action: "open", title: "Abrir NEXLAB" }]
  };

  event.waitUntil(self.registration.showNotification(String(payload.title || "NEXLAB").slice(0, 120), options));
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
      return undefined;
    })
  );
});

self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      clients.forEach((client) => client.postMessage({ type: "NEXLAB_PUSH_SUBSCRIPTION_CHANGED" }));
    })
  );
});
