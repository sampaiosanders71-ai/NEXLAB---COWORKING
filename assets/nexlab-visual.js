(function(){
  if (window.__NEXLAB_VISUAL_V26_7__) return;
  window.__NEXLAB_VISUAL_V26_7__ = true;

  const VERSION = '0.26.12';
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
    ['usuários','participantes'],
    ['permissões','permissoes'],
    ['equipes','equipes'],
    ['meu perfil','perfil'],
    ['projetos','projetos'],
    ['patrimônio','inventario'],
    ['reserva de sala','reserva'],
    ['reservas e reuniões','reserva'],
    ['estoque e patrimônio','inventario'],
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
    if (!page) {
      const activeSidebar = document.querySelector(
        'aside [aria-current="page"], aside button[aria-pressed="true"], aside button.bg-orange-500'
      );
      page = PAGE_LABELS.get(normalized(activeSidebar?.textContent)) || '';
    }
    const resolved = page || document.body.dataset.nexlabPage || 'carregamento';
    document.body.dataset.nexlabPage = resolved;
    return resolved;
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
    // O React permanece como único responsável por remover nós dentro de #root.
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
      const key = typeof event.key === 'string' ? event.key : '';
      if (key === 'Tab' || key.startsWith('Arrow')) {
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


  function testApiAllowed(){
    try {
      const host = String(location.hostname || '').toLowerCase();
      return window.__NEXLAB_ENABLE_TEST_API__ === true ||
        ['localhost','127.0.0.1','::1'].includes(host) ||
        /(?:^|[-.])(homolog|homologacao|test|testing|staging)(?:[-.]|$)/i.test(host);
    } catch { return false; }
  }

  function installV266TestApi(){
    if (!testApiAllowed()) {
      try { delete window.__NEXLAB_TEST_API__; } catch { window.__NEXLAB_TEST_API__ = undefined; }
      return;
    }
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
          hasSkipLink: Boolean(document.querySelector('.nexlab-skip-link'))
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


  function fieldContextLabelBeta(control, index){
    const placeholder = normalized(control.getAttribute('placeholder'));
    if (placeholder) return placeholder.replace(/\.{3}$/,'');

    const previous = control.previousElementSibling;
    if (previous && /^(LABEL|SPAN|P|STRONG)$/.test(previous.tagName)) {
      const text = normalized(previous.textContent).replace(/\s*\*\s*$/,'');
      if (text && text.length <= 100) return text;
    }

    const parent = control.parentElement;
    if (parent) {
      const sibling = Array.from(parent.children).find((node) =>
        node !== control && /^(LABEL|SPAN|P|STRONG)$/.test(node.tagName) && normalized(node.textContent)
      );
      const text = normalized(sibling?.textContent).replace(/\s*\*\s*$/,'');
      if (text && text.length <= 100) return text;
    }

    const type = String(control.getAttribute('type') || '').toLowerCase();
    const page = v261ModuleLabel(document.body.dataset.nexlabPage || markPage());
    if (type === 'search') return `Buscar em ${page}`;
    if (type === 'date') return `Data em ${page}`;
    if (type === 'time') return `Horário em ${page}`;
    if (control.tagName === 'SELECT') {
      const option = normalized(control.querySelector('option')?.textContent);
      return option ? `Filtro: ${option}` : `Filtro ${index + 1} em ${page}`;
    }
    if (type === 'email') return 'E-mail';
    if (type === 'password') return 'Senha';
    if (type === 'number') return `Valor numérico em ${page}`;
    return `Campo ${index + 1} em ${page}`;
  }

  function ensureAccessibleFieldNamesBeta(){
    const controls = document.querySelectorAll('input:not([type="hidden"]), select, textarea');
    controls.forEach((control, index) => {
      if (control.getAttribute('aria-label') || control.getAttribute('aria-labelledby')) return;
      if (control.closest('label')) return;
      if (control.id && document.querySelector(`label[for="${CSS.escape(control.id)}"]`)) return;

      const previous = control.previousElementSibling;
      if (previous?.matches?.('label')) {
        if (!control.id) control.id = `nexlab-beta-field-${index}`;
        previous.htmlFor = control.id;
        return;
      }

      control.setAttribute('aria-label', fieldContextLabelBeta(control, index));
      control.dataset.nexlabAccessibleName = 'beta-0-26-12';
    });
  }

  function run(){
    scheduled = false;
    markPage();
    ensureAccessibleFieldNamesBeta();
  }


  function decorateSummaryCardsV263034(){
    const root = document.querySelector('main') || document.getElementById('root') || document;
    const candidates = root.querySelectorAll('section, article, div');
    let decorated = 0;
    candidates.forEach((card) => {
      if (!(card instanceof HTMLElement)) return;
      if (card.classList.contains('nexlab-decor-card-v263034')) return;
      if (card.closest('form')) return;
      if (card.matches('form')) return;
      if (card.querySelector('form, table, input, select, textarea')) return;
      if (card.querySelector('[role="dialog"], [aria-modal="true"]')) return;
      const className = String(card.className || "");
      if (!/\bbg-white\b/.test(className)) return;
      if (!/\bborder\b/.test(className)) return;
      if (!/rounded-(3xl|\[26px\]|\[30px\])/.test(className)) return;
      const text = (card.textContent || "").replace(/\s+/g, " " ).trim();
      if (!text || text.length > 650) return;
      const buttonCount = card.querySelectorAll('button, a[href]').length;
      if (buttonCount > 4) return;
      const headings = card.querySelectorAll('h1, h2, h3, h4, strong').length;
      if (!headings) return;
      const children = card.children.length;
      if (children > 14) return;
      card.classList.add('nexlab-decor-card-v263034', `nexlab-decor-variant-${(decorated % 4) + 1}`);
      decorated += 1;
    });
  }


  function formControlLabelV263033(control){
    if (!control) return '';
    let label = null;
    if (control.id) {
      const escaped = String(control.id).replace(/(["\\])/g, '\\$1');
      label = document.querySelector(`label[for="${escaped}"]`);
    }
    if (!label) label = control.closest('label');
    if (!label && control.parentElement) {
      const candidates = Array.from(control.parentElement.children);
      label = candidates.find((node) =>
        node !== control &&
        (node.matches?.('label') || node.matches?.('.field-label'))
      ) || null;
    }
    return String(label?.textContent || '')
      .replace(/\s*\*\s*$/, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  function formControlPlaceholderV263033(control, label){
    const type = String(control.getAttribute('type') || '').toLowerCase();
    const normalized = String(label || '').toLocaleLowerCase('pt-BR');
    if (type === 'email') return 'nome@exemplo.com';
    if (type === 'url') return 'https://...';
    if (type === 'tel') return '(00) 00000-0000';
    if (type === 'password') return 'Digite a senha';
    if (type === 'number') {
      if (normalized.includes('vaga')) return 'Informe a quantidade de vagas';
      if (normalized.includes('quantidade')) return 'Informe a quantidade';
      return 'Informe um valor';
    }
    if (normalized.includes('título')) return 'Digite o título';
    if (normalized.includes('conteúdo')) return 'Digite o conteúdo';
    if (normalized.includes('descrição')) return 'Descreva as informações necessárias';
    if (normalized.includes('finalidade')) return 'Informe a finalidade';
    if (normalized.includes('local')) return 'Informe o local';
    if (normalized.includes('nome')) return 'Digite o nome';
    if (normalized.includes('motivo')) return 'Informe o motivo';
    if (normalized.includes('observa')) return 'Digite as observações';
    if (normalized.includes('pauta')) return 'Digite a pauta';
    if (normalized.includes('matrícula')) return 'Digite a matrícula';
    if (normalized.includes('responsável')) return 'Informe o responsável';
    return label ? `Preencha: ${label}` : 'Preencha este campo';
  }

  function enhanceFormControlsV263033(){
    const root = document.getElementById('root') || document;
    root.querySelectorAll('form input, form select, form textarea').forEach((control) => {
      const type = String(control.getAttribute('type') || '').toLowerCase();
      if (['checkbox','radio','range','color','file','hidden','submit','button','reset','image'].includes(type)) return;
      if (control.hasAttribute('data-nexlab-unstyled')) return;
      control.classList.add('nexlab-form-control-v263033');
      if (
        control.tagName !== 'SELECT' &&
        !['date','time','datetime-local','month','week'].includes(type) &&
        !control.hasAttribute('placeholder')
      ) {
        const label = formControlLabelV263033(control);
        control.setAttribute('placeholder', formControlPlaceholderV263033(control, label));
      }
    });
  }


  window.nexlabRequestPermissionPassword = function(options = {}){
    return new Promise((resolve) => {
      document.querySelector('.nexlab-permission-password-backdrop')?.remove();
      const title = String(options.title || 'Autorizar alteração de permissões');
      const message = String(options.message || 'Informe a senha administrativa para continuar.');
      const confirmLabel = String(options.confirmLabel || 'Confirmar');
      const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      const backdrop = document.createElement('div');
      backdrop.className = 'nexlab-confirm-backdrop nexlab-permission-password-backdrop';
      backdrop.setAttribute('role','dialog');
      backdrop.setAttribute('aria-modal','true');
      backdrop.setAttribute('aria-labelledby','nexlab-permission-password-title');
      backdrop.setAttribute('aria-describedby','nexlab-permission-password-message');
      backdrop.innerHTML = `
        <div class="nexlab-confirm-card nexlab-permission-password-card" role="document">
          <div class="nexlab-confirm-head">
            <div class="nexlab-permission-password-icon" aria-hidden="true">✓</div>
            <div>
              <h2 id="nexlab-permission-password-title" class="nexlab-confirm-title"></h2>
              <p id="nexlab-permission-password-message" class="nexlab-confirm-text"></p>
            </div>
          </div>
          <label class="nexlab-permission-password-field">
            <span>Senha administrativa</span>
            <input type="password" maxlength="128" autocomplete="current-password" spellcheck="false" placeholder="Digite a senha" />
          </label>
          <p class="nexlab-permission-password-error" role="alert" aria-live="assertive"></p>
          <div class="nexlab-confirm-actions">
            <button type="button" class="nexlab-confirm-btn nexlab-confirm-cancel">Cancelar</button>
            <button type="button" class="nexlab-confirm-btn nexlab-confirm-ok"></button>
          </div>
        </div>`;
      backdrop.querySelector('#nexlab-permission-password-title').textContent = title;
      backdrop.querySelector('#nexlab-permission-password-message').textContent = message;
      const input = backdrop.querySelector('input');
      const error = backdrop.querySelector('.nexlab-permission-password-error');
      const cancel = backdrop.querySelector('.nexlab-confirm-cancel');
      const confirm = backdrop.querySelector('.nexlab-confirm-ok');
      confirm.textContent = confirmLabel;
      let closed = false;
      const close = (value) => {
        if (closed) return;
        closed = true;
        document.removeEventListener('keydown', onKey, true);
        input.value = '';
        backdrop.remove();
        if (previousFocus && document.body.contains(previousFocus)) {
          requestAnimationFrame(() => previousFocus.focus({preventScroll:true}));
        }
        resolve(value);
      };
      const submit = () => {
        if (!input.value.length) {
          error.textContent = 'Informe a senha administrativa.';
          input.setAttribute('aria-invalid','true');
          input.focus();
          return;
        }
        const password = input.value;
        close(password);
      };
      const onKey = (event) => {
        if (event.key === 'Escape') {
          event.preventDefault();
          close(null);
          return;
        }
        if (event.key === 'Enter' && document.activeElement === input) {
          event.preventDefault();
          submit();
          return;
        }
        if (event.key !== 'Tab') return;
        const focusable = [input,cancel,confirm];
        const first = focusable[0];
        const last = focusable[focusable.length-1];
        if (event.shiftKey && document.activeElement === first) {
          last.focus();
          event.preventDefault();
        } else if (!event.shiftKey && document.activeElement === last) {
          first.focus();
          event.preventDefault();
        }
      };
      input.addEventListener('input', () => {
        error.textContent = '';
        input.removeAttribute('aria-invalid');
      });
      cancel.addEventListener('click', () => close(null));
      confirm.addEventListener('click', submit);
      backdrop.addEventListener('click', (event) => {
        if (event.target === backdrop) close(null);
      });
      document.addEventListener('keydown', onKey, true);
      document.body.appendChild(backdrop);
      requestAnimationFrame(() => input.focus());
    });
  };


  window.nexlabMeetingDeclinePrompt = function(){
    return new Promise((resolve) => {
      document.querySelector('.nexlab-meeting-decline-backdrop-r55627')?.remove();
      const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      const backdrop = document.createElement('div');
      backdrop.className = 'nexlab-confirm-backdrop nexlab-meeting-decline-backdrop-r55627';
      backdrop.setAttribute('role','dialog');
      backdrop.setAttribute('aria-modal','true');
      backdrop.setAttribute('aria-labelledby','nexlab-meeting-decline-title-r55627');
      backdrop.setAttribute('aria-describedby','nexlab-meeting-decline-description-r55627');
      backdrop.innerHTML = `
        <div class="nexlab-confirm-card nexlab-meeting-decline-card-r55627" role="document">
          <div class="nexlab-confirm-head">
            <div class="nexlab-meeting-decline-icon-r55627" aria-hidden="true">!</div>
            <div>
              <h2 id="nexlab-meeting-decline-title-r55627" class="nexlab-confirm-title">Não poderei participar</h2>
              <p id="nexlab-meeting-decline-description-r55627" class="nexlab-confirm-text">A observação é opcional e ficará disponível para o responsável pela reunião.</p>
            </div>
          </div>
          <label class="nexlab-meeting-decline-field-r55627">
            <span>Observação opcional</span>
            <textarea rows="4" maxlength="500" placeholder="Ex.: conflito de horário"></textarea>
            <small><strong>0</strong>/500 caracteres</small>
          </label>
          <div class="nexlab-confirm-actions">
            <button type="button" class="nexlab-confirm-btn nexlab-confirm-cancel">Cancelar</button>
            <button type="button" class="nexlab-confirm-btn nexlab-confirm-ok">Confirmar resposta</button>
          </div>
        </div>`;
      const field = backdrop.querySelector('textarea');
      const counter = backdrop.querySelector('small strong');
      const cancel = backdrop.querySelector('.nexlab-confirm-cancel');
      const confirm = backdrop.querySelector('.nexlab-confirm-ok');
      let closed = false;
      const close = (value) => {
        if (closed) return;
        closed = true;
        document.removeEventListener('keydown', onKey, true);
        field.value = '';
        backdrop.remove();
        if (previousFocus && document.body.contains(previousFocus)) {
          requestAnimationFrame(() => previousFocus.focus({preventScroll:true}));
        }
        resolve(value);
      };
      const submit = () => close(field.value.trim());
      const onKey = (event) => {
        if (event.key === 'Escape') {
          event.preventDefault();
          close(null);
          return;
        }
        if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
          event.preventDefault();
          submit();
          return;
        }
        if (event.key !== 'Tab') return;
        const focusable = [field,cancel,confirm];
        const first = focusable[0];
        const last = focusable[focusable.length-1];
        if (event.shiftKey && document.activeElement === first) {
          last.focus();
          event.preventDefault();
        } else if (!event.shiftKey && document.activeElement === last) {
          first.focus();
          event.preventDefault();
        }
      };
      field.addEventListener('input', () => {
        counter.textContent = String(field.value.length);
      });
      cancel.addEventListener('click', () => close(null));
      confirm.addEventListener('click', submit);
      backdrop.addEventListener('click', (event) => {
        if (event.target === backdrop) close(null);
      });
      document.addEventListener('keydown', onKey, true);
      document.body.appendChild(backdrop);
      requestAnimationFrame(() => field.focus());
    });
  };

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
    const labels={dashboard:'Dashboard',pendencias:'Pendências',agenda:'Agenda',notificacoes:'Notificações',participantes:'Usuários',permissoes:'Permissões',equipes:'Equipes',perfil:'Meu Perfil',projetos:'Projetos',inventario:'Estoque e Patrimônio',reserva:'Reservas e Reuniões',marketing:'Marketing',eventos:'Eventos',mural:'Mural Interno',feedback:'Feedback',relatorios:'Relatórios','saude-sistema':'Saúde do Sistema',logs:'Central de Atividades'};
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
