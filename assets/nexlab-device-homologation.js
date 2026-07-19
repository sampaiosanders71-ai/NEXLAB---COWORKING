(function(){
  'use strict';
  const BUILD=globalThis.__NEXLAB_BUILD_IDENTITY__||Object.freeze({version:'0.26.12',revision:'beta-0-26-12-bookings-render-loop-recovery'});
  const VERSION=BUILD.version;
  const REVISION=BUILD.revision;
  if(globalThis.__NEXLAB_DEVICE_HOMOLOGATION__?.revision===REVISION)return;
  const EVIDENCE_KEY='nexlab:device-homologation:'+VERSION;
  const RPC='nexlab_record_device_homologation_v02612';
  const syncRequested=()=>{try{return new URL(location.href).searchParams.get('nexlabHomologationSync')==='1';}catch{return false;}};
  const read=()=>{try{return JSON.parse(localStorage.getItem(EVIDENCE_KEY)||'{}')||{};}catch{return {};}};
  const write=(patch)=>{
    const current=read();
    const next={...current,...patch,version:VERSION,revision:REVISION,updatedAt:new Date().toISOString()};
    try{localStorage.setItem(EVIDENCE_KEY,JSON.stringify(next));}catch{}
    return next;
  };
  const localComplete=(evidence)=>evidence?.revision===REVISION
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
    if(!syncRequested()&&!bannerNode)return;
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
      if(client?.rpc&&client?.auth?.getSession)return client;
      await delay(500);
    }
    throw new Error('O cliente Supabase não ficou disponível.');
  }
  let activeSync=null;
  async function sync({redirect=syncRequested()}={}){
    if(activeSync)return activeSync;
    activeSync=(async()=>{
      const evidence=read();
      if(!localComplete(evidence))throw new Error('As cinco evidências automáticas locais ainda não estão completas.');
      if(navigator.onLine===false)throw new Error('Reconecte a internet para registrar a homologação.');
      banner('Aguardando autenticação administrativa...');
      const client=await waitForClient();
      let session=null;
      for(let attempt=0;attempt<120;attempt+=1){
        const result=await client.auth.getSession();
        if(result?.error)throw result.error;
        session=result?.data?.session||null;
        if(session)break;
        await delay(1000);
      }
      if(!session)throw new Error('Entre com uma conta administradora para registrar a evidência.');
      banner('Registrando evidência física no Supabase...');
      const {data,error}=await client.rpc(RPC,{p_evidence:evidence});
      if(error)throw error;
      if(!data?.ok||data?.complete!==true||!data?.homologation_id)throw new Error(String(data?.error||'O Supabase não confirmou a homologação.'));
      const next=write({
        serverReceiptId:String(data.homologation_id),
        serverReceiptAt:String(data.completed_at||new Date().toISOString()),
        serverReceiptHash:String(data.evidence_hash||''),
        serverReceiptRevision:REVISION,
        serverReceiptComplete:true,
        serverReceiptUserId:String(session.user?.id||'')
      });
      globalThis.dispatchEvent(new CustomEvent('nexlab:device-homologation-synced',{detail:{receipt:data,evidence:next}}));
      banner('Homologação física registrada. Abrindo o diagnóstico final...','ok');
      if(redirect)setTimeout(()=>location.replace('./pwa-check.html?nexlabHomologationSynced=1'),900);
      return {ok:true,receipt:data,evidence:next};
    })().catch(error=>{
      banner(String(error?.message||error),'error');
      globalThis.dispatchEvent(new CustomEvent('nexlab:device-homologation-sync-error',{detail:{error:String(error?.message||error)}}));
      return {ok:false,error:String(error?.message||error)};
    }).finally(()=>{activeSync=null;});
    return activeSync;
  }
  globalThis.__NEXLAB_DEVICE_HOMOLOGATION__=Object.freeze({version:VERSION,revision:REVISION,read,localComplete,sync});
  if(syncRequested()){
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>{banner('Preparando registro da homologação...');void sync();},{once:true});
    else{banner('Preparando registro da homologação...');void sync();}
  }
})();
