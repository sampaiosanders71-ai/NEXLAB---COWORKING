(function(){
  if (window.__NEXLAB_VISUAL_V26_7__) return;
  window.__NEXLAB_VISUAL_V26_7__ = true;

  const VERSION = '26.7.5';
  let connectionBackdrop = null;
  let connectionDismissedUntil = 0;
  let activeActions = 0;
  let updateBanner = null;
  let refreshingForUpdate = false;
  let scheduled = false;
  let lastSignature = '';

  const PAGE_LABELS = new Map([
    ['dashboard','dashboard'],
    ['pendências','pendencias'],
    ['agenda','agenda'],
    ['notificações','notificacoes'],
    ['usuários','usuarios'],
    ['permissões','permissoes'],
    ['equipes','equipes'],
    ['meu perfil','perfil'],
    ['projetos','projetos'],
    ['patrimônio','patrimonio'],
    ['reserva de sala','reserva'],
    ['marketing','marketing'],
    ['eventos','eventos'],
    ['mural','mural'],
    ['feedback','feedback'],
    ['relatórios','relatorios'],
    ['saúde do sistema','saude-sistema'],
    ['central de atividades','logs']
  ]);

  function normalized(text){
    return String(text || '').replace(/\s+/g,' ').trim().toLowerCase();
  }

  function currentHeaderLabel(){
    return normalized(
      document.querySelector('header.sticky span.font-semibold, header span.font-semibold, header h1, header h2')?.textContent
    );
  }

  function markPage(){
    const label = currentHeaderLabel();
    let page = PAGE_LABELS.get(label) || '';
    if (!page) {
      const heading = normalized(document.querySelector('main h1, main h2, main .module-title')?.textContent);
      for (const [name, key] of PAGE_LABELS) {
        if (heading === name || heading.startsWith(name + ' ')) {
          page = key;
          break;
        }
      }
    }
    document.body.dataset.nexlabPage = page || 'claro';
    return page || 'claro';
  }

  function ensureOfflineToast(){
    let toast = document.querySelector('.nexlab-offline-toast');
    if (navigator.onLine) {
      toast?.remove();
      return;
    }
    if (toast) return;

    toast = document.createElement('div');
    toast.className = 'nexlab-offline-toast';
    toast.setAttribute('role','status');
    toast.innerHTML = '<div><strong>Modo offline ativo</strong><div>Dados já carregados podem continuar visíveis; novas alterações precisam de conexão.</div></div><button type="button">Tentar reconectar</button>';
    toast.querySelector('button')?.addEventListener('click', () => location.reload());
    document.body.appendChild(toast);
  }

  function openStandardModal(options){
    const opts = options || {};
    const resolve = typeof opts.resolve === 'function' ? opts.resolve : function(){};
    document.querySelector('.nexlab-modal-backdrop')?.remove();

    const variant = ['success','warning','danger','info'].includes(String(opts.variant || 'info'))
      ? String(opts.variant || 'info')
      : 'info';
    const icon = variant === 'success' ? '✓' : variant === 'info' ? 'i' : '!';
    const title = String(opts.title || 'Aviso do NEXLAB');
    const message = String(opts.message || opts.text || 'Operação concluída.');
    const okLabel = String(opts.okLabel || 'Entendi');

    const backdrop = document.createElement('div');
    backdrop.className = 'nexlab-modal-backdrop';
    backdrop.setAttribute('role','dialog');
    backdrop.setAttribute('aria-modal','true');
    backdrop.setAttribute('aria-labelledby','nexlab-modal-title');
    backdrop.innerHTML = '<section class="nexlab-modal-card" data-variant="' + variant + '"><div class="nexlab-modal-head"><div class="nexlab-modal-icon" aria-hidden="true">' + icon + '</div><div><h2 id="nexlab-modal-title" class="nexlab-modal-title"></h2><p class="nexlab-modal-text"></p></div></div><div class="nexlab-modal-actions"><button type="button" class="nexlab-modal-btn nexlab-modal-ok"></button></div></section>';
    backdrop.querySelector('.nexlab-modal-title').textContent = title;
    backdrop.querySelector('.nexlab-modal-text').textContent = message;

    const ok = backdrop.querySelector('.nexlab-modal-ok');
    ok.textContent = okLabel;

    function close(value){
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      resolve(value);
    }
    function onKey(event){
      if (event.key === 'Escape' || event.key === 'Enter') {
        event.preventDefault();
        close(true);
      }
    }

    ok.addEventListener('click', () => close(true));
    backdrop.addEventListener('click', (event) => {
      if (event.target === backdrop) close(true);
    });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    setTimeout(() => ok.focus(), 0);
  }

  function showConnectionError(detail){
    if (Date.now() < connectionDismissedUntil) return;
    const info = detail || {};
    connectionBackdrop?.remove();

    connectionBackdrop = document.createElement('div');
    connectionBackdrop.className = 'nexlab-connection-backdrop';
    connectionBackdrop.setAttribute('role','dialog');
    connectionBackdrop.setAttribute('aria-modal','true');
    connectionBackdrop.setAttribute('aria-labelledby','nexlab-connection-title');
    connectionBackdrop.innerHTML = '<section class="nexlab-connection-card"><div class="nexlab-connection-top"><div class="nexlab-connection-icon" aria-hidden="true">!</div><div><h2 id="nexlab-connection-title" class="nexlab-connection-title"></h2><p class="nexlab-connection-text"></p></div></div><div class="nexlab-connection-body"><p class="nexlab-connection-detail"></p><div class="nexlab-connection-actions"><button type="button" class="nexlab-connection-btn nexlab-connection-close">Continuar offline</button><button type="button" class="nexlab-connection-btn nexlab-connection-retry">Tentar novamente</button></div></div></section>';

    connectionBackdrop.querySelector('.nexlab-connection-title').textContent =
      String(info.title || 'Falha de conexão');
    connectionBackdrop.querySelector('.nexlab-connection-text').textContent =
      String(info.message || 'Não foi possível conectar ao servidor agora.');
    connectionBackdrop.querySelector('.nexlab-connection-detail').textContent =
      String(info.detail || 'Confira sua internet e tente novamente.');

    connectionBackdrop.querySelector('.nexlab-connection-retry')?.addEventListener('click', () => location.reload());
    connectionBackdrop.querySelector('.nexlab-connection-close')?.addEventListener('click', () => {
      connectionDismissedUntil = Date.now() + 120000;
      connectionBackdrop?.remove();
      connectionBackdrop = null;
    });

    document.body.appendChild(connectionBackdrop);
    setTimeout(() => connectionBackdrop?.querySelector('.nexlab-connection-retry')?.focus(), 0);
  }

  function hideConnectionError(){
    if (!connectionBackdrop) return;
    connectionBackdrop.remove();
    connectionBackdrop = null;
    openStandardModal({
      title: 'Conexão restabelecida',
      message: 'A comunicação com o servidor voltou ao normal.',
      variant: 'success',
      okLabel: 'Ok'
    });
  }

  function ensureActionLoader(){
    let loader = document.querySelector('.nexlab-action-loader');
    if (loader) return loader;
    loader = document.createElement('div');
    loader.className = 'nexlab-action-loader';
    loader.setAttribute('role','status');
    loader.setAttribute('aria-live','polite');
    loader.innerHTML = '<div class="nexlab-action-loader-bar"></div><div class="nexlab-action-loader-pill"><span class="nexlab-action-spinner" aria-hidden="true"></span><span>Processando ação...</span></div>';
    document.body.appendChild(loader);
    return loader;
  }

  function setActionLoading(on){
    const loader = ensureActionLoader();
    document.documentElement.dataset.nexlabBusy = on ? 'true' : 'false';
    loader.dataset.visible = on ? 'true' : 'false';
  }

  function showUpdateBanner(registration){
    if (updateBanner || !registration?.waiting) return;
    updateBanner = document.createElement('div');
    updateBanner.className = 'nexlab-update-banner';
    updateBanner.setAttribute('role','status');
    updateBanner.innerHTML = '<div><strong>Nova versão disponível</strong><span>Atualize o NEXLAB para usar as correções mais recentes.</span></div><div class="nexlab-update-actions"><button type="button" class="nexlab-update-later">Depois</button><button type="button" class="nexlab-update-now">Atualizar app</button></div>';
    updateBanner.querySelector('.nexlab-update-later')?.addEventListener('click', () => {
      updateBanner?.remove();
      updateBanner = null;
    });
    updateBanner.querySelector('.nexlab-update-now')?.addEventListener('click', () => {
      refreshingForUpdate = true;
      registration.waiting?.postMessage({ type: 'NEXLAB_SKIP_WAITING' });
    });
    document.body.appendChild(updateBanner);
  }

  function setupServiceWorkerUpdateButton(){
    if (!('serviceWorker' in navigator) || location.protocol === 'file:') return;

    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (!refreshingForUpdate) return;
      refreshingForUpdate = false;
      location.reload();
    });

    navigator.serviceWorker.getRegistration('./').then((registration) => {
      if (!registration) return;
      if (registration.waiting) showUpdateBanner(registration);
      registration.addEventListener('updatefound', () => {
        const worker = registration.installing;
        if (!worker) return;
        worker.addEventListener('statechange', () => {
          if (worker.state === 'installed' && navigator.serviceWorker.controller) {
            showUpdateBanner(registration);
          }
        });
      });
      window.setTimeout(() => registration.update().catch(() => undefined), 2500);
    }).catch(() => undefined);
  }

  function removeObsoleteUi(){
    document.querySelectorAll(
      '.nexlab-help-launcher,.nexlab-help-backdrop,.nexlab-module-transition,.nexlab-module-timeout-note,.nexlab-marketing-agenda-board'
    ).forEach((element) => element.remove());
  }

  function removeModuleHeaderSubtitles(){
    const main = document.querySelector('main');
    if (!main) return;

    if (document.body.dataset.nexlabPage === 'marketing') {
      main.querySelectorAll('.nexlab-mkt-hero-copy p,.nexlab-mkt-agenda-head span').forEach((element) => {
        element.dataset.nexlabModuleSubtitleHidden = 'true';
      });
    }

    const shell = main.querySelector(':scope > .module-shell') || main.querySelector('.module-shell');
    if (!shell) return;

    const candidates = Array.from(shell.children).slice(0, 3);
    for (const block of candidates) {
      if (!block.querySelector('h1,h2,h3')) continue;
      const paragraphs = Array.from(block.querySelectorAll(':scope > p,:scope > div > p'));
      const eligible = paragraphs.filter((p) => {
        const text = normalized(p.textContent);
        return text.length >= 12 && text.length <= 180 && !p.closest('form,dialog,table,[role="table"]');
      });
      eligible.forEach((p) => p.dataset.nexlabModuleSubtitleHidden = 'true');
      if (eligible.length) break;
    }
  }

  function ensureNotificationHubStatus(){
    if(document.body.dataset.nexlabPage!==`notificacoes`)return;
    let host=document.querySelector(`main .module-shell,main > div`);
    if(!host)return;
    let el=host.querySelector(`.nexlab-v262-notification-status`);
    if(!el){el=document.createElement(`div`);el.className=`nexlab-v262-notification-status`;el.innerHTML=`<span class="nexlab-v262-status-dot"></span><span>Sincronização única ativa</span>`;host.prepend(el)}
  }


  function applyDevicePerformanceMode(){
    try {
      const memory = Number(navigator.deviceMemory || 0);
      const cores = Number(navigator.hardwareConcurrency || 0);
      const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
      const slowNetwork = connection && (
        connection.saveData ||
        connection.effectiveType === 'slow-2g' ||
        connection.effectiveType === '2g'
      );
      if ((memory && memory <= 4) || (cores && cores <= 4) || slowNetwork) {
        document.documentElement.dataset.nexlabPerformanceMode = 'economy';
      } else {
        document.documentElement.dataset.nexlabPerformanceMode = 'standard';
      }
    } catch {
      document.documentElement.dataset.nexlabPerformanceMode = 'standard';
    }
  }

  function optimizeRenderedMedia(){
    const images = document.querySelectorAll('main img:not([data-nexlab-media-optimized]), aside img:not([data-nexlab-media-optimized])');
    images.forEach((image) => {
      image.dataset.nexlabMediaOptimized = 'true';
      image.decoding = 'async';
      const rect = image.getBoundingClientRect();
      const isPriority = !!image.closest('header,aside') || rect.top < window.innerHeight * 1.05;
      if (isPriority) {
        try { image.fetchPriority = 'high'; } catch {}
      } else {
        image.loading = 'lazy';
        try { image.fetchPriority = 'low'; } catch {}
      }
    });
  }

  function markDeferredSections(){
    const shell = document.querySelector('main .module-shell');
    if (!shell) return;
    const children = Array.from(shell.children);
    children.forEach((element, index) => {
      if (index < 2) return;
      if (element.matches('form,dialog,table,[role="table"]')) return;
      if (element.querySelector(':scope > form,:scope > dialog')) return;
      const rect = element.getBoundingClientRect();
      if (rect.top > window.innerHeight * 0.85 || rect.height > 500) {
        element.classList.add('nexlab-content-auto');
      }
    });
  }


  let v264SecurityAuditLoaded = false;
  let v264SecurityAuditLoading = false;

  function v264FindAccessToken(value, depth = 0){
    if (!value || depth > 6) return '';
    if (typeof value === 'object' && typeof value.access_token === 'string') {
      return value.access_token;
    }
    if (Array.isArray(value)) {
      for (const item of value) {
        const found = v264FindAccessToken(item, depth + 1);
        if (found) return found;
      }
      return '';
    }
    if (typeof value === 'object') {
      for (const item of Object.values(value)) {
        const found = v264FindAccessToken(item, depth + 1);
        if (found) return found;
      }
    }
    return '';
  }

  function v264ReadAccessToken(){
    try {
      const url = String(globalThis.__NEXLAB_CONFIG__?.supabaseUrl || '');
      const projectRef = new URL(url).hostname.split('.')[0];
      const raw = localStorage.getItem(`sb-${projectRef}-auth-token`);
      if (!raw) return '';
      return v264FindAccessToken(JSON.parse(raw));
    } catch {
      return '';
    }
  }

  function v264CreateSecurityPanel(){
    const panel = document.createElement('section');
    panel.className = 'nexlab-v264-security-panel';
    panel.dataset.nexlabV264SecurityPanel = 'true';
    panel.innerHTML = `
      <div class="nexlab-v264-security-head">
        <div>
          <span class="nexlab-v264-security-kicker">SUPABASE E SEGURANÇA</span>
          <h2>Auditoria v26.4</h2>
        </div>
        <button type="button" class="nexlab-v264-security-refresh">Verificar novamente</button>
      </div>
      <div class="nexlab-v264-security-content" role="status" aria-live="polite">
        <p>Execute o SQL da v26.4 para carregar o diagnóstico de RLS, RPCs, índices e integridade.</p>
      </div>
    `;
    panel.querySelector('.nexlab-v264-security-refresh')?.addEventListener('click', () => {
      v264SecurityAuditLoaded = false;
      v264LoadSecurityAudit(panel, true);
    });
    return panel;
  }

  function v264RenderSecurityAudit(panel, rows){
    const content = panel.querySelector('.nexlab-v264-security-content');
    if (!content) return;

    const safeRows = Array.isArray(rows) ? rows : [];
    const critical = safeRows.filter((row) => row?.status === 'critical').length;
    const warnings = safeRows.filter((row) => row?.status === 'warning').length;
    const passed = safeRows.filter((row) => row?.status === 'pass').length;
    const relevant = safeRows
      .filter((row) => row?.status === 'critical' || row?.status === 'warning')
      .slice(0, 8);

    content.replaceChildren();

    const summary = document.createElement('div');
    summary.className = 'nexlab-v264-security-summary';

    for (const item of [
      ['Críticos', critical, 'critical'],
      ['Atenção', warnings, 'warning'],
      ['Aprovados', passed, 'pass']
    ]) {
      const card = document.createElement('div');
      card.className = `nexlab-v264-security-stat is-${item[2]}`;
      const label = document.createElement('span');
      label.textContent = item[0];
      const value = document.createElement('strong');
      value.textContent = String(item[1]);
      card.append(label, value);
      summary.appendChild(card);
    }

    content.appendChild(summary);

    if (relevant.length === 0) {
      const message = document.createElement('p');
      message.className = 'nexlab-v264-security-ok';
      message.textContent = 'Nenhuma falha crítica ou ponto de atenção foi identificado pela auditoria v26.4.';
      content.appendChild(message);
      return;
    }

    const list = document.createElement('div');
    list.className = 'nexlab-v264-security-list';

    for (const row of relevant) {
      const item = document.createElement('article');
      item.className = `nexlab-v264-security-item is-${row.status || 'warning'}`;

      const title = document.createElement('strong');
      title.textContent = `${row.category || 'Diagnóstico'} — ${row.object_name || 'objeto'}`;

      const detail = document.createElement('p');
      detail.textContent = String(
        row?.details?.message ||
        (row.status === 'critical' ? 'Correção necessária.' : 'Revisão recomendada.')
      );

      item.append(title, detail);
      list.appendChild(item);
    }

    content.appendChild(list);
  }

  async function v264LoadSecurityAudit(panel, force = false){
    if (!panel || v264SecurityAuditLoading || (v264SecurityAuditLoaded && !force)) return;

    const content = panel.querySelector('.nexlab-v264-security-content');
    const button = panel.querySelector('.nexlab-v264-security-refresh');

    v264SecurityAuditLoading = true;
    button?.setAttribute('disabled', 'disabled');
    if (content) content.innerHTML = '<p>Verificando RLS, RPCs, índices e integridade...</p>';

    try {
      const config = globalThis.__NEXLAB_CONFIG__ || {};
      const token = v264ReadAccessToken();

      if (!config.supabaseUrl || !config.supabaseAnonKey || !token) {
        throw new Error('Sessão administrativa não localizada. Entre novamente no NEXLAB.');
      }

      const response = await fetch(
        `${String(config.supabaseUrl).replace(/\/+$/, '')}/rest/v1/rpc/nexlab_security_audit_v26_4`,
        {
          method: 'POST',
          headers: {
            apikey: config.supabaseAnonKey,
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json'
          },
          body: '{}'
        }
      );

      if (!response.ok) {
        const errorBody = await response.text().catch(() => '');
        if (response.status === 404 || /PGRST202|nexlab_security_audit_v26_4/i.test(errorBody)) {
          throw new Error('SQL da v26.4 ainda não foi executado no Supabase.');
        }
        throw new Error(errorBody || `Supabase respondeu com status ${response.status}.`);
      }

      const rows = await response.json();
      v264RenderSecurityAudit(panel, rows);
      v264SecurityAuditLoaded = true;
    } catch (error) {
      if (content) {
        content.replaceChildren();
        const message = document.createElement('p');
        message.className = 'nexlab-v264-security-error';
        message.textContent = error?.message || 'Não foi possível executar a auditoria de segurança.';
        content.appendChild(message);
      }
    } finally {
      v264SecurityAuditLoading = false;
      button?.removeAttribute('disabled');
    }
  }

  function ensureV264SecurityAuditPanel(page){
    const existing = document.querySelector('[data-nexlab-v264-security-panel="true"]');

    if (page !== 'saude-sistema') {
      existing?.remove();
      v264SecurityAuditLoaded = false;
      return;
    }

    const main = document.querySelector('main');
    if (!main) return;

    const host = main.querySelector('.module-shell') || main.firstElementChild || main;
    let panel = existing;

    if (!panel) {
      panel = v264CreateSecurityPanel();
      host.appendChild(panel);
    }

    v264LoadSecurityAudit(panel);
  }


  let v265LastPage = '';
  let v265KeyboardNavigation = false;
  let v265LastDialog = null;

  function ensureV265SkipLink(){
    if (document.querySelector('.nexlab-v265-skip-link')) return;
    const link = document.createElement('a');
    link.className = 'nexlab-v265-skip-link';
    link.href = '#nexlab-main-content';
    link.textContent = 'Pular para o conteúdo principal';
    document.body.prepend(link);
  }

  function ensureV265LiveRegion(){
    let region = document.querySelector('.nexlab-v265-live-region');
    if (region) return region;
    region = document.createElement('div');
    region.className = 'nexlab-v265-live-region';
    region.setAttribute('role', 'status');
    region.setAttribute('aria-live', 'polite');
    region.setAttribute('aria-atomic', 'true');
    document.body.appendChild(region);
    return region;
  }

  function v265Announce(message){
    const region = ensureV265LiveRegion();
    region.textContent = '';
    window.setTimeout(() => {
      region.textContent = String(message || '');
    }, 30);
  }

  function enhanceV265Landmarks(page){
    const main = document.getElementById('nexlab-main-content') || document.querySelector('main');
    if (main) {
      main.setAttribute('role', 'main');
      if (!main.hasAttribute('aria-label')) {
        main.setAttribute('aria-label', currentHeaderLabel() || 'Conteúdo principal');
      }
    }

    const sidebar = document.getElementById('mobile-sidebar');
    const trigger = document.getElementById('mobile-sidebar-trigger');
    const nav = sidebar?.querySelector('nav');

    if (nav && !nav.hasAttribute('aria-label')) {
      nav.setAttribute('aria-label', 'Navegação principal');
    }

    if (sidebar) {
      sidebar.setAttribute('aria-label', 'Menu principal do NEXLAB');
      const isMobile = window.matchMedia('(max-width: 767px)').matches;
      const expanded = trigger?.getAttribute('aria-expanded') === 'true';

      if (isMobile) {
        sidebar.setAttribute('aria-hidden', expanded ? 'false' : 'true');
        try { sidebar.inert = !expanded; } catch {}
      } else {
        sidebar.removeAttribute('aria-hidden');
        try { sidebar.inert = false; } catch {}
      }

      sidebar.querySelectorAll('nav button').forEach((button) => {
        const selected =
          button.classList.contains('bg-orange-500') ||
          button.getAttribute('aria-current') === 'page';
        if (selected) button.setAttribute('aria-current', 'page');
        else button.removeAttribute('aria-current');
      });
    }

    if (trigger) {
      trigger.setAttribute(
        'title',
        trigger.getAttribute('aria-expanded') === 'true'
          ? 'Fechar menu de navegação'
          : 'Abrir menu de navegação'
      );
    }

    if (page !== v265LastPage) {
      const label = currentHeaderLabel() || page || 'módulo';
      if (v265LastPage) {
        v265Announce(`Módulo ${label} aberto.`);
        if (v265KeyboardNavigation) {
          window.setTimeout(() => main?.focus({ preventScroll: true }), 40);
        }
      }
      v265LastPage = page;
    }
  }

  function v265AccessibleName(element){
    return normalized(
      element.getAttribute('aria-label') ||
      element.getAttribute('aria-labelledby') ||
      element.getAttribute('title') ||
      element.textContent
    );
  }

  function enhanceV265Buttons(){
    document.querySelectorAll('button').forEach((button) => {
      if (v265AccessibleName(button)) return;

      const text = normalized(button.textContent);
      const title = button.getAttribute('title');
      if (title) {
        button.setAttribute('aria-label', title);
        return;
      }

      if (text === '+' || button.closest('.nexlab-mkt-day')) {
        button.setAttribute('aria-label', 'Adicionar item');
        return;
      }

      if (text === '×' || text === 'x') {
        button.setAttribute('aria-label', 'Fechar');
      }
    });
  }

  function enhanceV265Forms(){
    const controls = document.querySelectorAll(
      'main input:not([type="hidden"]), main select, main textarea'
    );

    controls.forEach((control, index) => {
      if (!control.id) {
        control.id = `nexlab-field-${index}-${Math.random().toString(36).slice(2, 7)}`;
      }

      const wrappingLabel = control.closest('label');
      if (wrappingLabel) {
        if (!wrappingLabel.htmlFor) wrappingLabel.htmlFor = control.id;
        return;
      }

      if (
        control.hasAttribute('aria-label') ||
        control.hasAttribute('aria-labelledby')
      ) return;

      const previous = control.previousElementSibling;
      if (previous && previous.matches('label')) {
        previous.htmlFor = control.id;
        return;
      }

      const placeholder = control.getAttribute('placeholder');
      const name = control.getAttribute('name');
      if (placeholder) {
        control.setAttribute('aria-label', placeholder.replace(/\.{3}$/,''));
      } else if (name) {
        control.setAttribute('aria-label', name.replace(/[_-]+/g, ' '));
      }
    });

    document.querySelectorAll('main [aria-invalid="true"]').forEach((field) => {
      if (!field.getAttribute('aria-describedby')) {
        const error = field.parentElement?.querySelector(
          '.text-red-500,.text-red-600,[role="alert"]'
        );
        if (error) {
          if (!error.id) error.id = `nexlab-error-${Math.random().toString(36).slice(2, 8)}`;
          field.setAttribute('aria-describedby', error.id);
        }
      }
    });
  }

  function enhanceV265ScrollableRegions(){
    document.querySelectorAll('main table').forEach((table, index) => {
      const parent = table.parentElement;
      if (!parent) return;
      parent.classList.add('nexlab-v265-table-scroll');
      if (!parent.hasAttribute('tabindex')) parent.tabIndex = 0;
      if (!parent.hasAttribute('role')) parent.setAttribute('role', 'region');

      if (!parent.hasAttribute('aria-label')) {
        const heading = table.closest('section,article,div')?.querySelector('h1,h2,h3');
        parent.setAttribute(
          'aria-label',
          heading?.textContent?.trim() || `Tabela de dados ${index + 1}`
        );
      }
    });

    if (document.body.dataset.nexlabPage === 'agenda') {
      document.querySelectorAll('main .grid').forEach((grid) => {
        const columns = getComputedStyle(grid).gridTemplateColumns.split(' ').length;
        if (columns === 7 || grid.className.includes('grid-cols-7')) {
          grid.classList.add('nexlab-v265-calendar-grid');
          grid.parentElement?.classList.add('nexlab-v265-calendar-scroll');
          const parent = grid.parentElement;
          if (parent && !parent.hasAttribute('tabindex')) parent.tabIndex = 0;
          if (parent && !parent.hasAttribute('role')) parent.setAttribute('role', 'region');
          if (parent && !parent.hasAttribute('aria-label')) {
            parent.setAttribute('aria-label', 'Calendário mensal, deslize horizontalmente para ver todos os dias');
          }
        }
      });
    }
  }

  function enhanceV265Dialogs(){
    const dialog = document.querySelector(
      '[role="dialog"][aria-modal="true"]:not([aria-hidden="true"])'
    );
    if (!dialog || dialog === v265LastDialog) return;

    v265LastDialog = dialog;

    const heading = dialog.querySelector('h1,h2,h3');
    if (heading && !dialog.hasAttribute('aria-labelledby')) {
      if (!heading.id) heading.id = `nexlab-dialog-title-${Date.now()}`;
      dialog.setAttribute('aria-labelledby', heading.id);
    }

    const description = dialog.querySelector('p');
    if (description && !dialog.hasAttribute('aria-describedby')) {
      if (!description.id) description.id = `nexlab-dialog-description-${Date.now()}`;
      dialog.setAttribute('aria-describedby', description.id);
    }
  }

  function installV265DialogFocusTrap(){
    if (window.__NEXLAB_V265_DIALOG_TRAP__) return;
    window.__NEXLAB_V265_DIALOG_TRAP__ = true;

    document.addEventListener('keydown', (event) => {
      if (event.key !== 'Tab') return;

      const dialog = document.querySelector(
        '[role="dialog"][aria-modal="true"]:not([aria-hidden="true"])'
      );
      if (!dialog) return;

      const focusables = Array.from(dialog.querySelectorAll(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
      )).filter((element) => element.offsetParent !== null);

      if (!focusables.length) return;

      const first = focusables[0];
      const last = focusables[focusables.length - 1];

      if (event.shiftKey && document.activeElement === first) {
        last.focus();
        event.preventDefault();
      } else if (!event.shiftKey && document.activeElement === last) {
        first.focus();
        event.preventDefault();
      }
    }, true);
  }

  function installV265InputModality(){
    if (window.__NEXLAB_V265_INPUT_MODE__) return;
    window.__NEXLAB_V265_INPUT_MODE__ = true;

    document.addEventListener('keydown', (event) => {
      if (event.key === 'Tab' || event.key.startsWith('Arrow')) {
        v265KeyboardNavigation = true;
        document.documentElement.dataset.nexlabInput = 'keyboard';
      }
    }, true);

    document.addEventListener('pointerdown', () => {
      v265KeyboardNavigation = false;
      document.documentElement.dataset.nexlabInput = 'pointer';
    }, true);
  }

  function applyV265Accessibility(page){
    ensureV265SkipLink();
    ensureV265LiveRegion();
    enhanceV265Landmarks(page);
    enhanceV265Buttons();
    enhanceV265Forms();
    enhanceV265ScrollableRegions();
    enhanceV265Dialogs();
  }


  function installV266TestApi(){
    if (window.__NEXLAB_TEST_API__) return;

    const snapshot = () => {
      const main = document.querySelector('main');
      const unnamedButtons = Array.from(document.querySelectorAll('button'))
        .filter((button) => button.offsetParent !== null)
        .filter((button) => !normalized(
          button.getAttribute('aria-label') ||
          button.getAttribute('title') ||
          button.textContent
        )).length;

      const unlabeledFields = Array.from(document.querySelectorAll(
        'input:not([type="hidden"]),select,textarea'
      ))
        .filter((field) => field.offsetParent !== null)
        .filter((field) => {
          if (field.getAttribute('aria-label') || field.getAttribute('aria-labelledby')) return false;
          if (field.closest('label')) return false;
          if (field.id && document.querySelector(`label[for="${CSS.escape(field.id)}"]`)) return false;
          return true;
        }).length;

      return Object.freeze({
        version: VERSION,
        page: document.body.dataset.nexlabPage || '',
        online: navigator.onLine,
        standalone: window.matchMedia('(display-mode: standalone)').matches,
        serviceWorkerSupported: 'serviceWorker' in navigator,
        serviceWorkerControlled: Boolean(navigator.serviceWorker?.controller),
        viewport: {
          width: window.innerWidth,
          height: window.innerHeight,
          devicePixelRatio: window.devicePixelRatio || 1
        },
        accessibility: {
          unnamedVisibleButtons: unnamedButtons,
          unlabeledVisibleFields: unlabeledFields,
          hasMainLandmark: Boolean(main),
          hasSkipLink: Boolean(document.querySelector('.nexlab-v265-skip-link'))
        },
        performance: window.__NEXLAB_PERFORMANCE__ || null,
        capturedAt: new Date().toISOString()
      });
    };

    window.__NEXLAB_TEST_API__ = Object.freeze({
      version: VERSION,
      snapshot
    });
  }


  let v267ProductionLoaded = false;
  let v267ProductionLoading = false;
  let v267ProductionPanel = null;

  function v267CreateProductionPanel(){
    const panel = document.createElement('section');
    panel.className = 'nexlab-v267-production-panel';
    panel.dataset.nexlabV267ProductionPanel = 'true';
    panel.innerHTML = `
      <div class="nexlab-v267-production-head">
        <div>
          <span>MONITORAMENTO E PRONTIDÃO FINAL</span>
          <h2>NEXLAB v26.7.5</h2>
        </div>
        <div class="nexlab-v267-production-actions">
          <a href="./prontidao.html">Checklist final</a>
          <button type="button">Atualizar</button>
        </div>
      </div>
      <div class="nexlab-v267-production-content" role="status" aria-live="polite">
        <p>Execute a migration v26.7.4 para ativar o monitoramento seguro.</p>
      </div>
    `;

    panel.querySelector('button')?.addEventListener('click', () => {
      v267ProductionLoaded = false;
      v267LoadProductionPanel(panel, true);
    });

    return panel;
  }

  function v267LocalObservability(){
    return window.__NEXLAB_OBSERVABILITY__ || {
      environment: 'production',
      queued: 0,
      sent: 0,
      dropped: 0,
      lastSentAt: null,
      sqlReady: null,
      lastError: null
    };
  }

  function v267Stat(label, value, type = ''){
    const element = document.createElement('div');
    element.className = `nexlab-v267-production-stat ${type ? `is-${type}` : ''}`;
    const caption = document.createElement('span');
    caption.textContent = label;
    const strong = document.createElement('strong');
    strong.textContent = String(value ?? 0);
    element.append(caption, strong);
    return element;
  }

  function v267RenderProduction(panel, summary){
    const content = panel.querySelector('.nexlab-v267-production-content');
    if (!content) return;

    const local = v267LocalObservability();
    content.replaceChildren();

    const grid = document.createElement('div');
    grid.className = 'nexlab-v267-production-grid';
    grid.append(
      v267Stat('Erros 24h', Number(summary?.total || 0), Number(summary?.total || 0) ? 'warning' : 'pass'),
      v267Stat('Críticos 24h', Number(summary?.critical || 0), Number(summary?.critical || 0) ? 'critical' : 'pass'),
      v267Stat('Usuários afetados', Number(summary?.affected_users || 0)),
      v267Stat('Fila local', Number(local.queued || 0), Number(local.queued || 0) ? 'warning' : 'pass')
    );
    content.appendChild(grid);

    const status = document.createElement('div');
    status.className = 'nexlab-v267-production-status';

    const migration = document.createElement('p');
    migration.textContent = local.sqlReady === false
      ? 'A migration de observabilidade ainda não foi instalada.'
      : 'Observabilidade autenticada disponível.';

    const latest = document.createElement('p');
    latest.textContent = summary?.latest_event_at
      ? `Último evento: ${new Date(summary.latest_event_at).toLocaleString('pt-BR')}.`
      : 'Nenhum erro registrado no período consultado.';

    const environment = document.createElement('p');
    const environmentLabels = {
      production: 'Produção',
      homologacao: 'Homologação',
      development: 'Desenvolvimento',
      test: 'Testes'
    };
    environment.textContent = `Ambiente consultado: ${environmentLabels[summary?.environment || local.environment] || 'Produção'}.`;

    const delivery = document.createElement('p');
    delivery.textContent = local.lastSentAt
      ? `Último envio deste dispositivo: ${new Date(local.lastSentAt).toLocaleString('pt-BR')}.`
      : 'Este dispositivo ainda não enviou eventos técnicos.';

    status.append(migration, environment, latest, delivery);
    content.appendChild(status);

    const modules = Array.isArray(summary?.top_modules)
      ? summary.top_modules.slice(0, 5)
      : [];

    if (modules.length) {
      const list = document.createElement('div');
      list.className = 'nexlab-v267-production-modules';
      const title = document.createElement('strong');
      title.textContent = 'Módulos com mais eventos';
      list.appendChild(title);

      for (const item of modules) {
        const row = document.createElement('div');
        const label = document.createElement('span');
        label.textContent = item.module || 'não identificado';
        const count = document.createElement('b');
        count.textContent = String(item.total || 0);
        row.append(label, count);
        list.appendChild(row);
      }
      content.appendChild(list);
    }
  }

  async function v267LoadProductionPanel(panel, force = false){
    if (!panel || v267ProductionLoading || (v267ProductionLoaded && !force)) return;

    const content = panel.querySelector('.nexlab-v267-production-content');
    const button = panel.querySelector('button');
    v267ProductionLoading = true;
    button?.setAttribute('disabled', 'disabled');
    if (content) content.innerHTML = '<p>Consultando observabilidade e prontidão...</p>';

    try {
      const config = globalThis.__NEXLAB_CONFIG__ || {};
      const token = v264ReadAccessToken();

      if (!config.supabaseUrl || !config.supabaseAnonKey || !token) {
        throw new Error('Sessão administrativa não localizada.');
      }

      const response = await fetch(
        `${String(config.supabaseUrl).replace(/\/+$/, '')}/rest/v1/rpc/nexlab_get_observability_summary_v26_7_4`,
        {
          method: 'POST',
          headers: {
            apikey: config.supabaseAnonKey,
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({ p_hours: 24, p_environment: v267LocalObservability().environment || 'production' })
        }
      );

      if (!response.ok) {
        const body = await response.text().catch(() => '');
        if (
          response.status === 404 ||
          /PGRST202|nexlab_get_observability_summary_v26_7_4/i.test(body)
        ) {
          throw new Error('Execute o SQL da v26.7.4 para ativar o monitoramento seguro.');
        }
        throw new Error(body || `Supabase respondeu com status ${response.status}.`);
      }

      const summary = await response.json();
      v267RenderProduction(panel, summary);
      v267ProductionLoaded = true;
    } catch (error) {
      if (content) {
        content.replaceChildren();
        const message = document.createElement('p');
        message.className = 'nexlab-v267-production-error';
        message.textContent = error?.message || 'Não foi possível carregar a prontidão final.';
        content.appendChild(message);
      }
    } finally {
      v267ProductionLoading = false;
      button?.removeAttribute('disabled');
    }
  }

  function ensureV267ProductionPanel(page){
    const existing = document.querySelector('[data-nexlab-v267-production-panel="true"]');

    if (page !== 'saude-sistema') {
      existing?.remove();
      v267ProductionPanel = null;
      v267ProductionLoaded = false;
      return;
    }

    const main = document.querySelector('main');
    if (!main) return;

    const host = main.querySelector('.module-shell') || main.firstElementChild || main;

    if (!existing) {
      v267ProductionPanel = v267CreateProductionPanel();
      host.appendChild(v267ProductionPanel);
    } else {
      v267ProductionPanel = existing;
    }

    v267LoadProductionPanel(v267ProductionPanel);
  }

  function run(){
    scheduled = false;
    const page = markPage();
    const main = document.querySelector('main');
    const signature = [
      page,
      currentHeaderLabel(),
      main?.firstElementChild?.className || '',
      main?.childElementCount || 0
    ].join('|');

    if (signature !== lastSignature) {
      lastSignature = signature;
      removeObsoleteUi();
      removeModuleHeaderSubtitles();
      optimizeRenderedMedia();
      markDeferredSections();
    }

    ensureOfflineToast();
    ensureV264SecurityAuditPanel(page);
    ensureV267ProductionPanel(page);
    ensureNotificationHubStatus();
    applyV265Accessibility(page);
  }

  function schedule(){
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(run);
  }

  window.nexlabShowModal = window.nexlabShowModal || function(options){
    return new Promise((resolve) => openStandardModal(Object.assign({}, options || {}, { resolve })));
  };
  window.__NEXLAB_MODAL_READY__ = true;

  window.addEventListener('nexlab:modal', (event) => openStandardModal(event.detail || {}));
  window.addEventListener('nexlab:connection-error', (event) => showConnectionError(event.detail || {}));
  window.addEventListener('nexlab:connection-restored', hideConnectionError);
  window.addEventListener('offline', ensureOfflineToast);
  window.addEventListener('online', ensureOfflineToast);
  window.addEventListener('nexlab:action-start', () => {
    activeActions += 1;
    setActionLoading(true);
  });
  window.addEventListener('nexlab:action-end', () => {
    activeActions = Math.max(0, activeActions - 1);
    if (activeActions === 0) window.setTimeout(() => setActionLoading(false), 180);
  });

  installV265DialogFocusTrap();
  installV265InputModality();
  installV266TestApi();

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      applyDevicePerformanceMode();
      run();
      setupServiceWorkerUpdateButton();
    }, { once: true });
  } else {
    applyDevicePerformanceMode();
    run();
    setupServiceWorkerUpdateButton();
  }

  new MutationObserver(schedule).observe(
    document.getElementById('root') || document.body,
    { childList: true, subtree: true }
  );

  let v261PartialBanner = null;
  let v261LoadingChip = null;

  function v261ModuleLabel(module){
    const labels={dashboard:'Dashboard',participantes:'Usuários',equipes:'Equipes',projetos:'Projetos',planejamentos:'Projetos',patrimonio:'Patrimônio',reserva:'Reserva de Sala',marketing:'Marketing',eventos:'Eventos',mural:'Mural',feedback:'Feedback',relatorios:'Relatórios',logs:'Central de Atividades'};
    return labels[module] || 'módulo';
  }

  function v261ShowLoading(detail){
    const info=detail||{};
    if(!info.loading){v261LoadingChip?.remove();v261LoadingChip=null;return;}
    if(!v261LoadingChip){
      v261LoadingChip=document.createElement('div');
      v261LoadingChip.className='nexlab-v261-loading-chip';
      v261LoadingChip.innerHTML='<span></span><strong></strong>';
      document.body.appendChild(v261LoadingChip);
    }
    v261LoadingChip.querySelector('strong').textContent=`Atualizando ${v261ModuleLabel(info.module)}...`;
  }

  function v261ShowPartial(detail){
    const info=detail||{};
    const failures=Array.isArray(info.failures)?info.failures:[];
    v261PartialBanner?.remove();
    v261PartialBanner=document.createElement('section');
    v261PartialBanner.className='nexlab-v261-partial-banner';
    v261PartialBanner.setAttribute('role','status');
    v261PartialBanner.innerHTML='<div><strong>Dados carregados parcialmente</strong><p></p></div><button type="button">Tentar novamente</button>';
    v261PartialBanner.querySelector('p').textContent=`Não foi possível atualizar: ${failures.join(', ')}. Os dados anteriores foram preservados.`;
    v261PartialBanner.querySelector('button').addEventListener('click',()=>window.dispatchEvent(new CustomEvent('nexlab:retry-module',{detail:{module:info.module}})));
    const main=document.querySelector('main');
    if(main) main.prepend(v261PartialBanner); else document.body.appendChild(v261PartialBanner);
  }

  function v261ClearPartial(){v261PartialBanner?.remove();v261PartialBanner=null;}

  function v261ShowRenderError(detail){
    console.error('Falha de renderização protegida:',detail||{});
  }

  window.addEventListener('nexlab:module-loading',event=>v261ShowLoading(event.detail));
  window.addEventListener('nexlab:module-partial-error',event=>v261ShowPartial(event.detail));
  window.addEventListener('nexlab:module-partial-clear',v261ClearPartial);
  window.addEventListener('nexlab:module-render-error',event=>v261ShowRenderError(event.detail));

  window.addEventListener('nexlab:observability-status', () => {
    const panel = document.querySelector('[data-nexlab-v267-production-panel="true"]');
    if (panel && window.__NEXLAB_OBSERVABILITY__?.sqlReady !== false) {
      v267ProductionLoaded = false;
    }
  });
})();