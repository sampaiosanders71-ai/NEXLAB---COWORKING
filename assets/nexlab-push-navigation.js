/* NEXLAB Beta 0.26.12 — navegação Push com confirmação explícita, deduplicação e fallback seguro. */
(()=>{
  if(globalThis.__NEXLAB_PUSH_NAVIGATION__?.version==='0.26.12')return;
  const VERSION='0.26.12';
  const EVIDENCE_KEY='nexlab:device-homologation:'+VERSION;
  const ALLOWED_TABS=new Set(['dashboard','pendencias','agenda','notificacoes','participantes','permissoes','equipes','perfil','projetos','inventario','patrimonio','estoque','reserva','marketing','eventos','mural','feedback','relatorios','saude-sistema','logs']);
  const RECENT_TTL_MS=10000;
  const CONFIRM_TIMEOUT_MS=4500;
  const clean=(value,max=180)=>String(value??'').trim().slice(0,max);
  const normalize=(source={})=>{
    const tabCandidate=clean(source.tab||source.targetTab||source.target_tab||'notificacoes',60);
    const tab=ALLOWED_TABS.has(tabCandidate)?tabCandidate:'notificacoes';
    return {
      tab,
      notificationId:clean(source.notificationId||source.notification_id||source.notification,80),
      entityId:clean(source.entityId||source.entity_id||source.entity,100),
      entityType:clean(source.entityType||source.entity_type,80),
      pushRequestId:clean(source.pushRequestId||source.push_request_id||source.nexlabPushRequest,100),
      url:clean(source.url,1200),
      source:'push'
    };
  };
  const signature=(target)=>[target.tab,target.notificationId,target.entityId,target.entityType].join('|');
  const fromLocation=()=>{
    const params=new URL(location.href).searchParams;
    return normalize({
      tab:params.get('nexlabTab'),notificationId:params.get('notification'),
      entityId:params.get('entity'),entityType:params.get('entityType'),
      pushRequestId:params.get('nexlabPushRequest'),url:location.href
    });
  };
  const readEvidence=()=>{try{return JSON.parse(localStorage.getItem(EVIDENCE_KEY)||'{}')||{};}catch{return {};}};
  const writeEvidence=(patch)=>{
    const current=readEvidence();
    const next={...current,version:VERSION,revision:'beta-0-26-12-bookings-render-loop-recovery',userAgent:navigator.userAgent,updatedAt:new Date().toISOString(),...patch};
    try{localStorage.setItem(EVIDENCE_KEY,JSON.stringify(next));}catch{}
    globalThis.dispatchEvent(new CustomEvent('nexlab:push-navigation-evidence',{detail:next}));
    return next;
  };
  const persist=(target)=>{
    try{
      sessionStorage.setItem('nexlabNotificationTarget',JSON.stringify(target));
      if(target.tab==='reserva'&&target.entityId){
        sessionStorage.setItem('nexlabBookingTarget',JSON.stringify({kind:target.entityType==='meeting'?'meeting':'reservation',id:target.entityId,source:'push'}));
      }
      if(target.tab==='projetos'&&target.entityId)sessionStorage.setItem('nexlabProjectTarget',JSON.stringify({id:target.entityId,source:'push'}));
      if(target.tab==='agenda'&&target.entityId)sessionStorage.setItem('nexlabAgendaTarget',JSON.stringify({id:target.entityId,entityType:target.entityType,source:'push'}));
    }catch{}
  };
  const updateLocation=(target)=>{
    try{
      const url=new URL(location.href);
      url.searchParams.set('nexlabTab',target.tab);
      if(target.notificationId)url.searchParams.set('notification',target.notificationId);else url.searchParams.delete('notification');
      if(target.entityId)url.searchParams.set('entity',target.entityId);else url.searchParams.delete('entity');
      if(target.entityType)url.searchParams.set('entityType',target.entityType);else url.searchParams.delete('entityType');
      if(target.pushRequestId)url.searchParams.set('nexlabPushRequest',target.pushRequestId);else url.searchParams.delete('nexlabPushRequest');
      history.replaceState({...history.state,nexlabTab:target.tab,nexlabPushTarget:target},'',url);
    }catch{}
  };
  const waitForInterface=()=>new Promise((resolve)=>{
    const ready=()=>Boolean(document.querySelector('#root')?.childElementCount||document.body?.dataset?.nexlabPage);
    if(ready())return resolve(true);
    let settled=false;
    const finish=(value)=>{if(settled)return;settled=true;observer.disconnect();clearTimeout(timer);resolve(value);};
    const observer=new MutationObserver(()=>{if(ready())finish(true);});
    observer.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['data-nexlab-page']});
    const timer=setTimeout(()=>finish(false),8000);
  });
  const matchesConfirmation=(detail,target)=>{
    if(!detail||String(detail.tabId||'')!==target.tab)return false;
    const notificationMatches=!target.notificationId||!detail.notificationId||clean(detail.notificationId,80)===target.notificationId;
    const entityMatches=!target.entityId||!detail.id||clean(detail.id,100)===target.entityId;
    return notificationMatches&&entityMatches;
  };
  const waitForAppConfirmation=(target)=>new Promise((resolve)=>{
    let settled=false;
    const finish=(value)=>{if(settled)return;settled=true;clearTimeout(timer);globalThis.removeEventListener('nexlab:push-navigation-confirmed',onConfirmed);resolve(value);};
    const onConfirmed=(event)=>{if(matchesConfirmation(event?.detail,target))finish(true);};
    globalThis.addEventListener('nexlab:push-navigation-confirmed',onConfirmed);
    const timer=setTimeout(()=>finish(false),CONFIRM_TIMEOUT_MS);
  });
  const dispatchFlow=async(target)=>{
    persist(target);updateLocation(target);
    globalThis.__NEXLAB_LAST_PUSH_TARGET__=Object.freeze({...target});
    globalThis.dispatchEvent(new CustomEvent('nexlab:push-navigation',{detail:target}));
    const interfaceReady=await waitForInterface();
    const confirmation=waitForAppConfirmation(target);
    const recordId=target.entityId||target.notificationId;
    globalThis.dispatchEvent(new CustomEvent('nexlab:navigate-record',{detail:{
      tabId:target.tab,id:recordId||null,entityType:target.entityType||'notification',
      notificationId:target.notificationId||null,pushRequestId:target.pushRequestId||null,
      source:'push',groupLabel:'Notificação Push'
    }}));
    const confirmed=await confirmation;
    if(confirmed)writeEvidence({
      automaticPushDisplayedAt:new Date().toISOString(),
      automaticPushDestinationAt:new Date().toISOString(),
      automaticPushDestinationSignature:signature(target),
      automaticPushRequestId:target.pushRequestId||null
    });
    return {ok:confirmed,confirmed,interfaceReady,target,error:confirmed?'':'O aplicativo não confirmou a navegação dentro do prazo.'};
  };
  const dispatch=(source)=>{
    const target=normalize(source);
    const key=signature(target);
    const now=Date.now();
    const previous=globalThis.__NEXLAB_LAST_PUSH_DISPATCH__;
    if(previous?.key===key&&now-previous.at<RECENT_TTL_MS)return previous.promise;
    const promise=dispatchFlow(target);
    globalThis.__NEXLAB_LAST_PUSH_DISPATCH__={key,at:now,target,promise};
    return promise;
  };
  const respond=(port,payload)=>{try{port?.postMessage(payload);}catch{}};
  const onMessage=(event)=>{
    if(event?.data?.type!=='NEXLAB_NAVIGATE')return;
    const target=normalize(event.data);
    writeEvidence({automaticPushDisplayedAt:new Date().toISOString(),automaticPushRequestId:target.pushRequestId||null});
    void dispatch(target).then(result=>respond(event.ports?.[0],{
      type:'NEXLAB_NAVIGATE_ACK',requestId:target.pushRequestId||'',ok:result.ok===true,
      confirmed:result.confirmed===true,tab:target.tab,notificationId:target.notificationId,
      entityId:target.entityId,error:result.error||''
    })).catch(error=>respond(event.ports?.[0],{type:'NEXLAB_NAVIGATE_ACK',requestId:target.pushRequestId||'',ok:false,error:String(error?.message||error)}));
  };
  navigator.serviceWorker?.addEventListener('message',onMessage);
  const initial=()=>{
    const target=fromLocation();
    if(target.notificationId||target.entityId||target.pushRequestId){
      if(target.pushRequestId)writeEvidence({automaticPushDisplayedAt:new Date().toISOString(),automaticPushRequestId:target.pushRequestId});
      void dispatch(target);
    }
  };
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',initial,{once:true});else initial();
  globalThis.__NEXLAB_PUSH_NAVIGATION__=Object.freeze({version:VERSION,normalize,dispatch,getLast:()=>globalThis.__NEXLAB_LAST_PUSH_TARGET__||null});
})();
