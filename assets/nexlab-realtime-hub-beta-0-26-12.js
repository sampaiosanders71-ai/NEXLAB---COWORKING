(function(){
  'use strict';
  const ID=globalThis.__NEXLAB_BUILD_IDENTITY__||Object.freeze({version:'0.26.12',revision:'beta-0-26-12-bookings-render-loop-recovery'});
  if(globalThis.__NEXLAB_PENDING_REALTIME_HUB__?.revision===ID.revision)return;

  const VERSION=ID.version;
  const REVISION=ID.revision;
  const TABLES=['profiles','bookings','booking_participants','feedback','projects','project_tasks','assets','teams','team_members','stock_items','meetings'];
  const listeners=new Set();
  let channel=null;
  let connecting=null;
  let eventTimer=null;
  let idleTimer=null;

  const wait=(ms)=>new Promise(resolve=>setTimeout(resolve,ms));

  async function getClient(){
    for(let attempt=0;attempt<80;attempt+=1){
      const client=globalThis.__NEXLAB_SUPABASE__;
      if(client?.channel&&client?.removeChannel)return client;
      await wait(100);
    }
    throw new Error('Cliente Supabase indisponível para o Realtime de Pendências.');
  }

  function notify(detail={}){
    if(eventTimer)clearTimeout(eventTimer);
    eventTimer=setTimeout(()=>{
      eventTimer=null;
      for(const listener of [...listeners]){
        try{listener(detail);}catch(error){console.error('Falha ao atualizar Pendências:',error);}
      }
    },300);
  }

  async function connect(){
    if(channel||connecting||listeners.size===0)return connecting;
    connecting=(async()=>{
      try{
        const client=await getClient();
        if(listeners.size===0)return;
        let next=client.channel('nexlab-pending-hub-canonical');
        for(const table of TABLES){
          next=next.on('postgres_changes',{event:'*',schema:'public',table},payload=>notify({table,eventType:payload?.eventType||''}));
        }
        channel=next.subscribe(status=>{
          if(channel!==next)return;
          if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)){channel=null;setTimeout(connect,1000);}
        });
      }catch(error){
        console.warn('Realtime de Pendências indisponível; nova tentativa agendada.',error);
        setTimeout(connect,1500);
      }finally{connecting=null;}
    })();
    return connecting;
  }

  function subscribe(listener){
    if(typeof listener!=='function')return null;
    if(idleTimer){clearTimeout(idleTimer);idleTimer=null;}
    listeners.add(listener);connect();
    return function unsubscribe(){
      listeners.delete(listener);
      if(listeners.size===0){
        if(eventTimer){clearTimeout(eventTimer);eventTimer=null;}
        idleTimer=setTimeout(async()=>{
          idleTimer=null;
          if(listeners.size===0&&channel){const old=channel;channel=null;try{await globalThis.__NEXLAB_SUPABASE__?.removeChannel?.(old);}catch{}}
        },1200);
      }
    };
  }

  function reset(){
    listeners.clear();
    if(eventTimer){clearTimeout(eventTimer);eventTimer=null;}
    if(idleTimer){clearTimeout(idleTimer);idleTimer=null;}
    if(channel){const old=channel;channel=null;globalThis.__NEXLAB_SUPABASE__?.removeChannel?.(old);}
  }

  globalThis.__NEXLAB_PENDING_REALTIME_HUB__=Object.freeze({
    version:VERSION,revision:REVISION,subscribe,refresh:notify,reset,
    snapshot:()=>Object.freeze({listeners:listeners.size,connected:Boolean(channel),tables:[...TABLES]})
  });
})();
