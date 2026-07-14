(function(){
  if (window.__NEXLAB_BOOTSTRAP_V26_7__) return;
  window.__NEXLAB_BOOTSTRAP_V26_7__ = true;

  const nativeFetch = window.fetch ? window.fetch.bind(window) : null;
  const nativeAlert = window.alert ? window.alert.bind(window) : function(){};
  const SUPABASE_RE = /https:\/\/[a-z0-9.-]+\.supabase\.co/i;
  const SUPABASE_SOCKET_RE = /wss:\/\/[a-z0-9.-]+\.supabase\.co/i;
  const SUPABASE_REST_RE = /https:\/\/[a-z0-9.-]+\.supabase\.co\/rest\/v1\//i;
  const MUTATING_METHOD_RE = /^(POST|PUT|PATCH|DELETE)$/i;
  const READ_CACHE_TTL = 12000;
  const MAX_READ_CACHE_ENTRIES = 80;
  const readCache = new Map();

  function adaptiveReadCacheTtl(){
    try {
      const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
      if (!connection) return READ_CACHE_TTL;
      if (connection.saveData) return 30000;
      if (connection.effectiveType === 'slow-2g' || connection.effectiveType === '2g') return 45000;
      if (connection.effectiveType === '3g') return 24000;
    } catch {}
    return READ_CACHE_TTL;
  }

  function pruneReadCache(now = Date.now()){
    const ttl = adaptiveReadCacheTtl();
    for (const [key, value] of readCache) {
      if (!value || now - value.createdAt >= ttl) readCache.delete(key);
    }
    while (readCache.size > MAX_READ_CACHE_ENTRIES) {
      const oldestKey = readCache.keys().next().value;
      if (oldestKey === undefined) break;
      readCache.delete(oldestKey);
    }
  }
  const pendingReads = new Map();
  let readCacheGeneration = 0;

  function methodFrom(input, init){
    try {
      if (init && init.method) return String(init.method).toUpperCase();
      if (input && input.method) return String(input.method).toUpperCase();
      return 'GET';
    } catch { return 'GET'; }
  }

  function urlFrom(input){
    try {
      if (typeof input === 'string') return input;
      if (input && typeof input.url === 'string') return input.url;
      return String(input || '');
    } catch { return ''; }
  }

  function mergedHeaders(input, init){
    try {
      const headers = new Headers(input && input.headers ? input.headers : undefined);
      if (init && init.headers) new Headers(init.headers).forEach((value, key) => headers.set(key, value));
      return headers;
    } catch {
      return new Headers();
    }
  }

  function readKey(input, init, url){
    const headers = mergedHeaders(input, init);
    return [
      url,
      headers.get('authorization') || '',
      headers.get('range') || '',
      headers.get('accept-profile') || '',
      headers.get('prefer') || ''
    ].join('|');
  }

  function emit(name, detail){
    try { window.dispatchEvent(new CustomEvent(name, { detail: detail || {} })); } catch {}
  }

  function invalidateReadCache(reason = 'manual', detail = {}){
    readCacheGeneration += 1;
    readCache.clear();
    pendingReads.clear();
    emit('nexlab:read-cache-invalidated', {
      reason,
      generation: readCacheGeneration,
      ...detail
    });
  }

  function realtimePayloadHasDatabaseChange(value){
    if (typeof value !== 'string') return false;
    return /(?:\"event\"\s*:\s*\"postgres_changes\"|\"type\"\s*:\s*\"postgres_changes\"|,\s*\"postgres_changes\"\s*,)/.test(value);
  }

  function inspectRealtimePayload(value, socketUrl){
    try {
      if (typeof value === 'string') {
        if (realtimePayloadHasDatabaseChange(value)) {
          invalidateReadCache('realtime-postgres-change', { socketUrl });
        }
        return;
      }
      if (value instanceof ArrayBuffer) {
        inspectRealtimePayload(new TextDecoder().decode(value), socketUrl);
        return;
      }
      if (ArrayBuffer.isView(value)) {
        inspectRealtimePayload(
          new TextDecoder().decode(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)),
          socketUrl
        );
        return;
      }
      if (typeof Blob !== 'undefined' && value instanceof Blob) {
        value.text().then((text) => inspectRealtimePayload(text, socketUrl)).catch(() => undefined);
      }
    } catch {}
  }

  function installRealtimeCacheInvalidation(){
    const NativeWebSocket = globalThis.WebSocket;
    if (typeof NativeWebSocket !== 'function' || NativeWebSocket.__NEXLAB_CACHE_WRAPPED__) return;

    function NexlabWebSocket(...args){
      const socket = new NativeWebSocket(...args);
      try {
        const socketUrl = String(socket.url || args[0] || '');
        if (SUPABASE_SOCKET_RE.test(socketUrl)) {
          socket.addEventListener('message', (event) => {
            inspectRealtimePayload(event.data, socketUrl);
          });
        }
      } catch {}
      return socket;
    }

    NexlabWebSocket.prototype = NativeWebSocket.prototype;
    Object.setPrototypeOf(NexlabWebSocket, NativeWebSocket);
    Object.defineProperty(NexlabWebSocket, '__NEXLAB_CACHE_WRAPPED__', { value: true });
    globalThis.WebSocket = NexlabWebSocket;
  }

  installRealtimeCacheInvalidation();

  window.__NEXLAB_READ_CACHE__ = Object.freeze({
    invalidate: (reason = 'test-or-manual') => invalidateReadCache(reason),
    snapshot: () => Object.freeze({
      entries: readCache.size,
      pending: pendingReads.size,
      generation: readCacheGeneration,
      ttl: adaptiveReadCacheTtl()
    })
  });

  window.nexlabShowModal = function(options){
    if (!window.__NEXLAB_MODAL_READY__) {
      nativeAlert(String(options?.message || options?.text || 'Aviso do NEXLAB'));
      return Promise.resolve(true);
    }
    return new Promise((resolve) => {
      emit('nexlab:modal', Object.assign({}, options || {}, { resolve }));
    });
  };

  window.alert = function(message){
    if (!window.__NEXLAB_MODAL_READY__) return nativeAlert(message);
    try {
      window.nexlabShowModal({
        title: 'Aviso do NEXLAB',
        message: String(message || ''),
        variant: 'info',
        okLabel: 'Entendi'
      });
    } catch {
      nativeAlert(message);
    }
  };

  async function fetchAndMonitor(input, init, target, method, isSupabase){
    const isMutatingSupabase = isSupabase && MUTATING_METHOD_RE.test(method);
    const startedAt = Date.now();

    if (isMutatingSupabase) {
      invalidateReadCache('supabase-mutation', { method, url: target });
      emit('nexlab:action-start', { method, url: target, startedAt });
    }

    try {
      const response = await nativeFetch(input, init);
      if (isSupabase) {
        if (response.status === 0 || response.status === 502 || response.status === 503 || response.status === 504 || response.status >= 500) {
          if (!target.includes('/rpc/nexlab_record_client_error_v26_7_4') && !target.includes('/rpc/nexlab_record_client_error_v26_7')) {
            observabilityQueueEvent({
              source: 'fetch',
              severity: 'error',
              message: `Falha HTTP ${response.status} em ${method}.`,
              metadata: {
                status: response.status,
                method,
                path: observabilitySanitize(new URL(target).pathname, 300)
              }
            });
          }
          emit('nexlab:connection-error', {
            title: 'Falha de conexão com o NEXLAB',
            message: 'O app não conseguiu confirmar a comunicação com o servidor. Verifique sua internet e tente novamente.',
            detail: `Servidor respondeu com status ${response.status}.`,
            status: response.status,
            url: target
          });
        } else if (response.ok) {
          emit('nexlab:connection-restored', { url: target });
        }
      }
      return response;
    } catch (error) {
      if (isSupabase || !navigator.onLine) {
        emit('nexlab:connection-error', {
          title: navigator.onLine ? 'Falha de conexão com o NEXLAB' : 'Você está sem internet',
          message: navigator.onLine ? 'Não foi possível conectar ao Supabase agora. Tente novamente em alguns instantes.' : 'A conexão caiu. O app pode exibir dados já carregados, mas novas alterações dependem de internet.',
          detail: error && error.message ? error.message : 'Erro de rede não identificado.',
          url: target
        });
      }
      throw error;
    } finally {
      if (isMutatingSupabase) {
        const elapsed = Date.now() - startedAt;
        window.setTimeout(
          () => emit('nexlab:action-end', { method, url: target, elapsed }),
          Math.max(120, 360 - elapsed)
        );
      }
    }
  }

  window.addEventListener('nexlab:retry-module', () => invalidateReadCache('module-retry'));

  if (nativeFetch) {
    window.fetch = async function(input, init){
      const target = urlFrom(input);
      const method = methodFrom(input, init);
      const isSupabase = SUPABASE_RE.test(target);
      const cacheableRead = method === 'GET' && SUPABASE_REST_RE.test(target);

      if (!cacheableRead) {
        return fetchAndMonitor(input, init, target, method, isSupabase);
      }

      const key = readKey(input, init, target);
      const now = Date.now();
      pruneReadCache(now);
      const cached = readCache.get(key);
      const ttl = adaptiveReadCacheTtl();

      if (cached && now - cached.createdAt < ttl) {
        return cached.response.clone();
      }
      if (cached) readCache.delete(key);

      const pending = pendingReads.get(key);
      if (pending) {
        const template = await pending;
        return template.clone();
      }

      const requestGeneration = readCacheGeneration;
      const request = fetchAndMonitor(input, init, target, method, isSupabase)
        .then((response) => {
          if (response.ok && requestGeneration === readCacheGeneration) {
            const cacheTemplate = response.clone();
            readCache.delete(key);
            readCache.set(key, { createdAt: Date.now(), response: cacheTemplate });
            pruneReadCache();
          }
          return response;
        });

      pendingReads.set(key, request.then((response) => response.clone()));
      try {
        return await request;
      } finally {
        pendingReads.delete(key);
      }
    };
  }



  const OBSERVABILITY_VERSION = '26.15.0';
  const OBSERVABILITY_QUEUE_KEY = 'nexlab:observability:queue:v26.7.5';
  const OBSERVABILITY_DEDUP_KEY = 'nexlab:observability:dedup:v26.7.5';
  const OBSERVABILITY_RPC = 'nexlab_record_client_error_v26_7_4';
  const OBSERVABILITY_MAX_QUEUE = 20;
  const OBSERVABILITY_DEDUP_MS = 5 * 60 * 1000;
  let observabilityFlushRunning = false;
  let observabilityRetryAfter = 0;

  function observabilityReadJson(key, fallback){
    try {
      const value = sessionStorage.getItem(key);
      return value ? JSON.parse(value) : fallback;
    } catch {
      return fallback;
    }
  }

  let observabilityQueue = observabilityReadJson(OBSERVABILITY_QUEUE_KEY, []);
  if (!Array.isArray(observabilityQueue)) observabilityQueue = [];

  const observabilityState = {
    version: OBSERVABILITY_VERSION,
    environment: observabilityEnvironment(),
    queued: observabilityQueue.length,
    sent: 0,
    dropped: 0,
    lastSentAt: null,
    lastError: null,
    sqlReady: null
  };

  function observabilityPublishState(){
    observabilityState.queued = observabilityQueue.length;
    window.__NEXLAB_OBSERVABILITY__ = Object.freeze({ ...observabilityState });
    try {
      sessionStorage.setItem(
        OBSERVABILITY_QUEUE_KEY,
        JSON.stringify(observabilityQueue.slice(-OBSERVABILITY_MAX_QUEUE))
      );
    } catch {}
    emit('nexlab:observability-status', { ...observabilityState });
  }

  function observabilitySanitize(value, maxLength = 1000){
    let text = String(value || '');
    text = text
      .replace(/eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}/g, '[token]')
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[email]')
      .replace(/([?&](?:access_token|refresh_token|token|apikey|key)=)[^&\s]+/gi, '$1[redacted]')
      .replace(/((?:access_token|refresh_token|token|apikey|api_key|authorization|password|secret)[=:]\s*)[^&\s,;]+/gi, '$1[redacted]')
      .replace(/\bBearer\s+[A-Za-z0-9._-]+/gi, 'Bearer [redacted]');
    return text.slice(0, maxLength);
  }

  function observabilityEnvironment(){
    const explicit = String(
      globalThis.__NEXLAB_ENVIRONMENT__ ||
      globalThis.__NEXLAB_CONFIG__?.environment ||
      ''
    ).trim().toLowerCase();

    if (['production','prod','producao'].includes(explicit)) return 'production';
    if (['homologacao','homologation','staging','hml'].includes(explicit)) return 'homologacao';
    if (['development','dev','local'].includes(explicit)) return 'development';
    if (['test','tests','testing'].includes(explicit)) return 'test';

    try {
      if (location.protocol === 'file:') return 'development';
      const address = `${location.hostname}${location.pathname}`.toLowerCase();
      if (/^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:|$)/.test(location.host)) {
        return 'development';
      }
      if (/(^|[\W_-])(homolog|homologacao|staging|hml)([\W_-]|$)/.test(address)) {
        return 'homologacao';
      }
      if (/(^|[\W_-])(test|tests|testing)([\W_-]|$)/.test(address)) {
        return 'test';
      }
    } catch {}

    return 'production';
  }

  const OBSERVABILITY_METADATA_FIELDS = Object.freeze({
    filename: 'string',
    line: 'number',
    column: 'number',
    component: 'string',
    failures: 'string-array',
    status: 'number',
    method: 'string',
    path: 'string',
    lcpMs: 'number',
    navigationMs: 'number',
    domContentLoadedMs: 'number',
    longTasks: 'number',
    longestTaskMs: 'number',
    transferBytes: 'number'
  });

  function observabilitySanitizeMetadata(value){
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    const result = {};

    for (const [key, type] of Object.entries(OBSERVABILITY_METADATA_FIELDS)) {
      const item = value[key];
      if (item === undefined || item === null) continue;

      if (type === 'string' && typeof item === 'string') {
        result[key] = observabilitySanitize(item, 300);
        continue;
      }

      if (type === 'number' && Number.isFinite(Number(item))) {
        result[key] = Number(item);
        continue;
      }

      if (type === 'string-array' && Array.isArray(item)) {
        result[key] = item
          .filter((entry) => typeof entry === 'string')
          .slice(0, 12)
          .map((entry) => observabilitySanitize(entry, 120));
      }
    }

    return result;
  }

  function observabilityHash(value){
    const input = String(value || '');
    let hash = 2166136261;
    for (let index = 0; index < input.length; index += 1) {
      hash ^= input.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return `v267-${(hash >>> 0).toString(16)}`;
  }

  function observabilityFindToken(value, depth = 0){
    if (!value || depth > 6) return '';
    if (typeof value === 'object' && typeof value.access_token === 'string') {
      return value.access_token;
    }
    if (Array.isArray(value)) {
      for (const item of value) {
        const found = observabilityFindToken(item, depth + 1);
        if (found) return found;
      }
      return '';
    }
    if (typeof value === 'object') {
      for (const item of Object.values(value)) {
        const found = observabilityFindToken(item, depth + 1);
        if (found) return found;
      }
    }
    return '';
  }

  function observabilityAccessToken(){
    try {
      const url = String(globalThis.__NEXLAB_CONFIG__?.supabaseUrl || '');
      if (!url) return '';
      const projectRef = new URL(url).hostname.split('.')[0];
      const raw = localStorage.getItem(`sb-${projectRef}-auth-token`);
      if (!raw) return '';
      return observabilityFindToken(JSON.parse(raw));
    } catch {
      return '';
    }
  }

  function observabilityDedupAllowed(fingerprint){
    const dedup = observabilityReadJson(OBSERVABILITY_DEDUP_KEY, {});
    const last = Number(dedup[fingerprint] || 0);
    const now = Date.now();
    if (now - last < OBSERVABILITY_DEDUP_MS) return false;

    dedup[fingerprint] = now;
    const entries = Object.entries(dedup)
      .filter(([, timestamp]) => now - Number(timestamp) < 24 * 60 * 60 * 1000)
      .slice(-80);

    try {
      sessionStorage.setItem(
        OBSERVABILITY_DEDUP_KEY,
        JSON.stringify(Object.fromEntries(entries))
      );
    } catch {}
    return true;
  }

  function observabilityQueueEvent(input){
    try {
      const message = observabilitySanitize(input?.message || 'Erro técnico sem mensagem.', 1000);
      const source = observabilitySanitize(input?.source || 'client', 80);
      const moduleName = observabilitySanitize(
        input?.module || document.body?.dataset?.nexlabPage || '',
        120
      );
      const fingerprint = observabilityHash(
        input?.fingerprint ||
        `${source}|${moduleName}|${message.slice(0, 300)}`
      );

      if (!observabilityDedupAllowed(fingerprint)) {
        observabilityState.dropped += 1;
        observabilityPublishState();
        return;
      }

      const metadata = observabilitySanitizeMetadata(input?.metadata);
      const environment = observabilityEnvironment();
      observabilityState.environment = environment;

      observabilityQueue.push({
        p_app_version: OBSERVABILITY_VERSION,
        p_environment: environment,
        p_source: source,
        p_severity: ['critical','error','warning','info'].includes(input?.severity)
          ? input.severity
          : 'error',
        p_message: message,
        p_stack: observabilitySanitize(input?.stack || '', 5000) || null,
        p_module: moduleName || null,
        p_page: observabilitySanitize(
          input?.page || document.body?.dataset?.nexlabPage || '',
          120
        ) || null,
        p_url_path: observabilitySanitize(location.pathname, 500),
        p_user_agent: observabilitySanitize(navigator.userAgent, 500),
        p_metadata: metadata,
        p_fingerprint: fingerprint
      });

      if (observabilityQueue.length > OBSERVABILITY_MAX_QUEUE) {
        observabilityQueue.splice(
          0,
          observabilityQueue.length - OBSERVABILITY_MAX_QUEUE
        );
        observabilityState.dropped += 1;
      }

      observabilityPublishState();
      window.setTimeout(observabilityFlush, 350);
    } catch {}
  }

  async function observabilityFlush(){
    if (
      observabilityFlushRunning ||
      !navigator.onLine ||
      !observabilityQueue.length ||
      Date.now() < observabilityRetryAfter
    ) return;

    const config = globalThis.__NEXLAB_CONFIG__ || {};
    const token = observabilityAccessToken();
    if (!config.supabaseUrl || !config.supabaseAnonKey || !token) {
      observabilityPublishState();
      return;
    }

    observabilityFlushRunning = true;

    try {
      let sentThisRun = 0;
      while (observabilityQueue.length && sentThisRun < 5) {
        const payload = observabilityQueue[0];
        const response = await nativeFetch(
          `${String(config.supabaseUrl).replace(/\/+$/, '')}/rest/v1/rpc/${OBSERVABILITY_RPC}`,
          {
            method: 'POST',
            headers: {
              apikey: config.supabaseAnonKey,
              Authorization: `Bearer ${token}`,
              'Content-Type': 'application/json'
            },
            body: JSON.stringify(payload)
          }
        );

        if (response.ok) {
          observabilityQueue.shift();
          observabilityState.sent += 1;
          observabilityState.lastSentAt = new Date().toISOString();
          observabilityState.lastError = null;
          observabilityState.sqlReady = true;
          sentThisRun += 1;
          observabilityPublishState();
          continue;
        }

        const body = await response.text().catch(() => '');
        if (
          response.status === 404 ||
          /PGRST202|nexlab_record_client_error_v26_7/i.test(body)
        ) {
          observabilityState.sqlReady = false;
          observabilityState.lastError = 'Migration v26.7.4 não instalada.';
          observabilityRetryAfter = Date.now() + 10 * 60 * 1000;
        } else if (response.status === 401 || response.status === 403) {
          observabilityState.lastError = 'Sessão sem autorização para observabilidade.';
          observabilityRetryAfter = Date.now() + 2 * 60 * 1000;
        } else {
          observabilityState.lastError = `Falha HTTP ${response.status}.`;
          observabilityRetryAfter = Date.now() + 60 * 1000;
        }
        observabilityPublishState();
        break;
      }
    } catch (error) {
      observabilityState.lastError = observabilitySanitize(error?.message || error, 300);
      observabilityRetryAfter = Date.now() + 60 * 1000;
      observabilityPublishState();
    } finally {
      observabilityFlushRunning = false;
    }
  }

  window.addEventListener('error', (event) => {
    observabilityQueueEvent({
      source: 'window.error',
      severity: 'error',
      message: event.message || 'Erro JavaScript não tratado.',
      stack: event.error?.stack || '',
      metadata: {
        filename: observabilitySanitize(event.filename || '', 300),
        line: Number(event.lineno || 0),
        column: Number(event.colno || 0)
      }
    });
  }, true);

  window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    observabilityQueueEvent({
      source: 'unhandledrejection',
      severity: 'error',
      message: reason?.message || String(reason || 'Promise rejeitada sem tratamento.'),
      stack: reason?.stack || ''
    });
  });

  window.addEventListener('nexlab:module-render-error', (event) => {
    observabilityQueueEvent({
      source: 'module-render',
      severity: 'critical',
      message: event.detail?.message || 'Falha protegida de renderização.',
      stack: event.detail?.stack || '',
      module: event.detail?.module || document.body?.dataset?.nexlabPage || '',
      metadata: {
        component: observabilitySanitize(event.detail?.component || '', 160)
      }
    });
  });

  window.addEventListener('nexlab:module-partial-error', (event) => {
    observabilityQueueEvent({
      source: 'partial-load',
      severity: 'warning',
      message: `Carregamento parcial: ${(event.detail?.failures || []).join(', ') || 'consulta não identificada'}.`,
      module: event.detail?.module || '',
      metadata: {
        failures: Array.isArray(event.detail?.failures)
          ? event.detail.failures.slice(0, 12)
          : []
      }
    });
  });

  window.addEventListener('nexlab:performance-metrics', (event) => {
    const metrics = event.detail || {};
    const degraded =
      Number(metrics.lcpMs || 0) > 4000 ||
      Number(metrics.navigationMs || 0) > 6000 ||
      Number(metrics.longestTaskMs || 0) > 1000 ||
      Number(metrics.longTasks || 0) > 12;

    if (!degraded) return;

    observabilityQueueEvent({
      source: 'performance',
      severity: 'warning',
      message: 'Degradação de desempenho detectada no cliente.',
      metadata: {
        lcpMs: Number(metrics.lcpMs || 0),
        navigationMs: Number(metrics.navigationMs || 0),
        domContentLoadedMs: Number(metrics.domContentLoadedMs || 0),
        longTasks: Number(metrics.longTasks || 0),
        longestTaskMs: Number(metrics.longestTaskMs || 0),
        transferBytes: Number(metrics.mainBundleTransferBytes || 0)
      }
    });
  });

  window.addEventListener('online', observabilityFlush);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') observabilityFlush();
  });

  window.setInterval(observabilityFlush, 60 * 1000);
  observabilityPublishState();
  window.setTimeout(observabilityFlush, 1800);

  const performanceState = {
    version: '26.15.0',
    longTasks: 0,
    longestTaskMs: 0,
    lcpMs: 0,
    navigationMs: 0,
    domContentLoadedMs: 0,
    mainBundleTransferBytes: 0,
    capturedAt: null
  };

  function savePerformanceState(){
    performanceState.capturedAt = new Date().toISOString();
    window.__NEXLAB_PERFORMANCE__ = Object.freeze({ ...performanceState });
    try {
      sessionStorage.setItem('nexlab:performance:v26.7.5', JSON.stringify(performanceState));
    } catch {}
    emit('nexlab:performance-metrics', { ...performanceState });
  }

  function collectStaticPerformanceMetrics(){
    try {
      const navigation = performance.getEntriesByType('navigation')[0];
      if (navigation) {
        performanceState.navigationMs = Math.round(navigation.duration || 0);
        performanceState.domContentLoadedMs = Math.round(navigation.domContentLoadedEventEnd || 0);
      }

      const mainResource = performance.getEntriesByType('resource').find((entry) =>
        /assets\/index-[^/]+\.js/.test(entry.name)
      );
      if (mainResource) {
        performanceState.mainBundleTransferBytes = Math.round(
          mainResource.transferSize || mainResource.encodedBodySize || 0
        );
      }
      savePerformanceState();
    } catch {}
  }

  try {
    if ('PerformanceObserver' in window) {
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            performanceState.longTasks += 1;
            performanceState.longestTaskMs = Math.max(
              performanceState.longestTaskMs,
              Math.round(entry.duration || 0)
            );
          }
          savePerformanceState();
        }).observe({ type: 'longtask', buffered: true });
      } catch {}

      try {
        new PerformanceObserver((list) => {
          const entries = list.getEntries();
          const latest = entries[entries.length - 1];
          if (latest) {
            performanceState.lcpMs = Math.round(latest.startTime || 0);
            savePerformanceState();
          }
        }).observe({ type: 'largest-contentful-paint', buffered: true });
      } catch {}
    }
  } catch {}

  if (document.readyState === 'complete') {
    window.setTimeout(collectStaticPerformanceMetrics, 0);
  } else {
    window.addEventListener('load', () => window.setTimeout(collectStaticPerformanceMetrics, 0), { once: true });
  }

  window.addEventListener('offline', function(){
    emit('nexlab:connection-error', {
      title: 'Você está sem internet',
      message: 'O NEXLAB entrou em modo offline. Dados já carregados podem continuar visíveis; salvamentos e sincronizações precisam de conexão.',
      detail: 'Evento offline detectado pelo navegador.'
    });
  });
})();