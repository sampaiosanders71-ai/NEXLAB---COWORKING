(function(){
  'use strict';
  if (window.__NEXLAB_UPDATE_MANAGER__?.version === '26.30.19') return;

  const CURRENT_VERSION = '26.30.19';
  const CURRENT_REVISION = 'publication-syntax-fix-r5566';
  const RELEASE_URL = './release.json';
  const CHECK_INTERVAL_MS = 15 * 60 * 1000;
  const MESSAGE_TIMEOUT_MS = 2500;
  let intervalId = null;
  let started = false;
  let applying = false;
  let reloaded = false;
  let banner = null;

  const state = {
    version: CURRENT_VERSION,
    revision: CURRENT_REVISION,
    status: 'idle',
    updateAvailable: false,
    remoteVersion: null,
    workerVersion: null,
    checkedAt: null,
    error: null
  };

  function versionParts(value){
    return String(value || '')
      .split(/[^0-9]+/)
      .filter(Boolean)
      .slice(0, 4)
      .map((part) => Number(part) || 0);
  }

  function compareVersions(left, right){
    const a = versionParts(left);
    const b = versionParts(right);
    const length = Math.max(a.length, b.length, 3);
    for (let index = 0; index < length; index += 1) {
      const difference = (a[index] || 0) - (b[index] || 0);
      if (difference !== 0) return difference > 0 ? 1 : -1;
    }
    return 0;
  }

  function dispatch(name, detail){
    try { window.dispatchEvent(new CustomEvent(name, { detail })); } catch {}
  }

  function ensureStyle(){
    if (document.getElementById('nexlab-update-manager-style')) return;
    const style = document.createElement('style');
    style.id = 'nexlab-update-manager-style';
    style.textContent = [
      '.nexlab-update-banner{position:fixed;right:18px;bottom:18px;z-index:2147483000;max-width:390px;padding:16px;border:1px solid #b9c8de;border-radius:16px;background:#fff;color:#10233f;box-shadow:0 18px 48px rgba(15,35,65,.24);font:14px/1.45 Arial,sans-serif}',
      '.nexlab-update-banner strong{display:block;margin-bottom:5px;font-size:15px}',
      '.nexlab-update-banner p{margin:0 0 12px}',
      '.nexlab-update-actions{display:flex;gap:8px;justify-content:flex-end}',
      '.nexlab-update-actions button{border-radius:10px;border:1px solid #b9c8de;padding:8px 12px;font-weight:700;cursor:pointer}',
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
  }

  function showBanner(remoteVersion){
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
    text.textContent = remoteVersion
      ? `A versão ${remoteVersion} está pronta. Atualize para aplicar as correções mais recentes.`
      : 'Uma nova versão está pronta. Atualize para aplicar as correções mais recentes.';
    const actions = document.createElement('div');
    actions.className = 'nexlab-update-actions';
    const later = document.createElement('button');
    later.type = 'button';
    later.className = 'nexlab-update-later';
    later.textContent = 'Depois';
    later.addEventListener('click', hideBanner);
    const now = document.createElement('button');
    now.type = 'button';
    now.className = 'nexlab-update-now';
    now.textContent = 'Atualizar agora';
    now.addEventListener('click', () => applyUpdate());
    actions.append(later, now);
    container.append(title, text, actions);
    document.body.appendChild(container);
    banner = container;
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
    const existing = await navigator.serviceWorker.getRegistration('./');
    if (existing) return existing;
    try {
      return await withTimeout(
        navigator.serviceWorker.ready,
        12000,
        'O Service Worker do NEXLAB não ficou pronto.'
      );
    } catch {
      return null;
    }
  }

  async function workerVersion(worker){
    if (!worker || typeof MessageChannel === 'undefined') return null;
    return withTimeout(new Promise((resolve) => {
      const channel = new MessageChannel();
      channel.port1.onmessage = (event) => resolve(event.data?.version || null);
      worker.postMessage({ type: 'NEXLAB_GET_VERSION' }, [channel.port2]);
    }), MESSAGE_TIMEOUT_MS, 'O worker não respondeu com a versão.').catch(() => null);
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
    return data && typeof data === 'object' ? data : {};
  }

  function observeRegistration(registration){
    if (!registration || registration.__nexlabObserved) return;
    registration.__nexlabObserved = true;
    registration.addEventListener('updatefound', () => {
      const installing = registration.installing;
      if (!installing) return;
      state.status = 'installing';
      dispatch('nexlab:update-state', { ...state });
      installing.addEventListener('statechange', async () => {
        if (installing.state === 'installed' && navigator.serviceWorker.controller) {
          const version = await workerVersion(registration.waiting || installing);
          state.workerVersion = version;
          state.remoteVersion = version || state.remoteVersion;
          state.updateAvailable = true;
          state.status = 'available';
          showBanner(state.remoteVersion);
          dispatch('nexlab:update-available', { ...state });
        }
      });
    });
  }

  async function check(options = {}){
    const forceWorkerUpdate = options.forceWorkerUpdate !== false;
    state.status = 'checking';
    state.error = null;
    dispatch('nexlab:update-state', { ...state });
    try {
      const registration = await getRegistration();
      if (registration) {
        observeRegistration(registration);
        if (forceWorkerUpdate) {
          try { await registration.update(); } catch {}
        }
      }

      let release = {};
      try { release = await fetchRelease(); } catch (error) {
        if (!registration) throw error;
      }

      const remoteVersion = String(release.version || '').trim() || null;
      const candidateWorker = registration?.waiting || registration?.installing || null;
      const candidateVersion = await workerVersion(candidateWorker);
      const hasWaitingWorker = Boolean(registration?.waiting);
      const newerRelease = Boolean(remoteVersion && compareVersions(remoteVersion, CURRENT_VERSION) > 0);
      const newerWorker = Boolean(candidateVersion && compareVersions(candidateVersion, CURRENT_VERSION) > 0);
      const available = hasWaitingWorker || newerRelease || newerWorker;

      state.remoteVersion = candidateVersion || remoteVersion;
      state.workerVersion = candidateVersion;
      state.updateAvailable = available;
      state.checkedAt = new Date().toISOString();
      state.status = available ? 'available' : 'current';

      if (available) {
        showBanner(state.remoteVersion);
        dispatch('nexlab:update-available', { ...state });
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

  async function waitForWaitingWorker(registration, milliseconds = 12000){
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
    }), milliseconds, 'A nova versão não terminou de instalar.').catch(() => null);
  }

  async function applyUpdate(){
    if (applying) return { ok: false, reason: 'already_applying' };
    applying = true;
    state.status = 'applying';
    dispatch('nexlab:update-state', { ...state });
    try {
      const registration = await getRegistration();
      if (!registration) {
        location.reload();
        return { ok: true, action: 'reload' };
      }
      if (!registration.waiting) {
        try { await registration.update(); } catch {}
      }
      const waitingWorker = registration.waiting || await waitForWaitingWorker(registration);
      if (waitingWorker) {
        waitingWorker.postMessage({ type: 'NEXLAB_SKIP_WAITING' });
        return { ok: true, action: 'skip_waiting' };
      }
      applying = false;
      state.status = 'current';
      await check({ forceWorkerUpdate: false });
      return { ok: false, reason: 'worker_not_ready' };
    } catch (error) {
      applying = false;
      state.status = 'error';
      state.error = String(error?.message || error);
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
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (!applying || reloaded) return;
      reloaded = true;
      location.reload();
    });
    setTimeout(() => check(), 2200);
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
    revision: CURRENT_REVISION,
    state,
    compareVersions,
    check,
    applyUpdate,
    start,
    stop
  };

  if (document.readyState === 'complete') start();
  else window.addEventListener('load', start, { once: true });
})();
