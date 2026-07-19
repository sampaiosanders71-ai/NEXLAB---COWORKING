(function(){
  'use strict';

  const BUILD_IDENTITY = window.__NEXLAB_BUILD_IDENTITY__ || Object.freeze({version:'0.26.12',release:'Beta',revision:'beta-0-26-12-bookings-render-loop-recovery',generatedAt:'2026-07-19T22:17:34Z',cacheName:'nexlab-beta-0-26-12-bookings-render-loop-recovery'});
  const CURRENT_VERSION = BUILD_IDENTITY.version;
  const CURRENT_RELEASE = BUILD_IDENTITY.release;
  const CURRENT_REVISION = BUILD_IDENTITY.revision;
  const CURRENT_GENERATED_AT = BUILD_IDENTITY.generatedAt;
  const RELEASE_URL = './release.json';
  const WORKER_URL = './nexlab-sw.js';
  const CHECK_INTERVAL_MS = 15 * 60 * 1000;
  const MESSAGE_TIMEOUT_MS = 3000;
  const INSTALL_TIMEOUT_MS = 18000;

  if (window.__NEXLAB_UPDATE_MANAGER__?.revision === CURRENT_REVISION) return;

  let intervalId = null;
  let started = false;
  let applying = false;
  let reloaded = false;
  let banner = null;
  let bannerNowButton = null;
  let bannerText = null;
  let observedRegistration = null;

  const state = {
    version: CURRENT_VERSION,
    release: CURRENT_RELEASE,
    revision: CURRENT_REVISION,
    generatedAt: CURRENT_GENERATED_AT,
    status: 'idle',
    updateAvailable: false,
    remoteVersion: null,
    remoteRelease: null,
    remoteRevision: null,
    remoteGeneratedAt: null,
    workerVersion: null,
    workerRelease: null,
    workerRevision: null,
    activeRevision: null,
    checkedAt: null,
    error: null
  };

  function numericParts(value){
    return String(value || '')
      .split(/[^0-9]+/)
      .filter(Boolean)
      .slice(0, 6)
      .map((part) => Number(part) || 0);
  }

  function compareNumbers(left, right){
    const a = numericParts(left);
    const b = numericParts(right);
    const length = Math.max(a.length, b.length, 1);
    for (let index = 0; index < length; index += 1) {
      const difference = (a[index] || 0) - (b[index] || 0);
      if (difference !== 0) return difference > 0 ? 1 : -1;
    }
    return 0;
  }

  function identityFrom(value){
    if (!value || typeof value !== 'object') return null;
    return {
      version: String(value.version || '').trim() || null,
      release: String(value.release || '').trim() || null,
      revision: String(value.revision || '').trim() || null,
      generatedAt: String(value.generatedAt || value.generated_at || '').trim() || null,
      cache: String(value.cache || '').trim() || null
    };
  }

  const CURRENT_IDENTITY = Object.freeze({
    version: CURRENT_VERSION,
    release: CURRENT_RELEASE,
    revision: CURRENT_REVISION,
    generatedAt: CURRENT_GENERATED_AT
  });

  function compareIdentity(leftValue, rightValue = CURRENT_IDENTITY){
    const left = identityFrom(leftValue);
    const right = identityFrom(rightValue);
    if (!left || !right) return 0;

    const versionComparison = compareNumbers(left.version, right.version);
    if (versionComparison !== 0) return versionComparison;

    const releaseComparison = compareNumbers(left.release, right.release);
    if (releaseComparison !== 0) return releaseComparison;

    // A mesma versão, release e revisão representa a mesma compilação.
    // generatedAt é apenas metadado e nunca pode provocar recarga nesse caso.
    if (left.revision && right.revision && left.revision === right.revision) return 0;

    // Revisões diferentes na mesma versão são comparadas primeiro por seu número.
    if (left.revision && right.revision) {
      const revisionComparison = compareNumbers(left.revision, right.revision);
      if (revisionComparison !== 0) return revisionComparison;
    }

    // A data só desempata revisões ausentes ou realmente diferentes.
    const leftTime = Date.parse(left.generatedAt || '');
    const rightTime = Date.parse(right.generatedAt || '');
    if (Number.isFinite(leftTime) && Number.isFinite(rightTime) && leftTime !== rightTime) {
      return leftTime > rightTime ? 1 : -1;
    }
    return 0;
  }

  function isNewer(identity){
    return compareIdentity(identity, CURRENT_IDENTITY) > 0;
  }

  function dispatch(name, detail){
    try { window.dispatchEvent(new CustomEvent(name, { detail })); } catch {}
  }

  function ensureStyle(){
    if (document.getElementById('nexlab-update-manager-style')) return;
    const style = document.createElement('style');
    style.id = 'nexlab-update-manager-style';
    style.textContent = [
      '.nexlab-update-banner{position:fixed;right:18px;bottom:18px;z-index:2147483000;max-width:410px;padding:16px;border:1px solid #b9c8de;border-radius:16px;background:#fff;color:#10233f;box-shadow:0 18px 48px rgba(15,35,65,.24);font:14px/1.45 Arial,sans-serif}',
      '.nexlab-update-banner strong{display:block;margin-bottom:5px;font-size:15px}',
      '.nexlab-update-banner p{margin:0 0 12px}',
      '.nexlab-update-actions{display:flex;gap:8px;justify-content:flex-end}',
      '.nexlab-update-actions button{border-radius:10px;border:1px solid #b9c8de;padding:8px 12px;font-weight:700;cursor:pointer}',
      '.nexlab-update-actions button:disabled{cursor:wait;opacity:.65}',
      '.nexlab-update-now{background:#0b2a63;color:#fff;border-color:#0b2a63!important}',
      '.nexlab-update-later{background:#fff;color:#263b58}',
      '@media(max-width:520px){.nexlab-update-banner{left:12px;right:12px;bottom:12px;max-width:none}}'
    ].join('');
    document.head.appendChild(style);
  }

  function hideBanner(){
    if (!banner) return;
    banner.remove();
    banner = null;
    bannerNowButton = null;
    bannerText = null;
  }

  function deferUpdate(){
    hideBanner();
    state.status = 'deferred';
    state.error = null;
    dispatch('nexlab:update-deferred', { ...state });
  }

  function identityLabel(identity){
    const normalized = identityFrom(identity) || {};
    if (String(normalized.release || '').toLowerCase() === 'beta' && normalized.version) {
      return `Beta ${normalized.version}`;
    }
    return [normalized.version, normalized.release].filter(Boolean).join(' — ');
  }

  function setBannerProgress(message){
    if (bannerText) bannerText.textContent = message;
    if (bannerNowButton) {
      bannerNowButton.disabled = true;
      bannerNowButton.textContent = 'Aplicando...';
    }
  }

  function restoreBannerAction(message){
    if (bannerText && message) bannerText.textContent = message;
    if (bannerNowButton) {
      bannerNowButton.disabled = false;
      bannerNowButton.textContent = 'Tentar novamente';
    }
  }

  function showBanner(identity){
    if (!document.body) return;
    ensureStyle();
    hideBanner();
    const container = document.createElement('section');
    container.className = 'nexlab-update-banner';
    container.setAttribute('role', 'status');
    container.setAttribute('aria-live', 'polite');
    const title = document.createElement('strong');
    title.textContent = 'Atualização do NEXLAB disponível';
    const text = document.createElement('p');
    const label = identityLabel(identity);
    text.textContent = label
      ? `A versão ${label} está pronta. A página só será trocada depois da sua confirmação.`
      : 'Uma nova revisão está pronta. A página só será trocada depois da sua confirmação.';
    const actions = document.createElement('div');
    actions.className = 'nexlab-update-actions';
    const later = document.createElement('button');
    later.type = 'button';
    later.className = 'nexlab-update-later';
    later.textContent = 'Depois';
    later.addEventListener('click', deferUpdate);
    const now = document.createElement('button');
    now.type = 'button';
    now.className = 'nexlab-update-now';
    now.textContent = 'Atualizar agora';
    now.addEventListener('click', () => applyUpdate());
    actions.append(later, now);
    container.append(title, text, actions);
    document.body.appendChild(container);
    banner = container;
    bannerNowButton = now;
    bannerText = text;
  }

  async function withTimeout(promise, milliseconds, message){
    let timer;
    try {
      return await Promise.race([
        promise,
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error(message)), milliseconds);
        })
      ]);
    } finally {
      clearTimeout(timer);
    }
  }

  async function getRegistration(){
    if (!('serviceWorker' in navigator) || location.protocol === 'file:') return null;
    let registration = await navigator.serviceWorker.getRegistration('./');
    if (!registration) {
      registration = await navigator.serviceWorker.register(WORKER_URL, {
        scope: './',
        updateViaCache: 'none'
      });
    }
    observeRegistration(registration);
    return registration;
  }

  async function workerIdentity(worker){
    if (!worker || typeof MessageChannel === 'undefined') return null;
    return withTimeout(new Promise((resolve) => {
      const channel = new MessageChannel();
      channel.port1.onmessage = (event) => resolve(identityFrom(event.data));
      worker.postMessage({ type: 'NEXLAB_GET_VERSION' }, [channel.port2]);
    }), MESSAGE_TIMEOUT_MS, 'O worker não respondeu com sua identificação.').catch(() => null);
  }

  async function fetchRelease(){
    const url = new URL(RELEASE_URL, location.href);
    url.searchParams.set('nexlabUpdateCheck', String(Date.now()));
    const response = await fetch(url.toString(), {
      method: 'GET',
      cache: 'no-store',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' }
    });
    if (!response.ok) throw new Error(`Falha ao consultar release.json (${response.status}).`);
    const data = await response.json();
    return identityFrom(data) || {};
  }

  function publishAvailable(identity){
    const normalized = identityFrom(identity) || {};
    state.remoteVersion = normalized.version || state.remoteVersion;
    state.remoteRelease = normalized.release || state.remoteRelease;
    state.remoteRevision = normalized.revision || state.remoteRevision;
    state.remoteGeneratedAt = normalized.generatedAt || state.remoteGeneratedAt;
    state.updateAvailable = true;
    state.status = 'available';
    showBanner(normalized);
    dispatch('nexlab:update-available', { ...state });
  }

  function observeRegistration(registration){
    if (!registration || observedRegistration === registration) return;
    observedRegistration = registration;
    registration.addEventListener('updatefound', () => {
      const installing = registration.installing;
      if (!installing) return;
      state.status = 'installing';
      dispatch('nexlab:update-state', { ...state });
      installing.addEventListener('statechange', async () => {
        if (installing.state === 'installed' && navigator.serviceWorker.controller) {
          const identity = await workerIdentity(registration.waiting || installing);
          if (isNewer(identity)) {
            state.workerVersion = identity?.version || null;
            state.workerRelease = identity?.release || null;
            state.workerRevision = identity?.revision || null;
            publishAvailable(identity);
          }
        }
      });
    });
  }

  async function reloadForIdentity(identity, reason){
    const normalized = identityFrom(identity);
    if (!normalized || !isNewer(normalized) || reloaded) return false;
    const now = Date.now();
    const reloadKey = normalized.revision || normalized.generatedAt || 'unknown';
    try {
      const previous = JSON.parse(sessionStorage.getItem('nexlab:update-reload-guard') || 'null');
      if (previous?.key === reloadKey && now - Number(previous.at || 0) < 10000) {
        state.status = 'error';
        state.error = 'Atualização interrompida para evitar recarregamento repetitivo.';
        dispatch('nexlab:update-reload-blocked', { ...state, reason, identity: normalized });
        return false;
      }
      sessionStorage.setItem('nexlab:update-reload-guard', JSON.stringify({ key: reloadKey, at: now }));
    } catch {}
    reloaded = true;
    state.status = 'reloading';
    state.activeRevision = normalized.revision || null;
    dispatch('nexlab:update-reloading', { ...state, reason });
    try {
      sessionStorage.setItem('nexlab:last-activated-revision', reloadKey);
    } catch {}
    window.setTimeout(() => location.reload(), 40);
    return true;
  }

  async function check(options = {}){
    const forceWorkerUpdate = options.forceWorkerUpdate !== false;
    state.status = 'checking';
    state.error = null;
    dispatch('nexlab:update-state', { ...state });
    try {
      const registration = await getRegistration();
      if (registration && forceWorkerUpdate) {
        try { await registration.update(); } catch {}
      }

      let releaseIdentity = null;
      try { releaseIdentity = await fetchRelease(); } catch (error) {
        if (!registration) throw error;
      }

      const activeIdentity = await workerIdentity(registration?.active || navigator.serviceWorker.controller);
      state.activeRevision = activeIdentity?.revision || null;

      const candidateWorker = registration?.waiting || registration?.installing || null;
      const candidateIdentity = await workerIdentity(candidateWorker);
      const waitingNewer = Boolean(registration?.waiting && isNewer(candidateIdentity));
      const installingNewer = Boolean(registration?.installing && isNewer(candidateIdentity));
      const activeNewer = isNewer(activeIdentity);
      const releaseNewer = isNewer(releaseIdentity);
      const availableIdentity = waitingNewer || installingNewer
        ? candidateIdentity
        : (activeNewer ? activeIdentity : (releaseNewer ? releaseIdentity : null));

      state.workerVersion = candidateIdentity?.version || null;
      state.workerRelease = candidateIdentity?.release || null;
      state.workerRevision = candidateIdentity?.revision || null;
      state.checkedAt = new Date().toISOString();
      state.updateAvailable = Boolean(availableIdentity);
      state.status = availableIdentity ? 'available' : 'current';

      if (availableIdentity) {
        publishAvailable(availableIdentity);
      } else {
        hideBanner();
        dispatch('nexlab:update-current', { ...state });
      }
      return { ok: true, ...state };
    } catch (error) {
      state.status = 'error';
      state.error = String(error?.message || error);
      state.checkedAt = new Date().toISOString();
      dispatch('nexlab:update-error', { ...state });
      return { ok: false, ...state };
    }
  }

  async function waitForWaitingWorker(registration, milliseconds = INSTALL_TIMEOUT_MS){
    if (registration?.waiting) return registration.waiting;
    return withTimeout(new Promise((resolve) => {
      let installing = registration?.installing || null;
      const inspect = () => {
        if (registration?.waiting) return resolve(registration.waiting);
        installing = registration?.installing || installing;
        if (!installing) return;
        if (installing.state === 'installed') return resolve(registration.waiting || installing);
        if (installing.state === 'redundant') return resolve(null);
      };
      const onUpdateFound = () => {
        installing = registration.installing;
        installing?.addEventListener('statechange', inspect);
        inspect();
      };
      registration?.addEventListener('updatefound', onUpdateFound, { once: true });
      installing?.addEventListener('statechange', inspect);
      inspect();
    }), milliseconds, 'A nova versão ainda não terminou de instalar.').catch(() => null);
  }

  async function requestActivation(worker){
    if (!worker) return false;
    return withTimeout(new Promise((resolve, reject) => {
      const channel = new MessageChannel();
      channel.port1.onmessage = (event) => {
        if (event.data?.ok) resolve(true);
        else reject(new Error(event.data?.error || 'O Service Worker recusou a ativação.'));
      };
      worker.postMessage({
        type: 'NEXLAB_SKIP_WAITING',
        expectedVersion: state.workerVersion || state.remoteVersion || null,
        expectedRevision: state.workerRevision || state.remoteRevision || null
      }, [channel.port2]);
    }), MESSAGE_TIMEOUT_MS, 'O Service Worker não confirmou a ativação.');
  }

  async function waitForControllerChange(expectedIdentity, milliseconds = 12000){
    const expected = identityFrom(expectedIdentity);
    return new Promise((resolve, reject) => {
      let settled = false;
      let timer = null;
      const cleanup = () => {
        navigator.serviceWorker.removeEventListener('controllerchange', onControllerChange);
        if (timer) window.clearTimeout(timer);
      };
      const finish = (value, error) => {
        if (settled) return;
        settled = true;
        cleanup();
        if (error) reject(error);
        else resolve(value);
      };
      const onControllerChange = async () => {
        const identity = await workerIdentity(navigator.serviceWorker.controller);
        if (!identity) return;
        if (expected?.revision && identity.revision !== expected.revision) return;
        if (!isNewer(identity)) return;
        finish(identity);
      };
      timer = window.setTimeout(async () => {
        const registration = await navigator.serviceWorker.getRegistration('./').catch(() => null);
        const identity = await workerIdentity(registration?.active || navigator.serviceWorker.controller);
        if (identity && isNewer(identity) && (!expected?.revision || identity.revision === expected.revision)) {
          finish(identity);
          return;
        }
        finish(null, new Error('A ativação terminou sem transferir o controle para a nova revisão.'));
      }, milliseconds);
      navigator.serviceWorker.addEventListener('controllerchange', onControllerChange);
    });
  }

  async function applyUpdate(){
    if (applying) return { ok: false, reason: 'already_applying' };
    applying = true;
    state.status = 'applying';
    state.error = null;
    setBannerProgress('Instalando e validando a nova revisão. Esta página será recarregada quando a ativação terminar.');
    dispatch('nexlab:update-state', { ...state });

    try {
      const registration = await getRegistration();
      if (!registration) throw new Error('Service Worker indisponível neste navegador.');

      if (!registration.waiting) {
        await registration.update();
      }

      const waitingWorker = registration.waiting || await waitForWaitingWorker(registration);
      const identity = await workerIdentity(waitingWorker);
      if (!waitingWorker || !isNewer(identity)) {
        const activeIdentity = await workerIdentity(registration.active || navigator.serviceWorker.controller);
        if (activeIdentity && isNewer(activeIdentity)) {
          const reloading = await reloadForIdentity(activeIdentity, 'manual-confirmation-active-worker');
          if (reloading) return { ok: true, action: 'reload-active', identity: activeIdentity };
        }
        throw new Error('A nova revisão foi anunciada, mas os arquivos ainda não chegaram completos ao servidor. Tente novamente em instantes.');
      }

      state.workerVersion = identity.version;
      state.workerRelease = identity.release;
      state.workerRevision = identity.revision;
      state.status = 'activating';
      setBannerProgress('Atualização validada. Ativando a nova revisão...');
      dispatch('nexlab:update-state', { ...state });

      const controllerChange = waitForControllerChange(identity);
      await requestActivation(waitingWorker);
      const activatedIdentity = await controllerChange;
      const reloading = await reloadForIdentity(activatedIdentity, 'manual-confirmation-controller-change');
      if (!reloading) throw new Error('A revisão foi ativada, mas a recarga segura não pôde ser iniciada.');
      return { ok: true, action: 'reload-confirmed', identity: activatedIdentity };
    } catch (error) {
      applying = false;
      state.status = 'error';
      state.error = String(error?.message || error);
      restoreBannerAction(state.error);
      dispatch('nexlab:update-error', { ...state });
      return { ok: false, error: state.error };
    }
  }

  function start(){
    if (started) return;
    started = true;
    if (!('serviceWorker' in navigator) || location.protocol === 'file:') {
      state.status = 'unsupported';
      return;
    }

    navigator.serviceWorker.addEventListener('controllerchange', async () => {
      const identity = await workerIdentity(navigator.serviceWorker.controller);
      state.activeRevision = identity?.revision || state.activeRevision;
      if (!applying && isNewer(identity)) {
        publishAvailable(identity);
      }
      dispatch('nexlab:update-controller-changed', { ...state, identity });
    });

    navigator.serviceWorker.addEventListener('message', (event) => {
      if (event.data?.type !== 'NEXLAB_SW_ACTIVATED') return;
      state.status = applying ? 'activating' : 'available';
      if (!applying && isNewer(event.data)) {
        publishAvailable(event.data);
      }
      dispatch('nexlab:update-state', { ...state, worker: event.data });
    });

    setTimeout(() => check(), 1200);
    intervalId = window.setInterval(() => check(), CHECK_INTERVAL_MS);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') check();
    });
    window.addEventListener('online', () => check(), { passive: true });
  }

  function stop(){
    if (intervalId) window.clearInterval(intervalId);
    intervalId = null;
    started = false;
  }

  window.__NEXLAB_UPDATE_MANAGER__ = {
    version: CURRENT_VERSION,
    release: CURRENT_RELEASE,
    revision: CURRENT_REVISION,
    state,
    compareVersions: compareNumbers,
    compareIdentity,
    check,
    applyUpdate,
    start,
    stop
  };

  if (document.readyState === 'complete') start();
  else window.addEventListener('load', start, { once: true });
})();
