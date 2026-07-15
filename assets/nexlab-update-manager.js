(function(){
  'use strict';

  if (window.__NEXLAB_UPDATE_MANAGER__) return;

  const CURRENT_VERSION = document.querySelector('meta[name="nexlab-version"]')?.content || '26.30.4';
  const CURRENT_REVISION = 'integrated-homologation-r554';
  const CHECK_INTERVAL_MS = 15 * 60 * 1000;
  const AUTO_APPLY_DELAY_MS = 8000;
  const SNOOZE_MS = 10 * 60 * 1000;
  const UPDATE_LOCK_MS = 20000;
  const CHANNEL_NAME = 'nexlab-app-update';
  const STORAGE_PREFIX = 'nexlab:update:';

  const state = {
    started: false,
    registration: null,
    waitingWorker: null,
    release: null,
    activeActions: 0,
    lastInteractionAt: Date.now(),
    autoTimer: null,
    checkTimer: null,
    heartbeatTimer: null,
    peerStates: new Map(),
    snoozedUntil: Number(sessionStorage.getItem(`${STORAGE_PREFIX}snoozed-until`) || 0),
    applying: false,
    banner: null,
    overlay: null,
    dirtyElements: new Set(),
    submittedRoots: new Set(),
    lastActionRoot: null,
    token: `${Date.now()}-${Math.random().toString(36).slice(2)}`,
    channel: typeof BroadcastChannel === 'function' ? new BroadcastChannel(CHANNEL_NAME) : null
  };

  function compareVersions(left, right){
    const a = String(left || '').split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0);
    const b = String(right || '').split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0);
    const length = Math.max(a.length, b.length);
    for (let index = 0; index < length; index += 1) {
      const difference = (a[index] || 0) - (b[index] || 0);
      if (difference !== 0) return difference > 0 ? 1 : -1;
    }
    return 0;
  }

  function cleanDirtyElements(){
    for (const element of state.dirtyElements) {
      if (!element?.isConnected || element.dataset.nexlabUpdateDirty !== 'true') {
        state.dirtyElements.delete(element);
      }
    }
  }

  function markDirty(element){
    if (!element || element.closest?.('.nexlab-update-banner,.nexlab-update-overlay,.nexlab-modal-backdrop,.nexlab-confirm-backdrop')) return;
    const type = String(element.type || '').toLowerCase();
    const descriptor = `${element.name || ''} ${element.id || ''} ${element.placeholder || ''}`.toLowerCase();
    if (type === 'search' || /(?:buscar|pesquisar|filtro|search|filter)/.test(descriptor)) return;
    const root = element.closest?.('form,[data-nexlab-dirty-scope]') || element;
    root.dataset.nexlabUpdateDirty = 'true';
    state.dirtyElements.add(root);
    broadcastSafetyState();
    reevaluateUpdate();
  }

  function clearDirty(root){
    if (!root) return;
    root.removeAttribute?.('data-nexlab-update-dirty');
    state.dirtyElements.delete(root);
    broadcastSafetyState();
  }

  function dirtyCount(){
    cleanDirtyElements();
    return state.dirtyElements.size;
  }

  function hasPendingFiles(){
    return Array.from(document.querySelectorAll('input[type="file"]')).some((input) => input.files?.length > 0);
  }

  function isBusy(){
    return state.activeActions > 0
      || document.documentElement.dataset.nexlabBusy === 'true'
      || document.querySelector('[aria-busy="true"][data-nexlab-busy="true"], [data-nexlab-update-block="true"]');
  }

  function safeToApply(){
    return !isBusy() && dirtyCount() === 0 && !hasPendingFiles();
  }

  function prunePeerStates(){
    const cutoff = Date.now() - 120000;
    for (const [token, peer] of state.peerStates) {
      if (!peer || Number(peer.at || 0) < cutoff) state.peerStates.delete(token);
    }
  }

  function unsafePeerCount(){
    prunePeerStates();
    let count = 0;
    for (const peer of state.peerStates.values()) {
      if (!peer.safe) count += 1;
    }
    return count;
  }

  function safeAcrossTabs(){
    return safeToApply() && unsafePeerCount() === 0;
  }

  function updateSafetyReason(){
    const reasons = [];
    const dirty = dirtyCount();
    const peers = unsafePeerCount();
    if (dirty > 0) reasons.push(`${dirty} formulário(s) com alterações não salvas nesta aba`);
    if (hasPendingFiles()) reasons.push('arquivo ainda selecionado para envio nesta aba');
    if (isBusy()) reasons.push('operação em andamento nesta aba');
    if (peers > 0) reasons.push(`${peers} outra(s) aba(s) com trabalho em andamento`);
    return reasons.join(' e ');
  }

  function safetyPayload(){
    return {
      type: 'safety-state',
      source: state.token,
      at: Date.now(),
      safe: safeToApply(),
      dirtyCount: dirtyCount(),
      activeActions: state.activeActions,
      pendingFiles: hasPendingFiles()
    };
  }

  function broadcastSafetyState(){
    state.channel?.postMessage(safetyPayload());
  }

  function changesHtml(){
    const changes = Array.isArray(state.release?.changes) ? state.release.changes.slice(0, 3) : [];
    if (!changes.length) return '';
    return `<ul class="nexlab-update-changes">${changes.map((change) => `<li>${escapeHtml(change)}</li>`).join('')}</ul>`;
  }

  function escapeHtml(value){
    const element = document.createElement('span');
    element.textContent = String(value || '');
    return element.innerHTML;
  }

  function ensureBanner(){
    if (state.banner?.isConnected) return state.banner;
    const banner = document.createElement('section');
    banner.className = 'nexlab-update-banner nexlab-update-banner-v2';
    banner.setAttribute('role', 'status');
    banner.setAttribute('aria-live', 'polite');
    banner.innerHTML = `
      <div class="nexlab-update-copy">
        <div class="nexlab-update-kicker">Atualização do sistema</div>
        <strong class="nexlab-update-title"></strong>
        <span class="nexlab-update-message"></span>
        <div class="nexlab-update-release-notes"></div>
      </div>
      <div class="nexlab-update-actions">
        <button type="button" class="nexlab-update-later">Depois</button>
        <button type="button" class="nexlab-update-now">Atualizar agora</button>
      </div>`;

    banner.querySelector('.nexlab-update-later')?.addEventListener('click', () => {
      state.snoozedUntil = Date.now() + SNOOZE_MS;
      sessionStorage.setItem(`${STORAGE_PREFIX}snoozed-until`, String(state.snoozedUntil));
      cancelAutoApply();
      banner.remove();
      state.banner = null;
      window.setTimeout(reevaluateUpdate, SNOOZE_MS + 100);
    });

    banner.querySelector('.nexlab-update-now')?.addEventListener('click', async () => {
      if (!safeAcrossTabs()) {
        const reason = updateSafetyReason();
        const confirmed = typeof window.nexlabConfirm === 'function'
          ? await window.nexlabConfirm(
              `Há ${reason}. Atualizar agora pode descartar essas alterações. Deseja continuar?`,
              { title: 'Atualizar mesmo assim?', confirmLabel: 'Atualizar agora', cancelLabel: 'Continuar no app' }
            )
          : window.confirm(`Há ${reason}. Atualizar agora pode descartar alterações. Continuar?`);
        if (!confirmed) return;
      }
      requestApply('manual');
    });

    document.body.appendChild(banner);
    state.banner = banner;
    return banner;
  }

  function renderBanner(){
    if (!state.waitingWorker) return;
    if (Date.now() < state.snoozedUntil && !state.applying) return;

    const banner = ensureBanner();
    const version = state.release?.version || 'nova';
    const safe = safeAcrossTabs();
    const reason = updateSafetyReason();
    const title = banner.querySelector('.nexlab-update-title');
    const message = banner.querySelector('.nexlab-update-message');
    const notes = banner.querySelector('.nexlab-update-release-notes');
    const later = banner.querySelector('.nexlab-update-later');
    const now = banner.querySelector('.nexlab-update-now');

    title.textContent = `NEXLAB v${version} pronta para instalar`;
    message.textContent = safe
      ? 'A atualização foi baixada. O aplicativo será atualizado automaticamente quando permanecer ocioso.'
      : `A atualização aguardará com segurança: ${reason}.`;
    notes.innerHTML = changesHtml();
    later.textContent = safe ? 'Adiar 10 min' : 'Atualizar depois';
    now.textContent = safe ? 'Atualizar agora' : 'Atualizar mesmo assim';
    banner.dataset.safe = safe ? 'true' : 'false';
  }

  function cancelAutoApply(){
    if (state.autoTimer) window.clearTimeout(state.autoTimer);
    state.autoTimer = null;
  }

  function scheduleAutoApply(){
    cancelAutoApply();
    if (!state.waitingWorker || !safeAcrossTabs() || Date.now() < state.snoozedUntil || state.applying) return;
    const idleFor = Date.now() - state.lastInteractionAt;
    const delay = Math.max(AUTO_APPLY_DELAY_MS, AUTO_APPLY_DELAY_MS - idleFor);
    state.autoTimer = window.setTimeout(() => {
      if (safeAcrossTabs() && Date.now() >= state.snoozedUntil) requestApply('automatic');
      else reevaluateUpdate();
    }, delay);
  }

  function reevaluateUpdate(){
    if (!state.waitingWorker) return;
    renderBanner();
    scheduleAutoApply();
  }

  function showUpdatingOverlay(version){
    if (state.overlay?.isConnected) return;
    const overlay = document.createElement('div');
    overlay.className = 'nexlab-update-overlay';
    overlay.setAttribute('role', 'status');
    overlay.setAttribute('aria-live', 'assertive');
    overlay.innerHTML = `
      <div class="nexlab-update-overlay-card">
        <span class="nexlab-update-spinner" aria-hidden="true"></span>
        <strong>Atualizando o NEXLAB</strong>
        <p>Instalando a versão ${escapeHtml(version || '')}. Não feche o aplicativo.</p>
      </div>`;
    document.body.appendChild(overlay);
    state.overlay = overlay;
  }

  function currentTab(){
    const page = document.body?.dataset?.nexlabPage;
    if (page && page !== 'claro') return page;
    return new URL(location.href).searchParams.get('nexlabTab') || '';
  }

  function reloadWithCurrentTab(version){
    const tab = currentTab();
    const reloadKey = `${STORAGE_PREFIX}last-reload`;
    const previous = JSON.parse(sessionStorage.getItem(reloadKey) || 'null');
    if (previous?.version === version && Date.now() - Number(previous?.at || 0) < 30000) return;
    sessionStorage.setItem(reloadKey, JSON.stringify({ version, at: Date.now() }));
    const url = new URL(location.href);
    if (tab) url.searchParams.set('nexlabTab', tab);
    url.searchParams.set('nexlabUpdated', version || CURRENT_VERSION);
    location.replace(url.toString());
  }

  function claimApplyLock(){
    const key = `${STORAGE_PREFIX}apply-lock`;
    const now = Date.now();
    let existing = null;
    try { existing = JSON.parse(localStorage.getItem(key) || 'null'); } catch {}
    if (existing && existing.token !== state.token && Number(existing.expiresAt || 0) > now) return false;
    localStorage.setItem(key, JSON.stringify({ token: state.token, expiresAt: now + UPDATE_LOCK_MS }));
    return true;
  }

  function requestApply(mode){
    if (state.applying || !state.waitingWorker) return;
    if (mode === 'automatic' && !safeAcrossTabs()) return reevaluateUpdate();
    if (!claimApplyLock()) {
      state.channel?.postMessage({ type: 'apply-requested', version: state.release?.version, source: state.token });
      return;
    }

    state.applying = true;
    cancelAutoApply();
    const version = state.release?.version || 'mais recente';
    showUpdatingOverlay(version);
    sessionStorage.setItem(`${STORAGE_PREFIX}pending-version`, String(version));
    state.channel?.postMessage({ type: 'reloading', version, mode, source: state.token });
    state.waitingWorker.postMessage({ type: 'NEXLAB_SKIP_WAITING', version, mode });

    window.setTimeout(() => {
      if (state.applying) reloadWithCurrentTab(version);
    }, 12000);
  }

  async function fetchRelease(){
    try {
      const response = await fetch(`./release.json?t=${Date.now()}`, {
        cache: 'no-store',
        headers: { 'Cache-Control': 'no-cache' }
      });
      if (!response.ok) throw new Error(`release.json ${response.status}`);
      const release = await response.json();
      if (!release?.version) return null;
      state.release = release;
      if (compareVersions(release.version, CURRENT_VERSION) > 0 || release.revision !== CURRENT_REVISION) {
        state.channel?.postMessage({ type: 'release-detected', release, source: state.token });
        await state.registration?.update();
      }
      return release;
    } catch {
      return null;
    }
  }

  function handleWaitingWorker(worker){
    if (!worker) return;
    state.waitingWorker = worker;
    state.snoozedUntil = Math.min(state.snoozedUntil, Date.now() + SNOOZE_MS);
    state.channel?.postMessage({ type: 'update-ready', release: state.release, source: state.token });
    reevaluateUpdate();
  }

  function observeInstalling(registration){
    const worker = registration.installing;
    if (!worker) return;
    worker.addEventListener('statechange', () => {
      if (worker.state === 'installed' && navigator.serviceWorker.controller) {
        handleWaitingWorker(registration.waiting || worker);
      }
    });
  }

  function recordInteraction(){
    state.lastInteractionAt = Date.now();
    broadcastSafetyState();
    if (state.waitingWorker && safeAcrossTabs()) scheduleAutoApply();
  }

  function installDirtyTracking(){
    const onEdit = (event) => {
      if (!event.isTrusted) return;
      const target = event.target;
      if (!(target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement || target?.isContentEditable)) return;
      markDirty(target);
      recordInteraction();
    };

    document.addEventListener('input', onEdit, true);
    document.addEventListener('change', onEdit, true);
    document.addEventListener('reset', (event) => window.setTimeout(() => clearDirty(event.target), 0), true);
    document.addEventListener('submit', (event) => {
      const root = event.target;
      if (root) state.submittedRoots.add(root);
    }, true);

    document.addEventListener('click', (event) => {
      const button = event.target?.closest?.('button,[role="button"],input[type="submit"]');
      if (!button) return;
      const root = button.closest?.('form,[data-nexlab-dirty-scope]');
      if (root && root.dataset.nexlabUpdateDirty === 'true') state.lastActionRoot = root;
    }, true);

    window.addEventListener('nexlab:action-start', () => {
      state.activeActions += 1;
      broadcastSafetyState();
      if (state.lastActionRoot) state.submittedRoots.add(state.lastActionRoot);
      reevaluateUpdate();
    });

    window.addEventListener('nexlab:action-end', () => {
      state.activeActions = Math.max(0, state.activeActions - 1);
      if (state.activeActions === 0) {
        window.setTimeout(() => {
          for (const root of state.submittedRoots) clearDirty(root);
          state.submittedRoots.clear();
          state.lastActionRoot = null;
          broadcastSafetyState();
          reevaluateUpdate();
        }, 350);
      }
    });

    ['pointerdown','keydown','touchstart'].forEach((name) => {
      window.addEventListener(name, recordInteraction, { capture: true, passive: true });
    });

    window.addEventListener('beforeunload', (event) => {
      if (dirtyCount() === 0 || state.applying) return;
      event.preventDefault();
      event.returnValue = '';
    });
  }

  function installCrossTabChannel(){
    if (!state.channel) return;
    state.channel.addEventListener('message', (event) => {
      const message = event.data || {};
      if (message.source === state.token) return;
      if (message.release) state.release = message.release;
      if (message.type === 'safety-state') {
        state.peerStates.set(message.source, message);
        reevaluateUpdate();
        return;
      }
      if (message.type === 'tab-closed') {
        state.peerStates.delete(message.source);
        reevaluateUpdate();
        return;
      }
      if (message.type === 'update-ready' || message.type === 'release-detected') {
        state.registration?.update().catch(() => undefined);
      }
      if (message.type === 'reloading') {
        showUpdatingOverlay(message.version || 'mais recente');
      }
      if (message.type === 'version-active') {
        reloadWithCurrentTab(message.version || state.release?.version || CURRENT_VERSION);
      }
    });
  }

  async function start(){
    if (state.started || !('serviceWorker' in navigator) || location.protocol === 'file:') return;
    state.started = true;
    installDirtyTracking();
    installCrossTabChannel();
    broadcastSafetyState();
    state.heartbeatTimer = window.setInterval(broadcastSafetyState, 5000);
    window.addEventListener('pagehide', () => state.channel?.postMessage({ type: 'tab-closed', source: state.token }), { once: true });

    navigator.serviceWorker.addEventListener('controllerchange', () => {
      const version = sessionStorage.getItem(`${STORAGE_PREFIX}pending-version`) || state.release?.version || CURRENT_VERSION;
      state.channel?.postMessage({ type: 'version-active', version, source: state.token });
      reloadWithCurrentTab(version);
    });

    navigator.serviceWorker.addEventListener('message', (event) => {
      const message = event.data || {};
      if (message.type === 'NEXLAB_UPDATE_READY') {
        state.registration?.update().catch(() => undefined);
        window.setTimeout(() => handleWaitingWorker(state.registration?.waiting), 100);
      }
      if (message.type === 'NEXLAB_UPDATE_ACTIVATED') {
        state.channel?.postMessage({ type: 'version-active', version: message.version, source: state.token });
      }
    });

    try {
      state.registration = await navigator.serviceWorker.register('./nexlab-sw.js', {
        scope: './',
        updateViaCache: 'none'
      });
      if (state.registration.waiting) handleWaitingWorker(state.registration.waiting);
      state.registration.addEventListener('updatefound', () => observeInstalling(state.registration));
      await fetchRelease();
      await state.registration.update();
    } catch (error) {
      console.error('Falha ao inicializar atualização automática do NEXLAB:', error);
    }

    state.checkTimer = window.setInterval(async () => {
      await fetchRelease();
      await state.registration?.update().catch(() => undefined);
    }, CHECK_INTERVAL_MS);

    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        fetchRelease().then(() => state.registration?.update()).catch(() => undefined);
        reevaluateUpdate();
      }
    });

    window.addEventListener('online', () => {
      fetchRelease().then(() => state.registration?.update()).catch(() => undefined);
    });
  }

  window.__NEXLAB_UPDATE_MANAGER__ = Object.freeze({
    version: CURRENT_VERSION,
    revision: CURRENT_REVISION,
    start,
    check: async () => {
      await fetchRelease();
      return state.registration?.update();
    },
    apply: () => requestApply('api'),
    markDirty,
    clearDirty,
    isSafeToApply: safeToApply,
    snapshot: () => Object.freeze({
      currentVersion: CURRENT_VERSION,
      targetVersion: state.release?.version || null,
      waiting: Boolean(state.waitingWorker),
      applying: state.applying,
      dirtyCount: dirtyCount(),
      activeActions: state.activeActions,
      safeToApply: safeToApply(),
      safeAcrossTabs: safeAcrossTabs(),
      unsafePeerCount: unsafePeerCount(),
      snoozedUntil: state.snoozedUntil
    })
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
