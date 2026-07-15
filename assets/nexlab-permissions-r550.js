(function(){
  'use strict';
  try { window.__NEXLAB_PERMISSIONS_PHASE2__?.destroy?.(); } catch {}
  try { delete window.__NEXLAB_PERMISSIONS_PHASE2__; } catch { window.__NEXLAB_PERMISSIONS_PHASE2__ = null; }
  const selectors = [
    '.nexlab-p2-history', '.nexlab-p2-status', '.nexlab-p2-conflict',
    '.nexlab-r550-assistant-preset', '.nexlab-r550-delegation-summary',
    '.nexlab-permission-password-modal', '.nexlab-permission-password-inline'
  ];
  for (const selector of selectors) {
    document.querySelectorAll(selector).forEach((node) => node.remove());
  }
  window.__NEXLAB_PERMISSIONS_R550_DISABLED__ = true;
})();
