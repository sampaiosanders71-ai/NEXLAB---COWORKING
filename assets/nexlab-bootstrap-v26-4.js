(function(){
  if (window.__NEXLAB_BOOTSTRAP_V26_4__) return;
  window.__NEXLAB_BOOTSTRAP_V26_4__ = true;

  const nativeFetch = window.fetch ? window.fetch.bind(window) : null;
  const nativeAlert = window.alert ? window.alert.bind(window) : function(){};
  const SUPABASE_RE = /https:\/\/[a-z0-9.-]+\.supabase\.co/i;
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
      readCache.clear();
      emit('nexlab:action-start', { method, url: target, startedAt });
    }

    try {
      const response = await nativeFetch(input, init);
      if (isSupabase) {
        if (response.status === 0 || response.status === 502 || response.status === 503 || response.status === 504 || response.status >= 500) {
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

  window.addEventListener('nexlab:retry-module', () => readCache.clear());

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

      const request = fetchAndMonitor(input, init, target, method, isSupabase)
        .then((response) => {
          if (response.ok) {
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


  const performanceState = {
    version: '26.4',
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
      sessionStorage.setItem('nexlab:performance:v26.4', JSON.stringify(performanceState));
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