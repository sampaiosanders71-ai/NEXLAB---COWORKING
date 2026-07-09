(function(){
  if (window.__NEXLAB_V25_17_8_VISUAL__) return;
  window.__NEXLAB_V25_17_8_VISUAL__ = true;

  const VERSION = '25.17.8';
  const BRAND = 'brand-r21';
  const ONBOARDING_KEY = 'nexlab:onboarding:v1:done';
  const CHANGELOG_KEY = 'nexlab:changelog:25.17.8:seen';
  let connectionBackdrop = null;
  let connectionDismissedUntil = 0;
  let activeActions = 0;
  let updateBanner = null;
  let refreshingForUpdate = false;

  function currentTopText(){
    const header = document.querySelector('header.sticky span.font-semibold, header span.font-semibold, header h1')?.textContent || '';
    const h1 = document.querySelector('main h1, main .module-title')?.textContent || '';
    return `${header} ${h1} ${(document.querySelector('main')?.textContent || '').slice(0,360)}`.toLowerCase();
  }

  function markPage(){
    const text = currentTopText();
    let page = 'claro';
    const isMarketing = text.includes('marketing e divulgação') || text.includes('buscar no marketing') || text.includes('planejar campanha');
    const isAgenda = text.includes('agenda integrada') || text.includes('buscar na agenda') || text.includes('visão consolidada');
    if (text.includes('dashboard')) page = 'dashboard';
    else if (isMarketing) page = 'marketing';
    else if (isAgenda) page = 'agenda';
    else if (text.includes('perfil')) page = 'perfil';
    else if (text.includes('notifica')) page = 'notificacoes';
    else if (text.includes('usu')) page = 'usuarios';
    else if (text.includes('permiss')) page = 'permissoes';
    else if (text.includes('relat')) page = 'relatorios';
    else if (text.includes('marketing')) page = 'marketing';
    document.body.dataset.nexlabPage = page;
  }

  function safeGet(key){ try { return localStorage.getItem(key); } catch { return null; } }
  function safeSet(key,value){ try { localStorage.setItem(key,value); } catch {} }

  function warmOfflineCache(){
    if (!('caches' in window)) return;
    const files = [
      './',
      './index.html',
      './offline.html',
      './changelog.html',
      './publicacao.html',
      `./assets/nexlab-bootstrap-v25-17-8.js?v=${BRAND}`,
      `./assets/index-CKPsxFpP.js?v=${BRAND}`,
      `./assets/index-B1u8eynw.css?v=${BRAND}`,
      `./assets/nexlab-visual-v25-17-8.css?v=${BRAND}`,
      `./assets/nexlab-visual-v25-17-8.js?v=${BRAND}`,
      `./brand/nexlab-logo-light.png?v=${BRAND}`,
      `./brand/nexlab-logo-dark.png?v=${BRAND}`,
      `./icons/nexlab-192.png?v=${BRAND}`,
      `./icons/nexlab-512.png?v=${BRAND}`
    ];
    caches.open('nexlab-v25-17-8-runtime-r1')
      .then(cache => cache.addAll(files))
      .catch(() => undefined);
  }

  function ensureOfflineToast(){
    let toast = document.querySelector('.nexlab-offline-toast');
    if (navigator.onLine) {
      if (toast) toast.remove();
      return;
    }
    if (toast) return;
    toast = document.createElement('div');
    toast.className = 'nexlab-offline-toast';
    toast.setAttribute('role','status');
    toast.innerHTML = `<div><strong>Modo offline ativo</strong><div>Você está sem internet. O que já foi carregado pode continuar visível; novas alterações dependem de conexão.</div></div><button type="button">Tentar reconectar</button>`;
    toast.querySelector('button')?.addEventListener('click', () => location.reload());
    document.body.appendChild(toast);
  }

  function openStandardModal(options){
    const opts = options || {};
    const resolve = typeof opts.resolve === 'function' ? opts.resolve : function(){};
    document.querySelector('.nexlab-modal-backdrop')?.remove();
    const variant = ['success','warning','danger','info'].includes(String(opts.variant || 'info')) ? String(opts.variant || 'info') : 'info';
    const icon = variant === 'success' ? '✓' : variant === 'danger' ? '!' : variant === 'warning' ? '!' : 'i';
    const title = String(opts.title || 'Aviso do NEXLAB');
    const message = String(opts.message || opts.text || 'Operação concluída.');
    const okLabel = String(opts.okLabel || 'Entendi');
    const backdrop = document.createElement('div');
    backdrop.className = 'nexlab-modal-backdrop';
    backdrop.setAttribute('role','dialog');
    backdrop.setAttribute('aria-modal','true');
    backdrop.setAttribute('aria-labelledby','nexlab-modal-title');
    backdrop.innerHTML = `<section class="nexlab-modal-card" data-variant="${variant}"><div class="nexlab-modal-head"><div class="nexlab-modal-icon" aria-hidden="true">${icon}</div><div><h2 id="nexlab-modal-title" class="nexlab-modal-title"></h2><p class="nexlab-modal-text"></p></div></div><div class="nexlab-modal-actions"><button type="button" class="nexlab-modal-btn nexlab-modal-ok"></button></div></section>`;
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
      if (event.key === 'Escape' || event.key === 'Enter') { event.preventDefault(); close(true); }
    }
    ok.addEventListener('click', () => close(true));
    backdrop.addEventListener('click', (event) => { if (event.target === backdrop) close(true); });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    setTimeout(() => ok.focus(), 0);
  }

  function showConnectionError(detail){
    const now = Date.now();
    if (now < connectionDismissedUntil) return;
    const info = detail || {};
    if (connectionBackdrop) connectionBackdrop.remove();
    connectionBackdrop = document.createElement('div');
    connectionBackdrop.className = 'nexlab-connection-backdrop';
    connectionBackdrop.setAttribute('role','dialog');
    connectionBackdrop.setAttribute('aria-modal','true');
    connectionBackdrop.setAttribute('aria-labelledby','nexlab-connection-title');
    connectionBackdrop.innerHTML = `
      <section class="nexlab-connection-card">
        <div class="nexlab-connection-top">
          <div class="nexlab-connection-icon" aria-hidden="true">!</div>
          <div>
            <h2 id="nexlab-connection-title" class="nexlab-connection-title"></h2>
            <p class="nexlab-connection-text"></p>
          </div>
        </div>
        <div class="nexlab-connection-body">
          <p class="nexlab-connection-detail"></p>
          <div class="nexlab-connection-actions">
            <button type="button" class="nexlab-connection-btn nexlab-connection-close">Continuar offline</button>
            <button type="button" class="nexlab-connection-btn nexlab-connection-retry">Tentar novamente</button>
          </div>
        </div>
      </section>`;
    connectionBackdrop.querySelector('.nexlab-connection-title').textContent = String(info.title || 'Falha de conexão');
    connectionBackdrop.querySelector('.nexlab-connection-text').textContent = String(info.message || 'Não foi possível conectar ao servidor agora.');
    connectionBackdrop.querySelector('.nexlab-connection-detail').textContent = String(info.detail || 'Confira sua internet. Se o problema continuar, aguarde alguns instantes e tente novamente.');
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
    openStandardModal({ title: 'Conexão restabelecida', message: 'A comunicação com o servidor voltou ao normal.', variant: 'success', okLabel: 'Ok' });
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

  function markClickedActionButton(target){
    const btn = target?.closest?.('button,[role="button"],input[type="submit"]');
    if (!btn || btn.closest('.nexlab-help-backdrop,.nexlab-modal-backdrop,.nexlab-confirm-backdrop,.nexlab-connection-backdrop,.nexlab-update-banner')) return;
    const text = [(btn.innerText || btn.textContent || ''), btn.getAttribute?.('aria-label') || '', btn.value || ''].join(' ').toLowerCase();
    if (!/salvar|criar|cadastrar|enviar|excluir|remover|aprovar|rejeitar|arquivar|restaurar|publicar|exportar|entrar|confirmar|finalizar|concluir/.test(text) && btn.type !== 'submit') return;
    btn.dataset.nexlabVisualBusy = 'true';
    btn.setAttribute('aria-busy','true');
    window.setTimeout(() => {
      if (!btn.isConnected) return;
      delete btn.dataset.nexlabVisualBusy;
      if (btn.dataset.nexlabBusy !== 'true') btn.removeAttribute('aria-busy');
    }, 4200);
  }

  function getDetectedProfile(){
    const text = ((document.getElementById('root')?.innerText || '') + ' ' + (document.querySelector('header')?.innerText || '')).toLowerCase();
    if (/administrador|\badm\b/.test(text)) return 'Administrador';
    if (/coordenador/.test(text)) return 'Coordenador';
    if (/bolsista/.test(text)) return 'Bolsista';
    if (/coworking\s*j[uú]nior|j[uú]nior/.test(text)) return 'Coworking Júnior';
    if (/pendente|aguardando aprova/.test(text)) return 'Cadastro pendente';
    if (/inativo|bloqueado|desativado/.test(text)) return 'Usuário inativo';
    return 'Não identificado nesta tela';
  }

  function profileValidationMarkup(){
    const detected = getDetectedProfile();
    const profiles = [
      ['Administrador','Deve visualizar usuários, permissões, saúde do sistema, logs, notificações administrativas e ações de exclusão.'],
      ['Coordenador','Deve visualizar gestão operacional, agenda, projetos, participantes, patrimônio e relatórios permitidos; não deve acessar saúde/logs administrativos.'],
      ['Bolsista','Deve acessar rotinas operacionais autorizadas, mural/feed, reservas e registros compatíveis com sua função.'],
      ['Coworking Júnior','Deve ter acesso simplificado, sem módulos administrativos e sem ações sensíveis de gestão.'],
      ['Cadastro pendente','Deve ver acesso limitado até aprovação do administrador.'],
      ['Usuário inativo','Não deve operar módulos internos nem executar ações de escrita.']
    ];
    return `
      <div class="nexlab-profile-detected"><span>Perfil detectado visualmente</span><strong>${detected}</strong></div>
      <div class="nexlab-profile-grid">
        ${profiles.map(([name,desc]) => `<article class="nexlab-profile-card"><div><strong>${name}</strong><p>${desc}</p></div><label><input type="checkbox" /> Validado</label></article>`).join('')}
      </div>
      <div class="nexlab-profile-note"><strong>Uso correto:</strong> entre no app com cada tipo de usuário e marque o que foi conferido. Este painel é uma validação visual; a proteção real continua sendo RLS, RPCs e permissões do Supabase.</div>`;
  }

  function copyProfileChecklist(){
    const text = [
      'Checklist de validação por perfil — NEXLAB v' + VERSION,
      '- Administrador: usuários, permissões, saúde, logs, notificações e exclusões.',
      '- Coordenador: gestão operacional, agenda, projetos, participantes, patrimônio e relatórios permitidos.',
      '- Bolsista: rotinas operacionais autorizadas, mural/feed, reservas e registros permitidos.',
      '- Coworking Júnior: acesso simplificado, sem módulos administrativos.',
      '- Cadastro pendente: acesso limitado até aprovação.',
      '- Usuário inativo: sem operação interna nem ações de escrita.'
    ].join('\n');
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text).then(() => openStandardModal({title:'Checklist copiado',message:'O checklist de validação por perfil foi copiado.',variant:'success',okLabel:'Ok'})).catch(() => openStandardModal({title:'Checklist de perfis',message:text,variant:'info',okLabel:'Ok'}));
    } else {
      openStandardModal({title:'Checklist de perfis',message:text,variant:'info',okLabel:'Ok'});
    }
  }



  function publicationChecklistMarkup(){
    const items = [
      ['Versão e cache', 'Confirmar NEXLAB v' + VERSION + ', manifest, Service Worker, cache brand-r21 e botão “Atualizar app”.'],
      ['Supabase conectado', 'Entrar com usuário real e confirmar login, sessão, leitura de perfil e carregamento dos módulos.'],
      ['RLS e permissões', 'Testar Administrador, Coordenador, Bolsista, Coworking Júnior, cadastro pendente e usuário inativo.'],
      ['Edge Functions/RPCs', 'Validar funções administrativas, notificações, exclusão protegida, exportações e logs.'],
      ['PWA/Offline', 'Publicar em HTTPS, instalar no celular, testar offline.html, cache e retorno de conexão.'],
      ['Teste mobile', 'Conferir Sidebar, login, botões, modais, loaders, rolagem, toque e contraste em Android/iOS.'],
      ['Publicação final', 'Subir arquivos na raiz do GitHub Pages, limpar cache antigo e registrar evidências do teste.']
    ];
    return `
      <div class="nexlab-publication-summary">
        <strong>Checklist de publicação final</strong>
        <p>Use antes de liberar o NEXLAB para coordenadores ou usuários reais. Este painel não substitui RLS, testes no Supabase nem validação em HTTPS.</p>
      </div>
      <div class="nexlab-publication-grid">
        ${items.map(([name,desc], index) => `<article class="nexlab-publication-card"><div><span>${String(index + 1).padStart(2,'0')}</span><strong>${name}</strong><p>${desc}</p></div><label><input type="checkbox" /> Conferido</label></article>`).join('')}
      </div>
      <div class="nexlab-publication-note"><strong>Critério de aprovação:</strong> não publique como final se login, permissões, cache, offline ou ações administrativas apresentarem falha. Primeiro corrija, depois publique.</div>`;
  }

  function copyPublicationChecklist(){
    const text = [
      'Checklist de publicação final — NEXLAB v' + VERSION,
      '- Versão e cache: manifest, Service Worker, cache brand-r21 e botão Atualizar app.',
      '- Supabase conectado: login, sessão, perfil e módulos carregando.',
      '- RLS e permissões: testar ADM, Coordenador, Bolsista, Coworking Júnior, pendente e inativo.',
      '- Edge Functions/RPCs: validar funções administrativas, notificações, exclusão protegida, exportações e logs.',
      '- PWA/Offline: publicar em HTTPS, instalar no celular, testar offline e retorno de conexão.',
      '- Mobile: conferir Sidebar, login, botões, modais, loaders, rolagem, toque e contraste.',
      '- Publicação final: subir na raiz do GitHub Pages, limpar cache antigo e registrar evidências.'
    ].join('\n');
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text).then(() => openStandardModal({title:'Checklist copiado',message:'O checklist de publicação foi copiado.',variant:'success',okLabel:'Ok'})).catch(() => openStandardModal({title:'Checklist de publicação',message:text,variant:'info',okLabel:'Ok'}));
    } else {
      openStandardModal({title:'Checklist de publicação',message:text,variant:'info',okLabel:'Ok'});
    }
  }

  function showUpdateBanner(registration){
    if (updateBanner || !registration) return;
    updateBanner = document.createElement('div');
    updateBanner.className = 'nexlab-update-banner';
    updateBanner.setAttribute('role','status');
    updateBanner.innerHTML = `
      <div><strong>Nova versão disponível</strong><span>Atualize o NEXLAB para usar os arquivos mais recentes.</span></div>
      <div class="nexlab-update-actions"><button type="button" class="nexlab-update-later">Depois</button><button type="button" class="nexlab-update-now">Atualizar app</button></div>`;
    updateBanner.querySelector('.nexlab-update-later')?.addEventListener('click', () => { updateBanner?.remove(); updateBanner = null; });
    updateBanner.querySelector('.nexlab-update-now')?.addEventListener('click', () => {
      const worker = registration.waiting || registration.installing;
      if (worker) worker.postMessage({ type: 'NEXLAB_SKIP_WAITING' });
      else location.reload();
    });
    document.body.appendChild(updateBanner);
  }

  function setupServiceWorkerUpdateButton(){
    if (!('serviceWorker' in navigator) || location.protocol === 'file:') return;
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (refreshingForUpdate) return;
      refreshingForUpdate = true;
      location.reload();
    });
    navigator.serviceWorker.getRegistration('./').then((registration) => {
      if (!registration) return;
      if (registration.waiting) showUpdateBanner(registration);
      registration.addEventListener('updatefound', () => {
        const worker = registration.installing;
        if (!worker) return;
        worker.addEventListener('statechange', () => {
          if (worker.state === 'installed' && navigator.serviceWorker.controller) showUpdateBanner(registration);
        });
      });
      window.setTimeout(() => registration.update().catch(() => undefined), 2500);
    }).catch(() => undefined);
  }

  function openHelp(initialTab){
    document.querySelector('.nexlab-help-backdrop')?.remove();
    const allowedHelpTabs = new Set(['onboarding','changelog','profiles','publication']);
    const tab = allowedHelpTabs.has(initialTab) ? initialTab : 'onboarding';
    const backdrop = document.createElement('div');
    backdrop.className = 'nexlab-help-backdrop';
    backdrop.setAttribute('role','dialog');
    backdrop.setAttribute('aria-modal','true');
    backdrop.setAttribute('aria-labelledby','nexlab-help-title');
    backdrop.innerHTML = `
      <section class="nexlab-help-card">
        <header class="nexlab-help-head">
          <div>
            <p class="nexlab-help-kicker">NEXLAB v${VERSION}</p>
            <h2 id="nexlab-help-title" class="nexlab-help-title">Ajuda rápida e novidades</h2>
          </div>
          <button type="button" class="nexlab-help-close" aria-label="Fechar">×</button>
        </header>
        <div class="nexlab-help-tabs" role="tablist" aria-label="Ajuda do NEXLAB">
          <button type="button" class="nexlab-help-tab" data-tab="onboarding" role="tab">Primeiros passos</button>
          <button type="button" class="nexlab-help-tab" data-tab="changelog" role="tab">Novidades da versão</button>
          <button type="button" class="nexlab-help-tab" data-tab="profiles" role="tab">Validação por perfil</button>
          <button type="button" class="nexlab-help-tab" data-tab="publication" role="tab">Publicação final</button>
        </div>
        <div class="nexlab-help-body">
          <div class="nexlab-help-panel" data-panel="onboarding" role="tabpanel">
            <div class="nexlab-onboarding-grid">
              <article class="nexlab-onboarding-step"><span>1</span><h3>Acesse com o perfil correto</h3><p>Administrador, Coordenador, Bolsista e Coworking Júnior veem módulos diferentes. Se algo não aparecer, provavelmente é permissão.</p></article>
              <article class="nexlab-onboarding-step"><span>2</span><h3>Use a Sidebar por blocos</h3><p>Os módulos ficam agrupados por rotina: gestão, operação, comunicação, relatórios e sistema. Evite abrir várias ações ao mesmo tempo.</p></article>
              <article class="nexlab-onboarding-step"><span>3</span><h3>Aguarde ações sensíveis</h3><p>Ao salvar, excluir, aprovar ou exportar, espere o botão liberar. Isso evita duplicidade e registros repetidos.</p></article>
              <article class="nexlab-onboarding-step"><span>4</span><h3>PWA e conexão</h3><p>Instale o app no celular quando possível. Se a internet cair ou o Supabase falhar, o app exibe uma tela clara de conexão.</p></article>
            </div>
          </div>
          <div class="nexlab-help-panel" data-panel="changelog" role="tabpanel" hidden>
            <ul class="nexlab-changelog-list">
              <li class="nexlab-changelog-item"><strong>Loader real em ações</strong><p>Ações com gravação no Supabase agora exibem estado de processamento e barra superior, reduzindo sensação de travamento.</p></li>
              <li class="nexlab-changelog-item"><strong>Validação visual por perfil</strong><p>Adicionado painel de checklist para testar Administrador, Coordenador, Bolsista, Coworking Júnior, pendentes e inativos.</p></li>
              <li class="nexlab-changelog-item"><strong>Atualização do app</strong><p>Quando o Service Worker encontrar uma nova versão, o usuário verá o botão “Atualizar app”.</p></li>
              <li class="nexlab-changelog-item"><strong>Checklist de publicação</strong><p>Adicionada página de publicação final com conferência de versão, Supabase, RLS, Edge Functions, PWA, cache e testes mobile.</p></li>
              <li class="nexlab-changelog-item"><strong>Base anterior preservada</strong><p>Mantidas tela de conexão, modal padrão, offline, changelog, onboarding, Sidebar institucional e proteção contra clique duplicado.</p></li>
            </ul>
          </div>
          <div class="nexlab-help-panel" data-panel="profiles" role="tabpanel" hidden>
            ${profileValidationMarkup()}
          </div>
          <div class="nexlab-help-panel" data-panel="publication" role="tabpanel" hidden>
            ${publicationChecklistMarkup()}
          </div>
          <div class="nexlab-help-actions">
            <button type="button" class="nexlab-help-btn nexlab-help-btn-secondary" data-action="copy-profiles" hidden>Copiar checklist</button>
            <button type="button" class="nexlab-help-btn nexlab-help-btn-secondary" data-action="open-publication" hidden>Abrir página</button>
            <button type="button" class="nexlab-help-btn nexlab-help-btn-secondary" data-action="switch-changelog">Ver novidades</button>
            <button type="button" class="nexlab-help-btn nexlab-help-btn-primary" data-action="finish">Entendi</button>
          </div>
        </div>
      </section>`;

    function close(){
      safeSet(ONBOARDING_KEY,'1');
      if (activeTab() === 'changelog') safeSet(CHANGELOG_KEY,'1');
      backdrop.remove();
      document.querySelector('.nexlab-help-launcher')?.removeAttribute('data-highlight');
    }
    function activeTab(){ return backdrop.querySelector('.nexlab-help-tab[aria-selected="true"]')?.dataset.tab || 'onboarding'; }
    function setTab(next){
      backdrop.querySelectorAll('.nexlab-help-tab').forEach(btn => btn.setAttribute('aria-selected', btn.dataset.tab === next ? 'true' : 'false'));
      backdrop.querySelectorAll('.nexlab-help-panel').forEach(panel => { panel.hidden = panel.dataset.panel !== next; });
      const switchBtn = backdrop.querySelector('[data-action="switch-changelog"]');
      const copyBtn = backdrop.querySelector('[data-action="copy-profiles"]');
      const openPublicationBtn = backdrop.querySelector('[data-action="open-publication"]');
      if (switchBtn) switchBtn.textContent = next === 'changelog' ? 'Ver primeiros passos' : 'Ver novidades';
      if (copyBtn) { copyBtn.hidden = !(next === 'profiles' || next === 'publication'); copyBtn.textContent = next === 'publication' ? 'Copiar checklist de publicação' : 'Copiar checklist'; }
      if (openPublicationBtn) openPublicationBtn.hidden = next !== 'publication';
      if (next === 'changelog') safeSet(CHANGELOG_KEY,'1');
    }

    backdrop.querySelector('.nexlab-help-close')?.addEventListener('click', close);
    backdrop.addEventListener('click', (event) => { if (event.target === backdrop) close(); });
    backdrop.querySelectorAll('.nexlab-help-tab').forEach(btn => btn.addEventListener('click', () => setTab(btn.dataset.tab)));
    backdrop.querySelector('[data-action="switch-changelog"]')?.addEventListener('click', () => setTab(activeTab() === 'changelog' ? 'onboarding' : 'changelog'));
    backdrop.querySelector('[data-action="copy-profiles"]')?.addEventListener('click', () => activeTab() === 'publication' ? copyPublicationChecklist() : copyProfileChecklist());
    backdrop.querySelector('[data-action="open-publication"]')?.addEventListener('click', () => { window.open('./publicacao.html','_blank','noopener'); });
    backdrop.querySelector('[data-action="finish"]')?.addEventListener('click', close);
    document.addEventListener('keydown', function esc(event){
      if (event.key === 'Escape' && document.body.contains(backdrop)) { close(); document.removeEventListener('keydown', esc); }
    });
    document.body.appendChild(backdrop);
    setTab(tab);
    backdrop.querySelector('.nexlab-help-close')?.focus({preventScroll:true});
  }

  function ensureHelpLauncher(){
    if (document.querySelector('.nexlab-help-launcher')) return;
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'nexlab-help-launcher';
    btn.innerHTML = '<span>?</span><span>Ajuda</span>';
    btn.setAttribute('aria-label','Abrir ajuda rápida e novidades do NEXLAB');
    btn.addEventListener('click', () => openHelp(safeGet(CHANGELOG_KEY) ? 'onboarding' : 'changelog'));
    if (!safeGet(ONBOARDING_KEY) || !safeGet(CHANGELOG_KEY)) btn.dataset.highlight = 'true';
    document.body.appendChild(btn);
  }

  function maybeAutoShowOnboarding(){
    if (safeGet(ONBOARDING_KEY)) return;
    if (document.querySelector('.nexlab-help-backdrop')) return;
    setTimeout(() => {
      if (!safeGet(ONBOARDING_KEY) && document.body.contains(document.getElementById('root'))) openHelp('onboarding');
    }, 1400);
  }


  const NEXLAB_OLD_MARKETING_MONTHS = ['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'];
  const NEXLAB_OLD_MARKETING_MONTH_INDEX = NEXLAB_OLD_MARKETING_MONTHS.reduce((acc, name, idx) => {
    acc[name.toLowerCase()] = idx;
    acc[name.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase()] = idx;
    return acc;
  }, {});
  const NEXLAB_OLD_MARKETING_MONTH_RE = /\b(Janeiro|Fevereiro|Março|Marco|Abril|Maio|Junho|Julho|Agosto|Setembro|Outubro|Novembro|Dezembro)\s+(20\d{2}|19\d{2})\b/i;

  function normalizeOldMarketingMonthLabel(text){
    const m = String(text||'').replace(/\s+/g,' ').trim().match(NEXLAB_OLD_MARKETING_MONTH_RE);
    if(!m) return '';
    const raw = m[1].replace(/^Marco$/i,'Março');
    const idx = NEXLAB_OLD_MARKETING_MONTH_INDEX[raw.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase()];
    return `${NEXLAB_OLD_MARKETING_MONTHS[idx ?? new Date().getMonth()]} ${m[2]}`;
  }

  function detectOldMarketingMonthFromDom(){
    const main = document.querySelector('main') || document.body;
    const candidates = Array.from(main.querySelectorAll('h1,h2,h3,h4,p,span,button,div'));
    for(const el of candidates){
      if(el.closest('.nexlab-filter-toggle')) continue;
      if(el.classList?.contains('nexlab-month-button')) continue;
      const text = (el.textContent || '').replace(/\s+/g,' ').trim();
      if(text.length > 40) continue;
      const label = normalizeOldMarketingMonthLabel(text);
      if(label) return label;
    }
    const d = new Date();
    return `${NEXLAB_OLD_MARKETING_MONTHS[d.getMonth()]} ${d.getFullYear()}`;
  }

  function getOldMarketingMonthState(){
    if(!window.__nexlabMarketingMonthState){
      const label = detectOldMarketingMonthFromDom();
      const m = label.match(NEXLAB_OLD_MARKETING_MONTH_RE);
      const month = NEXLAB_OLD_MARKETING_MONTH_INDEX[(m?.[1] || '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase()];
      window.__nexlabMarketingMonthState = { month: month ?? new Date().getMonth(), year: Number(m?.[2] || new Date().getFullYear()) };
    }
    return window.__nexlabMarketingMonthState;
  }

  function setOldMarketingMonthState(offset){
    const st = getOldMarketingMonthState();
    let month = st.month + offset;
    let year = st.year;
    while(month < 0){ month += 12; year--; }
    while(month > 11){ month -= 12; year++; }
    window.__nexlabMarketingMonthState = { month, year };
    return `${NEXLAB_OLD_MARKETING_MONTHS[month]} ${year}`;
  }

  function oldMarketingMonthLabel(){
    const st = getOldMarketingMonthState();
    return `${NEXLAB_OLD_MARKETING_MONTHS[st.month]} ${st.year}`;
  }

  function findOldMarketingMonthNavButtons(){
    const main = document.querySelector('main');
    if(!main) return {left:null, center:null, right:null};
    const buttons = Array.from(main.querySelectorAll('button'));
    let center = buttons.find(btn => /^Hoje$/i.test((btn.textContent || '').trim())) || buttons.find(btn => btn.classList.contains('nexlab-month-button'));
    if(!center) center = buttons.find(btn => NEXLAB_OLD_MARKETING_MONTH_RE.test(btn.textContent || ''));
    if(!center) return {left:null, center:null, right:null};
    const row = center.closest('div, section, article') || main;
    const rowButtons = Array.from(row.querySelectorAll('button'));
    const idx = rowButtons.indexOf(center);
    return { left: rowButtons[idx-1] || null, center, right: rowButtons[idx+1] || null };
  }

  function hideOldMarketingDuplications(){
    const main = document.querySelector('main');
    if(!main) return;
    main.querySelectorAll('h1,h2,h3,h4,p,span,div').forEach(el => {
      if(el.closest('button')) return;
      if(el.closest('.nexlab-filter-toggle')) return;
      const text = (el.textContent || '').replace(/\s+/g,' ').trim();
      const isMonthOnly = NEXLAB_OLD_MARKETING_MONTH_RE.test(text) && text.length <= 40;
      const isSubtitle = /^visualização\s+mensal\s+de\s+marketing$/i.test(text);
      if((isMonthOnly || isSubtitle) && el.children.length <= 2){
        el.dataset.nexlabMarketingHidden = 'true';
      }
    });
  }

  function findOldMarketingFilterPanel(){
    const main = document.querySelector('main');
    if(!main) return null;
    const nodes = Array.from(main.querySelectorAll('section,article,div'));
    return nodes.find(el => {
      if(el.classList?.contains('nexlab-marketing-filter-panel')) return true;
      const text = (el.textContent || '').replace(/\s+/g,' ').toLowerCase();
      const hasCategories = text.includes('todos') && text.includes('campanhas') && (text.includes('eventos') || text.includes('datas'));
      const hasStatus = text.includes('status') && text.includes('todos');
      return hasCategories && hasStatus && text.length < 700;
    }) || null;
  }

  function setupOldMarketingFilters(){
    const panel = findOldMarketingFilterPanel();
    if(!panel) return;
    panel.classList.add('nexlab-marketing-filter-panel');
    if(panel.previousElementSibling?.classList?.contains('nexlab-filter-toggle')) return;
    document.querySelectorAll('.nexlab-filter-toggle').forEach(el => el.remove());
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'nexlab-filter-toggle';
    btn.innerHTML = '<span class="nexlab-filter-left"><span class="nexlab-filter-icon">☰</span><span class="nexlab-filter-title"><strong>Filtros</strong><small>Mostrar categorias e status</small></span></span><span class="nexlab-filter-chevron">⌄</span>';
    btn.addEventListener('click', () => document.body.classList.toggle('nexlab-filters-open'));
    panel.parentNode.insertBefore(btn, panel);
  }

  function patchMarketingLikeV25_16_3(){
    if(document.body.dataset.nexlabPage !== 'marketing') return;
    const nav = findOldMarketingMonthNavButtons();
    if(nav.center){
      nav.center.textContent = oldMarketingMonthLabel();
      nav.center.setAttribute('aria-label', `Mês selecionado: ${oldMarketingMonthLabel()}`);
      nav.center.classList.add('nexlab-month-button');
    }
    if(nav.left && !nav.left.dataset.nexlabMonthBound){
      nav.left.dataset.nexlabMonthBound = 'true';
      nav.left.addEventListener('click', () => {
        setOldMarketingMonthState(-1);
        setTimeout(run, 40);
      }, true);
    }
    if(nav.right && !nav.right.dataset.nexlabMonthBound){
      nav.right.dataset.nexlabMonthBound = 'true';
      nav.right.addEventListener('click', () => {
        setOldMarketingMonthState(1);
        setTimeout(run, 40);
      }, true);
    }
    hideOldMarketingDuplications();
    setupOldMarketingFilters();
  }


  function getMarketingAgendaItems(){
    const main = document.querySelector('main');
    if(!main) return [];
    const items = [];
    const year = getOldMarketingMonthState?.().year || new Date().getFullYear();
    const month = (getOldMarketingMonthState?.().month ?? new Date().getMonth()) + 1;
    const datePatterns = [
      /\b(0?[1-9]|[12]\d|3[01])\/(0?[1-9]|1[0-2])(?:\/(20\d{2}))?\b/g,
      /\b(20\d{2})-(0?[1-9]|1[0-2])-(0?[1-9]|[12]\d|3[01])\b/g
    ];
    const candidates = Array.from(main.querySelectorAll('article, li, tr, .card, [class*="rounded"], [class*="shadow"]'))
      .filter(el => !el.closest('.nexlab-marketing-agenda-board') && !el.closest('.nexlab-filter-toggle') && !el.closest('.nexlab-marketing-filter-panel'));
    candidates.forEach(el => {
      const text = (el.textContent || '').replace(/\s+/g,' ').trim();
      if(!text || text.length < 8 || text.length > 900) return;
      let found = [];
      for(const pattern of datePatterns){
        pattern.lastIndex = 0;
        let m;
        while((m = pattern.exec(text))){
          if(pattern.source.startsWith('\\b(0?')){
            const d = Number(m[1]), mo = Number(m[2]), y = Number(m[3] || year);
            found.push({day:d, month:mo, year:y});
          }else{
            const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]);
            found.push({day:d, month:mo, year:y});
          }
        }
      }
      found.forEach(dt => {
        if(dt.year !== year || dt.month !== month || dt.day < 1 || dt.day > 31) return;
        const titleNode = el.querySelector('h1,h2,h3,h4,strong,b,[class*="font-bold"],[class*="font-extrabold"]');
        let title = (titleNode?.textContent || text).replace(/\s+/g,' ').trim();
        title = title.replace(/\b(0?[1-9]|[12]\d|3[01])\/(0?[1-9]|1[0-2])(?:\/(20\d{2}))?\b/g,'').replace(/\b(20\d{2})-(0?[1-9]|1[0-2])-(0?[1-9]|[12]\d|3[01])\b/g,'').trim();
        if(title.length > 64) title = title.slice(0,61).trim() + '...';
        const status = /publicad/i.test(text) ? 'Publicado' : /agendad/i.test(text) ? 'Agendado' : /revis/i.test(text) ? 'Revisão' : /rascunh/i.test(text) ? 'Rascunho' : 'Campanha';
        items.push({day:dt.day, title:title || 'Campanha', status});
      });
    });
    const seen = new Set();
    return items.filter(item => {
      const key = `${item.day}|${item.title}|${item.status}`;
      if(seen.has(key)) return false;
      seen.add(key);
      return true;
    }).slice(0,60);
  }

  function buildMarketingAgendaCells(year, monthIndex, items){
    const first = new Date(year, monthIndex, 1);
    const daysInMonth = new Date(year, monthIndex + 1, 0).getDate();
    const firstWeekday = first.getDay(); // 0 domingo
    const mondayIndex = (firstWeekday + 6) % 7;
    const prevDays = new Date(year, monthIndex, 0).getDate();
    const cells = [];
    for(let i=0;i<42;i++){
      const raw = i - mondayIndex + 1;
      let day = raw, muted = false, dateMonth = monthIndex, dateYear = year;
      if(raw < 1){
        day = prevDays + raw;
        muted = true;
        dateMonth = monthIndex - 1;
        if(dateMonth < 0){ dateMonth = 11; dateYear--; }
      }else if(raw > daysInMonth){
        day = raw - daysInMonth;
        muted = true;
        dateMonth = monthIndex + 1;
        if(dateMonth > 11){ dateMonth = 0; dateYear++; }
      }
      const dayItems = muted ? [] : items.filter(item => item.day === day);
      cells.push({day, muted, today: !muted && day === new Date().getDate() && monthIndex === new Date().getMonth() && year === new Date().getFullYear(), items: dayItems});
    }
    return cells;
  }

  function cleanupAgendaDuplicateTables(){
    if (document.body.dataset.nexlabPage === 'agenda') {
      document.querySelectorAll('main .nexlab-marketing-agenda-board').forEach(el => el.remove());
      const main = document.querySelector('main');
      if (!main) return;
      const candidates = Array.from(main.querySelectorAll('section, article, div')).filter(el => {
        if (el.closest('[data-nexlab-agenda-duplicate-hidden="true"]')) return false;
        const text = (el.textContent || '').replace(/\s+/g,' ').toLowerCase();
        const weekdays = ['seg','ter','qua','qui','sex','sáb','dom'].filter(day => text.includes(day)).length;
        const hasAgendaTitle = text.includes('agenda integrada') || text.includes('visualização mensal');
        return weekdays >= 5 && hasAgendaTitle && text.length > 180;
      });
      const roots = candidates.filter(el => !candidates.some(other => other !== el && other.contains(el)));
      roots.slice(1).forEach(el => {
        el.dataset.nexlabAgendaDuplicateHidden = 'true';
        el.style.display = 'none';
      });
    }
  }

  function ensureMarketingAgendaTable(){
    if(document.body.dataset.nexlabPage !== 'marketing') { document.querySelectorAll('main .nexlab-marketing-agenda-board').forEach(el => el.remove()); return; }
    const main = document.querySelector('main');
    if(!main) return;

    let board = main.querySelector('.nexlab-marketing-agenda-board');
    if(!board){
      board = document.createElement('section');
      board.className = 'nexlab-marketing-agenda-board';
      board.setAttribute('aria-label','Tabela de visualização mensal de marketing');
      const anchor = document.querySelector('.nexlab-filter-toggle') || document.querySelector('.nexlab-marketing-filter-panel') || Array.from(main.querySelectorAll('.filter-toolbar')).at(-1);
      if(anchor && anchor.parentNode){
        const filterPanel = document.querySelector('.nexlab-marketing-filter-panel');
        if(filterPanel) filterPanel.insertAdjacentElement('afterend', board);
        else anchor.insertAdjacentElement('afterend', board);
      }else{
        main.appendChild(board);
      }
    }

    const state = getOldMarketingMonthState?.() || {month:new Date().getMonth(), year:new Date().getFullYear()};
    const items = getMarketingAgendaItems();
    const cells = buildMarketingAgendaCells(state.year, state.month, items);
    const monthName = NEXLAB_OLD_MARKETING_MONTHS?.[state.month] || 'Mês';
    board.innerHTML = `
      <div class="nexlab-marketing-agenda-head">
        <button type="button" class="nexlab-mkt-agenda-prev" aria-label="Mês anterior">‹</button>
        <div class="nexlab-marketing-agenda-title">
          <strong>${monthName} de ${state.year}</strong>
          <span>Visualização mensal de campanhas, publicações e pendências</span>
        </div>
        <button type="button" class="nexlab-mkt-agenda-next" aria-label="Próximo mês">›</button>
      </div>
      <div class="nexlab-marketing-agenda-table" role="table" aria-label="Calendário editorial de marketing">
        <div class="nexlab-marketing-agenda-weekdays" role="row">
          ${['SEG','TER','QUA','QUI','SEX','SÁB','DOM'].map(day => `<div role="columnheader">${day}</div>`).join('')}
        </div>
        <div class="nexlab-marketing-agenda-grid" role="rowgroup">
          ${cells.map(cell => `
            <div class="nexlab-marketing-agenda-cell ${cell.muted ? 'is-muted' : ''} ${cell.today ? 'is-today' : ''}" role="cell">
              <div class="nexlab-marketing-agenda-day">${cell.day}</div>
              <div class="nexlab-marketing-agenda-items">
                ${cell.items.slice(0,3).map(item => `<span class="nexlab-marketing-agenda-item" data-status="${item.status}"><b>${item.title}</b><small>${item.status}</small></span>`).join('')}
                ${cell.items.length > 3 ? `<span class="nexlab-marketing-agenda-more">+${cell.items.length - 3} item(ns)</span>` : ''}
              </div>
            </div>
          `).join('')}
        </div>
      </div>
    `;
    board.querySelector('.nexlab-mkt-agenda-prev')?.addEventListener('click', () => {
      setOldMarketingMonthState(-1);
      setTimeout(run, 30);
    });
    board.querySelector('.nexlab-mkt-agenda-next')?.addEventListener('click', () => {
      setOldMarketingMonthState(1);
      setTimeout(run, 30);
    });
  }

  let scheduled = false;
  function run(){
    scheduled = false;
    markPage();
    cleanupAgendaDuplicateTables();
    patchMarketingLikeV25_16_3();
    ensureMarketingAgendaTable();
    ensureOfflineToast();
    ensureHelpLauncher();
  }
  function schedule(){
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(run);
  }

  window.nexlabShowModal = window.nexlabShowModal || function(options){ return new Promise(resolve => openStandardModal(Object.assign({}, options || {}, { resolve }))); };
  window.addEventListener('nexlab:modal', (event) => openStandardModal(event.detail || {}));
  window.addEventListener('nexlab:connection-error', (event) => showConnectionError(event.detail || {}));
  window.addEventListener('nexlab:connection-restored', hideConnectionError);
  window.addEventListener('offline', ensureOfflineToast);
  window.addEventListener('online', ensureOfflineToast);
  window.addEventListener('click', (event) => markClickedActionButton(event.target), true);
  window.addEventListener('nexlab:action-start', () => { activeActions += 1; setActionLoading(true); });
  window.addEventListener('nexlab:action-end', () => { activeActions = Math.max(0, activeActions - 1); if (activeActions === 0) window.setTimeout(() => setActionLoading(false), 180); });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { run(); warmOfflineCache(); maybeAutoShowOnboarding(); setupServiceWorkerUpdateButton(); }, { once: true });
  else { run(); warmOfflineCache(); maybeAutoShowOnboarding(); setupServiceWorkerUpdateButton(); }
  new MutationObserver(schedule).observe(document.getElementById('root') || document.body, { childList: true, subtree: true });
})();
