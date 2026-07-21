(function(){
  'use strict';
  if(window.__NEXLAB_FEEDBACK_EVIDENCE_02622__)return;
  window.__NEXLAB_FEEDBACK_EVIDENCE_02622__=true;

  const BUILD=globalThis.__NEXLAB_BUILD_IDENTITY__||Object.freeze({version:'0.26.22',revision:'beta-0-26-22-feedback-resolved-bulk-delete'});
  const FUNCTION_NAME='nexlab-feedback-evidence';
  const MAX_FILES=3;
  const MAX_ORIGINAL_BYTES=5*1024*1024;
  const MAX_PROCESSED_BYTES=Math.floor(1.5*1024*1024);
  const MAX_DIMENSION=1920;
  const ALLOWED_TYPES=new Set(['image/png','image/jpeg','image/webp']);
  const DRAFT_KEY='nexlab:feedback-draft:v0.26.22';
  const state={configured:null,statusCheckedAt:0,pending:[],processing:Promise.resolve(),processingActive:false,pickerActive:false,pickerReleaseTimer:null,role:null,userId:null,listCache:new Map(),listLoading:false};

  function client(){return globalThis.__NEXLAB_SUPABASE__||null;}
  function isFeedbackPage(){return document.body?.dataset?.nexlabPage==='feedback'||Boolean(findFeedbackForm())||Boolean(document.querySelector('[data-nexlab-record-id]'));}
  function formatBytes(value){const n=Number(value)||0;return n>=1048576?`${(n/1048576).toFixed(2)} MB`:`${Math.max(1,Math.round(n/1024))} KB`;}
  function safeName(value,index){const base=String(value||'').replace(/[\r\n\t]+/g,' ').trim().slice(0,100);return base||`Evidência ${index+1}`;}
  function announce(message,type='info'){
    let box=document.getElementById('nexlab-feedback-evidence-global-status');
    if(!box){box=document.createElement('div');box.id='nexlab-feedback-evidence-global-status';box.className='nexlab-evidence-global-status';box.setAttribute('role','status');box.setAttribute('aria-live','polite');document.body.appendChild(box);}
    box.dataset.type=type;box.textContent=message;box.hidden=false;
    clearTimeout(announce.timer);announce.timer=setTimeout(()=>{box.hidden=true;},7000);
  }

  function formFields(form){
    if(!form)return{};
    const textarea=[...form.querySelectorAll('textarea')].find(el=>/Descreva sua observação/i.test(el.placeholder||''))||form.querySelector('textarea');
    const subject=[...form.querySelectorAll('input[type="text"],input:not([type])')].find(el=>/Assunto|Conectividade|Ergonomia/i.test(`${el.placeholder||''} ${el.getAttribute('aria-label')||''}`))||form.querySelector('input[type="text"]');
    const category=[...form.querySelectorAll('select')].find(el=>[...el.options||[]].some(option=>/Sugestão de melhoria|Reportar falha/i.test(option.textContent||'')))||form.querySelector('select');
    return{textarea,subject,category};
  }
  function draftFromForm(form){const{textarea,subject,category}=formFields(form);return{message:String(textarea?.value||''),subject:String(subject?.value||''),category:String(category?.value||'Sugestão'),savedAt:Date.now()};}
  function persistDraft(form){
    try{const draft=draftFromForm(form);if(draft.message||draft.subject||draft.category!=='Sugestão')sessionStorage.setItem(DRAFT_KEY,JSON.stringify(draft));else sessionStorage.removeItem(DRAFT_KEY);}catch{}
  }
  function readDraft(){try{const value=JSON.parse(sessionStorage.getItem(DRAFT_KEY)||'null');return value&&typeof value==='object'?value:null;}catch{return null;}}
  function setControlledValue(element,value,eventName='input'){
    if(!element)return;
    const prototype=element instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:element instanceof HTMLSelectElement?HTMLSelectElement.prototype:HTMLInputElement.prototype;
    const setter=Object.getOwnPropertyDescriptor(prototype,'value')?.set;
    if(setter)setter.call(element,value);else element.value=value;
    element.dispatchEvent(new Event(eventName,{bubbles:true}));
  }
  function restoreDraft(form){
    if(!form||form.dataset.nexlabEvidenceDraftRestored==='true')return;
    form.dataset.nexlabEvidenceDraftRestored='true';
    const draft=readDraft();if(!draft)return;
    requestAnimationFrame(()=>{
      const{textarea,subject,category}=formFields(form);
      if(subject&&!subject.value&&draft.subject)setControlledValue(subject,draft.subject,'input');
      if(textarea&&!textarea.value&&draft.message)setControlledValue(textarea,draft.message,'input');
      if(category&&draft.category&&category.value!==draft.category)setControlledValue(category,draft.category,'change');
    });
  }
  function clearDraft(){try{sessionStorage.removeItem(DRAFT_KEY);}catch{}}
  function setPickerGuard(active){state.pickerActive=Boolean(active);globalThis.__NEXLAB_FILE_PICKER_ACTIVE__=Boolean(active);document.documentElement?.toggleAttribute('data-nexlab-file-picker-active',Boolean(active));}
  function beginPicker(form){persistDraft(form);if(state.pickerReleaseTimer)clearTimeout(state.pickerReleaseTimer);setPickerGuard(true);}
  function endPicker(delay=900){
    if(state.pickerReleaseTimer)clearTimeout(state.pickerReleaseTimer);
    state.pickerReleaseTimer=setTimeout(()=>{if(state.processingActive)return endPicker(500);setPickerGuard(false);state.pickerReleaseTimer=null;schedule();},delay);
  }

  async function invoke(body){
    const sb=client();
    if(!sb?.functions?.invoke)throw Object.assign(new Error('Integração externa indisponível.'),{code:'client_unavailable'});
    const {data,error}=await sb.functions.invoke(FUNCTION_NAME,{body:{...body,app_version:BUILD.version}});
    if(error){
      const code=data?.code||error?.context?.code||'edge_function_failed';
      throw Object.assign(new Error(data?.message||'Não foi possível concluir a operação externa.'),{code,data,error});
    }
    if(!data?.ok)throw Object.assign(new Error(data?.message||'Não foi possível concluir a operação externa.'),{code:data?.code||'external_operation_failed',data});
    return data;
  }

  async function loadSession(){
    const sb=client();if(!sb?.auth)return null;
    try{
      const {data}=await sb.auth.getUser();
      const user=data?.user;if(!user)return null;
      state.userId=user.id;
      const {data:profile}=await sb.from('profiles').select('role,ativo').eq('id',user.id).maybeSingle();
      state.role=profile?.ativo===true?String(profile.role||''):null;
      return state.role;
    }catch{return null;}
  }

  async function checkStatus(force=false){
    if(!force&&state.configured!==null&&Date.now()-state.statusCheckedAt<120000)return state.configured;
    try{const data=await invoke({action:'status'});state.configured=Boolean(data.configured);state.statusCheckedAt=Date.now();}
    catch{state.configured=false;state.statusCheckedAt=Date.now();}
    return state.configured;
  }

  function findFeedbackForm(){
    const textarea=[...document.querySelectorAll('textarea')].find(el=>/Descreva sua observação com clareza/i.test(el.placeholder||''));
    return textarea?.closest('form')||null;
  }

  function canvasBlob(canvas,type,quality){return new Promise(resolve=>canvas.toBlob(resolve,type,quality));}
  function loadImage(file){
    if('createImageBitmap' in window)return createImageBitmap(file).then(bitmap=>({source:bitmap,width:bitmap.width,height:bitmap.height,close:()=>bitmap.close?.()}));
    return new Promise((resolve,reject)=>{
      const url=URL.createObjectURL(file),img=new Image();
      img.onload=()=>resolve({source:img,width:img.naturalWidth,height:img.naturalHeight,close:()=>URL.revokeObjectURL(url)});
      img.onerror=()=>{URL.revokeObjectURL(url);reject(new Error('Não foi possível ler a imagem.'));};img.src=url;
    });
  }
  async function sha256(blob){const buffer=await blob.arrayBuffer(),hash=await crypto.subtle.digest('SHA-256',buffer);return [...new Uint8Array(hash)].map(v=>v.toString(16).padStart(2,'0')).join('');}

  async function processImage(file,index){
    if(!ALLOWED_TYPES.has(file.type))throw new Error(`${file.name}: formato não permitido.`);
    if(file.size<1||file.size>MAX_ORIGINAL_BYTES)throw new Error(`${file.name}: o arquivo deve ter no máximo 5 MB.`);
    const image=await loadImage(file);
    try{
      let scale=Math.min(1,MAX_DIMENSION/Math.max(image.width,image.height));
      let width=Math.max(1,Math.round(image.width*scale)),height=Math.max(1,Math.round(image.height*scale));
      let canvas=document.createElement('canvas'),blob=null,mime='image/webp';
      for(let round=0;round<7;round+=1){
        canvas.width=width;canvas.height=height;
        const ctx=canvas.getContext('2d',{alpha:false});
        if(!ctx)throw new Error('O navegador não conseguiu processar a imagem.');
        ctx.fillStyle='#ffffff';ctx.fillRect(0,0,width,height);ctx.drawImage(image.source,0,0,width,height);
        for(const quality of [0.84,0.74,0.64,0.54]){
          blob=await canvasBlob(canvas,'image/webp',quality);
          if(blob&&blob.type==='image/webp'&&blob.size<=MAX_PROCESSED_BYTES){mime='image/webp';break;}
          blob=await canvasBlob(canvas,'image/jpeg',quality);
          mime='image/jpeg';
          if(blob&&blob.size<=MAX_PROCESSED_BYTES)break;
        }
        if(blob&&blob.size<=MAX_PROCESSED_BYTES)break;
        width=Math.max(1,Math.round(width*.82));height=Math.max(1,Math.round(height*.82));
      }
      if(!blob||blob.size>MAX_PROCESSED_BYTES)throw new Error(`${file.name}: não foi possível reduzir a imagem para 1,5 MB.`);
      return {blob,mime_type:mime,display_name:safeName(file.name,index),original_size_bytes:file.size,size_bytes:blob.size,width,height,sha256:await sha256(blob)};
    }finally{image.close?.();}
  }

  function renderPending(container){
    const list=container.querySelector('[data-evidence-pending-list]');if(!list)return;
    list.innerHTML='';
    state.pending.forEach((item,index)=>{
      const row=document.createElement('div');row.className='nexlab-evidence-pending-item';
      row.innerHTML=`<div><strong></strong><span></span></div><button type="button" aria-label="Remover evidência">Remover</button>`;
      row.querySelector('strong').textContent=`Evidência ${index+1}`;
      row.querySelector('span').textContent=`${item.display_name} · ${item.width}×${item.height} · ${formatBytes(item.size_bytes)}`;
      row.querySelector('button').addEventListener('click',()=>{state.pending.splice(index,1);renderPending(container);});list.appendChild(row);
    });
    const count=container.querySelector('[data-evidence-count]');if(count)count.textContent=`${state.pending.length}/${MAX_FILES}`;
  }

  async function selectFiles(input,container){
    const selected=[...input.files||[]];
    if(!selected.length){input.value='';return;}
    if(state.pending.length+selected.length>MAX_FILES){input.value='';announce('É permitido anexar no máximo três imagens por Feedback.','error');return;}
    const status=container.querySelector('[data-evidence-status]');
    state.processingActive=true;
    state.processing=(async()=>{
      status.textContent='Processando as imagens no aparelho...';status.dataset.type='loading';
      for(const file of selected){
        try{state.pending.push(await processImage(file,state.pending.length));}
        catch(error){announce(error.message||'Uma imagem não pôde ser processada.','error');}
      }
      renderPending(container);status.textContent=state.pending.length?'As imagens estão prontas para envio. Metadados EXIF foram removidos.':'Nenhuma imagem selecionada.';status.dataset.type=state.pending.length?'ready':'idle';
    })();
    try{await state.processing;}finally{state.processingActive=false;input.value='';endPicker(700);}
  }

  async function injectUploader(){
    const form=findFeedbackForm();if(!form||form.querySelector('[data-nexlab-evidence-uploader]'))return;
    const textarea=[...form.querySelectorAll('textarea')].find(el=>/Descreva sua observação/i.test(el.placeholder||''));
    const anchor=textarea?.parentElement;if(!anchor)return;
    const wrap=document.createElement('section');wrap.className='nexlab-evidence-uploader';wrap.dataset.nexlabEvidenceUploader='true';
    wrap.innerHTML=`<div class="nexlab-evidence-heading"><div><h4>Adicionar evidências do problema</h4><p>Até 3 imagens em PNG, JPEG ou WebP. Máximo de 5 MB por arquivo antes do processamento.</p></div><span data-evidence-count>0/3</span></div><div class="nexlab-evidence-controls"><input type="file" accept="image/png,image/jpeg,image/webp" multiple hidden data-evidence-input><button type="button" data-evidence-select>Selecionar imagens</button><span data-evidence-status data-type="loading">Verificando armazenamento externo...</span></div><div data-evidence-pending-list class="nexlab-evidence-pending-list"></div><p class="nexlab-evidence-privacy">As imagens são comprimidas no aparelho, armazenadas fora do Supabase e abertas pelos Administradores somente por acesso temporário.</p>`;
    anchor.insertAdjacentElement('afterend',wrap);
    const button=wrap.querySelector('[data-evidence-select]'),input=wrap.querySelector('[data-evidence-input]'),status=wrap.querySelector('[data-evidence-status]');
    if(form.dataset.nexlabEvidenceDraftBound!=='true'){
      form.dataset.nexlabEvidenceDraftBound='true';
      form.addEventListener('input',()=>persistDraft(form),true);
      form.addEventListener('change',()=>persistDraft(form),true);
    }
    restoreDraft(form);
    button.addEventListener('click',event=>{event.preventDefault();event.stopPropagation();beginPicker(form);setTimeout(()=>input.click(),0);});
    input.addEventListener('change',async event=>{event.preventDefault();event.stopPropagation();persistDraft(form);try{await selectFiles(input,wrap);}finally{endPicker(900);}});
    const configured=await checkStatus();
    button.disabled=!configured;
    status.textContent=configured?'Armazenamento privado disponível.':'Armazenamento externo ainda não configurado. O Feedback pode ser enviado sem imagens.';
    status.dataset.type=configured?'ready':'unavailable';
  }

  async function deleteResolvedAll(feedbackIds){
    const ids=[...new Set((Array.isArray(feedbackIds)?feedbackIds:[]).map(value=>String(value||'').trim()).filter(value=>/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)))];
    if(!ids.length)return {ok:true,deleted_count:0,deleted_attachment_count:0,feedback_ids:[]};
    const sb=client();
    if(!sb?.from||!sb?.rpc)throw Object.assign(new Error('Integração administrativa indisponível.'),{code:'client_unavailable'});

    const attachments=[];
    for(let index=0;index<ids.length;index+=100){
      const batch=ids.slice(index,index+100);
      const {data,error}=await sb.from('nexlab_feedback_attachments').select('id,feedback_id,status').in('feedback_id',batch).order('created_at',{ascending:true});
      if(error)throw Object.assign(new Error('Não foi possível preparar a limpeza das imagens anexadas.'),{code:error.code||'attachment_lookup_failed',error});
      attachments.push(...(data||[]));
    }

    const removable=attachments.filter(item=>item?.id&&!['deleted','cancelled'].includes(String(item.status||'')));
    const failures=[];
    let cursor=0;
    const worker=async()=>{
      while(cursor<removable.length){
        const item=removable[cursor++];
        try{await invoke({action:'delete',attachment_id:item.id});}
        catch(error){failures.push({attachment_id:item.id,code:error?.code||'external_delete_failed'});}
      }
    };
    await Promise.all(Array.from({length:Math.min(4,removable.length)},worker));
    if(failures.length){
      throw Object.assign(new Error('Não foi possível remover todas as imagens anexadas. Nenhum Feedback foi excluído do banco. Tente novamente.'),{code:'external_cleanup_failed',failures});
    }

    const {data,error}=await sb.rpc('nexlab_admin_delete_resolved_feedback_v02622',{p_feedback_ids:ids});
    if(error||!data?.ok)throw Object.assign(new Error(data?.message||'Não foi possível excluir os Feedbacks resolvidos.'),{code:data?.code||error?.code||'bulk_delete_failed',data,error});
    state.listCache.clear();
    return {
      ok:true,
      deleted_count:Number(data.deleted_count||0),
      deleted_attachment_count:Number(data.deleted_attachment_count||attachments.length||0),
      feedback_ids:Array.isArray(data.feedback_ids)?data.feedback_ids:ids
    };
  }

  async function uploadPending(feedbackId){
    await state.processing;
    if(!state.pending.length)return {ok:true,uploaded:0,failed:0};
    if(!(await checkStatus(true)))return {ok:false,uploaded:0,failed:state.pending.length,code:'external_storage_not_configured'};
    let uploaded=0,failed=0;const remaining=[];
    for(const item of state.pending){
      let attachmentId=null;
      try{
        const reservation=await invoke({action:'reserve_upload',feedback_id:feedbackId,display_name:item.display_name,mime_type:item.mime_type,original_size_bytes:item.original_size_bytes,size_bytes:item.size_bytes,width:item.width,height:item.height,sha256:item.sha256});
        attachmentId=reservation.attachment_id;
        const response=await fetch(reservation.upload_url,{method:'PUT',headers:{...reservation.upload_headers},body:item.blob,cache:'no-store',credentials:'omit',referrerPolicy:'no-referrer'});
        if(!response.ok)throw Object.assign(new Error('O armazenamento externo recusou a imagem.'),{code:`r2_put_${response.status}`});
        await invoke({action:'complete_upload',attachment_id:attachmentId});uploaded+=1;
      }catch(error){
        failed+=1;remaining.push(item);
        if(attachmentId){try{await invoke({action:'cancel_upload',attachment_id:attachmentId,reason:error.code||'client_upload_failed'});}catch{} }
        console.warn('Falha controlada ao enviar evidência externa:',error?.code||'unknown');
      }
    }
    state.pending=remaining;
    const uploader=document.querySelector('[data-nexlab-evidence-uploader]');if(uploader)renderPending(uploader);
    if(failed)announce(`O Feedback foi registrado. ${uploaded} imagem(ns) enviada(s) e ${failed} não enviada(s).`,'error');
    return {ok:failed===0,uploaded,failed};
  }

  function evidenceRow(item,feedbackId){
    const row=document.createElement('div');row.className='nexlab-evidence-admin-item';
    row.innerHTML=`<div><strong></strong><span></span></div><div class="nexlab-evidence-admin-actions"><button type="button" data-mode="open">Abrir em nova guia</button><button type="button" data-mode="download">Baixar</button><button type="button" data-mode="delete" class="danger">Excluir</button></div>`;
    row.querySelector('strong').textContent=item.display_name||'Evidência visual';
    row.querySelector('span').textContent=`${item.width}×${item.height} · ${formatBytes(item.size_bytes)} · acesso temporário`;
    row.querySelectorAll('button').forEach(button=>button.addEventListener('click',async()=>{
      const mode=button.dataset.mode;
      if(mode==='delete'){
        const confirmed=window.nexlabConfirm?await window.nexlabConfirm('Excluir permanentemente esta evidência do armazenamento externo?',{title:'Excluir evidência',confirmLabel:'Excluir'}):window.confirm('Excluir permanentemente esta evidência?');
        if(!confirmed)return;
        button.disabled=true;try{await invoke({action:'delete',attachment_id:item.id});state.listCache.delete(feedbackId);announce('Evidência excluída.','success');await refreshAdminEvidence(true);}catch(error){announce(error.message,'error');}finally{button.disabled=false;}return;
      }
      const popup=window.open('about:blank','_blank');if(popup)popup.opener=null;button.disabled=true;
      try{const data=await invoke({action:'open',attachment_id:item.id,mode});if(popup)popup.location.replace(data.url);else window.open(data.url,'_blank','noopener,noreferrer');}
      catch(error){popup?.close();announce(error.message,'error');}finally{button.disabled=false;}
    }));
    return row;
  }

  async function refreshAdminEvidence(force=false){
    if(state.role!=='admin'||state.listLoading)return;
    const cards=[...document.querySelectorAll('[data-nexlab-record-id]')];
    const ids=[...new Set(cards.map(card=>card.dataset.nexlabRecordId).filter(Boolean))];if(!ids.length)return;
    const missing=force?ids:ids.filter(id=>!state.listCache.has(id));
    if(missing.length){state.listLoading=true;try{const sb=client();if(!sb)throw Object.assign(new Error('Cliente indisponível.'),{code:'client_unavailable'});const {data:items,error}=await sb.from('nexlab_feedback_attachments').select('id,feedback_id,display_name,mime_type,size_bytes,width,height,uploaded_at,available_at,created_at').in('feedback_id',missing).eq('status','available').order('created_at',{ascending:true});if(error)throw error;missing.forEach(id=>state.listCache.set(id,[]));(items||[]).forEach(item=>{const list=state.listCache.get(item.feedback_id)||[];list.push(item);state.listCache.set(item.feedback_id,list);});}catch(error){console.warn('Consulta controlada de evidências:',error?.code||'unknown');}finally{state.listLoading=false;}}
    cards.forEach(card=>{
      const feedbackId=card.dataset.nexlabRecordId;if(!feedbackId)return;
      let section=card.querySelector('[data-nexlab-evidence-admin]');if(!section){section=document.createElement('section');section.className='nexlab-evidence-admin';section.dataset.nexlabEvidenceAdmin='true';card.appendChild(section);}
      const items=state.listCache.get(feedbackId)||[];section.innerHTML='';
      const title=document.createElement('div');title.className='nexlab-evidence-admin-title';title.innerHTML='<strong>Evidências visuais</strong><span></span>';title.querySelector('span').textContent=String(items.length);section.appendChild(title);
      if(!items.length){const empty=document.createElement('p');empty.className='nexlab-evidence-admin-empty';empty.textContent='Nenhuma imagem anexada.';section.appendChild(empty);}
      else items.forEach(item=>section.appendChild(evidenceRow(item,feedbackId)));
    });
  }

  let scheduled=false;
  async function scan(){
    scheduled=false;if(state.pickerActive||state.processingActive||!isFeedbackPage())return;
    if(state.role===null)await loadSession();
    await injectUploader();
    if(state.role==='admin')await refreshAdminEvidence();
  }
  function schedule(){if(scheduled||state.pickerActive||state.processingActive)return;scheduled=true;setTimeout(scan,80);}
  new MutationObserver(schedule).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['data-nexlab-page']});
  window.addEventListener('nexlab:navigate-record',schedule);
  window.addEventListener('focus',()=>{if(state.pickerActive)endPicker(1200);else schedule();});
  document.addEventListener('visibilitychange',()=>{if(!document.hidden){if(state.pickerActive)endPicker(1200);else schedule();}});
  window.NexLabFeedbackEvidence=Object.freeze({version:BUILD.version,uploadPending,deleteResolvedAll,refresh:()=>refreshAdminEvidence(true),status:()=>checkStatus(true),clearDraft,persistDraft:()=>persistDraft(findFeedbackForm())});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',schedule,{once:true});else schedule();
})();
