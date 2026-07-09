const CACHE_NAME = "nexlab-v25-16-3-shell";
const SHELL_FILES = [
  "./",
  "./manifest.webmanifest",
  "./icons/nexlab-192.png",
  "./icons/nexlab-512.png",
  "./icons/nexlab-maskable-192.png",
  "./icons/nexlab-maskable-512.png",
  "./icons/apple-touch-icon.png",
  "./brand/nexlab-logo-light.png",
  "./brand/nexlab-logo-dark.png",
  "./brand/nexlab-icon.png",
  "./assets/nexlab-visual-v25-16-3.css",
  "./assets/nexlab-visual-v25-16-3.js",
];
const ALLOWED_TABS = new Set([
  "dashboard", "pendencias", "agenda", "notificacoes", "participantes",
  "permissoes", "equipes", "perfil", "projetos", "patrimonio", "reserva",
  "marketing", "eventos", "mural", "feedback", "relatorios", "saude-sistema", "logs",
]);

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(() => undefined));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  if (event.request.mode === "navigate") {
    event.respondWith(
      fetch(event.request)
        .then((response) => response)
        .catch(() => caches.match("./")),
    );
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).then((response) => {
        if (!response || response.status !== 200 || response.type !== "basic") return response;
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(() => undefined);
        return response;
      });
    }),
  );
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
    icon: "./icons/nexlab-192.png",
    badge: "./icons/nexlab-192.png",
    tag: String(payload.tag || `nexlab-${Date.now()}`).slice(0, 160),
    renotify: false,
    data: { targetTab },
    actions: [{ action: "open", title: "Abrir NEXLAB" }],
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
    }),
  );
});

self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      clients.forEach((client) => client.postMessage({ type: "NEXLAB_PUSH_SUBSCRIPTION_CHANGED" }));
    }),
  );
});
