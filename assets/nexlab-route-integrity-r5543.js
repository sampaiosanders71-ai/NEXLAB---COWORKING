(function(){
  'use strict';
  if (window.__NEXLAB_ROUTE_INTEGRITY_R5543__) return;
  window.__NEXLAB_ROUTE_INTEGRITY_R5543__ = true;

  const staleSelectors = [
    '.nexlab-p2-history', '.nexlab-p2-status', '.nexlab-p2-conflict',
    '.nexlab-r550-assistant-preset', '.nexlab-r550-delegation-summary',
    '.nexlab-permission-password-modal', '.nexlab-permission-password-inline'
  ];
  let retryUsed = false;
  let scheduled = false;

  async function purgeLegacyCaches(){
    try {
      if ('caches' in window) {
        const keys = await caches.keys();
        await Promise.all(keys.filter((key) => key.startsWith('nexlab-') && !key.includes('r5543')).map((key) => caches.delete(key)));
      }
      if ('serviceWorker' in navigator) {
        const registration = await navigator.serviceWorker.getRegistration();
        await registration?.update?.();
        registration?.waiting?.postMessage?.({type:'NEXLAB_SKIP_WAITING'});
      }
    } catch (error) {
      console.warn('Não foi possível limpar todos os caches antigos do NEXLAB.', error);
    }
  }

  function hasRealPermissionScreen(){
    const root = document.querySelector('.permission-matrix-page,.permission-layout');
    if (!root) return false;
    const markers = [
      '.permission-role-button', '.permission-tab', '.permission-toggle',
      '.permission-sidebar-card textarea'
    ];
    return markers.filter((selector) => root.querySelector(selector)).length >= 2;
  }

  function cleanStalePermissionUi(){
    if (hasRealPermissionScreen()) {
      retryUsed = false;
      return;
    }

    try { window.__NEXLAB_PERMISSIONS_PHASE2__?.destroy?.(); } catch {}
    try { delete window.__NEXLAB_PERMISSIONS_PHASE2__; } catch { window.__NEXLAB_PERMISSIONS_PHASE2__ = null; }

    for (const selector of staleSelectors) {
      document.querySelectorAll(selector).forEach((node) => node.remove());
    }

    const boundary = document.querySelector('.nexlab-module-error-boundary');
    const title = (document.querySelector('main h1, main h2, header h1, header h2')?.textContent || '').toLowerCase();
    const activeNav = [...document.querySelectorAll('aside a, aside button, nav a, nav button')]
      .find((node) => node.getAttribute('aria-current') === 'page' || /active|bg-orange/.test(node.className || ''));
    const activeText = (activeNav?.textContent || '').toLowerCase();
    const isPending = title.includes('pendên') || activeText.includes('pendên');

    if (boundary && isPending && !retryUsed) {
      retryUsed = true;
      const retry = [...boundary.querySelectorAll('button')].find((button) => /tentar novamente/i.test(button.textContent || ''));
      if (retry) window.setTimeout(() => retry.click(), 80);
    }
  }

  function schedule(){
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      cleanStalePermissionUi();
    });
  }

  new MutationObserver(schedule).observe(document.documentElement, {childList:true, subtree:true});
  window.addEventListener('popstate', schedule);
  window.addEventListener('hashchange', schedule);
  document.addEventListener('click', schedule, true);
  purgeLegacyCaches();
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', schedule, {once:true});
  else schedule();
})();
