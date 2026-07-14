(function(){
  'use strict';
  if(window.__NEXLAB_PERMISSIONS_PHASE2__) return;

  const VERSION='26.26.3';
  const PROJECT_REF='eahldhabwulnwhuwrhvc';
  const BASE_URL=(window.__NEXLAB_CONFIG__?.supabaseUrl||`https://${PROJECT_REF}.supabase.co`).replace(/\/$/,'');
  const ANON_KEY=window.__NEXLAB_CONFIG__?.supabaseAnonKey||'sb_publishable_hr-WTQUBbBE0Ei3Lr2hkhQ_XSKG_PXa';
  const state={matrix:null,page:1,pageSize:20,scope:'',search:'',loading:false,observer:null,channel:null,refreshTimer:null};

  function token(){
    const candidates=[`sb-${PROJECT_REF}-auth-token`,...Object.keys(localStorage).filter(k=>k.includes(PROJECT_REF)&&k.includes('auth-token'))];
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
    const access=token();
    if(!access) throw new Error('Sessão autenticada não localizada. Recarregue o aplicativo.');
    const response=await fetch(`${BASE_URL}/rest/v1/rpc/${name}`,{
      method:'POST',cache:'no-store',headers:{apikey:ANON_KEY,Authorization:`Bearer ${access}`,'Content-Type':'application/json','Cache-Control':'no-cache'},body:JSON.stringify(body)
    });
    const text=await response.text();
    let data=null; try{data=text?JSON.parse(text):null}catch{data=text}
    if(!response.ok){const error=new Error(data?.message||data?.hint||`Falha ${response.status}`);error.code=data?.code;error.details=data?.details;throw error}
    return data;
  }

  function toast(message,tone='info'){
    if(typeof window.nexlabToast==='function') return window.nexlabToast(message,tone);
    const el=document.createElement('div');el.className='nexlab-p2-conflict';el.innerHTML=`<strong>${tone==='err'?'Atenção':'Permissões'}</strong><span></span>`;el.querySelector('span').textContent=message;document.body.appendChild(el);setTimeout(()=>el.remove(),6000);
  }

  function visibleElement(element){
    if(!element)return false;
    const style=getComputedStyle(element),rect=element.getBoundingClientRect();
    return style.display!=='none'&&style.visibility!=='hidden'&&rect.width>0&&rect.height>0;
  }
  function findSaveButton(){
    return [...document.querySelectorAll('button')].find(button=>visibleElement(button)&&/salvar\s+\d+\s+altera|salvar/i.test((button.textContent||'').trim()))||null;
  }
  function permissionPage(){
    const save=findSaveButton();
    if(!save)return null;
    return save.closest('main')||document.querySelector('main')||document.body;
  }
  function isPermissionScreen(){
    const save=findSaveButton();
    if(!save)return false;
    const pageText=((document.querySelector('h1,h2,[role="heading"]')?.textContent||'')+' '+(document.title||'')+' '+(document.body?.innerText||'').slice(0,1200)).toLowerCase();
    return pageText.includes('permiss');
  }
  function positionSensitivePasswordField(){
    const panel=document.querySelector('.nexlab-sensitive-password-portal'),save=findSaveButton();
    if(!panel||!save||!isPermissionScreen()){if(panel)panel.hidden=true;return}
    panel.hidden=false;
    const rect=save.getBoundingClientRect();
    const width=Math.max(280,Math.min(420,rect.width||320));
    panel.style.width=`${width}px`;
    panel.style.left=`${Math.max(12,Math.min(window.innerWidth-width-12,rect.left))}px`;
    const desiredTop=rect.bottom+10;
    const maxTop=window.innerHeight-panel.offsetHeight-12;
    panel.style.top=`${Math.max(12,Math.min(desiredTop,maxTop))}px`;
  }
  function createSensitivePasswordMarkup(className){
    const panel=document.createElement('section');panel.className=className;
    panel.innerHTML=`<div class="nexlab-sensitive-password-inline-head"><span aria-hidden="true">🔐</span><div><strong>Senha administrativa</strong><small>Obrigatória somente para ativar “Exportar dados pessoais identificáveis”.</small></div></div><label>Digite a senha</label><div class="nexlab-sensitive-password-input-wrap"><input type="password" autocomplete="current-password" placeholder="Senha administrativa"><button type="button" class="nexlab-sensitive-password-toggle" aria-label="Mostrar senha">Mostrar</button></div><div class="nexlab-sensitive-password-inline-error" aria-live="polite"></div>`;
    const input=panel.querySelector('input'),toggle=panel.querySelector('.nexlab-sensitive-password-toggle');
    input.addEventListener('input',()=>{panel.querySelector('.nexlab-sensitive-password-inline-error').textContent='';panel.dataset.filled=input.value?'true':'false'});
    toggle.addEventListener('click',()=>{const visible=input.type==='text';input.type=visible?'password':'text';toggle.textContent=visible?'Mostrar':'Ocultar';toggle.setAttribute('aria-label',visible?'Mostrar senha':'Ocultar senha')});
    return panel;
  }
  function ensureSensitivePasswordField(){
    if(!isPermissionScreen())return null;
    let panel=document.querySelector('.nexlab-sensitive-password-portal');
    if(!panel){panel=createSensitivePasswordMarkup('nexlab-sensitive-password-inline nexlab-sensitive-password-portal');document.body.appendChild(panel)}
    syncSensitivePasswordField();requestAnimationFrame(positionSensitivePasswordField);return panel;
  }
  function sensitivePassword(){return document.querySelector('.nexlab-sensitive-password-portal input')?.value||''}
  function clearSensitivePassword(){for(const panel of document.querySelectorAll('.nexlab-sensitive-password-portal,.nexlab-sensitive-password-modal-card')){const input=panel.querySelector('input');if(input)input.value='';panel.dataset.filled='false';const error=panel.querySelector('.nexlab-sensitive-password-inline-error');if(error)error.textContent=''}}
  function showSensitivePasswordError(message){const panel=ensureSensitivePasswordField();if(panel){panel.dataset.required='true';panel.querySelector('.nexlab-sensitive-password-inline-error').textContent=message;const input=panel.querySelector('input');input.focus();positionSensitivePasswordField()}return requestSensitivePassword(message)}
  function requestSensitivePassword(message='Digite a senha administrativa para continuar.'){
    return new Promise(resolve=>{
      document.querySelector('.nexlab-sensitive-password-modal')?.remove();
      const overlay=document.createElement('div');overlay.className='nexlab-sensitive-password-modal';overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');
      const card=createSensitivePasswordMarkup('nexlab-sensitive-password-modal-card');
      card.insertAdjacentHTML('beforeend','<div class="nexlab-sensitive-password-modal-actions"><button type="button" data-action="cancel">Cancelar</button><button type="button" data-action="confirm">Confirmar senha</button></div>');
      const error=card.querySelector('.nexlab-sensitive-password-inline-error');error.textContent=message;
      overlay.appendChild(card);document.body.appendChild(overlay);
      const input=card.querySelector('input');setTimeout(()=>input.focus(),30);
      const finish=value=>{overlay.remove();resolve(value)};
      card.querySelector('[data-action="cancel"]').onclick=()=>finish(null);
      card.querySelector('[data-action="confirm"]').onclick=()=>{const value=input.value;if(!value){error.textContent='Informe a senha administrativa.';input.focus();return}const portal=ensureSensitivePasswordField();const portalInput=portal?.querySelector('input');if(portalInput){portalInput.value=value;portal.dataset.filled='true'}finish(value)};
      input.addEventListener('keydown',event=>{if(event.key==='Enter'){event.preventDefault();card.querySelector('[data-action="confirm"]').click()}if(event.key==='Escape')finish(null)});
      overlay.addEventListener('click',event=>{if(event.target===overlay)finish(null)});
    })
  }
  function sensitiveGrantPending(){try{return activeTab()==='users'?changedOverrides().action_sensitive_export==='allow':changedRolePermissions().action_sensitive_export===true}catch{return false}}
  function syncSensitivePasswordField(){const panel=document.querySelector('.nexlab-sensitive-password-portal');if(!panel)return;const pending=sensitiveGrantPending();panel.dataset.required=pending?'true':'false';const hint=panel.querySelector('small');if(hint)hint.textContent=pending?'Digite a senha antes de salvar esta concessão.':'Obrigatória somente para ativar “Exportar dados pessoais identificáveis”.';positionSensitivePasswordField()}

  function activeRole(){const text=document.querySelector('.permission-role-button.is-active')?.textContent?.trim().toLowerCase()||'';return text.includes('admin')?'admin':text.includes('coorden')?'coordenador':text.includes('bols')?'bolsista':text.includes('júnior')||text.includes('junior')?'coworking_junior':'admin'}
  function activeTab(){return document.querySelector('.permission-tab.is-active')?.textContent?.toLowerCase().includes('exce')?'users':'roles'}
  function reason(){return document.querySelector('.permission-sidebar-card textarea')?.value?.trim()||''}
  function labelMap(){return new Map((state.matrix?.catalog||[]).map(item=>[String(item.label||'').trim(),item]))}
  function defaultMap(){return new Map((state.matrix?.defaults||[]).map(item=>[`${item.role_key}:${item.permission_key}`,item]))}
  function dependencyMap(){const map=new Map();for(const row of state.matrix?.dependencies||[]){if(!map.has(row.permission_key))map.set(row.permission_key,[]);map.get(row.permission_key).push(row)}return map}

  function updateMetaVersion(){let meta=document.querySelector('meta[name="nexlab-version"]');if(meta)meta.content=VERSION;document.documentElement.dataset.nexlabVersion=VERSION}

  async function loadMatrix(){
    if(state.loading)return;state.loading=true;
    try{state.matrix=await rpc('nexlab_get_permission_matrix');renderStatus();annotateDependencies();await renderHistory();}
    catch(error){console.error('Fase 2 Permissões:',error);}
    finally{state.loading=false}
  }

  function renderStatus(){
    const page=permissionPage();if(!page||!state.matrix)return;
    let box=page.querySelector('.nexlab-p2-status');if(!box){box=document.createElement('section');box.className='nexlab-p2-status';const metrics=page.querySelector('.compact-metrics');metrics?.insertAdjacentElement('afterend',box)}
    const summary=state.matrix.summary||{};box.innerHTML=`
      <div class="nexlab-p2-metric" data-tone="${summary.matrix_complete?'ok':'warn'}"><span>Matriz explícita</span><strong>${summary.actual_pairs||0}/${summary.expected_pairs||0}</strong></div>
      <div class="nexlab-p2-metric"><span>Revisão concorrente</span><strong>#${state.matrix.revision||0}</strong></div>
      <div class="nexlab-p2-metric"><span>Dependências</span><strong>${(state.matrix.dependencies||[]).length}</strong></div>
      <div class="nexlab-p2-metric" data-tone="ok"><span>Sincronização</span><strong class="nexlab-p2-live">Tempo real</strong></div>`;
  }

  function annotateDependencies(){
    if(!state.matrix)return;const labels=labelMap(),deps=dependencyMap();
    for(const item of document.querySelectorAll('.permission-content-card .permission-item')){
      const title=item.querySelector('strong')?.textContent?.trim();const permission=labels.get(title);if(!permission)continue;
      item.dataset.permissionKey=permission.permission_key;
      if(permission.permission_key==='action_sensitive_export'){
        const description=item.querySelector('.permission-item-copy p');
        if(description)description.textContent='Permite gerar relatório restrito com CPF e data de nascimento. Exige senha administrativa e auditoria.';
      }
      item.querySelector('.nexlab-p2-dependency')?.remove();
      const required=deps.get(permission.permission_key)||[];if(required.length){const line=document.createElement('span');line.className='nexlab-p2-dependency';line.textContent=`Exige: ${required.map(row=>row.required_label).join(', ')}`;item.querySelector('.permission-item-copy')?.appendChild(line)}
    }
  }

  function findItem(permissionKey){return document.querySelector(`.permission-item[data-permission-key="${CSS.escape(permissionKey)}"]`)}
  function enforceDependencies(target){
    const item=target.closest('.permission-item');const key=item?.dataset.permissionKey;if(!key||!state.matrix)return;
    const deps=dependencyMap();
    if(target.matches('input[type="checkbox"]')&&target.checked){for(const row of deps.get(key)||[]){const req=findItem(row.required_permission_key)?.querySelector('input[type="checkbox"]');if(req&&!req.disabled&&!req.checked){req.click()}}}
    if(target.matches('select')&&target.value==='allow'){for(const row of deps.get(key)||[]){const req=findItem(row.required_permission_key)?.querySelector('select');if(req&&!req.disabled&&req.value!=='allow'){req.value='allow';req.dispatchEvent(new Event('change',{bubbles:true}))}}}
    if(target.matches('input[type="checkbox"]')&&!target.checked){for(const row of state.matrix.dependencies||[]){if(row.required_permission_key!==key)continue;const dependent=findItem(row.permission_key)?.querySelector('input[type="checkbox"]');if(dependent&&!dependent.disabled&&dependent.checked)dependent.click()}}
  }

  function changedRolePermissions(){
    const role=activeRole(),defaults=defaultMap(),labels=labelMap(),changed={};
    for(const item of document.querySelectorAll('.permission-content-card .permission-item')){
      const permission=labels.get(item.querySelector('strong')?.textContent?.trim());const input=item.querySelector('input[type="checkbox"]');if(!permission||!input||input.disabled)continue;
      const current=Boolean(defaults.get(`${role}:${permission.permission_key}`)?.allowed);if(current!==input.checked)changed[permission.permission_key]=input.checked;
    }return changed;
  }

  function selectedUser(){const select=document.querySelector('.permission-sidebar-card select');return select?.value||''}
  function changedOverrides(){
    const user=selectedUser(),labels=labelMap(),existing=new Map((state.matrix?.overrides||[]).filter(r=>String(r.user_id)===String(user)).map(r=>[r.permission_key,r.effect])),changed={};
    for(const item of document.querySelectorAll('.permission-content-card .permission-user-item')){
      const permission=labels.get(item.querySelector('strong')?.textContent?.trim());const select=item.querySelector('select');if(!permission||!select||select.disabled)continue;
      const before=existing.get(permission.permission_key)||'default';if(before!==select.value)changed[permission.permission_key]=select.value;
    }return changed;
  }

  function conflict(error){return error?.code==='40001'||/alterada por outro|recarregue/i.test(error?.message||'')}
  function showConflict(){
    document.querySelector('.nexlab-p2-conflict')?.remove();const box=document.createElement('div');box.className='nexlab-p2-conflict';box.innerHTML='<strong>Matriz atualizada por outro Administrador</strong><span>Seus dados locais ficaram desatualizados. Recarregue a matriz antes de salvar novamente.</span><button type="button">Recarregar matriz</button>';box.querySelector('button').onclick=()=>{box.remove();refreshReact();};document.body.appendChild(box)
  }

  async function saveRole(){
    const changes=changedRolePermissions();if(!Object.keys(changes).length)return toast('Nenhuma alteração pendente.','info');if(!reason())return toast('Informe o motivo da alteração.','err');
    let password=null;if(changes.action_sensitive_export===true){password=sensitivePassword();if(!password)password=await requestSensitivePassword('Informe a senha administrativa para conceder esta permissão.');if(!password)return toast('A concessão foi cancelada porque a senha não foi informada.','err')}
    await rpc('nexlab_admin_save_role_permissions_v26261',{p_role:activeRole(),p_permissions:changes,p_reason:reason(),p_expected_revision:state.matrix.revision,p_sensitive_password:password});
    clearSensitivePassword();toast('Padrões salvos com revisão segura.','ok');refreshReact()
  }
  async function saveUser(){
    const changes=changedOverrides();if(!Object.keys(changes).length)return toast('Nenhuma alteração pendente.','info');if(!reason())return toast('Informe o motivo da alteração.','err');
    let password=null;if(changes.action_sensitive_export==='allow'){password=sensitivePassword();if(!password)password=await requestSensitivePassword('Informe a senha administrativa para conceder esta permissão.');if(!password)return toast('A concessão foi cancelada porque a senha não foi informada.','err')}
    await rpc('nexlab_admin_save_user_permissions_v26261',{p_target_user_id:selectedUser(),p_overrides:changes,p_reason:reason(),p_expected_revision:state.matrix.revision,p_sensitive_password:password});
    clearSensitivePassword();toast('Exceções salvas com revisão segura.','ok');refreshReact()
  }
  async function restoreUser(){if(!reason())return toast('Informe o motivo da restauração.','err');await rpc('nexlab_admin_restore_user_permissions',{p_target_user_id:selectedUser(),p_reason:reason(),p_expected_revision:state.matrix.revision});toast('Padrões restaurados com revisão segura.','ok');refreshReact()}

  function refreshReact(){clearTimeout(state.refreshTimer);state.refreshTimer=setTimeout(()=>{const button=[...document.querySelectorAll('button')].find(b=>/atualizar/i.test(b.textContent||''));button?.click();setTimeout(loadMatrix,600)},150)}

  async function handleAction(event){
    const button=event.target.closest?.('button');if(!button||!isPermissionScreen())return;
    const text=(button.textContent||'').toLowerCase();if(!/salvar|restaurar/.test(text))return;
    event.preventDefault();event.stopPropagation();event.stopImmediatePropagation();button.disabled=true;
    try{if(/restaurar/.test(text))await restoreUser();else if(activeTab()==='users')await saveUser();else await saveRole();}
    catch(error){console.error(error);if(conflict(error))showConflict();else toast(error.message||'Não foi possível salvar as permissões.','err')}
    finally{button.disabled=false}
  }

  async function renderHistory(){
    const page=permissionPage();if(!page)return;let card=page.querySelector('.nexlab-p2-history');if(!card){card=document.createElement('section');card.className='nexlab-p2-history';page.appendChild(card)}
    let result;try{result=await rpc('nexlab_list_permission_history_v26260',{p_page:state.page,p_page_size:state.pageSize,p_scope:state.scope||null,p_role:null,p_user_id:null,p_permission_key:null,p_search:state.search||null})}catch{return}
    const rows=result?.rows||[],pagination=result?.pagination||{};card.innerHTML=`<div class="nexlab-p2-history-head"><h3>Histórico completo de permissões</h3><div class="nexlab-p2-filters"><input type="search" placeholder="Buscar responsável, usuário ou motivo" value="${escapeHtml(state.search)}"><select><option value="">Todos os tipos</option><option value="role_default" ${state.scope==='role_default'?'selected':''}>Padrões de perfil</option><option value="user_override" ${state.scope==='user_override'?'selected':''}>Exceções individuais</option><option value="restore_defaults" ${state.scope==='restore_defaults'?'selected':''}>Restaurações</option></select></div></div><div class="nexlab-p2-history-list">${rows.length?rows.map(row=>`<article class="nexlab-p2-row"><div><strong>${escapeHtml(row.permission_label||row.permission_key||row.scope)}</strong><p>${escapeHtml(row.user_name||row.role_key||'Matriz')} — ${escapeHtml(row.reason||'Sem motivo informado')}</p><small>Por ${escapeHtml(row.actor_name||row.actor_email||'Sistema')} · ${escapeHtml(row.previous_value||'—')} → ${escapeHtml(row.next_value||'—')}</small></div><time>${new Date(row.created_at).toLocaleString('pt-BR')}</time></article>`).join(''):'<p class="permission-empty">Nenhum registro encontrado.</p>'}</div><div class="nexlab-p2-pages"><span>Página ${pagination.page||1} de ${pagination.pages||0} · ${pagination.total||0} registro(s)</span><button type="button" data-page="prev" ${Number(pagination.page||1)<=1?'disabled':''}>Anterior</button><button type="button" data-page="next" ${!pagination.has_more?'disabled':''}>Próxima</button></div>`;
    const search=card.querySelector('input');let timer;search.oninput=()=>{clearTimeout(timer);timer=setTimeout(()=>{state.search=search.value.trim();state.page=1;renderHistory()},450)};card.querySelector('select').onchange=e=>{state.scope=e.target.value;state.page=1;renderHistory()};card.querySelector('[data-page="prev"]')?.addEventListener('click',()=>{state.page=Math.max(1,state.page-1);renderHistory()});card.querySelector('[data-page="next"]')?.addEventListener('click',()=>{state.page+=1;renderHistory()});
  }

  function escapeHtml(value){const span=document.createElement('span');span.textContent=String(value??'');return span.innerHTML}

  async function realtime(){
    try{
      const {createClient}=await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');const client=createClient(BASE_URL,ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});const storage=JSON.parse(localStorage.getItem(`sb-${PROJECT_REF}-auth-token`)||'null');if(storage?.access_token&&storage?.refresh_token)await client.auth.setSession({access_token:storage.access_token,refresh_token:storage.refresh_token});
      state.channel=client.channel('nexlab-permissions-v26260').on('postgres_changes',{event:'*',schema:'public',table:'nexlab_permission_matrix_state'},()=>refreshReact()).on('postgres_changes',{event:'*',schema:'public',table:'nexlab_role_permission_defaults'},()=>refreshReact()).on('postgres_changes',{event:'*',schema:'public',table:'nexlab_user_permission_overrides'},()=>refreshReact()).subscribe();
    }catch(error){console.warn('Realtime de permissões indisponível; usando atualização periódica.',error);setInterval(()=>permissionPage()&&loadMatrix(),60000)}
  }

  function observe(){
    state.observer=new MutationObserver(()=>{if(isPermissionScreen()){renderStatus();annotateDependencies();ensureSensitivePasswordField();positionSensitivePasswordField();if(!state.matrix)loadMatrix()}else{const panel=document.querySelector('.nexlab-sensitive-password-portal');if(panel)panel.hidden=true}});state.observer.observe(document.documentElement,{childList:true,subtree:true});document.addEventListener('click',handleAction,true);document.addEventListener('change',event=>{if(isPermissionScreen()){enforceDependencies(event.target);setTimeout(()=>{syncSensitivePasswordField();ensureSensitivePasswordField();positionSensitivePasswordField()},0)}},true);window.addEventListener('resize',positionSensitivePasswordField,{passive:true});window.addEventListener('scroll',positionSensitivePasswordField,{passive:true,capture:true});setInterval(()=>{if(isPermissionScreen()){ensureSensitivePasswordField();positionSensitivePasswordField()}},1500);
  }

  updateMetaVersion();observe();loadMatrix();realtime();setTimeout(ensureSensitivePasswordField,300);
  window.__NEXLAB_PERMISSIONS_PHASE2__={version:VERSION,reload:loadMatrix,snapshot:()=>({revision:state.matrix?.revision||null,complete:state.matrix?.summary?.matrix_complete||false,permissions:state.matrix?.catalog?.length||0,dependencies:state.matrix?.dependencies?.length||0})};
})();
