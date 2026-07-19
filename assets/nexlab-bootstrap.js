(function(){
  if (window.__NEXLAB_BOOTSTRAP_V26_7__) return;
  window.__NEXLAB_BOOTSTRAP_V26_7__ = true;

  const BUILD_IDENTITY = window.__NEXLAB_BUILD_IDENTITY__ || Object.freeze({version:'0.26.12',release:'Beta',revision:'beta-0-26-12-bookings-render-loop-recovery',assetRevision:'app-beta-0-26-12-bookings-render-loop-recovery',cacheName:'nexlab-beta-0-26-12-bookings-render-loop-recovery',generatedAt:'2026-07-19T19:39:27Z'});
  const APP_VERSION = BUILD_IDENTITY.version;
  const APP_RELEASE = BUILD_IDENTITY.release;
  const APP_REVISION = BUILD_IDENTITY.revision;
  window.__NEXLAB_RELEASE__ = BUILD_IDENTITY;

  const nativeFetch = window.fetch ? window.fetch.bind(window) : null;
  const nativeAlert = window.alert ? window.alert.bind(window) : function(){};
  const SUPABASE_RE = /https:\/\/[a-z0-9.-]+\.supabase\.co/i;
  const MUTATING_METHOD_RE = /^(POST|PUT|PATCH|DELETE)$/i;
  const READ_METHOD_RE = /^(GET|HEAD|OPTIONS)$/i;
  const READ_ONLY_RPC_NAME_RE = /^(?:get_|nexlab_(?:get_|list_|check_|resolve_|prepare_|export_|notification_summary_))/i;
  const BACKGROUND_RPC_NAME_RE = /^(?:nexlab_record_client_error_v26_7(?:_4)?|record_security_audit)$/i;

  function rpcNameFromTarget(target){
    try {
      const match = new URL(target, location.href).pathname.match(/\/rest\/v1\/rpc\/([^/]+)$/i);
      return match ? decodeURIComponent(match[1]) : '';
    } catch {
      const match = String(target || '').match(/\/rest\/v1\/rpc\/([^/?#]+)/i);
      return match ? decodeURIComponent(match[1]) : '';
    }
  }

  function classifySupabaseRequest(target, method){
    const normalizedMethod = String(method || 'GET').toUpperCase();
    const rpcName = rpcNameFromTarget(target);
    let pathname = '';
    try { pathname = new URL(target, location.href).pathname; } catch { pathname = String(target || ''); }
    const authRequest = /\/auth\/v1\//i.test(pathname);
    const readOnly = !authRequest && (READ_METHOD_RE.test(normalizedMethod) || Boolean(rpcName && READ_ONLY_RPC_NAME_RE.test(rpcName)));
    const background = authRequest || Boolean(rpcName && BACKGROUND_RPC_NAME_RE.test(rpcName));
    return Object.freeze({ rpcName, authRequest, readOnly, background, mutating: MUTATING_METHOD_RE.test(normalizedMethod) && !readOnly && !background });
  }

  window.__NEXLAB_REQUEST_CLASSIFIER__ = Object.freeze({
    classify: (target, method = 'GET') => classifySupabaseRequest(target, method),
    isReadOnlyRpc: (name) => READ_ONLY_RPC_NAME_RE.test(String(name || ''))
  });
  let readCacheGeneration = 0;

  // R55.5.1: preserva o bloqueio imediato de mutações para impedir cliques duplos antes do React atualizar a interface.
  const mutationLocks = new Map();
  window.nexlabAcquireMutation = function(key, timeoutMs = 60000){
    const normalized = String(key || 'mutation');
    const now = Date.now();
    const lockedAt = Number(mutationLocks.get(normalized) || 0);
    if (lockedAt && now - lockedAt < Math.max(5000, Number(timeoutMs) || 60000)) return false;
    mutationLocks.set(normalized, now);
    return true;
  };
  window.nexlabReleaseMutation = function(key){
    mutationLocks.delete(String(key || 'mutation'));
  };
  window.nexlabMutationConfirmed = function(data, expectedId){
    if (data === true) return true;
    if (typeof data === 'number') return Number.isFinite(data) && data > 0;
    if (typeof data === 'string') return data.trim() !== '' && !/^(?:false|0|null|undefined)$/i.test(data.trim());
    if (Array.isArray(data)) return data.length > 0;
    if (!data || typeof data !== 'object') return false;
    const negativeFlags = ['ok','success','deleted','removed','applied'];
    if (negativeFlags.some((field) => data[field] === false)) return false;
    const positiveFlags = ['ok','success','deleted','removed','updated','created','archived','cancelled','canceled','applied','linked','unlinked','responsibility_transferred'];
    if (positiveFlags.some((field) => data[field] === true)) return true;
    const expected = expectedId == null ? '' : String(expectedId);
    const candidates = [
      data.id, data.user_id, data.entity_id, data.record_id,
      data.record?.id, data.item?.id, data.asset?.id, data.team?.id,
      data.member?.user_id, data.link?.entity_id, data.booking?.id
    ].filter((value) => value !== undefined && value !== null).map(String);
    if (expected && candidates.includes(expected)) return true;
    return !expected && candidates.length > 0;
  };

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

  function signalFrom(input, init){
    try {
      if (init && init.signal) return init.signal;
      if (typeof Request !== 'undefined' && input instanceof Request && input.signal) return input.signal;
    } catch {}
    return null;
  }

  function isExpectedAbort(error, signal){
    if (signal?.aborted) return true;
    const name = String(error?.name || '');
    const message = String(error?.message || '');
    return name === 'AbortError' || /(?:signal is aborted|aborted without reason|operation was aborted|the operation was aborted)/i.test(message);
  }

  function emit(name, detail){
    try { window.dispatchEvent(new CustomEvent(name, { detail: detail || {} })); } catch {}
  }

  function invalidateReadCache(reason = 'manual', detail = {}){
    readCacheGeneration += 1;
    emit('nexlab:read-cache-invalidated', {
      reason,
      generation: readCacheGeneration,
      cacheEnabled: false,
      ...detail
    });
  }

  window.__NEXLAB_NATIVE_WEBSOCKET__ = globalThis.WebSocket;

  window.__NEXLAB_READ_CACHE__ = Object.freeze({
    enabled: false,
    invalidate: (reason = 'test-or-manual') => invalidateReadCache(reason),
    snapshot: () => Object.freeze({
      enabled: false,
      entries: 0,
      pending: 0,
      generation: readCacheGeneration,
      ttl: 0
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
    const requestClass = isSupabase ? classifySupabaseRequest(target, method) : { readOnly:false, background:false, mutating:false, rpcName:"" };
    const isMutatingSupabase = isSupabase && requestClass.mutating;
    const isReadOnlySupabase = isSupabase && requestClass.readOnly;
    const startedAt = Date.now();
    const requestId = `${startedAt}-${Math.random().toString(36).slice(2,9)}`;

    if (isReadOnlySupabase) emit('nexlab:read-start', { method, url: target, rpc: requestClass.rpcName, requestId, startedAt });

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
      const requestSignal = signalFrom(input, init);
      if (isExpectedAbort(error, requestSignal)) {
        emit('nexlab:request-aborted', { method, url: target });
        throw error;
      }
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
      const elapsed = Date.now() - startedAt;
      if (isReadOnlySupabase) emit('nexlab:read-end', { method, url: target, rpc: requestClass.rpcName, requestId, elapsed });
      if (isMutatingSupabase) {
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
      // Estável: o wrapper observa erros e mutações, sem cachear ou compartilhar
      // respostas REST. Deduplicação pertence aos loaders canônicos por módulo.
      return fetchAndMonitor(input, init, target, method, isSupabase);
    };
  }



  const OBSERVABILITY_VERSION = APP_VERSION;
  const OBSERVABILITY_QUEUE_KEY = 'nexlab:observability:queue:v0.26.12';
  const OBSERVABILITY_DEDUP_KEY = 'nexlab:observability:dedup:v0.26.12';
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
    wrapper: 'string',
    causeName: 'string',
    failures: 'string-array',
    status: 'number',
    method: 'string',
    path: 'string',
    lcpMs: 'number',
    navigationMs: 'number',
    domContentLoadedMs: 'number',
    longTasks: 'number',
    longestTaskMs: 'number',
    transferBytes: 'number',
    initialTransferBytes: 'number',
    lazyFeatureTransferBytes: 'number',
    loadedChunkCount: 'number',
    occurrences: 'number',
    chunk: 'string'
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
    const cause = event.error?.cause || event.error;
    observabilityQueueEvent({
      source: 'window.error',
      severity: 'error',
      message: cause?.message || event.message || 'Erro JavaScript não tratado.',
      stack: cause?.stack || event.error?.stack || '',
      metadata: {
        filename: observabilitySanitize(event.filename || '', 300),
        line: Number(event.lineno || 0),
        column: Number(event.colno || 0),
        wrapper: observabilitySanitize(event.message || '', 300),
        causeName: observabilitySanitize(cause?.name || '', 120)
      }
    });
  }, true);

  window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    if (isExpectedAbort(reason)) {
      event.preventDefault();
      return;
    }
    observabilityQueueEvent({
      source: 'unhandledrejection',
      severity: 'error',
      message: reason?.message || String(reason || 'Promise rejeitada sem tratamento.'),
      stack: reason?.stack || ''
    });
  });

  const reactRecoverableWindow = new Map();
  window.addEventListener('nexlab:react-recoverable-error', (event) => {
    const detail = event.detail || {};
    const moduleName = detail.module || document.body?.dataset?.nexlabPage || '';
    const combined = `${detail.message || ''} ${detail.stack || ''}`;
    const fingerprint = `${moduleName}|${detail.message || ''}`.slice(0, 600);
    const now = Date.now();
    const recent = (reactRecoverableWindow.get(fingerprint) || []).filter((stamp) => now - stamp < 30000);
    recent.push(now);
    reactRecoverableWindow.set(fingerprint, recent);
    const occurrences = recent.length;
    const serious = /removeChild|Maximum call stack|recursion|Maximum update depth|Minified React error #185/i.test(combined);
    const chunkMatch = combined.match(/assets\/(nexlab-[^\s):]+\.js|index-[^\s):]+\.js)/i);
    observabilityQueueEvent({
      source: 'react-recoverable',
      severity: serious || occurrences >= 3 ? 'critical' : 'warning',
      message: detail.message || 'O React recuperou uma falha de renderização concorrente.',
      stack: detail.stack || '',
      module: moduleName,
      metadata: {
        wrapper: observabilitySanitize(detail.wrapper || '', 300),
        causeName: observabilitySanitize(detail.causeName || '', 120),
        occurrences,
        chunk: observabilitySanitize(chunkMatch?.[1] || '', 180)
      }
    });
  });

  window.addEventListener('nexlab:realtime-cleanup-error', (event) => {
    observabilityQueueEvent({
      source: 'realtime-cleanup',
      severity: 'warning',
      message: event.detail?.message || 'Falha protegida ao encerrar canal Realtime.',
      stack: event.detail?.stack || '',
      metadata: {
        component: observabilitySanitize(event.detail?.context || '', 160)
      }
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
        transferBytes: Number(metrics.initialTransferBytes || metrics.mainBundleTransferBytes || 0),
        initialTransferBytes: Number(metrics.initialTransferBytes || 0),
        lazyFeatureTransferBytes: Number(metrics.lazyFeatureTransferBytes || 0),
        loadedChunkCount: Number(metrics.loadedChunkCount || 0)
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
    version: APP_VERSION,
    longTasks: 0,
    longestTaskMs: 0,
    lcpMs: 0,
    navigationMs: 0,
    domContentLoadedMs: 0,
    mainBundleTransferBytes: 0,
    initialTransferBytes: 0,
    lazyFeatureTransferBytes: 0,
    loadedChunkCount: 0,
    capturedAt: null
  };

  function savePerformanceState(){
    performanceState.capturedAt = new Date().toISOString();
    window.__NEXLAB_PERFORMANCE__ = Object.freeze({ ...performanceState });
    try {
      sessionStorage.setItem('nexlab:performance:v0.26.12', JSON.stringify(performanceState));
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

      const resources = performance.getEntriesByType('resource');
      const initialPattern = /assets\/(?:index-beta-0-26-12|nexlab-vendor-beta-0-26-12|nexlab-app-shared-beta-0-26-12|nexlab-bootstrap|nexlab-realtime-core-beta-0-26-12|nexlab-realtime-hub-beta-0-26-12|nexlab-update-manager|nexlab-visual|nexlab-vapid-rotation)\.js/i;
      const featurePattern = /assets\/nexlab-feature-modules-beta-0-26-12\.js/i;
      const initial = resources.filter((entry) => initialPattern.test(entry.name));
      const feature = resources.filter((entry) => featurePattern.test(entry.name));
      performanceState.initialTransferBytes = Math.round(initial.reduce((sum, entry) => sum + Number(entry.transferSize || entry.encodedBodySize || 0), 0));
      performanceState.mainBundleTransferBytes = performanceState.initialTransferBytes;
      performanceState.lazyFeatureTransferBytes = Math.round(feature.reduce((sum, entry) => sum + Number(entry.transferSize || entry.encodedBodySize || 0), 0));
      performanceState.loadedChunkCount = initial.length + feature.length;
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


      try {
        new PerformanceObserver((list) => {
          if (list.getEntries().some((entry) => /assets\/nexlab-feature-modules-beta-0-26-12\.js/i.test(entry.name))) {
            collectStaticPerformanceMetrics();
          }
        }).observe({ type: 'resource', buffered: true });
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
