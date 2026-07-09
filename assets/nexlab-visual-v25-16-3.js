(function(){
  if (window.__NEXLAB_V25_16_3_PROD__) return;
  window.__NEXLAB_V25_16_3_PROD__ = true;

  const BRAND = {
    light: './brand/nexlab-logo-light.png?v=logo-fix-r1',
    dark: './brand/nexlab-logo-dark.png?v=logo-fix-r1',
    icon: './brand/nexlab-icon.png?v=logo-fix-r1',
    favicon: './icons/nexlab-favicon-rounded.png?v=logo-fix-r1'
  };
  const MONTHS = ['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'];
  const MONTH_INDEX = MONTHS.reduce((acc, name, idx) => {
    acc[name.toLowerCase()] = idx;
    acc[name.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase()] = idx;
    return acc;
  }, {});
  const MONTH_RE = /\b(Janeiro|Fevereiro|Março|Marco|Abril|Maio|Junho|Julho|Agosto|Setembro|Outubro|Novembro|Dezembro)\s+(20\d{2}|19\d{2})\b/i;

  function normalizeName(root=document.body){
    if(!root) return;
    document.title = 'NEXLAB';
    document.querySelector('meta[name="application-name"]')?.setAttribute('content','NEXLAB');
    document.querySelector('meta[name="apple-mobile-web-app-title"]')?.setAttribute('content','NEXLAB');
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node){
        const p = node.parentElement;
        if(!p || ['SCRIPT','STYLE','TEXTAREA','INPUT'].includes(p.tagName)) return NodeFilter.FILTER_REJECT;
        return /NexLab v25\.16\.3|NEXLAB v25\.16\.3|NexLab v25\.16\.2|NEXLAB v25\.16\.2|NexLab/.test(node.nodeValue||'') ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      }
    });
    const nodes=[];
    while(walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(node => {
      node.nodeValue = node.nodeValue
        .replace(/NexLab v25\.16\.3/g,'NEXLAB')
        .replace(/NEXLAB v25\.16\.3/g,'NEXLAB')
        .replace(/NexLab v25\.16\.2/g,'NEXLAB')
        .replace(/NEXLAB v25\.16\.2/g,'NEXLAB')
        .replace(/NexLab/g,'NEXLAB');
    });
  }


  function looksAvatar(el){
    if(!el) return false;
    const alt = el.alt || '';
    const src = el.getAttribute('src') || '';
    const cls = el.getAttribute('class') || '';
    const aria = el.getAttribute('aria-label') || '';
    const joined = `${alt} ${src} ${cls} ${aria}`.toLowerCase();
    if(/avatar|perfil|profile|usu[aá]rio|user|foto/.test(joined)) return true;
    if(el.closest('[class*="avatar" i], [class*="profile" i], [class*="perfil" i], [data-avatar], [data-profile]')) return true;
    const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : {width:0,height:0};
    const w = rect.width || el.naturalWidth || el.width || 0;
    const h = rect.height || el.naturalHeight || el.height || 0;
    const rounded = /rounded-full|rounded\-\[9999px\]/.test(cls) || (Math.abs(w-h) <= 8 && w > 24 && w < 96 && h > 24 && h < 96);
    if(rounded && (el.closest('header') || el.closest('button') || el.closest('nav'))) return true;
    if((el.closest('header, nav, [role="banner"]') || el.closest('button')) && w >= 24 && w <= 96 && h >= 24 && h <= 96) return true;
    return false;
  }
  function useDarkLogo(el){
    if(isSidebar(el)) return true;
    if(el?.closest?.('[class*="bg-blue-dark" i], [class*="bg-slate-900" i], [class*="bg-slate-950" i], [class*="bg-black" i]')) return true;
    const mainText = (document.querySelector('main')?.textContent || '').toLowerCase();
    if(mainText.includes('acesse seu painel') && el?.closest?.('main,section,div')) return true;
    return false;
  }
  function refreshFavicon(){
    document.querySelectorAll('link[rel="icon"]').forEach(link => link.setAttribute('href', BRAND.favicon));
  }

  function isSidebar(el){
    return !!el?.closest?.('#mobile-sidebar, aside#mobile-sidebar, aside, [id*="sidebar" i], [class*="sidebar" i]');
  }
  function scoreImage(img){
    const rect = img.getBoundingClientRect ? img.getBoundingClientRect() : {width:0,height:0};
    const w = rect.width || img.naturalWidth || img.width || 0;
    const h = rect.height || img.naturalHeight || img.height || 0;
    return w*h;
  }
  function applyLogos(){
    document.querySelectorAll('img').forEach(img => {
      if(looksAvatar(img)) return;
      const alt = img.alt || '';
      const src = img.getAttribute('src') || '';
      const cls = img.getAttribute('class') || '';
      const looksLogo = /nexlab|logo|brand/i.test(alt + ' ' + src + ' ' + cls);
      if(!looksLogo) return;
      const inSidebar = isSidebar(img);
      const isSmallSymbol = /(^|\s)(w-16|h-16|w-14|h-14|w-12|h-12)(\s|$)/.test(cls) && !/w-auto/.test(cls);
      img.alt = 'NEXLAB';
      img.referrerPolicy = 'no-referrer';
      img.removeAttribute('srcset');
      img.src = useDarkLogo(img) ? BRAND.dark : (isSmallSymbol ? BRAND.icon : BRAND.light);
      img.style.objectFit = 'contain';
      if(inSidebar){
        img.classList.add('nexlab-sidebar-logo');
        img.style.width = '154px';
        img.style.height = 'auto';
        img.style.maxWidth = '82%';
      }
    });

    const sidebars = Array.from(document.querySelectorAll('#mobile-sidebar, aside#mobile-sidebar, aside, [id*="sidebar" i], [class*="sidebar" i]'))
      .filter(el => /dashboard|marketing|sa[úu]de/i.test(el.textContent || ''));
    sidebars.forEach(sidebar => {
      const imgs = Array.from(sidebar.querySelectorAll('img')).filter(img => !looksAvatar(img));
      if(!imgs.length) return;
      const target = imgs.sort((a,b)=>scoreImage(b)-scoreImage(a))[0];
      target.alt = 'NEXLAB';
      target.src = BRAND.dark;
      target.removeAttribute('srcset');
      target.classList.add('nexlab-sidebar-logo');
      target.style.objectFit = 'contain';
      target.style.width = '154px';
      target.style.height = 'auto';
      target.style.maxWidth = '82%';
    });

    refreshFavicon();
  }

  function currentTopText(){
    const header = document.querySelector('header.sticky span.font-semibold, header span.font-semibold, header h1')?.textContent || '';
    const h1 = document.querySelector('main h1, main .module-title')?.textContent || '';
    return `${header} ${h1} ${(document.querySelector('main')?.textContent || '').slice(0,800)}`.toLowerCase();
  }
  function markPage(){
    const text = currentTopText();
    let page = 'claro';
    if(text.includes('dashboard')) page='dashboard';
    else if(text.includes('marketing')) page='marketing';
    else if(text.includes('perfil')) page='perfil';
    else if(text.includes('notifica')) page='notificacoes';
    else if(text.includes('usu')) page='usuarios';
    else if(text.includes('permiss')) page='permissoes';
    else if(text.includes('relat')) page='relatorios';
    document.body.dataset.nexlabPage = page;
  }

  function normalizeMonthLabel(text){
    const m = String(text||'').replace(/\s+/g,' ').trim().match(MONTH_RE);
    if(!m) return '';
    const raw = m[1].replace(/^Marco$/i,'Março');
    const idx = MONTH_INDEX[raw.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase()];
    return `${MONTHS[idx ?? new Date().getMonth()]} ${m[2]}`;
  }
  function detectMonthFromDom(){
    const main = document.querySelector('main') || document.body;
    const candidates = Array.from(main.querySelectorAll('h1,h2,h3,h4,p,span,button,div'));
    for(const el of candidates){
      if(el.closest('.nexlab-filter-toggle')) continue;
      if(el.classList?.contains('nexlab-month-button')) continue;
      const text = (el.textContent || '').replace(/\s+/g,' ').trim();
      if(text.length > 40) continue;
      const label = normalizeMonthLabel(text);
      if(label) return label;
    }
    const d = new Date();
    return `${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
  }
  function getMonthState(){
    if(!window.__nexlabMarketingMonthState){
      const label = detectMonthFromDom();
      const m = label.match(MONTH_RE);
      const month = MONTH_INDEX[(m?.[1] || '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase()];
      window.__nexlabMarketingMonthState = { month: month ?? new Date().getMonth(), year: Number(m?.[2] || new Date().getFullYear()) };
    }
    return window.__nexlabMarketingMonthState;
  }
  function setMonthState(offset){
    const st = getMonthState();
    let month = st.month + offset;
    let year = st.year;
    while(month < 0){ month += 12; year--; }
    while(month > 11){ month -= 12; year++; }
    window.__nexlabMarketingMonthState = { month, year };
    return `${MONTHS[month]} ${year}`;
  }
  function monthLabel(){
    const st = getMonthState();
    return `${MONTHS[st.month]} ${st.year}`;
  }

  function findMonthNavButtons(){
    const main = document.querySelector('main');
    if(!main) return {left:null, center:null, right:null};
    const buttons = Array.from(main.querySelectorAll('button'));
    let center = buttons.find(btn => /^Hoje$/i.test((btn.textContent || '').trim())) || buttons.find(btn => btn.classList.contains('nexlab-month-button'));
    if(!center){
      center = buttons.find(btn => MONTH_RE.test(btn.textContent || ''));
    }
    if(!center) return {left:null, center:null, right:null};
    const row = center.closest('div, section, article') || main;
    const rowButtons = Array.from(row.querySelectorAll('button'));
    const idx = rowButtons.indexOf(center);
    return { left: rowButtons[idx-1] || null, center, right: rowButtons[idx+1] || null };
  }
  function hideMarketingDuplications(){
    const main = document.querySelector('main');
    if(!main) return;
    main.querySelectorAll('h1,h2,h3,h4,p,span,div').forEach(el => {
      if(el.closest('button')) return;
      if(el.closest('.nexlab-filter-toggle')) return;
      const text = (el.textContent || '').replace(/\s+/g,' ').trim();
      const isMonthOnly = MONTH_RE.test(text) && text.length <= 40;
      const isSubtitle = /^visualização\s+mensal\s+de\s+marketing$/i.test(text);
      if((isMonthOnly || isSubtitle) && el.children.length <= 2){
        el.dataset.nexlabMarketingHidden = 'true';
      }
    });
  }
  function findFilterPanel(){
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
  function setupFilters(){
    const panel = findFilterPanel();
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
  function patchMarketing(){
    if(document.body.dataset.nexlabPage !== 'marketing') return;
    const nav = findMonthNavButtons();
    if(nav.center){
      nav.center.textContent = monthLabel();
      nav.center.setAttribute('aria-label', `Mês selecionado: ${monthLabel()}`);
      nav.center.classList.add('nexlab-month-button');
    }
    if(nav.left && !nav.left.dataset.nexlabMonthBound){
      nav.left.dataset.nexlabMonthBound = 'true';
      nav.left.addEventListener('click', () => {
        setMonthState(-1);
        setTimeout(run, 40);
      }, true);
    }
    if(nav.right && !nav.right.dataset.nexlabMonthBound){
      nav.right.dataset.nexlabMonthBound = 'true';
      nav.right.addEventListener('click', () => {
        setMonthState(1);
        setTimeout(run, 40);
      }, true);
    }
    hideMarketingDuplications();
    setupFilters();
  }

  let scheduled = false;
  function run(){
    scheduled = false;
    normalizeName();
    markPage();
    applyLogos();
    patchMarketing();
  }
  function schedule(){
    if(scheduled) return;
    scheduled = true;
    requestAnimationFrame(run);
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, {once:true}); else run();
  new MutationObserver(schedule).observe(document.getElementById('root') || document.body, {childList:true, subtree:true, attributes:true});
})();