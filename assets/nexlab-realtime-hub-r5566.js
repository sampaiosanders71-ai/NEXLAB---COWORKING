(function(){
  'use strict';
  if(globalThis.__NEXLAB_PENDING_REALTIME_HUB__)return;

  const TABLES=['profiles','reservations','feedback','projects','project_tasks','assets'];
  const listeners=new Set();
  let channel=null;
  let connecting=null;
  let retryTimer=null;
  let retryAttempt=0;
  let eventTimer=null;
  let idleTimer=null;
  let stopped=false;

  const wait=(ms)=>new Promise((resolve)=>setTimeout(resolve,ms));

  async function getClient(){
    for(let attempt=0;attempt<60;attempt+=1){
      const client=globalThis.__NEXLAB_SUPABASE__;
      if(client?.channel&&client?.removeChannel)return client;
      await wait(100);
    }
    throw new Error('Cliente Supabase indisponível para o Realtime de Pendências.');
  }

  function notify(){
    if(eventTimer)clearTimeout(eventTimer);
    eventTimer=setTimeout(()=>{
      eventTimer=null;
      for(const listener of [...listeners]){
        try{listener();}catch(error){console.error('Falha ao atualizar Pendências:',error);}
      }
    },350);
  }

  async function dropChannel(target=channel){
    if(!target)return;
    if(channel===target)channel=null;
    try{
      const client=globalThis.__NEXLAB_SUPABASE__;
      if(client?.removeChannel)await client.removeChannel(target);
      else await target.unsubscribe?.();
    }catch{}
  }

  function scheduleReconnect(){
    if(stopped||retryTimer||listeners.size===0)return;
    const delay=Math.min(30000,1000*Math.pow(2,Math.min(retryAttempt,5)));
    retryAttempt+=1;
    retryTimer=setTimeout(()=>{
      retryTimer=null;
      connect();
    },delay);
  }

  async function connect(){
    if(stopped||channel||connecting||listeners.size===0)return connecting;
    connecting=(async()=>{
      try{
        const client=await getClient();
        if(stopped||listeners.size===0)return;
        let next=client.channel('nexlab-pending-singleton-r5566');
        for(const table of TABLES){
          next=next.on('postgres_changes',{event:'*',schema:'public',table},notify);
        }
        channel=next;
        next.subscribe((status)=>{
          if(channel!==next)return;
          if(status==='SUBSCRIBED'){
            retryAttempt=0;
            return;
          }
          if(status==='CHANNEL_ERROR'||status==='TIMED_OUT'||status==='CLOSED'){
            dropChannel(next).finally(scheduleReconnect);
          }
        });
      }catch(error){
        console.warn('Realtime de Pendências indisponível; nova tentativa agendada.',error);
        scheduleReconnect();
      }finally{
        connecting=null;
      }
    })();
    return connecting;
  }

  function subscribe(listener){
    if(typeof listener!=='function')return null;
    stopped=false;
    if(idleTimer){clearTimeout(idleTimer);idleTimer=null;}
    listeners.add(listener);
    connect();
    return function unsubscribe(){
      listeners.delete(listener);
      if(listeners.size===0){
        if(retryTimer){clearTimeout(retryTimer);retryTimer=null;}
        if(eventTimer){clearTimeout(eventTimer);eventTimer=null;}
        if(idleTimer)clearTimeout(idleTimer);
        idleTimer=setTimeout(()=>{
          idleTimer=null;
          if(listeners.size===0)dropChannel();
        },1500);
      }
    };
  }

  globalThis.__NEXLAB_PENDING_REALTIME_HUB__={
    subscribe,
    refresh:notify,
    snapshot:()=>({listeners:listeners.size,connected:Boolean(channel),retryAttempt})
  };
})();
