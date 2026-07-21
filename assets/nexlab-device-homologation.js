(function(){
  'use strict';
  const BUILD=globalThis.__NEXLAB_BUILD_IDENTITY__||Object.freeze({version:'0.26.22',revision:'beta-0-26-22-feedback-resolved-bulk-delete',homologationRevision:'beta-0-26-22-feedback-resolved-bulk-delete'});
  const VERSION=BUILD.version;
  const BUILD_REVISION=BUILD.revision;
  const REVISION=BUILD.homologationRevision||'beta-0-26-22-feedback-resolved-bulk-delete';
  if(globalThis.__NEXLAB_DEVICE_HOMOLOGATION__?.revision===REVISION)return;
  const EVIDENCE_KEY='nexlab:device-homologation:'+VERSION+':'+BUILD_REVISION;
  const RPC='nexlab_record_device_homologation_v02622';
  const flag=(name)=>{try{return new URL(location.href).searchParams.get(name)==='1';}catch{return false;}};
  const syncRequested=()=>flag('nexlabHomologationSync');
  const pushTestRequested=()=>flag('nexlabPushTest');
  const anyRequested=()=>syncRequested()||pushTestRequested();
  const read=()=>{try{return JSON.parse(localStorage.getItem(EVIDENCE_KEY)||'{}')||{};}catch{return {};}};
  const write=(patch)=>{
    const current=read();
    const next={...current,...patch,version:VERSION,revision:REVISION,buildRevision:BUILD_REVISION,updatedAt:new Date().toISOString()};
    try{localStorage.setItem(EVIDENCE_KEY,JSON.stringify(next));}catch{}
    return next;
  };
  const localComplete=(evidence)=>evidence?.revision===REVISION&&evidence?.buildRevision===BUILD_REVISION
    && Boolean(evidence?.deviceSessionId)
    && Boolean(evidence?.automaticInstalledLaunchAt)
    && Boolean(evidence?.automaticUpdateActivationAt)
    && Boolean(evidence?.automaticOfflineNavigationAt)
    && Boolean(evidence?.automaticPushDisplayedAt)
    && Boolean(evidence?.automaticPushDestinationAt)
    && Boolean(evidence?.technicalReadyAt)
    && Boolean(evidence?.automaticPushRequestId)
    && Boolean(evidence?.automaticPushDestinationSignature);
  let bannerNode=null;
  function banner(message,state='pending'){
    if(!anyRequested()&&!bannerNode)return;
    if(!bannerNode){
      bannerNode=document.createElement('div');
      bannerNode.setAttribute('role','status');
      Object.assign(bannerNode.style,{position:'fixed',left:'16px',right:'16px',bottom:'16px',zIndex:'2147483647',padding:'14px 16px',borderRadius:'14px',fontFamily:'system-ui,sans-serif',fontWeight:'800',boxShadow:'0 12px 32px rgba(0,0,0,.25)',textAlign:'center'});
      document.body.appendChild(bannerNode);
    }
    bannerNode.textContent=message;
    bannerNode.style.background=state==='ok'?'#dcfce7':state==='error'?'#fee2e2':'#fff7ed';
    bannerNode.style.color=state==='ok'?'#166534':state==='error'?'#991b1b':'#9a5a00';
  }
  const delay=(ms)=>new Promise(resolve=>setTimeout(resolve,ms));
  async function waitForClient(timeoutMs=120000){
    const started=Date.now();
    while(Date.now()-started<timeoutMs){
      const client=globalThis.__NEXLAB_SUPABASE__;
      if(client?.rpc&&client?.auth?.getSession&&client?.functions?.invoke)return client;
      await delay(500);
    }
    throw new Error('O cliente Supabase não ficou disponível.');
  }
  async function waitForSession(client,timeoutMs=120000){
    const started=Date.now();
    while(Date.now()-started<timeoutMs){
      const result=await client.auth.getSession();
      if(result?.error)throw result.error;
      if(result?.data?.session)return result.data.session;
      await delay(1000);
    }
    throw new Error('Entre no aplicativo para continuar o teste.');
  }
  function clearRequestParams(){
    try{
      const url=new URL(location.href);
      url.searchParams.delete('nexlabPushTest');
      url.searchParams.delete('nexlabHomologationSync');
      history.replaceState(history.state,'',url);
    }catch{}
  }
  let activePushTest=null;
  async function requestPushTest(){
    if(activePushTest)return activePushTest;
    activePushTest=(async()=>{
      if(navigator.onLine===false)throw new Error('Reconecte a internet para solicitar o Push de teste.');
      if(!('Notification' in globalThis)||Notification.permission!=='granted')throw new Error('Ative as notificações Push no módulo Notificações antes de executar o teste.');
      const registration=await navigator.serviceWorker?.getRegistration?.('./');
      const subscription=await registration?.pushManager?.getSubscription?.();
      if(!registration?.active||!subscription)throw new Error('A inscrição Push não está ativa neste aparelho. Ative o Push no módulo Notificações.');
      banner('Aguardando autenticação para solicitar um Push real...');
      const client=await waitForClient();
      const session=await waitForSession(client);
      const created=await client.rpc('create_test_notification');
      if(created?.error)throw created.error;
      const notificationId=String(created?.data||'').trim();
      if(!notificationId)throw new Error('O Supabase não retornou o identificador da notificação de teste.');
      write({automaticPushTestRequestedAt:new Date().toISOString(),automaticPushTestNotificationId:notificationId,automaticPushTestUserId:String(session.user?.id||'')});
      const processing=await client.functions.invoke('process-notification-deliveries',{body:{action:'process',source:'device-homologation-push-test',notificationId}}).catch(error=>({data:null,error}));
      clearRequestParams();
      const delayed=Boolean(processing?.error);
      banner(delayed?'Push de teste colocado na fila. O processamento automático fará a tentativa; toque na notificação quando ela aparecer.':'Push de teste solicitado. Minimize o aplicativo e toque na notificação real quando ela aparecer.','ok');
      globalThis.dispatchEvent(new CustomEvent('nexlab:device-push-test-requested',{detail:{notificationId,queued:true,processedImmediately:!delayed}}));
      return {ok:true,notificationId,processedImmediately:!delayed};
    })().catch(error=>{
      clearRequestParams();
      banner(String(error?.message||error),'error');
      return {ok:false,error:String(error?.message||error)};
    }).finally(()=>{activePushTest=null;});
    return activePushTest;
  }
  let activeSync=null;
  async function sync({redirect=syncRequested(),silent=false}={}){
    if(activeSync)return activeSync;
    activeSync=(async()=>{
      const evidence=read();
      if(!localComplete(evidence))throw new Error('As cinco evidências automáticas locais ainda não estão completas.');
      if(navigator.onLine===false)throw new Error('Reconecte a internet para registrar a homologação.');
      if(!silent)banner('Aguardando autenticação administrativa...');
      const client=await waitForClient();
      const session=await waitForSession(client);
      const profileResult=await client.from('profiles').select('role').eq('id',session.user.id).maybeSingle();
      if(profileResult?.error)throw profileResult.error;
      const role=String(profileResult?.data?.role||'').toLowerCase();
      if(!['admin','administrador'].includes(role)){
        if(silent)return {ok:false,skipped:'administrator_required'};
        throw new Error('Entre com uma conta Administradora para registrar a homologação.');
      }
      if(!silent)banner('Registrando evidência física no Supabase...');
      const {data,error}=await client.rpc(RPC,{p_evidence:evidence});
      if(error)throw error;
      if(!data?.ok||data?.complete!==true||!data?.homologation_id)throw new Error(String(data?.error||'O Supabase não confirmou a homologação.'));
      const next=write({serverReceiptId:String(data.homologation_id),serverReceiptAt:String(data.completed_at||new Date().toISOString()),serverReceiptHash:String(data.evidence_hash||''),serverReceiptRevision:REVISION,serverReceiptComplete:true,serverReceiptUserId:String(session.user?.id||'')});
      globalThis.dispatchEvent(new CustomEvent('nexlab:device-homologation-synced',{detail:{receipt:data,evidence:next}}));
      clearRequestParams();
      if(!silent)banner('Homologação física registrada. Abrindo o diagnóstico final...','ok');
      if(redirect)setTimeout(()=>location.replace('./pwa-check.html?nexlabHomologationSynced=1'),900);
      return {ok:true,receipt:data,evidence:next};
    })().catch(error=>{
      clearRequestParams();
      if(!silent)banner(String(error?.message||error),'error');
      globalThis.dispatchEvent(new CustomEvent('nexlab:device-homologation-sync-error',{detail:{error:String(error?.message||error)}}));
      return {ok:false,error:String(error?.message||error)};
    }).finally(()=>{activeSync=null;});
    return activeSync;
  }
  globalThis.__NEXLAB_DEVICE_HOMOLOGATION__=Object.freeze({version:VERSION,revision:REVISION,read,localComplete,sync,requestPushTest});
  let silentSyncTimer=0;
  const attemptSilentSync=()=>{
    clearTimeout(silentSyncTimer);
    silentSyncTimer=setTimeout(()=>{
      const evidence=read();
      if(navigator.onLine!==false&&localComplete(evidence)&&(!evidence.serverReceiptComplete||evidence.serverReceiptRevision!==REVISION)){
        void sync({redirect:false,silent:true});
      }
    },2200);
  };
  const boot=()=>{
    if(pushTestRequested()){banner('Preparando Push real de homologação...');void requestPushTest();return;}
    if(syncRequested()){banner('Preparando registro da homologação...');void sync();return;}
    attemptSilentSync();
    globalThis.addEventListener('online',attemptSilentSync);
    globalThis.addEventListener('nexlab:pwa-readiness-complete',attemptSilentSync);
    globalThis.addEventListener('nexlab:push-navigation-evidence',attemptSilentSync);
  };
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
})();
