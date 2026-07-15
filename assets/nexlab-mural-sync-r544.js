(function(){
  'use strict';
  const VERSION='26.30.8';
  const RELEASE='R55.4.4';
  const KEY='__NEXLAB_MURAL_R544__';
  const STORAGE_PREFIX='storage://mural-media/';
  const ALLOWED_TYPES=new Set(['image/jpeg','image/png','image/webp']);
  const MAX_FILE_BYTES=5*1024*1024;
  if(window[KEY]?.version===VERSION)return;

  const state={root:null,legacy:null,observer:null,timer:null,mountTimer:null,reloadTimer:null,fallbackTimer:null,channel:null,mode:'active',loading:false,saving:false,data:null,editing:null,idempotencyKey:null,selectedFile:null,removeCover:false,previewObjectUrl:null,signedCache:new Map(),syncState:'connecting',lastSync:null,pendingReload:false};
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const norm=value=>String(value||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();
  const fmt=value=>{const date=new Date(value);return Number.isNaN(date.getTime())?'Data não informada':date.toLocaleString('pt-BR',{day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit'}).replace('.','');};
  const client=()=>window.__NEXLAB_SUPABASE__;
  const storagePath=value=>String(value||'').startsWith(STORAGE_PREFIX)?String(value).slice(STORAGE_PREFIX.length):null;
  const uuid=()=>crypto.randomUUID?.()||`${Date.now()}-${Math.random().toString(16).slice(2)}`;

  async function rpc(name,args={}){
    const supabase=client();
    if(!supabase?.rpc)throw new Error('Cliente autenticado indisponível. Recarregue o aplicativo.');
    const {data,error}=await supabase.rpc(name,args);
    if(error)throw error;
    return data;
  }
  function toast(message,tone='info'){
    if(typeof window.nexlabToast==='function')return window.nexlabToast(message,tone);
    window.alert(message);
  }
  function visible(element){
    if(!element)return false;
    const style=getComputedStyle(element),rect=element.getBoundingClientRect();
    return style.display!=='none'&&style.visibility!=='hidden'&&rect.width>0&&rect.height>0;
  }
  function findLegacy(){
    const managed=document.querySelector('.module-shell[data-nexlab-mural-legacy="true"]');
    if(managed&&visible(managed.parentElement))return managed;
    return [...document.querySelectorAll('.module-shell')].find(element=>{
      if(element.closest('[data-nexlab-mural-r544]')||!visible(element))return false;
      const text=norm(element.textContent);
      return text.includes('mural de comunicados')||(text.includes('mural interno')&&text.includes('nova publicacao'));
    })||null;
  }
  function isMural(){return Boolean(findLegacy());}
  function shell(){
    return `<section class="nexlab-mural-r544" data-nexlab-mural-r544="true" aria-labelledby="mural-r544-title">
      <header class="mural-r544-hero">
        <div><span>Comunicação interna</span><h1 id="mural-r544-title">Mural de comunicados</h1><p>Publicações com rastreabilidade, mídia privada e proteção contra envios duplicados.</p></div>
        <div class="mural-r544-status"><div class="mural-r544-sync" data-role="sync" data-state="connecting" role="status" aria-live="polite"><span class="mural-r544-sync-dot" aria-hidden="true"></span><span data-role="sync-label">Conectando ao tempo real…</span></div><div class="mural-r544-version">${RELEASE} · v${VERSION}</div></div>
      </header>
      <div class="mural-r544-alert" data-role="alert" hidden></div>
      <div class="mural-r544-toolbar" data-role="toolbar"></div>
      <div class="mural-r544-editor" data-role="editor" hidden></div>
      <div class="mural-r544-feed" data-role="feed" aria-live="polite"></div>
    </section>`;
  }
  function mount(){
    const legacy=findLegacy();
    if(!legacy)return unmount();
    if(state.root&&state.legacy===legacy)return;
    unmount();
    state.legacy=legacy;
    legacy.dataset.nexlabMuralLegacy='true';
    legacy.style.display='none';
    const holder=document.createElement('div');
    holder.innerHTML=shell();
    state.root=holder.firstElementChild;
    legacy.insertAdjacentElement('afterend',state.root);
    bind();
    connectRealtime();
    load();
  }
  function revokePreview(){
    if(state.previewObjectUrl){URL.revokeObjectURL(state.previewObjectUrl);state.previewObjectUrl=null;}
  }
  function resetEditorState(){
    revokePreview();
    state.editing=null;
    state.idempotencyKey=null;
    state.selectedFile=null;
    state.removeCover=false;
    state.saving=false;
  }
  function unmount(){
    disconnectRealtime();
    resetEditorState();
    if(state.root)state.root.remove();
    if(state.legacy){state.legacy.style.display='';delete state.legacy.dataset.nexlabMuralLegacy;}
    state.root=null;state.legacy=null;state.data=null;
  }
  function bind(){
    state.root.addEventListener('click',async event=>{
      const button=event.target.closest('[data-action]');
      if(!button||state.saving)return;
      const action=button.dataset.action,id=button.dataset.id;
      if(action==='new')return openEditor();
      if(action==='cancel')return closeEditor();
      if(action==='active'||action==='archived'){state.mode=action;closeEditor();return load();}
      if(action==='refresh')return load();
      if(action==='remove-cover')return markCoverRemoval();
      const post=(state.data?.rows||[]).find(item=>String(item.id)===String(id));
      if(!post)return;
      if(action==='edit')return openEditor(post);
      if(action==='pin'||action==='unpin')return moderate(post,action);
      if(action==='archive')return archive(post);
      if(action==='restore')return restore(post);
    });
    state.root.addEventListener('submit',async event=>{
      if(!event.target.matches('[data-form="post"]'))return;
      event.preventDefault();
      await save(new FormData(event.target),event.target);
    });
    state.root.addEventListener('change',event=>{
      if(event.target.matches('input[name="cover_file"]'))handleFileSelection(event.target.files?.[0]||null);
    });
  }
  function renderToolbar(){
    const permissions=state.data?.permissions||{};
    const toolbar=state.root.querySelector('[data-role="toolbar"]');
    toolbar.innerHTML=`<div class="mural-r544-tabs" role="tablist" aria-label="Situação das publicações">
      <button data-action="active" role="tab" aria-selected="${state.mode==='active'}" class="${state.mode==='active'?'active':''}">Publicações ativas</button>
      ${permissions.moderate?`<button data-action="archived" role="tab" aria-selected="${state.mode==='archived'}" class="${state.mode==='archived'?'active':''}">Arquivadas</button>`:''}
    </div><div class="mural-r544-actions">
      ${permissions.publish&&state.mode==='active'?'<button class="primary" data-action="new">Nova publicação</button>':''}
      <button data-action="refresh">Atualizar</button>
    </div>`;
  }
  async function signedUrl(value){
    const path=storagePath(value);
    if(!path)return null;
    if(state.signedCache.has(path))return state.signedCache.get(path);
    const supabase=client();
    if(!supabase?.storage)return null;
    const {data,error}=await supabase.storage.from('mural-media').createSignedUrl(path,3600);
    if(error)return null;
    const url=data?.signedUrl||null;
    if(url)state.signedCache.set(path,url);
    return url;
  }
  async function hydrateCovers(rows){
    await Promise.all(rows.map(async post=>{post._cover_signed_url=await signedUrl(post.capa_url);}));
    return rows;
  }
  function editedMeta(post){
    if(!post.updated_at)return '';
    const created=new Date(post.created_at).getTime(),updated=new Date(post.updated_at).getTime();
    if(!Number.isFinite(updated)||updated-created<1000)return '';
    return `<span>Editado em ${fmt(post.updated_at)}${post.updated_by_name?` por ${esc(post.updated_by_name)}`:''}</span>`;
  }
  function sortRows(rows){
    return [...(rows||[])].sort((a,b)=>{
      if(state.mode==='archived'){
        const archivedDiff=new Date(b.archived_at||0).getTime()-new Date(a.archived_at||0).getTime();
        if(archivedDiff)return archivedDiff;
      }else if(Boolean(a.fixado)!==Boolean(b.fixado))return a.fixado?-1:1;
      const createdDiff=new Date(b.created_at||0).getTime()-new Date(a.created_at||0).getTime();
      return createdDiff||String(b.id||'').localeCompare(String(a.id||''));
    });
  }
  function setSync(stateName,label){
    state.syncState=stateName;
    const element=state.root?.querySelector('[data-role="sync"]');
    const text=element?.querySelector('[data-role="sync-label"]');
    if(element)element.dataset.state=stateName;
    if(text)text.textContent=label;
  }
  function disconnectRealtime(){
    clearTimeout(state.reloadTimer);state.reloadTimer=null;
    clearInterval(state.fallbackTimer);state.fallbackTimer=null;
    const supabase=client();
    if(state.channel&&supabase?.removeChannel)supabase.removeChannel(state.channel).catch?.(()=>{});
    state.channel=null;
  }
  function scheduleReload(source='realtime'){
    if(!state.root)return;
    if(state.loading){state.pendingReload=true;return;}
    clearTimeout(state.reloadTimer);
    setSync('updating',source==='realtime'?'Nova atividade recebida. Atualizando…':'Sincronizando…');
    state.reloadTimer=setTimeout(()=>load({silent:true,source}),280);
  }
  function connectRealtime(){
    disconnectRealtime();
    const supabase=client();
    if(!supabase?.channel){setSync('fallback','Atualização automática a cada 60 s');return;}
    setSync('connecting','Conectando ao tempo real…');
    state.channel=supabase.channel(`nexlab-mural-r544-${uuid()}`)
      .on('postgres_changes',{event:'*',schema:'public',table:'board_posts'},()=>scheduleReload('realtime'))
      .subscribe(status=>{
        if(status==='SUBSCRIBED')setSync('live','Tempo real ativo');
        else if(status==='CHANNEL_ERROR'||status==='TIMED_OUT'||status==='CLOSED')setSync('fallback','Tempo real indisponível · fallback de 60 s');
      });
    state.fallbackTimer=setInterval(()=>{
      if(state.root&&!document.hidden&&!state.saving)scheduleReload('fallback');
    },60000);
  }
  function render(){
    renderToolbar();
    const feed=state.root.querySelector('[data-role="feed"]'),rows=sortRows(state.data?.rows||[]);
    if(!rows.length){
      feed.innerHTML=`<div class="mural-r544-empty"><strong>${state.mode==='archived'?'Nenhuma publicação arquivada':'O Mural ainda não possui publicações'}</strong><span>${state.mode==='archived'?'As publicações arquivadas poderão ser restauradas aqui.':'Use “Nova publicação” para criar o primeiro comunicado.'}</span></div>`;
      return;
    }
    feed.innerHTML=rows.map(post=>{
      const archived=Boolean(post.archived_at),controls=[];
      if(post.can_edit&&!archived)controls.push(`<button data-action="edit" data-id="${esc(post.id)}">Editar</button>`);
      if(post.can_moderate&&!archived)controls.push(`<button data-action="${post.fixado?'unpin':'pin'}" data-id="${esc(post.id)}">${post.fixado?'Desafixar':'Fixar'}</button>`,`<button class="danger" data-action="archive" data-id="${esc(post.id)}">Arquivar</button>`);
      if(post.can_moderate&&archived)controls.push(`<button class="primary" data-action="restore" data-id="${esc(post.id)}">Restaurar</button>`);
      return `<article class="mural-r544-card ${post.fixado?'pinned':''} ${archived?'archived':''}">
        ${post._cover_signed_url?`<figure class="mural-r544-cover"><img src="${esc(post._cover_signed_url)}" alt="Capa da publicação ${esc(post.titulo||'')}" loading="lazy"></figure>`:''}
        <div class="mural-r544-card-body">
          <div class="mural-r544-card-top"><div>${post.fixado?'<span class="mural-r544-badge">Fixado</span>':''}${archived?'<span class="mural-r544-badge muted">Arquivado</span>':''}</div><div class="mural-r544-card-actions">${controls.join('')}</div></div>
          <h2>${esc(post.titulo||'Comunicado sem título')}</h2>
          <p>${esc(post.conteudo||'').replace(/\n/g,'<br>')}</p>
          <footer><span>Publicado por ${esc(post.author_name||'Usuário removido')} em ${fmt(post.created_at)}</span>${editedMeta(post)}</footer>
          ${archived?`<div class="mural-r544-archive-info"><strong>Motivo:</strong> ${esc(post.archive_reason||'Não informado')}<br><small>Arquivada em ${fmt(post.archived_at)}${post.archived_by_name?` por ${esc(post.archived_by_name)}`:''}</small></div>`:''}
        </div>
      </article>`;
    }).join('');
  }
  async function load(options={}){
    if(!state.root)return;
    if(state.loading){state.pendingReload=true;return;}
    const silent=Boolean(options.silent&&state.data);
    state.loading=true;
    if(!silent)state.root.querySelector('[data-role="feed"]').innerHTML='<div class="mural-r544-loading">Carregando publicações…</div>';
    try{
      state.data=await rpc('nexlab_list_board_posts_v26293',{p_archived:state.mode==='archived'});
      state.data.rows=sortRows(state.data?.rows||[]);
      await hydrateCovers(state.data.rows);
      state.lastSync=new Date();
      render();
      setSync(state.channel?'live':'fallback',state.channel?'Tempo real ativo':`Atualizado às ${state.lastSync.toLocaleTimeString('pt-BR',{hour:'2-digit',minute:'2-digit'})} · fallback de 60 s`);
      window.dispatchEvent(new CustomEvent('nexlab:mural-synced',{detail:{version:VERSION,mode:state.mode,count:state.data.rows.length,source:options.source||'manual'}}));
    }catch(error){
      setSync('error','Falha de sincronização');
      if(!silent||!state.data)state.root.querySelector('[data-role="feed"]').innerHTML=`<div class="mural-r544-error"><strong>Não foi possível carregar o Mural.</strong><span>${esc(error.message||error)}</span><button data-action="refresh">Tentar novamente</button></div>`;
    }finally{
      state.loading=false;
      if(state.pendingReload){state.pendingReload=false;scheduleReload('pending');}
    }
  }
  function coverPreview(post){
    const source=state.previewObjectUrl||(!state.removeCover?post?._cover_signed_url:null);
    return `<div class="mural-r544-media-preview" data-role="media-preview">${source?`<img src="${esc(source)}" alt="Prévia da capa"><button type="button" data-action="remove-cover">Remover capa</button>`:'<div><strong>Sem imagem de capa</strong><span>JPG, PNG ou WebP, até 5 MB. O arquivo será armazenado de forma privada.</span></div>'}</div>`;
  }
  function openEditor(post=null){
    resetEditorState();
    state.editing=post;
    state.idempotencyKey=post?null:uuid();
    const box=state.root.querySelector('[data-role="editor"]'),canModerate=Boolean(state.data?.permissions?.moderate);
    box.hidden=false;
    box.innerHTML=`<form data-form="post" novalidate>
      <div class="mural-r544-editor-head"><div><strong>${post?'Editar publicação':'Nova publicação'}</strong><span>${post?'A autoria original será preservada e a edição ficará registrada.':'Envios repetidos serão detectados automaticamente.'}</span></div><button type="button" data-action="cancel" aria-label="Fechar editor">×</button></div>
      <div class="mural-r544-fields">
        <label>Título <span data-role="title-count">${String(post?.titulo||'').length}/150</span><input name="title" minlength="3" maxlength="150" required value="${esc(post?.titulo||'')}"></label>
        <label>Conteúdo <span data-role="content-count">${String(post?.conteudo||'').length}/10.000</span><textarea name="content" minlength="3" maxlength="10000" rows="7" required>${esc(post?.conteudo||'')}</textarea></label>
        <label class="mural-r544-file-label">Imagem de capa<input type="file" name="cover_file" accept="image/jpeg,image/png,image/webp"><small>O arquivo não fica público e é exibido por URL temporária assinada.</small></label>
        ${coverPreview(post)}
        ${canModerate?`<label class="mural-r544-check"><input type="checkbox" name="pinned" ${post?.fixado?'checked':''}> Fixar esta publicação</label>`:''}
      </div>
      <div class="mural-r544-editor-actions"><button type="button" data-action="cancel">Cancelar</button><button class="primary" type="submit" data-role="submit">${post?'Salvar alterações':'Publicar'}</button></div>
    </form>`;
    const title=box.querySelector('input[name="title"]'),content=box.querySelector('textarea[name="content"]');
    title?.addEventListener('input',()=>box.querySelector('[data-role="title-count"]').textContent=`${title.value.length}/150`);
    content?.addEventListener('input',()=>box.querySelector('[data-role="content-count"]').textContent=`${content.value.length}/10.000`);
    title?.focus();box.scrollIntoView({behavior:'smooth',block:'start'});
  }
  function closeEditor(){
    resetEditorState();
    const box=state.root?.querySelector('[data-role="editor"]');
    if(box){box.hidden=true;box.innerHTML='';}
  }
  function refreshEditorPreview(){
    const preview=state.root?.querySelector('[data-role="media-preview"]');
    if(!preview)return;
    const holder=document.createElement('div');holder.innerHTML=coverPreview(state.editing);preview.replaceWith(holder.firstElementChild);
  }
  function handleFileSelection(file){
    revokePreview();state.selectedFile=null;state.removeCover=false;
    if(!file)return refreshEditorPreview();
    if(!ALLOWED_TYPES.has(file.type)){toast('Formato inválido. Use JPG, PNG ou WebP.','err');return refreshEditorPreview();}
    if(file.size>MAX_FILE_BYTES){toast('A imagem deve ter no máximo 5 MB.','err');return refreshEditorPreview();}
    state.selectedFile=file;state.previewObjectUrl=URL.createObjectURL(file);refreshEditorPreview();
  }
  function markCoverRemoval(){
    revokePreview();state.selectedFile=null;state.removeCover=true;refreshEditorPreview();
  }
  async function uploadCover(file){
    const supabase=client(),userId=state.data?.current_user_id;
    if(!supabase?.storage||!userId)throw new Error('Armazenamento privado indisponível.');
    const extension={'image/jpeg':'jpg','image/png':'png','image/webp':'webp'}[file.type];
    const now=new Date(),path=`${userId}/${now.getUTCFullYear()}/${String(now.getUTCMonth()+1).padStart(2,'0')}/${uuid()}.${extension}`;
    const {error}=await supabase.storage.from('mural-media').upload(path,file,{cacheControl:'3600',contentType:file.type,upsert:false});
    if(error)throw error;
    return `${STORAGE_PREFIX}${path}`;
  }
  async function removeStoredCover(value){
    const path=storagePath(value),supabase=client();
    if(!path||!supabase?.storage)return;
    await supabase.storage.from('mural-media').remove([path]).catch(()=>{});
    state.signedCache.delete(path);
  }
  function setSaving(form,value){
    state.saving=value;
    form?.setAttribute('aria-busy',String(value));
    const button=form?.querySelector('[data-role="submit"]');
    if(button){button.disabled=value;button.textContent=value?'Salvando…':state.editing?'Salvar alterações':'Publicar';}
  }
  async function save(formData,form){
    if(state.saving)return;
    const title=String(formData.get('title')||'').trim(),content=String(formData.get('content')||'').trim(),pinned=formData.get('pinned')==='on';
    if(title.length<3||title.length>150)return toast('O título deve ter entre 3 e 150 caracteres.','err');
    if(content.length<3||content.length>10000)return toast('O conteúdo deve ter entre 3 e 10.000 caracteres.','err');
    setSaving(form,true);
    const previousCover=state.editing?.capa_url||null;
    let uploadedCover=null;
    try{
      if(state.selectedFile)uploadedCover=await uploadCover(state.selectedFile);
      const cover=uploadedCover||(state.removeCover?null:previousCover);
      let result;
      if(state.editing){
        result=await rpc('nexlab_update_board_post_v26293',{p_post_id:state.editing.id,p_title:title,p_content:content,p_pinned:pinned,p_cover_url:cover});
      }else{
        result=await rpc('nexlab_create_board_post_v26293',{p_title:title,p_content:content,p_pinned:pinned,p_cover_url:cover,p_idempotency_key:state.idempotencyKey});
      }
      if(uploadedCover&&result?.capa_url!==uploadedCover)await removeStoredCover(uploadedCover);
      if(previousCover&&previousCover!==result?.capa_url)await removeStoredCover(previousCover);
      if(result?.deduplicated)toast('Envio repetido detectado. A publicação existente foi mantida.','info');
      else toast(state.editing?'Publicação atualizada.':'Comunicado publicado.','ok');
      closeEditor();await load();
    }catch(error){
      if(uploadedCover)await removeStoredCover(uploadedCover);
      toast(error.message||'Não foi possível salvar a publicação.','err');
    }finally{if(form?.isConnected)setSaving(form,false);else state.saving=false;}
  }
  async function moderate(post,action){
    try{
      await rpc('nexlab_update_board_post_v26293',{p_post_id:post.id,p_title:post.titulo,p_content:post.conteudo,p_pinned:action==='pin',p_cover_url:post.capa_url||null});
      toast(action==='pin'?'Publicação fixada.':'Publicação desafixada.','ok');await load();
    }catch(error){toast(error.message||'Não foi possível alterar a fixação.','err');}
  }
  async function archive(post){
    const reason=prompt(`Informe o motivo para arquivar “${post.titulo}” (5 a 500 caracteres):`);
    if(reason===null)return;
    if(reason.trim().length<5)return toast('O motivo precisa ter pelo menos 5 caracteres.','err');
    try{await rpc('nexlab_archive_board_post_v26293',{p_post_id:post.id,p_reason:reason.trim()});toast('Publicação arquivada.','ok');await load();}
    catch(error){toast(error.message||'Não foi possível arquivar.','err');}
  }
  async function restore(post){
    if(!confirm(`Restaurar a publicação “${post.titulo}”?`))return;
    try{await rpc('nexlab_restore_board_post_v26293',{p_post_id:post.id});toast('Publicação restaurada.','ok');await load();}
    catch(error){toast(error.message||'Não foi possível restaurar.','err');}
  }
  function start(){
    state.observer=new MutationObserver(()=>{clearTimeout(state.timer);state.timer=setTimeout(()=>isMural()?mount():unmount(),80);});
    state.observer.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['style','class','data-nexlab-page']});
    state.mountTimer=setInterval(()=>isMural()?mount():unmount(),1000);
    mount();
  }
  window[KEY]={version:VERSION,refresh:load,destroy(){state.observer?.disconnect();clearInterval(state.mountTimer);unmount();}};
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
