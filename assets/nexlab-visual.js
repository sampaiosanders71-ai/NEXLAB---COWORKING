(function(){
  if (window.__NEXLAB_VISUAL_V26_7__) return;
  window.__NEXLAB_VISUAL_V26_7__ = true;

  const VERSION = '26.30.27';
  let connectionBackdrop = null;
  let connectionDismissedUntil = 0;
  let activeActions = 0;
  let actionSafetyTimer = 0;
  let updateBanner = null;
  let refreshingForUpdate = false;
  let scheduled = false;
  let lastSignature = '';
  let sidebarSelectionObserver = null;
  let observedSidebar = null;

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
    ['mural interno','mural'],
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

  function clearActionLoadingSafety(){
    if (!actionSafetyTimer) return;
    window.clearTimeout(actionSafetyTimer);
    actionSafetyTimer = 0;
  }

  function armActionLoadingSafety(){
    clearActionLoadingSafety();
    actionSafetyTimer = window.setTimeout(() => {
      activeActions = 0;
      setActionLoading(false);
      actionSafetyTimer = 0;
    }, 30000);
  }

  function setupServiceWorkerUpdateButton(){
    window.__NEXLAB_UPDATE_MANAGER__?.start?.();
  }

  function removeObsoleteUi(){
    // R55.6.14: o React permanece como único responsável por remover nós dentro de #root.
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
    // Status visual deve ser renderizado pelo componente React de Notificações.
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


  let v265LastPage = '';
  let v265KeyboardNavigation = false;
  let v265LastDialog = null;


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

  function syncSidebarCurrentPage(sidebar, page){
    const buttons = Array.from(sidebar?.querySelectorAll('nav button') || []);
    if (!buttons.length) return;

    // O React controla o módulo atual pela classe bg-orange-500.
    // aria-current apenas reflete esse estado para acessibilidade e não pode
    // ser usado como fonte, pois isso mantinha módulos antigos destacados.
    const activeByState = buttons.find((button) =>
      button.classList.contains('bg-orange-500')
    );

    const activeByLabel = buttons.find((button) =>
      PAGE_LABELS.get(normalized(button.textContent)) === page
    );

    const currentButton = activeByState || activeByLabel || null;

    buttons.forEach((button) => {
      const isCurrent = button === currentButton;
      if (isCurrent) {
        if (button.getAttribute('aria-current') !== 'page') {
          button.setAttribute('aria-current', 'page');
        }
      } else if (button.hasAttribute('aria-current')) {
        button.removeAttribute('aria-current');
      }
    });
  }

  function ensureSidebarSelectionObserver(sidebar){
    if (!sidebar || observedSidebar === sidebar) return;

    sidebarSelectionObserver?.disconnect();
    observedSidebar = sidebar;
    sidebarSelectionObserver = new MutationObserver(schedule);
    sidebarSelectionObserver.observe(sidebar, {
      subtree: true,
      attributes: true,
      attributeFilter: ['class']
    });
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

      syncSidebarCurrentPage(sidebar, page);
      ensureSidebarSelectionObserver(sidebar);
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
  window.addEventListener('nexlab:action-start', () => {
    activeActions += 1;
    setActionLoading(true);
    armActionLoadingSafety();
  });
  window.addEventListener('nexlab:action-end', () => {
    activeActions = Math.max(0, activeActions - 1);
    if (activeActions === 0) {
      clearActionLoadingSafety();
      window.setTimeout(() => setActionLoading(false), 180);
    } else {
      armActionLoadingSafety();
    }
  });

  installV265DialogFocusTrap();
  installV265InputModality();
  installV266TestApi();

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      applyDevicePerformanceMode();
      activeActions = 0;
      setActionLoading(false);
      run();
      setupServiceWorkerUpdateButton();
    }, { once: true });
  } else {
    applyDevicePerformanceMode();
    activeActions = 0;
    setActionLoading(false);
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
    document.body.appendChild(v261PartialBanner);
  }

  function v261ClearPartial(){v261PartialBanner?.remove();v261PartialBanner=null;}

  function v261ShowRenderError(detail){
    console.error('Falha de renderização protegida:',detail||{});
  }

  window.addEventListener('nexlab:module-loading',event=>v261ShowLoading(event.detail));
  window.addEventListener('nexlab:module-partial-error',event=>v261ShowPartial(event.detail));
  window.addEventListener('nexlab:module-partial-clear',v261ClearPartial);
  window.addEventListener('nexlab:module-render-error',event=>v261ShowRenderError(event.detail));

})();
