(function(){
  'use strict';

  const BUILD=globalThis.__NEXLAB_BUILD_IDENTITY__||Object.freeze({
    version:'0.26.22',
    revision:'beta-0-26-22-feedback-resolved-bulk-delete'
  });
  if(globalThis.__NEXLAB_PUSH_CONSENT__?.revision===BUILD.revision)return;

  const PROJECT_REF='eahldhabwulnwhuwrhvc';
  const API=(globalThis.__NEXLAB_CONFIG__?.supabaseUrl||`https://${PROJECT_REF}.supabase.co`).replace(/\/$/,'');
  const ANON=globalThis.__NEXLAB_CONFIG__?.supabaseAnonKey||'sb_publishable_hr-WTQUBbBE0Ei3Lr2hkhQ_XSKG_PXa';
  const DEFER_MS=7*24*60*60*1000;
  const CHECK_DELAY_MS=1500;
  const state={
    version:BUILD.version,
    revision:BUILD.revision,
    status:'idle',
    permission:('Notification'in globalThis?Notification.permission:'unsupported'),
    supported:false,
    userId:null,
    promptVisible:false,
    lastCheckedAt:null,
    error:null
  };
  globalThis.__NEXLAB_PUSH_CONSENT__=state;

  let modal=null;
  let evaluationPromise=null;
  let timer=null;

  function supported(){
    return location.protocol==='https:'
      && 'serviceWorker'in navigator
      && 'PushManager'in globalThis
      && 'Notification'in globalThis
      && typeof Notification.requestPermission==='function';
  }

  function authToken(){
    const keys=[`sb-${PROJECT_REF}-auth-token`,...Object.keys(localStorage).filter(key=>key.includes(PROJECT_REF)&&key.includes('auth-token'))];
    for(const key of keys){
      try{
        const parsed=JSON.parse(localStorage.getItem(key)||'null');
        const token=parsed?.access_token||parsed?.currentSession?.access_token||parsed?.session?.access_token;
        if(token)return token;
      }catch{}
    }
    return null;
  }

  function tokenSubject(token){
    try{
      const payload=String(token||'').split('.')[1]||'';
      const normalized=payload.replace(/-/g,'+').replace(/_/g,'/');
      const json=JSON.parse(atob(normalized+'='.repeat((4-normalized.length%4)%4)));
      return String(json.sub||'')||null;
    }catch{return null;}
  }

  function storageKey(name,userId){
    return `nexlab:push-consent:${name}:${userId||'anonymous'}`;
  }

  function readNumber(key){
    try{return Number(localStorage.getItem(key)||0)||0;}catch{return 0;}
  }

  function writeValue(key,value){
    try{localStorage.setItem(key,String(value));}catch{}
  }

  async function rpc(name,body){
    const access=authToken();
    if(!access)throw new Error('Sessão não localizada.');
    const response=await fetch(`${API}/rest/v1/rpc/${name}`,{
      method:'POST',
      cache:'no-store',
      headers:{apikey:ANON,Authorization:`Bearer ${access}`,'Content-Type':'application/json'},
      body:JSON.stringify(body||{})
    });
    const text=await response.text();
    let data=null;
    try{data=text?JSON.parse(text):null;}catch{data=text;}
    if(!response.ok)throw new Error(data?.message||data?.hint||`Falha ${response.status}`);
    return data;
  }

  async function hasApprovedAccess(){
    try{return (await rpc('nexlab_has_approved_access',{}))===true;}
    catch{return false;}
  }

  function dispatch(name,detail={}){
    globalThis.dispatchEvent(new CustomEvent(name,{detail:{...state,...detail}}));
  }

  function closeModal(reason='closed'){
    if(!modal)return;
    modal.remove();
    modal=null;
    state.promptVisible=false;
    document.documentElement.classList.remove('nexlab-push-consent-open');
    dispatch('nexlab:push-consent-closed',{reason});
  }

  function makeButton(label,className,handler){
    const button=document.createElement('button');
    button.type='button';
    button.className=className;
    button.textContent=label;
    button.addEventListener('click',handler);
    return button;
  }

  function showBlockedMessage(){
    closeModal('permission-denied');
    const wrapper=document.createElement('div');
    wrapper.className='nexlab-push-consent-overlay';
    wrapper.setAttribute('role','presentation');
    const dialog=document.createElement('section');
    dialog.className='nexlab-push-consent-dialog';
    dialog.setAttribute('role','dialog');
    dialog.setAttribute('aria-modal','true');
    dialog.setAttribute('aria-labelledby','nexlab-push-blocked-title');
    const icon=document.createElement('div');
    icon.className='nexlab-push-consent-icon';
    icon.setAttribute('aria-hidden','true');
    icon.textContent='!';
    const title=document.createElement('h2');
    title.id='nexlab-push-blocked-title';
    title.textContent='Notificações bloqueadas no aparelho';
    const text=document.createElement('p');
    text.textContent='O NEXLAB não pode abrir novamente o pedido oficial. Para receber Push, libere as notificações nas configurações do navegador ou do aplicativo instalado.';
    const actions=document.createElement('div');
    actions.className='nexlab-push-consent-actions';
    actions.append(makeButton('Entendi','nexlab-push-consent-primary',()=>closeModal('blocked-acknowledged')));
    dialog.append(icon,title,text,actions);
    wrapper.append(dialog);
    document.body.append(wrapper);
    modal=wrapper;
    state.promptVisible=true;
    document.documentElement.classList.add('nexlab-push-consent-open');
    requestAnimationFrame(()=>actions.querySelector('button')?.focus());
  }

  async function enablePreferenceOnce(userId){
    const key=storageKey('preference-initialized',userId);
    if(readNumber(key)>0)return false;
    await rpc('nexlab_set_notification_channel_v2702',{p_channel:'push',p_enabled:true});
    writeValue(key,Date.now());
    dispatch('nexlab:push-preference-enabled',{userId});
    return true;
  }

  async function syncSubscription(){
    globalThis.dispatchEvent(new CustomEvent('nexlab:push-permission-granted',{detail:{version:BUILD.version,revision:BUILD.revision}}));
    const sync=globalThis.__NEXLAB_VAPID_ROTATION_BETA_0264__?.sync;
    if(typeof sync==='function')await sync();
  }

  function requestPermissionFromGesture(){
    return new Promise((resolve,reject)=>{
      let settled=false;
      const finish=(value)=>{if(settled)return;settled=true;resolve(value||Notification.permission||'default');};
      try{
        const result=Notification.requestPermission(finish);
        if(result&&typeof result.then==='function')result.then(finish,reject);
      }catch(error){reject(error);}
    });
  }

  async function allow(userId,button){
    if(button)button.disabled=true;
    state.status='requesting';
    state.error=null;
    dispatch('nexlab:push-consent-state');
    try{
      const permission=await requestPermissionFromGesture();
      state.permission=permission;
      writeValue(storageKey('answered-at',userId),Date.now());
      if(permission==='granted'){
        state.status='granted';
        closeModal('granted');
        await enablePreferenceOnce(userId);
        await syncSubscription();
        dispatch('nexlab:push-consent-granted',{userId});
        return;
      }
      if(permission==='denied'){
        state.status='denied';
        dispatch('nexlab:push-consent-denied',{userId});
        showBlockedMessage();
        return;
      }
      state.status='default';
      writeValue(storageKey('deferred-until',userId),Date.now()+DEFER_MS);
      closeModal('dismissed-by-browser');
    }catch(error){
      state.status='error';
      state.error=String(error?.message||error);
      dispatch('nexlab:push-consent-error',{userId});
      if(button)button.disabled=false;
    }
  }

  function defer(userId){
    writeValue(storageKey('deferred-until',userId),Date.now()+DEFER_MS);
    state.status='deferred';
    closeModal('deferred');
  }

  function showPrompt(userId){
    if(modal||!document.body)return;
    const wrapper=document.createElement('div');
    wrapper.className='nexlab-push-consent-overlay';
    wrapper.setAttribute('role','presentation');
    const dialog=document.createElement('section');
    dialog.className='nexlab-push-consent-dialog';
    dialog.setAttribute('role','dialog');
    dialog.setAttribute('aria-modal','true');
    dialog.setAttribute('aria-labelledby','nexlab-push-consent-title');
    dialog.setAttribute('aria-describedby','nexlab-push-consent-description');

    const icon=document.createElement('div');
    icon.className='nexlab-push-consent-icon';
    icon.setAttribute('aria-hidden','true');
    icon.textContent='N';
    const title=document.createElement('h2');
    title.id='nexlab-push-consent-title';
    title.textContent='Ative as notificações do NEXLAB';
    const text=document.createElement('p');
    text.id='nexlab-push-consent-description';
    text.textContent='Receba avisos importantes sobre reuniões, reservas, eventos, projetos e outras atividades, mesmo quando o aplicativo estiver fechado.';
    const note=document.createElement('p');
    note.className='nexlab-push-consent-note';
    note.textContent='Ao continuar, o aparelho exibirá o pedido oficial de permissão.';
    const actions=document.createElement('div');
    actions.className='nexlab-push-consent-actions';
    const later=makeButton('Agora não','nexlab-push-consent-secondary',()=>defer(userId));
    const allowButton=makeButton('Permitir notificações','nexlab-push-consent-primary',()=>allow(userId,allowButton));
    actions.append(later,allowButton);
    dialog.append(icon,title,text,note,actions);
    wrapper.append(dialog);
    wrapper.addEventListener('keydown',event=>{
      if(event.key==='Escape'){event.preventDefault();defer(userId);}
      if(event.key!=='Tab')return;
      const focusable=[later,allowButton].filter(button=>!button.disabled);
      const first=focusable[0],last=focusable[focusable.length-1];
      if(event.shiftKey&&document.activeElement===first){last.focus();event.preventDefault();}
      else if(!event.shiftKey&&document.activeElement===last){first.focus();event.preventDefault();}
    });
    document.body.append(wrapper);
    modal=wrapper;
    state.status='prompting';
    state.promptVisible=true;
    document.documentElement.classList.add('nexlab-push-consent-open');
    dispatch('nexlab:push-consent-prompted',{userId});
    requestAnimationFrame(()=>allowButton.focus());
  }

  async function evaluate(options={}){
    if(evaluationPromise)return evaluationPromise;
    evaluationPromise=(async()=>{
      state.lastCheckedAt=new Date().toISOString();
      state.supported=supported();
      state.permission=('Notification'in globalThis?Notification.permission:'unsupported');
      if(!state.supported){state.status='unsupported';return state;}
      if(navigator.onLine===false){state.status='offline';return state;}
      const token=authToken();
      const userId=tokenSubject(token);
      state.userId=userId;
      if(!token||!userId){state.status='no-session';closeModal('signed-out');return state;}
      if(!await hasApprovedAccess()){state.status='profile-not-approved';return state;}

      const permission=Notification.permission;
      state.permission=permission;
      if(permission==='granted'){
        state.status='granted';
        closeModal('already-granted');
        try{
          await enablePreferenceOnce(userId);
          await syncSubscription();
        }catch(error){
          state.status='sync-error';
          state.error=String(error?.message||error);
          dispatch('nexlab:push-consent-error',{userId});
        }
        return state;
      }
      if(permission==='denied'){
        state.status='denied';
        closeModal('already-denied');
        return state;
      }
      const deferredUntil=readNumber(storageKey('deferred-until',userId));
      if(!options.force&&deferredUntil>Date.now()){
        state.status='deferred';
        return state;
      }
      const otherDialog=document.querySelector('[role="dialog"]:not(.nexlab-push-consent-dialog)');
      if(otherDialog){state.status='ui-busy';schedule(1800,options);return state;}
      showPrompt(userId);
      return state;
    })().finally(()=>{evaluationPromise=null;});
    return evaluationPromise;
  }

  function schedule(delay=CHECK_DELAY_MS,options={}){
    clearTimeout(timer);
    timer=setTimeout(()=>evaluate(options).catch(error=>{
      state.status='error';
      state.error=String(error?.message||error);
      dispatch('nexlab:push-consent-error');
    }),delay);
  }

  const observer=new MutationObserver(()=>schedule(900));
  function start(){
    state.supported=supported();
    observer.observe(document.getElementById('root')||document.body,{childList:true,subtree:true});
    schedule(1800);
  }

  globalThis.__NEXLAB_PUSH_CONSENT__.evaluate=evaluate;
  globalThis.__NEXLAB_PUSH_CONSENT__.request=()=>evaluate({force:true});
  globalThis.__NEXLAB_PUSH_CONSENT__.close=closeModal;

  globalThis.addEventListener('online',()=>schedule(500));
  globalThis.addEventListener('focus',()=>schedule(700));
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')schedule(700);});
  globalThis.addEventListener('nexlab:session-reset',()=>{closeModal('session-reset');state.userId=null;state.status='no-session';});
  globalThis.addEventListener('storage',event=>{if(event.key?.includes(PROJECT_REF)&&event.key?.includes('auth-token'))schedule(500);});

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});
  else start();
})();
