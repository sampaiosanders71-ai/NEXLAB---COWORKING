(function(){
  'use strict';
  if(window.__NEXLAB_PERMISSIONS_R5543__) return;

  const VERSION='26.30.8';
  const ASSISTANT_PRESET_EXCLUSIONS=new Set([
    'users_sensitive_view','action_sensitive_export','module_permissoes',
    'module_saude-sistema','module_logs','users_manage_profiles',
    'users_delete_accounts','permissions_manage_matrix'
  ]);
  const state={
    active:false,root:null,sidebar:null,matrix:null,loading:false,lastLoadedAt:0,
    page:1,pageSize:20,scope:'',search:'',historyLoaded:false,
    channel:null,fallbackTimer:null,reconnectTimer:null,reconnectAttempt:0,realtimeStatus:'idle',refreshTimer:null,enhanceTimer:null,
    observer:null,routeTimer:null,remoteChangePending:false,suppressRefreshGuard:false
  };

  const wait=(ms)=>new Promise(resolve=>setTimeout(resolve,ms));

  async function getClient(){
    let client=window.__NEXLAB_SUPABASE__;
    for(let attempt=0;!client&&attempt<25;attempt+=1){await wait(120);client=window.__NEXLAB_SUPABASE__}
    if(!client?.rpc||!client?.auth?.getSession) throw new Error('Cliente Supabase autenticado indisponível. Recarregue o aplicativo.');
    const {data,error}=await client.auth.getSession();
    if(error) throw error;
    if(!data?.session?.access_token) throw new Error('Sessão autenticada não localizada. Entre novamente no aplicativo.');
    return client;
  }

  function toError(error,fallback){
    const normalized=error instanceof Error?error:new Error(error?.message||fallback||'Falha inesperada.');
    if(error?.code) normalized.code=error.code;
    if(error?.details) normalized.details=error.details;
    return normalized;
  }

  async function rpc(name,body={}){
    const client=await getClient();
    const {data,error}=await client.rpc(name,body);
    if(error) throw toError(error,`Falha ao executar ${name}.`);
    return data;
  }

  function validateMatrix(value){
    if(!value||typeof value!=='object') throw new Error('O Supabase retornou uma matriz de permissões inválida.');
    for(const field of ['catalog','defaults','users','overrides']){
      if(!Array.isArray(value[field])) throw new Error(`A matriz de permissões não contém a lista ${field}.`);
    }
    const permissionKeys=value.catalog.map(row=>String(row?.permission_key||'')).filter(Boolean);
    if(new Set(permissionKeys).size!==permissionKeys.length) throw new Error('A matriz contém permissões duplicadas.');
    return {
      ...value,
      catalog:value.catalog,
      defaults:value.defaults,
      users:value.users,
      overrides:value.overrides,
      dependencies:Array.isArray(value.dependencies)?value.dependencies:[],
      history:Array.isArray(value.history)?value.history:[],
      summary:value.summary&&typeof value.summary==='object'?value.summary:{},
      revision:Number.isFinite(Number(value.revision))?Number(value.revision):0
    };
  }

  function requireMutationSuccess(result,action){
    if(!result||result.ok!==true) throw new Error(result?.message||`O servidor não confirmou ${action}.`);
    return result;
  }

  function toast(message,tone='info'){
    if(typeof window.nexlabToast==='function') return window.nexlabToast(message,tone);
    const element=document.createElement('div');element.className='nexlab-p2-conflict';
    element.innerHTML=`<strong>${tone==='err'?'Atenção':'Permissões'}</strong><span></span>`;
    element.querySelector('span').textContent=message;document.body.appendChild(element);setTimeout(()=>element.remove(),6000);
  }

  async function confirmAction(message){
    if(typeof window.nexlabConfirm==='function') return Boolean(await window.nexlabConfirm(message));
    return window.confirm(message);
  }

  function isPermissionScreen(root){
    if(!root) return false;
    const scope=root.closest('main')||root;
    const markers=[
      '.permission-role-button',
      '.permission-tab',
      '.permission-toggle',
      '.permission-sidebar-card textarea',
      '[data-action="apply-assistant-preset"]'
    ];
    const markerCount=markers.reduce((count,selector)=>count+(scope.querySelector(selector)?1:0),0);
    if(markerCount>=2) return true;
    const headingText=(scope.querySelector('h1,h2,h3')?.textContent||'').toLowerCase();
    if(/permiss/.test(headingText)&&markerCount>=1) return true;
    return false;
  }
  function permissionRoot(){
    const candidates=[...document.querySelectorAll('.permission-matrix-page,.permission-layout')];
    for(const candidate of candidates){
      const scope=candidate.closest('.permission-matrix-page,.permission-layout')||candidate;
      if(isPermissionScreen(scope)) return scope;
    }
    return null;
  }
  function permissionPage(){return state.root?.closest('main')||document.querySelector('main')||document.body}
  function activeRole(){const text=document.querySelector('.permission-role-button.is-active')?.textContent?.trim().toLowerCase()||'';return text.includes('admin')?'admin':text.includes('coorden')?'coordenador':text.includes('bols')?'bolsista':text.includes('júnior')||text.includes('junior')?'coworking_junior':''}
  function activeTab(){return document.querySelector('.permission-tab.is-active')?.textContent?.toLowerCase().includes('exce')?'users':'roles'}
  function reason(){return document.querySelector('.permission-sidebar-card textarea')?.value?.trim()||''}
  function selectedUser(){return document.querySelector('.permission-sidebar-card select')?.value||''}
  function selectedUserRecord(){return (state.matrix?.users||[]).find(row=>String(row.id)===String(selectedUser()))||null}
  function escapeHtml(value){const span=document.createElement('span');span.textContent=String(value??'');return span.innerHTML}

  function labelMap(){return new Map((state.matrix?.catalog||[]).map(item=>[String(item.label||'').trim(),item]))}
  function defaultMap(){return new Map((state.matrix?.defaults||[]).map(item=>[`${item.role_key}:${item.permission_key}`,item]))}
  function dependencyMap(){const map=new Map();for(const row of state.matrix?.dependencies||[]){if(!map.has(row.permission_key))map.set(row.permission_key,[]);map.get(row.permission_key).push(row)}return map}

  function createPasswordMarkup(className){
    const panel=document.createElement('section');panel.className=className;panel.setAttribute('aria-label','Autorização administrativa das permissões');
    panel.innerHTML='<div class="nexlab-sensitive-password-inline-head"><span aria-hidden="true">🔐</span><div><strong>Senha para autorizar alterações</strong><small>Obrigatória apenas ao salvar, conceder, revogar ou restaurar permissões.</small></div></div><label>Senha administrativa</label><div class="nexlab-sensitive-password-input-wrap"><input type="password" autocomplete="off" placeholder="Digite a senha administrativa"><button type="button" class="nexlab-sensitive-password-toggle" aria-label="Mostrar senha">Mostrar</button></div><div class="nexlab-sensitive-password-inline-error" aria-live="polite"></div>';
    const input=panel.querySelector('input'),toggle=panel.querySelector('.nexlab-sensitive-password-toggle');
    input.addEventListener('input',()=>{panel.querySelector('.nexlab-sensitive-password-inline-error').textContent='';panel.dataset.filled=input.value?'true':'false'});
    toggle.addEventListener('click',()=>{const visible=input.type==='text';input.type=visible?'password':'text';toggle.textContent=visible?'Mostrar':'Ocultar';toggle.setAttribute('aria-label',visible?'Mostrar senha':'Ocultar senha')});
    return panel;
  }

  function ensurePasswordField(){
    if(!state.active) return null;
    const sidebar=document.querySelector('.permission-sidebar-card');
    if(!sidebar) return null;
    let panel=sidebar.querySelector('.nexlab-permission-password-inline');
    if(!panel){panel=createPasswordMarkup('nexlab-sensitive-password-inline nexlab-permission-password-inline');sidebar.appendChild(panel)}
    state.sidebar=sidebar;syncPasswordField();return panel;
  }
  function permissionPassword(){const inputs=[...document.querySelectorAll('.nexlab-permission-password-inline input')].filter(input=>input.isConnected&&!input.disabled);const visible=inputs.findLast?.(input=>input.getClientRects().length>0)||inputs.at(-1);return visible?.value?.trim()||''}
  function clearPermissionPassword(){for(const panel of document.querySelectorAll('.nexlab-permission-password-inline,.nexlab-permission-password-modal-card')){const input=panel.querySelector('input');if(input){input.value='';input.type='password'}panel.dataset.filled='false';const error=panel.querySelector('.nexlab-sensitive-password-inline-error');if(error)error.textContent=''}}

  function requestPermissionPassword(message='Digite a senha administrativa para autorizar esta alteração.'){
    return new Promise(resolve=>{
      document.querySelector('.nexlab-permission-password-modal')?.remove();
      const overlay=document.createElement('div');overlay.className='nexlab-sensitive-password-modal nexlab-permission-password-modal';overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
      const card=createPasswordMarkup('nexlab-sensitive-password-modal-card nexlab-permission-password-modal-card');
      card.insertAdjacentHTML('beforeend','<div class="nexlab-sensitive-password-modal-actions"><button type="button" data-action="cancel">Cancelar</button><button type="button" data-action="confirm">Autorizar alteração</button></div>');
      const error=card.querySelector('.nexlab-sensitive-password-inline-error');error.textContent=message;overlay.appendChild(card);document.body.appendChild(overlay);
      const input=card.querySelector('input');setTimeout(()=>input.focus(),20);
      const finish=value=>{overlay.remove();resolve(value)};
      card.querySelector('[data-action="cancel"]').onclick=()=>finish(null);
      card.querySelector('[data-action="confirm"]').onclick=()=>{const value=input.value.trim();if(!value){error.textContent='Informe a senha administrativa.';input.focus();return}const inline=ensurePasswordField();const inlineInput=inline?.querySelector('input');if(inlineInput){inlineInput.value=value;inline.dataset.filled='true'}finish(value)};
      input.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();card.querySelector('[data-action="confirm"]').click()}else if(event.key==='Escape')finish(null)});
      overlay.addEventListener('click',event=>{if(event.target===overlay)finish(null)});
    });
  }

  async function requirePermissionPassword(){
    let password=permissionPassword();if(!password)password=await requestPermissionPassword();
    if(!password){toast('A alteração foi cancelada porque a senha não foi informada.','err');return null}
    return password;
  }

  function changedRolePermissions(){
    const role=activeRole(),defaults=defaultMap(),labels=labelMap(),changed={};
    for(const item of document.querySelectorAll('.permission-content-card .permission-item')){
      const permission=labels.get(item.querySelector('strong')?.textContent?.trim());const input=item.querySelector('input[type="checkbox"]');
      if(!permission||!input||input.disabled)continue;
      const current=Boolean(defaults.get(`${role}:${permission.permission_key}`)?.allowed);if(current!==input.checked)changed[permission.permission_key]=input.checked;
    }
    return changed;
  }

  function changedOverrides(){
    const user=selectedUser(),labels=labelMap(),existing=new Map((state.matrix?.overrides||[]).filter(row=>String(row.user_id)===String(user)).map(row=>[row.permission_key,row.effect])),changed={};
    for(const item of document.querySelectorAll('.permission-content-card .permission-user-item')){
      const permission=labels.get(item.querySelector('strong')?.textContent?.trim());const select=item.querySelector('select');
      if(!permission||!select||select.disabled)continue;
      const before=existing.get(permission.permission_key)||'default';if(before!==select.value)changed[permission.permission_key]=select.value;
    }
    return changed;
  }

  function hasPendingChanges(){try{return activeTab()==='users'?Object.keys(changedOverrides()).length>0:Object.keys(changedRolePermissions()).length>0}catch{return false}}
  function syncPasswordField(){const panel=document.querySelector('.nexlab-permission-password-inline');if(!panel)return;const pending=hasPendingChanges();panel.dataset.required=pending?'true':'false';const hint=panel.querySelector('small');if(hint)hint.textContent=pending?'Digite a senha antes de salvar as alterações pendentes.':'Obrigatória apenas quando uma alteração for confirmada.'}

  function renderStatus(){
    if(!state.active||!state.matrix)return;
    const page=permissionPage(),summary=state.matrix.summary||{};if(!page)return;
    let box=page.querySelector('.nexlab-p2-status');
    if(!box){box=document.createElement('section');box.className='nexlab-p2-status';const metrics=page.querySelector('.compact-metrics');metrics?.insertAdjacentElement('afterend',box);if(!box.isConnected)page.prepend(box)}
    const signature=`${state.matrix.revision||0}:${summary.actual_pairs||0}:${summary.expected_pairs||0}:${state.remoteChangePending}`;
    if(box.dataset.signature===signature)return;box.dataset.signature=signature;
    box.innerHTML=`<div class="nexlab-p2-metric" data-tone="${summary.matrix_complete?'ok':'warn'}"><span>Matriz explícita</span><strong>${summary.actual_pairs||0}/${summary.expected_pairs||0}</strong></div><div class="nexlab-p2-metric"><span>Revisão concorrente</span><strong>#${state.matrix.revision||0}</strong></div><div class="nexlab-p2-metric"><span>Dependências</span><strong>${(state.matrix.dependencies||[]).length}</strong></div><div class="nexlab-p2-metric" data-tone="${state.remoteChangePending?'warn':'ok'}"><span>Sincronização</span><strong class="nexlab-p2-live">${state.remoteChangePending?'Conflito pendente':'Em tempo real'}</strong></div>`;
  }

  function annotateDependencies(){
    if(!state.active||!state.matrix)return;
    const labels=labelMap(),dependencies=dependencyMap();
    for(const item of document.querySelectorAll('.permission-content-card .permission-item,.permission-content-card .permission-user-item')){
      const title=item.querySelector('strong')?.textContent?.trim(),permission=labels.get(title);if(!permission)continue;
      item.dataset.permissionKey=permission.permission_key;
      if(permission.permission_key==='action_sensitive_export'||permission.permission_key==='users_sensitive_view'){
        const description=item.querySelector('.permission-item-copy p');
        const text=permission.permission_key==='users_sensitive_view'?'Permite consultar CPF e data de nascimento individualmente. Toda consulta é auditada.':'Permite gerar relatório restrito com CPF e data de nascimento. Exige senha administrativa e auditoria.';
        if(description&&description.textContent!==text)description.textContent=text;
      }
      const required=dependencies.get(permission.permission_key)||[],expected=required.length?`Exige: ${required.map(row=>row.required_label).join(', ')}`:'';
      let line=item.querySelector('.nexlab-p2-dependency');
      if(expected){if(!line){line=document.createElement('span');line.className='nexlab-p2-dependency';item.querySelector('.permission-item-copy')?.appendChild(line)}if(line.textContent!==expected)line.textContent=expected}
      else line?.remove();
    }
  }

  function findItem(permissionKey){return document.querySelector(`.permission-item[data-permission-key="${CSS.escape(permissionKey)}"],.permission-user-item[data-permission-key="${CSS.escape(permissionKey)}"]`)}
  function enforceDependencies(target){
    const item=target.closest?.('.permission-item,.permission-user-item'),key=item?.dataset.permissionKey;if(!key||!state.matrix)return;
    const dependencies=dependencyMap();
    if(target.matches('input[type="checkbox"]')&&target.checked){for(const row of dependencies.get(key)||[]){const required=findItem(row.required_permission_key)?.querySelector('input[type="checkbox"]');if(required&&!required.disabled&&!required.checked)required.click()}}
    if(target.matches('select')&&target.value==='allow'){for(const row of dependencies.get(key)||[]){const required=findItem(row.required_permission_key)?.querySelector('select');if(required&&!required.disabled&&required.value!=='allow'){required.value='allow';required.dispatchEvent(new Event('change',{bubbles:true}))}}}
    if(target.matches('input[type="checkbox"]')&&!target.checked){for(const row of state.matrix.dependencies||[]){if(row.required_permission_key!==key)continue;const dependent=findItem(row.permission_key)?.querySelector('input[type="checkbox"]');if(dependent&&!dependent.disabled&&dependent.checked)dependent.click()}}
  }

  function ensureAssistantPreset(){
    const existing=document.querySelector('.nexlab-r550-assistant-preset');
    if(!state.active||activeTab()!=='users'){existing?.remove();return}
    const sidebar=document.querySelector('.permission-sidebar-card'),user=selectedUserRecord();
    if(!sidebar||!user||['admin','administrador'].includes(String(user.role||'').toLowerCase())){existing?.remove();return}
    let panel=existing;
    if(!panel){
      panel=document.createElement('section');panel.className='nexlab-r550-assistant-preset';
      panel.innerHTML='<div><strong>Modelo Coordenador assistente</strong><small>Concede funções operacionais de Coordenador sem mudar o perfil-base e sem liberar dados sensíveis ou poderes administrativos.</small></div><button type="button" data-action="apply-assistant-preset">Aplicar modelo</button>';
      const password=sidebar.querySelector('.nexlab-permission-password-inline');
      password?.insertAdjacentElement('beforebegin',panel);if(!panel.isConnected)sidebar.appendChild(panel);
    }
  }

  function renderDelegationSummary(){
    const page=permissionPage();let panel=page?.querySelector('.nexlab-r550-delegation-summary');
    if(!page||activeTab()!=='users'){panel?.remove();return}
    const user=selectedUserRecord();if(!user){panel?.remove();return}
    const overrides=(state.matrix?.overrides||[]).filter(row=>String(row.user_id)===String(user.id));
    const sensitive=overrides.find(row=>row.permission_key==='users_sensitive_view')?.effect==='allow';
    if(!panel){panel=document.createElement('section');panel.className='nexlab-r550-delegation-summary';const content=page.querySelector('.permission-content-card');content?.insertAdjacentElement('afterbegin',panel)}
    if(panel)panel.innerHTML=`<strong>${escapeHtml(user.nome||user.email||'Usuário selecionado')}</strong><span>${overrides.length} exceção(ões) individual(is) ativa(s)</span><span data-tone="${sensitive?'warn':'ok'}">Dados sensíveis: ${sensitive?'concedidos explicitamente':'não delegados'}</span>`;
  }

  function applyAssistantPreset(){
    const user=selectedUserRecord();if(!user)return toast('Selecione um usuário.','err');
    const role=String(user.role||'').toLowerCase();
    if(['admin','administrador'].includes(role))return toast('O modelo não se aplica a Administradores.','err');
    const defaults=defaultMap();let changed=0;
    for(const permission of state.matrix?.catalog||[]){
      if(permission.core||permission.admin_only||!permission.grantable||ASSISTANT_PRESET_EXCLUSIONS.has(permission.permission_key))continue;
      if(!defaults.get(`coordenador:${permission.permission_key}`)?.allowed)continue;
      if(Array.isArray(permission.eligible_roles)&&!permission.eligible_roles.includes(role))continue;
      const select=findItem(permission.permission_key)?.querySelector('select');
      if(select&&!select.disabled&&select.value!=='allow'){select.value='allow';select.dispatchEvent(new Event('change',{bubbles:true}));changed+=1}
    }
    const textarea=document.querySelector('.permission-sidebar-card textarea');
    if(textarea&&!textarea.value.trim()){textarea.value='Delegação operacional pelo modelo Coordenador assistente.';textarea.dispatchEvent(new Event('input',{bubbles:true}))}
    toast(changed?`${changed} permissão(ões) preparada(s). Revise e salve.`:'O usuário já possui as permissões operacionais do modelo.','info');
    scheduleEnhancements(30);
  }

  function ensureHistoryShell(){
    if(!state.active)return;
    const page=permissionPage();if(!page)return;
    let card=page.querySelector('.nexlab-p2-history');
    if(!card){card=document.createElement('section');card.className='nexlab-p2-history nexlab-p2-history-lazy';card.innerHTML='<div class="nexlab-p2-history-head"><div><h3>Histórico completo de permissões</h3><p>Carregado somente quando solicitado para reduzir uso de memória.</p></div><button type="button" data-action="load-history">Carregar histórico</button></div><div class="nexlab-p2-history-content" hidden></div>';page.appendChild(card)}
  }

  async function renderHistory(){
    const page=permissionPage(),card=page?.querySelector('.nexlab-p2-history');if(!card||!state.active)return;
    const content=card.querySelector('.nexlab-p2-history-content');content.hidden=false;content.innerHTML='<p class="permission-empty">Carregando histórico…</p>';
    let result;
    try{result=await rpc('nexlab_list_permission_history_v26260',{p_page:state.page,p_page_size:state.pageSize,p_scope:state.scope||null,p_role:null,p_user_id:null,p_permission_key:null,p_search:state.search||null})}
    catch(error){content.innerHTML=`<p class="permission-empty">${escapeHtml(error.message||'Não foi possível carregar o histórico.')}</p>`;return}
    state.historyLoaded=true;const rows=Array.isArray(result?.rows)?result.rows:[],pagination=result?.pagination||{};
    content.innerHTML=`<div class="nexlab-p2-filters"><input type="search" placeholder="Buscar responsável, usuário ou motivo" value="${escapeHtml(state.search)}"><select><option value="">Todos os tipos</option><option value="role_default" ${state.scope==='role_default'?'selected':''}>Padrões de perfil</option><option value="user_override" ${state.scope==='user_override'?'selected':''}>Exceções individuais</option><option value="restore_defaults" ${state.scope==='restore_defaults'?'selected':''}>Restaurações</option></select></div><div class="nexlab-p2-history-list">${rows.length?rows.map(row=>`<article class="nexlab-p2-row"><div><strong>${escapeHtml(row.permission_label||row.permission_key||row.scope)}</strong><p>${escapeHtml(row.user_name||row.role_key||'Matriz')} — ${escapeHtml(row.reason||'Sem motivo informado')}</p><small>Por ${escapeHtml(row.actor_name||row.actor_email||'Sistema')} · ${escapeHtml(row.previous_value||'—')} → ${escapeHtml(row.next_value||'—')}</small></div><time>${new Date(row.created_at).toLocaleString('pt-BR')}</time></article>`).join(''):'<p class="permission-empty">Nenhum registro encontrado.</p>'}</div><div class="nexlab-p2-pages"><span>Página ${pagination.page||1} de ${pagination.pages||0} · ${pagination.total||0} registro(s)</span><button type="button" data-page="prev" ${Number(pagination.page||1)<=1?'disabled':''}>Anterior</button><button type="button" data-page="next" ${!pagination.has_more?'disabled':''}>Próxima</button></div>`;
    const search=content.querySelector('input');let timer;search.oninput=()=>{clearTimeout(timer);timer=setTimeout(()=>{state.search=search.value.trim();state.page=1;renderHistory()},450)};
    content.querySelector('select').onchange=event=>{state.scope=event.target.value;state.page=1;renderHistory()};
    content.querySelector('[data-page="prev"]')?.addEventListener('click',()=>{state.page=Math.max(1,state.page-1);renderHistory()});
    content.querySelector('[data-page="next"]')?.addEventListener('click',()=>{state.page+=1;renderHistory()});
  }

  function ensureEnhancements(){
    if(!state.active)return;
    renderStatus();annotateDependencies();ensurePasswordField();ensureAssistantPreset();renderDelegationSummary();ensureHistoryShell();
  }
  function scheduleEnhancements(delay=60){clearTimeout(state.enhanceTimer);state.enhanceTimer=setTimeout(ensureEnhancements,delay)}

  async function loadMatrix(force=false){
    if(!state.active||state.loading)return state.matrix;
    if(!force&&state.matrix&&Date.now()-state.lastLoadedAt<120000){scheduleEnhancements(0);return state.matrix}
    state.loading=true;
    try{
      state.matrix=validateMatrix(await rpc('nexlab_get_permission_matrix'));
      state.lastLoadedAt=Date.now();state.remoteChangePending=false;scheduleEnhancements(0);return state.matrix;
    }catch(error){console.error('Permissões R55.4.2:',error);toast(error.message||'Não foi possível carregar a matriz de permissões.','err');return null}
    finally{state.loading=false}
  }

  async function loadFreshMatrix(){
    const matrix=validateMatrix(await rpc('nexlab_get_permission_matrix'));
    state.matrix=matrix;state.lastLoadedAt=Date.now();state.remoteChangePending=false;scheduleEnhancements(0);return matrix;
  }

  function conflict(error){return error?.code==='40001'||/alterada por outro|recarregue|revisão/i.test(error?.message||'')}
  function showConflict(customMessage){
    document.querySelector('.nexlab-p2-conflict')?.remove();const box=document.createElement('div');box.className='nexlab-p2-conflict';
    box.innerHTML='<strong>Matriz atualizada por outro Administrador</strong><span></span><button type="button">Recarregar matriz</button>';
    box.querySelector('span').textContent=customMessage||'As alterações locais foram preservadas. Recarregue a matriz antes de salvar novamente.';
    box.querySelector('button').onclick=async()=>{if(hasPendingChanges()&&!await confirmAction('Descartar as alterações locais e carregar a versão mais recente?'))return;box.remove();state.lastLoadedAt=0;state.remoteChangePending=false;refreshReact(true)};
    document.body.appendChild(box);
  }

  function verifyRoleChanges(matrix,role,changes){
    const defaults=new Map(matrix.defaults.map(row=>[`${row.role_key}:${row.permission_key}`,Boolean(row.allowed)]));
    for(const [key,value] of Object.entries(changes)) if(defaults.get(`${role}:${key}`)!==Boolean(value)) throw new Error(`A alteração da permissão ${key} não foi confirmada pelo banco.`);
  }
  function verifyUserChanges(matrix,userId,changes){
    const overrides=new Map(matrix.overrides.filter(row=>String(row.user_id)===String(userId)).map(row=>[row.permission_key,row.effect]));
    for(const [key,value] of Object.entries(changes)){
      if(value==='default'&&overrides.has(key)) throw new Error(`A restauração da permissão ${key} não foi confirmada pelo banco.`);
      if(value!=='default'&&overrides.get(key)!==value) throw new Error(`A exceção ${key} não foi confirmada pelo banco.`);
    }
  }

  async function saveRole(){
    const changes=changedRolePermissions(),role=activeRole();if(!role)throw new Error('Não foi possível identificar o perfil selecionado. Atualize a matriz e tente novamente.');if(!Object.keys(changes).length)return toast('Nenhuma alteração pendente.','info');if(!reason())return toast('Informe o motivo da alteração.','err');
    const password=await requirePermissionPassword();if(!password)return;
    const result=await rpc('nexlab_admin_save_role_permissions_v26264',{p_role:role,p_permissions:changes,p_reason:reason(),p_expected_revision:state.matrix.revision,p_admin_password:password});
    requireMutationSuccess(result,'a atualização dos padrões');const matrix=await loadFreshMatrix();verifyRoleChanges(matrix,role,changes);clearPermissionPassword();toast('Padrões salvos e confirmados pelo Supabase.','ok');refreshReact(false);
  }
  async function saveUser(){
    const changes=changedOverrides(),userId=selectedUser();if(!userId)throw new Error('Selecione um usuário antes de salvar as permissões delegadas.');if(!Object.keys(changes).length)return toast('Nenhuma alteração pendente.','info');if(!reason())return toast('Informe o motivo da alteração.','err');
    const password=await requirePermissionPassword();if(!password)return;
    const result=await rpc('nexlab_admin_save_user_permissions_v26264',{p_target_user_id:userId,p_overrides:changes,p_reason:reason(),p_expected_revision:state.matrix.revision,p_admin_password:password});
    requireMutationSuccess(result,'a atualização das exceções');const matrix=await loadFreshMatrix();verifyUserChanges(matrix,userId,changes);clearPermissionPassword();toast('Exceções salvas e confirmadas pelo Supabase.','ok');refreshReact(false);
  }
  async function restoreUser(){
    const userId=selectedUser();if(!userId)throw new Error('Selecione um usuário antes de restaurar as permissões.');if(!reason())return toast('Informe o motivo da restauração.','err');const password=await requirePermissionPassword();if(!password)return;
    const result=await rpc('nexlab_admin_restore_user_permissions_v26264',{p_target_user_id:userId,p_reason:reason(),p_expected_revision:state.matrix.revision,p_admin_password:password});
    requireMutationSuccess(result,'a restauração das permissões');const matrix=await loadFreshMatrix();if(matrix.overrides.some(row=>String(row.user_id)===String(userId)))throw new Error('O banco ainda retornou exceções para o usuário após a restauração.');clearPermissionPassword();toast('Padrões restaurados e confirmados pelo Supabase.','ok');refreshReact(false);
  }

  function refreshReact(forceMatrix=false){
    clearTimeout(state.refreshTimer);state.refreshTimer=setTimeout(()=>{
      if(!state.active)return;
      const page=permissionPage();const button=[...page.querySelectorAll('button')].find(element=>/atualizar/i.test(element.textContent||''));
      state.suppressRefreshGuard=true;button?.click();queueMicrotask(()=>{state.suppressRefreshGuard=false});
      if(forceMatrix){state.lastLoadedAt=0;setTimeout(()=>loadMatrix(true),350)}else scheduleEnhancements(250);
    },220);
  }

  async function handleClick(event){
    if(!state.active)return;
    const preset=event.target.closest?.('[data-action="apply-assistant-preset"]');if(preset){event.preventDefault();applyAssistantPreset();return}
    const historyButton=event.target.closest?.('[data-action="load-history"]');if(historyButton){historyButton.disabled=true;historyButton.textContent='Histórico carregado';await renderHistory();return}
    const button=event.target.closest?.('button');if(!button)return;
    const text=(button.textContent||'').toLowerCase();
    if(/atualizar/.test(text)&&hasPendingChanges()&&!state.suppressRefreshGuard){
      event.preventDefault();event.stopPropagation();event.stopImmediatePropagation();
      if(await confirmAction('Existem alterações ainda não salvas. Deseja descartá-las e recarregar a matriz?')){state.remoteChangePending=false;state.lastLoadedAt=0;refreshReact(true)}
      return;
    }
    if(!/salvar|restaurar/.test(text))return;
    if(button.closest('.nexlab-permission-password-modal'))return;
    event.preventDefault();event.stopPropagation();event.stopImmediatePropagation();button.disabled=true;
    try{if(!state.matrix)await loadMatrix(true);if(!state.matrix)throw new Error('Matriz de permissões indisponível.');if(state.remoteChangePending)throw new Error('A matriz mudou no servidor. Recarregue antes de salvar.');if(/restaurar/.test(text))await restoreUser();else if(activeTab()==='users')await saveUser();else await saveRole()}
    catch(error){console.error(error);if(conflict(error))showConflict();else toast(error.message||'Não foi possível salvar as permissões.','err')}
    finally{button.disabled=false}
  }

  function handleChange(event){if(!state.active)return;enforceDependencies(event.target);queueMicrotask(()=>{syncPasswordField();scheduleEnhancements(80)})}

  function unsubscribeRealtime(){
    if(state.channel){try{const client=window.__NEXLAB_SUPABASE__;if(client?.removeChannel)client.removeChannel(state.channel);else state.channel.unsubscribe?.()}catch{}state.channel=null}
    if(state.fallbackTimer){clearInterval(state.fallbackTimer);state.fallbackTimer=null}
    if(state.reconnectTimer){clearTimeout(state.reconnectTimer);state.reconnectTimer=null}
    state.realtimeStatus='idle';
  }

  function ensureRealtimeFallback(){
    if(state.fallbackTimer)return;
    state.fallbackTimer=setInterval(()=>{if(state.active&&!hasPendingChanges()){state.lastLoadedAt=0;loadMatrix(true)}},60000);
  }

  function scheduleRealtimeReconnect(){
    if(!state.active||state.reconnectTimer)return;
    ensureRealtimeFallback();
    const delay=Math.min(30000,1000*2**Math.min(state.reconnectAttempt++,5));
    state.reconnectTimer=setTimeout(()=>{state.reconnectTimer=null;subscribeRealtime()},delay);
  }

  function handleRemoteChange(){
    clearTimeout(state.refreshTimer);state.refreshTimer=setTimeout(()=>{
      if(!state.active)return;
      if(hasPendingChanges()){
        state.remoteChangePending=true;renderStatus();showConflict('Outra alteração foi recebida. Seus campos locais não foram apagados.');return;
      }
      state.lastLoadedAt=0;refreshReact(true);
    },650);
  }

  async function subscribeRealtime(){
    if(state.channel){try{const client=window.__NEXLAB_SUPABASE__;if(client?.removeChannel)await client.removeChannel(state.channel);else state.channel.unsubscribe?.()}catch{}state.channel=null}
    if(!state.active)return;
    try{
      const client=await getClient();if(!client?.channel)throw new Error('Realtime indisponível.');
      state.realtimeStatus='connecting';
      const channel=client.channel(`nexlab-permissions-r554-${Date.now()}`)
        .on('postgres_changes',{event:'*',schema:'public',table:'nexlab_permission_matrix_state'},handleRemoteChange)
        .on('postgres_changes',{event:'*',schema:'public',table:'nexlab_role_permission_defaults'},handleRemoteChange)
        .on('postgres_changes',{event:'*',schema:'public',table:'nexlab_user_permission_overrides'},handleRemoteChange);
      state.channel=channel;
      channel.subscribe(status=>{
        if(!state.active||state.channel!==channel)return;
        state.realtimeStatus=status;
        if(status==='SUBSCRIBED'){
          state.reconnectAttempt=0;
          if(state.fallbackTimer){clearInterval(state.fallbackTimer);state.fallbackTimer=null}
          return;
        }
        if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)){
          try{client.removeChannel?.(channel)}catch{}
          if(state.channel===channel)state.channel=null;
          scheduleRealtimeReconnect();
        }
      });
    }catch(error){console.warn('Realtime de permissões indisponível; reconexão e fallback ativos.',error);state.realtimeStatus='error';scheduleRealtimeReconnect()}
  }

  function enterScreen(root){
    state.active=true;state.root=root;state.sidebar=document.querySelector('.permission-sidebar-card');state.historyLoaded=false;state.remoteChangePending=false;
    document.documentElement.dataset.nexlabVersion=VERSION;
    loadMatrix(false);scheduleEnhancements(120);subscribeRealtime();
  }
  function leaveScreen(){
    state.active=false;state.root=null;state.sidebar=null;state.remoteChangePending=false;clearTimeout(state.enhanceTimer);clearTimeout(state.refreshTimer);unsubscribeRealtime();clearPermissionPassword();document.querySelector('.nexlab-permission-password-modal')?.remove();document.querySelector('.nexlab-r550-assistant-preset')?.remove();document.querySelector('.nexlab-r550-delegation-summary')?.remove();document.querySelector('.nexlab-p2-status')?.remove();document.querySelector('.nexlab-p2-history')?.remove();document.querySelector('.nexlab-p2-conflict')?.remove();
  }

  function routeTick(){
    state.routeTimer=null;const root=permissionRoot();
    if(root&&!state.active){enterScreen(root);return}
    if(!root&&state.active){leaveScreen();return}
    if(root&&state.active&&root!==state.root){state.root=root;state.sidebar=null;scheduleEnhancements(80);return}
    if(root&&state.active){const sidebar=document.querySelector('.permission-sidebar-card');const needsPassword=sidebar&&!sidebar.querySelector('.nexlab-permission-password-inline');const needsStatus=!permissionPage().querySelector('.nexlab-p2-status');if(needsPassword||needsStatus)scheduleEnhancements(0)}
  }
  function scheduleRouteTick(){if(state.routeTimer)return;state.routeTimer=setTimeout(routeTick,80)}

  document.addEventListener('click',handleClick,true);
  document.addEventListener('change',handleChange,true);
  window.addEventListener('popstate',scheduleRouteTick);
  window.addEventListener('hashchange',scheduleRouteTick);
  state.observer=new MutationObserver(scheduleRouteTick);
  state.observer.observe(document.getElementById('root')||document.body,{childList:true,subtree:true});
  routeTick();

  window.__NEXLAB_PERMISSIONS_R5543__={
    version:VERSION,
    reload:()=>{state.lastLoadedAt=0;return loadMatrix(true)},
    destroy:()=>{leaveScreen();state.observer?.disconnect();clearTimeout(state.routeTimer);window.removeEventListener('popstate',scheduleRouteTick);window.removeEventListener('hashchange',scheduleRouteTick);document.removeEventListener('click',handleClick,true);document.removeEventListener('change',handleChange,true)},
    snapshot:()=>({active:state.active,loading:state.loading,revision:state.matrix?.revision||null,complete:state.matrix?.summary?.matrix_complete||false,permissions:state.matrix?.catalog?.length||0,dependencies:state.matrix?.dependencies?.length||0,realtime:Boolean(state.channel),realtimeStatus:state.realtimeStatus,reconnectAttempt:state.reconnectAttempt,historyLoaded:state.historyLoaded,pendingChanges:hasPendingChanges(),remoteChangePending:state.remoteChangePending})
  };
})();
