(function(){
  'use strict';

  const GLOBAL_KEY='__NEXLAB_ACTIVITIES_PHASE4__';
  const VERSION='26.29.9';
  if(window[GLOBAL_KEY]?.version===VERSION) return;
  try{window[GLOBAL_KEY]?.destroy?.();}catch{}
  const PROJECT_REF='eahldhabwulnwhuwrhvc';
  const BASE_URL=(window.__NEXLAB_CONFIG__?.supabaseUrl||`https://${PROJECT_REF}.supabase.co`).replace(/\/$/,'');
  const ANON_KEY=window.__NEXLAB_CONFIG__?.supabaseAnonKey||'sb_publishable_hr-WTQUBbBE0Ei3Lr2hkhQ_XSKG_PXa';
  const PREF_KEY='nexlab:activities-phase4-preferences';
  const PAGE_SIZES=[10,25,50,100];

  const state={
    active:false,
    root:null,
    legacy:null,
    routeObserver:null,
    routeCheckTimer:null,
    mountRetryTimer:null,
    mountRetryCount:0,
    connectTimer:null,
    activation:0,
    loadSequence:0,
    channel:null,
    pollTimer:null,
    refreshTimer:null,
    searchTimer:null,
    loading:false,
    queuedLoad:false,
    page:1,
    pageSize:25,
    selected:new Set(),
    data:null,
    lastUpdated:null,
    pendingRealtime:0,
    realtimeStatus:'connecting',
    filtersExpanded:true,
    density:'comfortable',
    filters:{source:'all',module:'',action:'',actor:'',dateFrom:'',dateTo:'',search:''}
  };

  const moduleLabels={
    users:'Usuários',permissions:'Permissões',projects:'Projetos',teams:'Equipes',events:'Eventos',meetings:'Reuniões',
    reservations:'Reservas',assets:'Patrimônio',stock:'Estoque',marketing:'Marketing',mural:'Mural',feedback:'Feedback',
    reports:'Relatórios',activity:'Central de Atividades',security:'Segurança',system:'Sistema'
  };
  const moduleIcons={
    users:'users',permissions:'shield',projects:'folder',teams:'team',events:'calendar',meetings:'meeting',
    reservations:'clock',assets:'box',stock:'archive',marketing:'megaphone',mural:'message',feedback:'feedback',
    reports:'report',activity:'activity',security:'lock',system:'system'
  };
  const actionKindLabels={created:'Criação',updated:'Alteração',deleted:'Exclusão',exported:'Exportação',activity:'Atividade'};
  const actionTitles={
    project_created:'Projeto criado',project_updated:'Projeto atualizado',project_deleted:'Projeto excluído',
    task_created:'Tarefa criada',task_updated:'Tarefa atualizada',task_completed:'Tarefa concluída',task_reopened:'Tarefa reaberta',task_deleted:'Tarefa excluída',
    team_created:'Equipe criada',team_updated:'Equipe atualizada',team_archived:'Equipe arquivada',team_restored:'Equipe restaurada',team_deleted:'Equipe excluída',
    team_member_added:'Integrante adicionado',team_member_removed:'Integrante removido',team_member_role_updated:'Função de integrante alterada',team_responsibility_transferred:'Responsabilidade transferida',team_link_created:'Vínculo de equipe criado',team_link_removed:'Vínculo de equipe removido',
    event_created:'Evento criado',event_updated:'Evento atualizado',event_deleted:'Evento excluído',
    meeting_created:'Reunião criada',meeting_updated:'Reunião atualizada',meeting_cancelled:'Reunião cancelada',meeting_deleted:'Reunião excluída',meeting_participants_replaced:'Participantes da reunião atualizados',
    reservation_created:'Reserva criada',reservation_updated:'Reserva atualizada',reservation_approved:'Reserva aprovada',reservation_rejected:'Reserva recusada',reservation_cancelled:'Reserva cancelada',reservation_deleted:'Reserva excluída',reservation_participants_replaced:'Participantes da reserva atualizados',
    marketing_created:'Campanha criada',marketing_updated:'Campanha atualizada',marketing_status_updated:'Status da campanha alterado',marketing_deleted:'Campanha excluída',
    asset_created:'Bem patrimonial criado',asset_updated:'Bem patrimonial atualizado',asset_condition_updated:'Condição patrimonial alterada',asset_deleted:'Bem patrimonial excluído',
    stock_item_created:'Item de estoque criado',stock_item_updated:'Item de estoque atualizado',stock_item_deleted:'Item de estoque excluído',
    post_created:'Publicação criada',post_updated:'Publicação atualizada',post_deleted:'Publicação excluída',
    feedback_created:'Feedback enviado',feedback_updated:'Feedback atualizado',feedback_status_updated:'Status do feedback alterado',
    user_created:'Usuário criado',user_updated:'Usuário atualizado',user_deleted:'Usuário excluído',user_access_updated:'Acesso de usuário atualizado',user_deactivated:'Usuário desativado',user_reactivated:'Usuário reativado',
    profile_admin_managed:'Cadastro de usuário gerenciado',profile_request_approved:'Solicitação de perfil aprovada',profile_request_rejected:'Solicitação de perfil recusada',profile_request_cancelled:'Solicitação de perfil cancelada',profile_request_resubmitted:'Solicitação de perfil reenviada',profile_registration_submitted:'Cadastro de perfil enviado',
    role_permissions_updated:'Permissões do perfil atualizadas',user_permissions_updated:'Permissões individuais atualizadas',
    detailed_user_report_pdf:'Relatório sensível em PDF gerado',detailed_user_report_excel:'Relatório sensível em Excel gerado',sensitive_user_report_accessed:'Relatório sensível acessado',report_export_recorded:'Exportação registrada',
    privacy_documents_accepted:'Documentos de privacidade aceitos',optional_consent_granted:'Consentimento opcional concedido',optional_consent_revoked:'Consentimento opcional revogado',privacy_request_created:'Solicitação de privacidade criada',privacy_request_status_updated:'Solicitação de privacidade atualizada',
    profile_avatar_updated:'Foto de perfil atualizada',profile_avatar_removed:'Foto de perfil removida',own_profile_updated:'Perfil atualizado',own_sensitive_profile_updated:'Dados pessoais atualizados',
    activity_logs_bulk_deleted:'Registros operacionais excluídos',security_retention_applied:'Política de retenção aplicada'
  };
  const metadataLabels={
    operation:'Operação',table_name:'Tabela',changed_fields:'Campos alterados',activity_version:'Versão do registro',module:'Módulo',reason:'Motivo',review_reason:'Motivo da análise',previous_status:'Status anterior',new_status:'Novo status',previous_role:'Perfil anterior',next_role:'Novo perfil',previous_active:'Ativo anteriormente',next_active:'Ativo atualmente',deleted_count:'Quantidade excluída',removed_overrides:'Exceções removidas',changed_count:'Alterações',reservation_date:'Data da reserva',start_time:'Hora inicial',end_time:'Hora final',entity_id:'ID do registro',project_id:'ID do projeto',team_id:'ID da equipe',reservation_id:'ID da reserva',meeting_id:'ID da reunião',target_index:'Posição de destino',kanban_order:'Ordem no Kanban',consent_type:'Tipo de consentimento',version:'Versão',source:'Origem',atomic:'Transação atômica',devicesAttempted:'Dispositivos tentados',devicesAccepted:'Dispositivos aceitos'
  };

  function icon(name,size=18){
    const common=`width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"`;
    const paths={
      activity:'<path d="M4 6h16M4 12h16M4 18h10"/><circle cx="18" cy="18" r="2"/>',
      search:'<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
      refresh:'<path d="M20 6v5h-5"/><path d="M4 18v-5h5"/><path d="M6.1 9A7 7 0 0 1 18 6l2 5M4 13l2 5a7 7 0 0 0 11.9-3"/>',
      filter:'<path d="M4 5h16l-6 7v5l-4 2v-7z"/>',
      chevron:'<path d="m9 18 6-6-6-6"/>',
      left:'<path d="m15 18-6-6 6-6"/>',
      first:'<path d="M6 5v14M18 6l-6 6 6 6"/>',
      last:'<path d="M18 5v14M6 6l6 6-6 6"/>',
      lock:'<rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
      trash:'<path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5"/>',
      close:'<path d="m6 6 12 12M18 6 6 18"/>',
      copy:'<rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/>',
      check:'<path d="m5 12 4 4L19 6"/>',
      users:'<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/>',
      shield:'<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10"/><path d="m9 12 2 2 4-4"/>',
      folder:'<path d="M3 6h6l2 2h10v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
      team:'<circle cx="8" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M2 20v-2a5 5 0 0 1 10 0v2M13 20v-1a4 4 0 0 1 8 0v1"/>',
      calendar:'<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/>',
      meeting:'<path d="M4 4h16v12H7l-3 3z"/><path d="M8 9h8M8 12h5"/>',
      clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
      box:'<path d="m21 8-9 5-9-5 9-5z"/><path d="m3 8 9 5 9-5v9l-9 5-9-5zM12 13v9"/>',
      archive:'<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v11h14V9M9 13h6"/>',
      megaphone:'<path d="m3 11 14-6v14L3 13zM11 16l1 5H8l-2-7"/><path d="M19 9a3 3 0 0 1 0 6"/>',
      message:'<path d="M21 15a4 4 0 0 1-4 4H8l-5 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z"/>',
      feedback:'<path d="M4 4h16v13H8l-4 3z"/><path d="M8 9h8M8 13h5"/>',
      report:'<path d="M6 2h9l4 4v16H6z"/><path d="M14 2v5h5M9 12h6M9 16h6"/>',
      system:'<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 .6 1.7 1.7 0 0 0-.4 1.1V21h-4v-.09A1.7 1.7 0 0 0 8.6 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-.6-1 1.7 1.7 0 0 0-1.1-.4H3v-4h.09A1.7 1.7 0 0 0 4.6 8.6a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.83-2.83.06.06A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-.6 1.7 1.7 0 0 0 .4-1.1V3h4v.09A1.7 1.7 0 0 0 15.4 4.6a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.4 9c.15.37.37.7.67.96.3.26.68.4 1.08.4H21v4h-.09A1.7 1.7 0 0 0 19.4 15z"/>'
    };
    return `<svg ${common}>${paths[name]||paths.activity}</svg>`;
  }

  function escapeHtml(value){return String(value??'').replace(/[&<>'"]/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char]));}
  function normalizeText(value){return String(value||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().trim();}
  function isTypingTarget(target){return !!target?.closest?.('input,textarea,select,[contenteditable="true"]');}
  function safeJson(value){try{return JSON.stringify(value,null,2);}catch{return String(value);}}
  function truncate(value,max=320){const text=String(value??'');return text.length>max?`${text.slice(0,max)}…`:text;}
  function readPreferences(){
    try{
      const value=JSON.parse(localStorage.getItem(PREF_KEY)||'{}');
      if(PAGE_SIZES.includes(Number(value.pageSize))) state.pageSize=Number(value.pageSize);
      if(['comfortable','compact'].includes(value.density)) state.density=value.density;
      if(typeof value.filtersExpanded==='boolean') state.filtersExpanded=value.filtersExpanded;
    }catch{}
  }
  function savePreferences(){
    try{localStorage.setItem(PREF_KEY,JSON.stringify({pageSize:state.pageSize,density:state.density,filtersExpanded:state.filtersExpanded}));}catch{}
  }
  function token(){
    const candidates=[`sb-${PROJECT_REF}-auth-token`,...Object.keys(localStorage).filter(key=>key.includes(PROJECT_REF)&&key.includes('auth-token'))];
    for(const key of candidates){
      try{
        const parsed=JSON.parse(localStorage.getItem(key)||'null');
        const value=parsed?.access_token||parsed?.currentSession?.access_token||parsed?.session?.access_token;
        if(value) return value;
      }catch{}
    }
    return null;
  }
  async function rpc(name,body={}){
    const client=window.__NEXLAB_SUPABASE__;
    if(client?.rpc){
      const {data,error}=await client.rpc(name,body);
      if(error) throw error;
      return data;
    }
    const access=token();
    if(!access) throw new Error('Sessão autenticada não localizada. Recarregue o aplicativo.');
    const response=await fetch(`${BASE_URL}/rest/v1/rpc/${name}`,{
      method:'POST',cache:'no-store',headers:{apikey:ANON_KEY,Authorization:`Bearer ${access}`,'Content-Type':'application/json','Cache-Control':'no-cache'},body:JSON.stringify(body)
    });
    const text=await response.text();let data=null;try{data=text?JSON.parse(text):null;}catch{data=text;}
    if(!response.ok){const error=new Error(data?.message||data?.hint||`Falha ${response.status}`);error.code=data?.code;error.details=data?.details;throw error;}
    return data;
  }
  function toast(message,tone='info'){
    if(typeof window.nexlabToast==='function') return window.nexlabToast(message,tone);
    const element=document.createElement('div');
    element.className='nexlab-a4-toast';element.dataset.tone=tone;element.setAttribute('role','status');element.textContent=message;
    document.body.appendChild(element);setTimeout(()=>element.remove(),6000);
  }
  function visible(element){
    if(!element)return false;const style=getComputedStyle(element),rect=element.getBoundingClientRect();
    return style.display!=='none'&&style.visibility!=='hidden'&&rect.width>0&&rect.height>0;
  }
  function findLegacy(){
    const currentPage=document.body?.dataset?.nexlabPage||'';
    if(currentPage&&currentPage!=='claro'&&currentPage!=='logs') return null;
    const managed=document.querySelector('.module-shell[data-nexlab-activities-legacy="true"]');
    if(managed&&currentPage==='logs') return managed;
    return [...document.querySelectorAll('.module-shell')].find(element=>{
      if(element.closest('[data-nexlab-activities-phase4="true"]')) return false;
      if(!visible(element)) return false;
      const text=normalizeText(element.textContent);
      return text.includes('central de atividades')&&(text.includes('registros encontrados')||text.includes('auditoria e rastreabilidade')||text.includes('atividade'));
    })||null;
  }
  function isLogsScreen(){return !!findLegacy();}
  function formatDate(value){
    const date=new Date(value);if(Number.isNaN(date.getTime()))return 'Data não informada';
    return date.toLocaleString('pt-BR',{day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit'}).replace('.','');
  }
  function formatTime(value){
    const date=value instanceof Date?value:new Date(value);if(Number.isNaN(date.getTime()))return '—';
    return date.toLocaleTimeString('pt-BR',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
  }
  function actionTitle(row){
    if(actionTitles[row.action_key])return actionTitles[row.action_key];
    return String(row.action_key||row.raw_action||'Atividade registrada').replace(/_/g,' ').replace(/\b\w/g,char=>char.toUpperCase());
  }
  function kindTone(kind){return ({created:'green',updated:'amber',deleted:'red',exported:'blue',activity:'slate'})[kind]||'slate';}
  function friendlyDescription(row){
    const raw=String(row.description||'').trim();
    if(raw&&raw!=='Registro protegido de auditoria.'&&raw!==row.entity_name)return raw;
    const entity=row.entity_name?` em “${row.entity_name}”`:'';
    return `${actionTitle(row)}${entity}.`;
  }
  function humanMetadataValue(value){
    if(typeof value==='boolean')return value?'Sim':'Não';
    if(Array.isArray(value))return value.length?value.map(item=>typeof item==='object'?safeJson(item):String(item)).join(', '):'Nenhum';
    if(value&&typeof value==='object')return safeJson(value);
    return String(value??'—');
  }
  function metadataEntries(row){
    const metadata=row.metadata&&typeof row.metadata==='object'?row.metadata:{};
    const hidden=new Set(['previous_hash','integrity_hash','fingerprint','actor_email','actor_name','legacy_record','legacy_action','legacy_entity']);
    const entries=Object.entries(metadata).filter(([key,value])=>!hidden.has(key)&&value!==null&&value!==''&&!(Array.isArray(value)&&value.length===0));
    return entries.slice(0,30);
  }
  function activeFilterCount(){
    return Object.entries(state.filters).filter(([key,value])=>key==='source'?value&&value!=='all':Boolean(value)).length;
  }
  function currentPageRows(){return state.data?.rows||[];}
  function selectedCurrentRows(){const ids=state.selected;return currentPageRows().filter(row=>ids.has(String(row.id)));}

  function shell(){
    return `
      <section class="nexlab-a4" data-nexlab-activities-phase4="true" data-density="${escapeHtml(state.density)}" aria-labelledby="nexlab-a4-title">
        <a class="nexlab-a4-skip" href="#nexlab-a4-feed">Ir para os registros</a>
        <header class="nexlab-a4-hero">
          <div class="nexlab-a4-hero-icon">${icon('activity',24)}</div>
          <div class="nexlab-a4-hero-copy">
            <span>Auditoria e rastreabilidade</span>
            <h1 id="nexlab-a4-title">Central de Atividades</h1>
            <p>Histórico consolidado das operações do NEXLAB, com auditorias protegidas, filtros no servidor e atualização em tempo real.</p>
          </div>
          <div class="nexlab-a4-status-area">
            <div class="nexlab-a4-live" data-role="live" data-status="connecting"><i></i><span>Conectando</span></div>
            <small data-role="last-updated">Ainda não atualizado</small>
          </div>
        </header>

        <div class="nexlab-a4-announcer" data-role="announcer" aria-live="polite" aria-atomic="true"></div>
        <div class="nexlab-a4-network" data-role="network" hidden>${icon('system',16)}<span></span></div>
        <div class="nexlab-a4-metrics" data-role="metrics" aria-label="Resumo dos registros"></div>

        <section class="nexlab-a4-toolbar" aria-label="Controles da Central de Atividades">
          <div class="nexlab-a4-toolbar-top">
            <div class="nexlab-a4-search">
              ${icon('search',18)}
              <label class="sr-only" for="nexlab-a4-search-input">Pesquisar atividades</label>
              <input id="nexlab-a4-search-input" type="search" data-filter="search" placeholder="Pesquisar ação, módulo, registro ou responsável" autocomplete="off" spellcheck="false">
              <kbd>/</kbd>
            </div>
            <button type="button" data-action="toggle-filters" class="nexlab-a4-button subtle" aria-expanded="${state.filtersExpanded}" aria-controls="nexlab-a4-filter-grid">
              ${icon('filter',17)} <span>Filtros</span><b data-role="filter-count" hidden>0</b>
            </button>
            <button type="button" data-action="refresh" class="nexlab-a4-button subtle">${icon('refresh',17)}<span>Atualizar</span></button>
          </div>
          <div id="nexlab-a4-filter-grid" class="nexlab-a4-filter-grid" ${state.filtersExpanded?'':'hidden'}>
            <label><span>Origem</span><select data-filter="source"><option value="all">Todas as origens</option><option value="operational">Registros operacionais</option><option value="audit">Auditorias protegidas</option></select></label>
            <label><span>Módulo</span><select data-filter="module"><option value="">Todos os módulos</option></select></label>
            <label><span>Tipo de ação</span><select data-filter="action"><option value="">Todas as ações</option></select></label>
            <label><span>Responsável</span><select data-filter="actor"><option value="">Todos os responsáveis</option></select></label>
            <label><span>Data inicial</span><input type="date" data-filter="dateFrom"></label>
            <label><span>Data final</span><input type="date" data-filter="dateTo"></label>
            <div class="nexlab-a4-filter-actions">
              <button type="button" data-action="clear" class="nexlab-a4-button ghost">Limpar filtros</button>
            </div>
          </div>
        </section>

        <section class="nexlab-a4-realtime-banner" data-role="realtime-banner" hidden>
          <div>${icon('activity',18)}<span data-role="realtime-message">Nova atividade disponível.</span></div>
          <button type="button" data-action="load-new">Carregar agora</button>
        </section>

        <section class="nexlab-a4-selection" data-role="selection" hidden aria-live="polite"></section>

        <section class="nexlab-a4-panel" aria-busy="false">
          <div class="nexlab-a4-panel-head">
            <div>
              <h2>Registros encontrados</h2>
              <p data-role="result-caption">Carregando informações do servidor.</p>
            </div>
            <div class="nexlab-a4-panel-tools">
              <label class="nexlab-a4-select-page"><input type="checkbox" data-action="select-page"> <span>Selecionar operacionais da página</span></label>
              <label class="nexlab-a4-page-size"><span>Por página</span><select data-action="page-size">${PAGE_SIZES.map(size=>`<option value="${size}" ${size===state.pageSize?'selected':''}>${size}</option>`).join('')}</select></label>
              <button type="button" data-action="density" class="nexlab-a4-icon-button" title="Alternar densidade" aria-label="Alternar densidade da lista">${icon('activity',17)}</button>
            </div>
          </div>
          <div id="nexlab-a4-feed" data-role="content" class="nexlab-a4-content" tabindex="-1"></div>
          <footer data-role="pagination" class="nexlab-a4-pagination" aria-label="Paginação dos registros"></footer>
        </section>
      </section>`;
  }

  function stopRealtime(){
    if(state.connectTimer){clearTimeout(state.connectTimer);state.connectTimer=null;}
    if(state.pollTimer){clearInterval(state.pollTimer);state.pollTimer=null;}
    if(state.channel){
      try{const client=window.__NEXLAB_SUPABASE__;if(client?.removeChannel)client.removeChannel(state.channel);else state.channel.unsubscribe?.();}catch{}
      state.channel=null;
    }
  }
  function mount(){
    const legacy=findLegacy();
    if(!legacy){
      if(document.body?.dataset?.nexlabPage==='logs')scheduleMountRetry();
      else unmount();
      return;
    }
    clearTimeout(state.mountRetryTimer);state.mountRetryTimer=null;state.mountRetryCount=0;
    if(state.active&&state.legacy===legacy&&state.root?.isConnected){
      if(!legacy.hidden)legacy.hidden=true;
      if(legacy.getAttribute('aria-hidden')!=='true')legacy.setAttribute('aria-hidden','true');
      if(state.root.hidden)state.root.hidden=false;
      return;
    }
    unmount();
    state.active=true;state.activation+=1;state.legacy=legacy;
    legacy.dataset.nexlabActivitiesLegacy='true';
    if(!legacy.hidden)legacy.hidden=true;
    if(legacy.getAttribute('aria-hidden')!=='true')legacy.setAttribute('aria-hidden','true');
    const wrapper=document.createElement('div');wrapper.innerHTML=shell();state.root=wrapper.firstElementChild;
    legacy.parentNode.insertBefore(state.root,legacy);
    bind();syncControlValues();updateNetwork();renderLoading(true);load(true);setupRealtime();
  }
  function unmount(){
    if(!state.active&&!state.root&&!state.legacy)return;
    state.active=false;state.activation+=1;state.loadSequence+=1;state.loading=false;state.queuedLoad=false;
    clearTimeout(state.refreshTimer);state.refreshTimer=null;
    clearTimeout(state.searchTimer);state.searchTimer=null;
    clearTimeout(state.mountRetryTimer);state.mountRetryTimer=null;state.mountRetryCount=0;
    stopRealtime();
    state.root?.remove();state.root=null;
    if(state.legacy?.isConnected){
      if(state.legacy.hidden)state.legacy.hidden=false;
      state.legacy.removeAttribute('aria-hidden');delete state.legacy.dataset.nexlabActivitiesLegacy;
    }
    state.legacy=null;state.data=null;state.selected.clear();state.pendingRealtime=0;state.realtimeStatus='connecting';
  }
  function bind(){
    state.root.addEventListener('input',event=>{
      const filter=event.target?.dataset?.filter;
      if(filter==='search'){
        state.filters.search=event.target.value;renderFilterCount();clearTimeout(state.searchTimer);
        state.searchTimer=setTimeout(()=>{state.page=1;state.selected.clear();load();},350);
      }
    });
    state.root.addEventListener('change',event=>{
      const filter=event.target?.dataset?.filter;
      if(filter){state.filters[filter]=event.target.value;state.page=1;state.selected.clear();renderFilterCount();load();return;}
      if(event.target?.matches('[data-action="select-page"]')){togglePage(event.target.checked);return;}
      if(event.target?.matches('[data-record-select]')){toggleRecord(event.target.dataset.recordSelect,event.target.checked);return;}
      if(event.target?.matches('[data-action="page-size"]')){const size=Number(event.target.value);if(PAGE_SIZES.includes(size)){state.pageSize=size;state.page=1;state.selected.clear();savePreferences();load();}}
    });
    state.root.addEventListener('click',event=>{
      const button=event.target.closest('[data-action]');if(!button)return;
      const action=button.dataset.action;
      if(action==='clear')clearFilters();
      else if(action==='refresh')load(false,{manual:true});
      else if(action==='toggle-filters')toggleFilters(button);
      else if(action==='density')toggleDensity();
      else if(action==='first')goToPage(1);
      else if(action==='previous')goToPage(state.page-1);
      else if(action==='page')goToPage(Number(button.dataset.page));
      else if(action==='next')goToPage(state.page+1);
      else if(action==='last')goToPage(Number(state.data?.pagination?.pages||1));
      else if(action==='delete-selected')openDeleteModal(button);
      else if(action==='clear-selection'){state.selected.clear();renderSelection();renderRows();}
      else if(action==='load-new'){state.pendingRealtime=0;renderRealtimeBanner();state.page=1;state.selected.clear();load();}
      else if(action==='copy'){copyValue(button.dataset.copyValue,button);}
      else if(action==='empty-clear')clearFilters();
    });
    state.root.addEventListener('keydown',event=>{
      if(event.key==='/'&&!isTypingTarget(event.target)){event.preventDefault();state.root.querySelector('[data-filter="search"]')?.focus();}
    });
  }
  function syncControlValues(){
    state.root.querySelectorAll('[data-filter]').forEach(element=>{const key=element.dataset.filter;element.value=state.filters[key]||'';});
    const pageSize=state.root.querySelector('[data-action="page-size"]');if(pageSize)pageSize.value=String(state.pageSize);
    state.root.dataset.density=state.density;renderFilterCount();
  }
  function toggleFilters(button){
    state.filtersExpanded=!state.filtersExpanded;savePreferences();
    const grid=state.root.querySelector('#nexlab-a4-filter-grid');grid.hidden=!state.filtersExpanded;button.setAttribute('aria-expanded',String(state.filtersExpanded));
  }
  function toggleDensity(){state.density=state.density==='comfortable'?'compact':'comfortable';state.root.dataset.density=state.density;savePreferences();toast(`Densidade ${state.density==='compact'?'compacta':'confortável'} ativada.`);}
  function clearFilters(){
    state.filters={source:'all',module:'',action:'',actor:'',dateFrom:'',dateTo:'',search:''};state.page=1;state.selected.clear();syncControlValues();load();
  }
  function renderFilterCount(){
    const count=activeFilterCount(),badge=state.root?.querySelector('[data-role="filter-count"]');if(!badge)return;
    badge.textContent=String(count);badge.hidden=count===0;
  }
  function togglePage(checked){
    for(const row of currentPageRows())if(row.deletable){checked?state.selected.add(String(row.id)):state.selected.delete(String(row.id));}
    renderSelection();renderRows();
  }
  function toggleRecord(id,checked){checked?state.selected.add(String(id)):state.selected.delete(String(id));renderSelection();syncSelectPage();}
  function syncSelectPage(){
    const box=state.root?.querySelector('[data-action="select-page"]');if(!box)return;
    const ids=currentPageRows().filter(row=>row.deletable).map(row=>String(row.id));
    box.disabled=ids.length===0;box.checked=ids.length>0&&ids.every(id=>state.selected.has(id));box.indeterminate=ids.some(id=>state.selected.has(id))&&!box.checked;
  }
  function goToPage(page){
    const pages=Math.max(1,Number(state.data?.pagination?.pages||1)),next=Math.min(Math.max(1,Number(page)||1),pages);
    if(next===state.page||state.loading)return;state.page=next;load().then(()=>state.root?.querySelector('.nexlab-a4-panel')?.scrollIntoView({behavior:'smooth',block:'start'}));
  }

  async function load(first=false,options={}){
    if(!state.active||!state.root?.isConnected)return;
    if(state.loading){state.queuedLoad=true;return;}
    const activation=state.activation,sequence=++state.loadSequence;
    state.loading=true;state.queuedLoad=false;renderLoading(first);updateLive('loading');
    try{
      const data=await rpc('nexlab_list_activity_feed_v26280',{
        p_page:state.page,p_page_size:state.pageSize,p_source:state.filters.source||'all',p_module:state.filters.module||null,
        p_action:state.filters.action||null,p_actor_id:state.filters.actor||null,p_date_from:state.filters.dateFrom||null,
        p_date_to:state.filters.dateTo||null,p_search:state.filters.search||null
      });
      if(!state.active||activation!==state.activation||sequence!==state.loadSequence||!state.root?.isConnected)return;
      state.data=data||{rows:[],pagination:{page:1,pages:0,total:0},summary:{},facets:{}};
      if(state.page>(state.data.pagination?.pages||1)&&state.page>1){state.page=Math.max(1,state.data.pagination.pages);state.loading=false;return load();}
      state.lastUpdated=new Date();state.pendingRealtime=0;render();renderRealtimeBanner();
      announce(`${Number(state.data?.pagination?.total||0)} registros carregados.`);
      if(options.manual)toast('Central atualizada.','ok');
    }catch(error){
      if(state.active&&activation===state.activation&&sequence===state.loadSequence&&state.root?.isConnected){
        console.error('Falha ao carregar a Central de Atividades:',error);renderError(error?.message||'Não foi possível carregar os registros.');updateLive(navigator.onLine?'polling':'offline');
      }
    }finally{
      if(sequence!==state.loadSequence)return;
      state.loading=false;state.root?.querySelector('.nexlab-a4-panel')?.setAttribute('aria-busy','false');
      if(!state.active||activation!==state.activation)return;
      if(state.queuedLoad){state.queuedLoad=false;setTimeout(()=>load(),80);}else updateLive(state.channel?'live':navigator.onLine?'polling':'offline');
    }
  }
  function renderLoading(first){
    const panel=state.root?.querySelector('.nexlab-a4-panel'),content=state.root?.querySelector('[data-role="content"]');if(!content)return;
    panel?.setAttribute('aria-busy','true');state.root.classList.add('is-loading');
    if(first||!state.data){
      state.root.querySelector('[data-role="metrics"]').innerHTML=Array.from({length:4},()=>'<article class="nexlab-a4-metric skeleton"><i></i><b></b></article>').join('');
      content.innerHTML=Array.from({length:4},()=>'<article class="nexlab-a4-row skeleton"><i></i><div><b></b><span></span><span></span></div></article>').join('');
    }
  }
  function renderError(message){
    state.root.classList.remove('is-loading');const content=state.root.querySelector('[data-role="content"]');
    content.innerHTML=`<div class="nexlab-a4-state error" role="alert"><div>${icon('system',26)}</div><strong>Falha ao carregar a Central</strong><p>${escapeHtml(message)}</p><button type="button" data-action="refresh" class="nexlab-a4-button primary">${icon('refresh',17)} Tentar novamente</button></div>`;
    state.root.querySelector('[data-role="result-caption"]').textContent='Não foi possível consultar o servidor.';
  }
  function render(){
    state.root.classList.remove('is-loading');renderMetrics();renderFacets();renderRows();renderPagination();renderSelection();renderLastUpdated();renderFilterCount();
  }
  function renderMetrics(){
    const summary=state.data?.summary||{},metrics=state.root.querySelector('[data-role="metrics"]');
    const items=[
      {label:'Registros filtrados',value:summary.filtered_total||0,tone:'blue',icon:'activity'},
      {label:'Operacionais',value:summary.operational||0,tone:'orange',icon:'report'},
      {label:'Auditorias protegidas',value:summary.protected||0,tone:'green',icon:'lock'},
      {label:'Duplicidades consolidadas',value:summary.suppressed_duplicates||0,tone:'slate',icon:'check'}
    ];
    metrics.innerHTML=items.map(item=>`<article class="nexlab-a4-metric" data-tone="${item.tone}"><div>${icon(item.icon,18)}</div><span>${escapeHtml(item.label)}</span><strong>${Number(item.value).toLocaleString('pt-BR')}</strong></article>`).join('');
  }
  function fillSelect(selector,items,value,labelFn,valueFn){
    const select=state.root.querySelector(selector);if(!select)return;const first=select.options[0]?.outerHTML||'';
    select.innerHTML=first+items.map(item=>`<option value="${escapeHtml(valueFn(item))}">${escapeHtml(labelFn(item))}</option>`).join('');select.value=value||'';
  }
  function renderFacets(){
    const facets=state.data?.facets||{};
    fillSelect('[data-filter="module"]',facets.modules||[],state.filters.module,item=>`${moduleLabels[item.module_key]||item.module_key} (${item.total})`,item=>item.module_key);
    fillSelect('[data-filter="action"]',facets.actions||[],state.filters.action,item=>`${actionKindLabels[item.action_kind]||item.action_kind} (${item.total})`,item=>item.action_kind);
    fillSelect('[data-filter="actor"]',facets.actors||[],state.filters.actor,item=>`${item.actor_name||'Usuário'} (${item.total})`,item=>item.actor_id);
  }
  function renderRows(){
    const content=state.root.querySelector('[data-role="content"]'),rows=currentPageRows(),filters=activeFilterCount();
    if(!rows.length){
      content.innerHTML=`<div class="nexlab-a4-state"><div>${icon(filters?'search':'activity',28)}</div><strong>${filters?'Nenhum registro corresponde aos filtros':'Nenhuma atividade registrada'}</strong><p>${filters?'Revise a pesquisa, o período ou os filtros selecionados.':'As novas operações do sistema aparecerão aqui automaticamente.'}</p>${filters?'<button type="button" data-action="empty-clear" class="nexlab-a4-button primary">Limpar filtros</button>':'<button type="button" data-action="refresh" class="nexlab-a4-button primary">Atualizar</button>'}</div>`;
      syncSelectPage();updateCaption();return;
    }
    content.innerHTML=rows.map((row,index)=>renderRow(row,index)).join('');syncSelectPage();updateCaption();
  }
  function renderRow(row,index){
    const tone=kindTone(row.action_kind),title=actionTitle(row),module=moduleLabels[row.module_key]||row.module_key||'Sistema';
    const description=friendlyDescription(row),metadata=metadataEntries(row),rowId=`nexlab-a4-row-${escapeHtml(row.id)}`;
    const technical=[
      ['Origem',row.protected?'Auditoria protegida':'Registro operacional'],
      ['Ação técnica',row.action_key||row.raw_action||'—'],
      ['Módulo técnico',row.module_key||'system'],
      ['ID da atividade',row.id],
      ['ID do registro',row.entity_id||'—'],
      ['ID de correlação',row.correlation_id||'—']
    ];
    const detailRows=[...technical,...metadata.map(([key,value])=>[metadataLabels[key]||key.replace(/_/g,' ').replace(/\b\w/g,char=>char.toUpperCase()),humanMetadataValue(value)])];
    return `<article id="${rowId}" class="nexlab-a4-row" data-tone="${tone}" data-source="${escapeHtml(row.source)}">
      <div class="nexlab-a4-row-select">
        ${row.deletable?`<input type="checkbox" data-record-select="${escapeHtml(row.id)}" ${state.selected.has(String(row.id))?'checked':''} aria-label="Selecionar: ${escapeHtml(title)}">`:`<span class="nexlab-a4-protected" title="Auditoria protegida" aria-label="Auditoria protegida">${icon('lock',15)}</span>`}
      </div>
      <div class="nexlab-a4-module-icon" data-tone="${tone}">${icon(moduleIcons[row.module_key]||'system',18)}</div>
      <div class="nexlab-a4-row-body">
        <div class="nexlab-a4-row-top">
          <div class="nexlab-a4-badges"><span>${escapeHtml(module)}</span><span data-kind="${tone}">${escapeHtml(actionKindLabels[row.action_kind]||'Atividade')}</span><span data-source="${escapeHtml(row.source)}">${row.protected?'Protegido':'Operacional'}</span></div>
          <time datetime="${escapeHtml(row.created_at)}">${escapeHtml(formatDate(row.created_at))}</time>
        </div>
        <h3>${escapeHtml(title)}</h3>
        ${row.entity_name?`<p class="nexlab-a4-entity">${escapeHtml(row.entity_name)}</p>`:''}
        <p class="nexlab-a4-description">${escapeHtml(description)}</p>
        <div class="nexlab-a4-actor"><span class="nexlab-a4-avatar">${escapeHtml((row.actor_name||'S').trim().charAt(0).toUpperCase())}</span><div><small>Responsável</small><strong>${escapeHtml(row.actor_name||'Sistema / Servidor')}</strong>${row.actor_email?`<span>${escapeHtml(row.actor_email)}</span>`:''}</div></div>
        <details class="nexlab-a4-details">
          <summary><span>Ver detalhes</span>${icon('chevron',15)}</summary>
          <div class="nexlab-a4-detail-grid">${detailRows.map(([label,value])=>`<div><dt>${escapeHtml(label)}</dt><dd>${escapeHtml(truncate(value,700))}${String(value).length>45?`<button type="button" data-action="copy" data-copy-value="${escapeHtml(String(value))}" aria-label="Copiar ${escapeHtml(label)}" title="Copiar">${icon('copy',13)}</button>`:''}</dd></div>`).join('')}</div>
        </details>
      </div>
    </article>`;
  }
  function updateCaption(){
    const pagination=state.data?.pagination||{},summary=state.data?.summary||{},caption=state.root.querySelector('[data-role="result-caption"]');
    const start=pagination.total?((pagination.page-1)*pagination.page_size)+1:0,end=Math.min((pagination.page||1)*(pagination.page_size||state.pageSize),pagination.total||0);
    caption.textContent=pagination.total?`Exibindo ${start}–${end} de ${Number(pagination.total).toLocaleString('pt-BR')} registros. ${Number(summary.suppressed_duplicates||0).toLocaleString('pt-BR')} duplicidade(s) consolidada(s).`:'Nenhum registro encontrado.';
  }
  function pageWindow(current,total){
    const pages=[];let start=Math.max(1,current-2),end=Math.min(total,start+4);start=Math.max(1,end-4);for(let page=start;page<=end;page++)pages.push(page);return pages;
  }
  function renderPagination(){
    const pagination=state.data?.pagination||{},footer=state.root.querySelector('[data-role="pagination"]'),totalPages=Number(pagination.pages||0),current=Number(pagination.page||1);
    if(totalPages<=1){footer.innerHTML=`<span>${Number(pagination.total||0).toLocaleString('pt-BR')} registro${Number(pagination.total||0)===1?'':'s'}</span>`;return;}
    const pages=pageWindow(current,totalPages);
    footer.innerHTML=`<span>Página <strong>${current}</strong> de <strong>${totalPages}</strong></span><nav aria-label="Navegação entre páginas">
      <button type="button" data-action="first" ${current<=1?'disabled':''} aria-label="Primeira página">${icon('first',16)}</button>
      <button type="button" data-action="previous" ${current<=1?'disabled':''} aria-label="Página anterior">${icon('left',16)}</button>
      <div class="nexlab-a4-page-numbers">${pages.map(page=>`<button type="button" data-action="page" data-page="${page}" ${page===current?'aria-current="page"':''}>${page}</button>`).join('')}</div>
      <button type="button" data-action="next" ${current>=totalPages?'disabled':''} aria-label="Próxima página">${icon('chevron',16)}</button>
      <button type="button" data-action="last" ${current>=totalPages?'disabled':''} aria-label="Última página">${icon('last',16)}</button>
    </nav>`;
  }
  function renderSelection(){
    const selection=state.root.querySelector('[data-role="selection"]'),count=state.selected.size;
    selection.hidden=count===0;if(!count){selection.innerHTML='';return;}
    selection.innerHTML=`<div class="nexlab-a4-selection-copy"><div>${icon('trash',18)}</div><p><strong>${count} registro${count===1?'':'s'} operacional${count===1?'':'is'} selecionado${count===1?'':'s'}</strong><span>A exclusão será transacional e registrada na auditoria protegida.</span></p></div><div class="nexlab-a4-selection-actions"><button type="button" data-action="clear-selection" class="nexlab-a4-button ghost">Limpar seleção</button><button type="button" data-action="delete-selected" class="nexlab-a4-button danger">${icon('trash',16)} Excluir selecionados</button></div>`;
  }
  function openDeleteModal(trigger){
    const count=state.selected.size;if(!count)return;
    const selected=selectedCurrentRows(),examples=selected.slice(0,5).map(row=>`<li><strong>${escapeHtml(actionTitle(row))}</strong>${row.entity_name?`<span>${escapeHtml(row.entity_name)}</span>`:''}</li>`).join('');
    const modal=document.createElement('div');modal.className='nexlab-a4-modal';modal.innerHTML=`<div class="nexlab-a4-modal-card" role="dialog" aria-modal="true" aria-labelledby="nexlab-a4-delete-title" aria-describedby="nexlab-a4-delete-description"><form>
      <button type="button" data-modal-action="cancel" class="nexlab-a4-modal-close" aria-label="Fechar">${icon('close',18)}</button>
      <span>Exclusão administrativa</span><h2 id="nexlab-a4-delete-title">Excluir ${count} registro${count===1?'':'s'} operacional${count===1?'':'is'}?</h2>
      <p id="nexlab-a4-delete-description">A auditoria protegida não será removida. Se o registro de auditoria falhar, nenhuma exclusão será concluída.</p>
      ${examples?`<ul class="nexlab-a4-delete-preview">${examples}${count>5?`<li><strong>+ ${count-5} outro${count-5===1?'':'s'} registro${count-5===1?'':'s'}</strong></li>`:''}</ul>`:''}
      <label for="nexlab-a4-delete-reason">Motivo institucional obrigatório</label>
      <textarea id="nexlab-a4-delete-reason" minlength="10" maxlength="300" rows="4" placeholder="Descreva por que estes registros operacionais devem ser removidos." aria-describedby="nexlab-a4-reason-help"></textarea>
      <div id="nexlab-a4-reason-help" class="nexlab-a4-reason-help"><span>Mínimo de 10 caracteres</span><b data-role="char-count">0/300</b></div>
      <div class="nexlab-a4-modal-error" role="alert"></div>
      <div class="nexlab-a4-modal-actions"><button type="button" data-modal-action="cancel">Cancelar</button><button type="submit" disabled>${icon('trash',16)} Excluir e auditar</button></div>
    </form></div>`;
    const card=modal.querySelector('.nexlab-a4-modal-card'),textarea=modal.querySelector('textarea'),submit=modal.querySelector('button[type="submit"]'),errorNode=modal.querySelector('.nexlab-a4-modal-error'),counter=modal.querySelector('[data-role="char-count"]');
    const focusables=()=>[...modal.querySelectorAll('button:not([disabled]),textarea:not([disabled])')];
    const close=()=>{modal.remove();trigger?.focus?.();};
    const keyHandler=event=>{
      if(event.key==='Escape'){event.preventDefault();close();return;}
      if(event.key==='Tab'){const items=focusables(),first=items[0],last=items.at(-1);if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}}
    };
    modal.addEventListener('keydown',keyHandler);
    modal.addEventListener('click',event=>{if(event.target===modal||event.target.closest('[data-modal-action="cancel"]'))close();});
    textarea.addEventListener('input',()=>{const length=textarea.value.trim().length;counter.textContent=`${textarea.value.length}/300`;submit.disabled=length<10;errorNode.textContent='';});
    modal.querySelector('form').addEventListener('submit',async event=>{
      event.preventDefault();const reason=textarea.value.trim();if(reason.length<10){errorNode.textContent='Informe pelo menos 10 caracteres.';textarea.focus();return;}
      submit.disabled=true;submit.innerHTML=`<i class="nexlab-a4-spinner"></i> Excluindo...`;
      try{
        const result=await rpc('nexlab_admin_delete_activity_logs_v26270',{p_ids:[...state.selected],p_reason:reason});
        const deleted=Number(result?.deleted_count||0);toast(`${deleted} registro${deleted===1?'':'s'} excluído${deleted===1?'':'s'} com auditoria protegida.`,'ok');state.selected.clear();close();await load();
      }catch(error){console.error('Falha na exclusão atômica:',error);errorNode.textContent=error?.message||'Não foi possível excluir os registros.';submit.disabled=false;submit.innerHTML=`${icon('trash',16)} Excluir e auditar`;}
    });
    document.body.appendChild(modal);setTimeout(()=>textarea.focus(),0);
  }
  async function copyValue(value,button){
    try{await navigator.clipboard.writeText(String(value||''));const original=button.innerHTML;button.innerHTML=icon('check',13);button.dataset.copied='true';setTimeout(()=>{button.innerHTML=original;delete button.dataset.copied;},1200);}
    catch{toast('Não foi possível copiar o valor.','err');}
  }
  function announce(message){const node=state.root?.querySelector('[data-role="announcer"]');if(node){node.textContent='';requestAnimationFrame(()=>{node.textContent=message;});}}
  function renderLastUpdated(){const node=state.root?.querySelector('[data-role="last-updated"]');if(node)node.textContent=state.lastUpdated?`Atualizado às ${formatTime(state.lastUpdated)}`:'Ainda não atualizado';}
  function updateLive(status){
    state.realtimeStatus=status;const node=state.root?.querySelector('[data-role="live"]');if(!node)return;
    const label=node.querySelector('span');node.dataset.status=status;
    label.textContent=status==='live'?'Tempo real ativo':status==='loading'?'Atualizando':status==='polling'?'Atualização periódica':status==='offline'?'Sem conexão':'Conectando';
  }
  function updateNetwork(){
    const node=state.root?.querySelector('[data-role="network"]');if(!node)return;
    node.hidden=navigator.onLine;if(!navigator.onLine){node.querySelector('span').textContent='Sem conexão. Os registros serão atualizados quando a internet voltar.';updateLive('offline');}
  }
  function renderRealtimeBanner(){
    const node=state.root?.querySelector('[data-role="realtime-banner"]');if(!node)return;
    node.hidden=state.pendingRealtime===0;if(state.pendingRealtime){node.querySelector('[data-role="realtime-message"]').textContent=`${state.pendingRealtime} nova${state.pendingRealtime===1?'':'s'} atividade${state.pendingRealtime===1?'':'s'} disponível${state.pendingRealtime===1?'':'is'}.`;}
  }
  function onRealtime(){
    if(!state.active)return;
    if(document.visibilityState!=='visible'||state.page!==1||state.selected.size>0){state.pendingRealtime+=1;renderRealtimeBanner();announce('Nova atividade disponível.');return;}
    scheduleRefresh();
  }
  function scheduleRefresh(){
    if(!state.active)return;clearTimeout(state.refreshTimer);state.refreshTimer=setTimeout(()=>load(),500);
  }
  function setupRealtime(){
    stopRealtime();if(!state.active)return;
    const activation=state.activation;
    const startPolling=()=>{
      if(!state.active||activation!==state.activation)return;
      if(!state.pollTimer)state.pollTimer=setInterval(()=>{if(state.active&&activation===state.activation&&document.visibilityState==='visible'&&navigator.onLine)load();},60000);
      updateLive(navigator.onLine?'polling':'offline');
    };
    const connect=()=>{
      state.connectTimer=null;
      if(!state.active||activation!==state.activation)return;
      const client=window.__NEXLAB_SUPABASE__;
      if(!client?.channel){startPolling();return;}
      state.channel=client.channel(`nexlab-activities-v26297-${activation}`)
        .on('postgres_changes',{event:'*',schema:'public',table:'logs'},onRealtime)
        .on('postgres_changes',{event:'*',schema:'public',table:'security_audit_logs'},onRealtime)
        .subscribe(status=>{
          if(!state.active||activation!==state.activation)return;
          if(status==='SUBSCRIBED')updateLive('live');
          if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status))startPolling();
        });
    };
    if(window.__NEXLAB_SUPABASE__)connect();else state.connectTimer=setTimeout(connect,1500);
  }

  function scheduleMountRetry(){
    if(!state.active&&document.body?.dataset?.nexlabPage!=='logs')return;
    if(state.mountRetryTimer||state.mountRetryCount>=5)return;
    const delays=[100,250,500,1000,2000];
    const delay=delays[state.mountRetryCount++]||2000;
    state.mountRetryTimer=setTimeout(()=>{state.mountRetryTimer=null;routeCheck();},delay);
  }
  function routeCheck(){
    state.routeCheckTimer=null;
    const page=document.body?.dataset?.nexlabPage||'';
    if(page==='logs'||((!page||page==='claro')&&isLogsScreen())){
      const legacy=findLegacy();
      if(legacy)mount();else scheduleMountRetry();
    }else{
      state.mountRetryCount=0;clearTimeout(state.mountRetryTimer);state.mountRetryTimer=null;unmount();
    }
  }
  function scheduleRouteCheck(delay=0){
    clearTimeout(state.routeCheckTimer);state.routeCheckTimer=setTimeout(routeCheck,delay);
  }
  function onNavigationIntent(event){
    if(!event.target?.closest?.('a,button,[role="tab"],[data-tab],[data-nexlab-page]'))return;
    scheduleRouteCheck(0);setTimeout(()=>scheduleRouteCheck(0),120);setTimeout(()=>scheduleRouteCheck(0),420);
  }
  function onVisibilityChange(){if(state.active&&document.visibilityState==='visible'){if(state.pendingRealtime)renderRealtimeBanner();else if(navigator.onLine)scheduleRefresh();}}
  function onOnline(){updateNetwork();if(state.active)scheduleRefresh();}
  function onOffline(){updateNetwork();}
  function onRouteEvent(){scheduleRouteCheck(0);}

  readPreferences();
  const start=()=>{
    state.routeObserver=new MutationObserver(()=>scheduleRouteCheck(0));
    state.routeObserver.observe(document.body,{attributes:true,attributeFilter:['data-nexlab-page']});
    document.addEventListener('click',onNavigationIntent,true);
    document.addEventListener('visibilitychange',onVisibilityChange);
    window.addEventListener('online',onOnline);
    window.addEventListener('offline',onOffline);
    window.addEventListener('popstate',onRouteEvent);
    window.addEventListener('hashchange',onRouteEvent);
    window.addEventListener('nexlab:navigate',onRouteEvent);
    window.addEventListener('nexlab:page-change',onRouteEvent);
    scheduleRouteCheck(0);
  };
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();

  window[GLOBAL_KEY]={
    version:VERSION,state,refresh:()=>load(),
    snapshot:()=>({active:state.active,page:document.body?.dataset?.nexlabPage||'',rootConnected:Boolean(state.root?.isConnected),realtime:Boolean(state.channel),polling:Boolean(state.pollTimer),mountRetries:state.mountRetryCount}),
    destroy(){
      state.routeObserver?.disconnect();state.routeObserver=null;
      clearTimeout(state.routeCheckTimer);clearTimeout(state.mountRetryTimer);clearTimeout(state.connectTimer);
      document.removeEventListener('click',onNavigationIntent,true);
      document.removeEventListener('visibilitychange',onVisibilityChange);
      window.removeEventListener('online',onOnline);window.removeEventListener('offline',onOffline);
      window.removeEventListener('popstate',onRouteEvent);window.removeEventListener('hashchange',onRouteEvent);
      window.removeEventListener('nexlab:navigate',onRouteEvent);window.removeEventListener('nexlab:page-change',onRouteEvent);
      unmount();
    }
  };
})();
