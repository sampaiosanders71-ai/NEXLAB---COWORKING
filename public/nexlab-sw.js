const CACHE_NAME = "nexlab-v25-16-shell";
const SHELL_FILES = ["./", "./manifest.webmanifest", "./icons/nexlab-192.png", "./icons/nexlab-512.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(() => undefined),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(() => undefined);
        return response;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match("./"))),
  );
});

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    payload = { body: event.data ? event.data.text() : "Nova notificação do NexLab." };
  }

  const title = payload.title || "NexLab";
  const options = {
    body: payload.body || "Você recebeu uma nova notificação.",
    icon: payload.icon || "./icons/nexlab-192.png",
    badge: payload.badge || "./icons/nexlab-192.png",
    tag: payload.tag || `nexlab-${Date.now()}`,
    renotify: false,
    data: payload.data || { targetTab: "notificacoes" },
    actions: [{ action: "open", title: "Abrir NexLab" }],
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  const targetTab = data.targetTab || "notificacoes";
  const targetUrl = data.url || `./?nexlabTab=${encodeURIComponent(targetTab)}`;

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(async (clients) => {
      for (const client of clients) {
        if ("focus" in client) {
          client.postMessage({ type: "NEXLAB_NAVIGATE", tab: targetTab });
          await client.focus();
          return;
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
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
