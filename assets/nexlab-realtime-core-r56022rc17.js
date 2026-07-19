(function(){
  'use strict';

  if(globalThis.__NEXLAB_REALTIME_CORE__?.revision==='rc17-performance-hardening-r56022')return;

  const VERSION='26.31.22';
  const RELEASE='R56.0.22';
  const REVISION='rc17-performance-hardening-r56022';
  const virtualChannels=new Set();
  let client=null;
  let nativeChannel=null;
  let nativeRemoveChannel=null;
  let nativeRemoveAllChannels=null;
  let physicalChannel=null;
  let physicalSequence=0;
  let rebuildSequence=0;
  let rebuildTimer=null;
  let retryTimer=null;
  let retryAttempt=0;
  let currentStatus='CLOSED';
  let resetGeneration=0;

  function dispatch(name,detail){
    try{globalThis.dispatchEvent(new CustomEvent(name,{detail:detail||{}}));}catch{}
  }

  function activeChannels(){
    return [...virtualChannels].filter(channel=>channel.active&&channel.handlers.length>0);
  }

  function notifyStatus(channel,status,force=false){
    if(!channel.active)return;
    if(!force&&channel.status===status)return;
    channel.status=status;
    if(typeof channel.statusCallback==='function'){
      try{channel.statusCallback(status);}catch(error){console.error('Falha no status do Realtime:',error);}
    }
  }

  async function removePhysical(target){
    if(!target)return 'ok';
    try{
      if(nativeRemoveChannel)return await nativeRemoveChannel(target);
      if(typeof target.unsubscribe==='function')return await target.unsubscribe();
    }catch(error){
      dispatch('nexlab:realtime-cleanup-error',{message:String(error?.message||error),revision:REVISION});
    }
    return 'ok';
  }

  function reconnectDelay(){
    return Math.min(30000,1000*Math.pow(2,Math.min(retryAttempt,5)));
  }

  function scheduleReconnect(){
    if(retryTimer||activeChannels().length===0)return;
    const delay=reconnectDelay();retryAttempt+=1;
    retryTimer=setTimeout(()=>{retryTimer=null;scheduleRebuild(0,true);},delay);
  }

  function scheduleRebuild(delay=40,force=false){
    if(force&&rebuildTimer){clearTimeout(rebuildTimer);rebuildTimer=null;}
    if(rebuildTimer)return;
    rebuildTimer=setTimeout(()=>{rebuildTimer=null;rebuild();},Math.max(0,delay));
  }

  async function rebuild(){
    if(!nativeChannel)return;
    const generation=++rebuildSequence;
    const channels=activeChannels();
    if(channels.length===0){
      const old=physicalChannel;physicalChannel=null;currentStatus='CLOSED';
      if(old)await removePhysical(old);
      dispatch('nexlab:realtime-core-status',{status:'CLOSED',virtualChannels:0,subscriptions:0,version:VERSION,revision:REVISION});
      return;
    }

    const old=physicalChannel;
    const topic=`nexlab-core-r56022rc17-${++physicalSequence}`;
    let next;
    try{next=nativeChannel(topic);}catch(error){
      currentStatus='CHANNEL_ERROR';
      for(const channel of channels)notifyStatus(channel,'CHANNEL_ERROR',true);
      dispatch('nexlab:realtime-core-status',{status:'CHANNEL_ERROR',message:String(error?.message||error),version:VERSION,revision:REVISION});
      scheduleReconnect();return;
    }

    let subscriptionCount=0;
    for(const channel of channels){
      for(const handler of channel.handlers){
        subscriptionCount+=1;
        next=next.on(handler.type,handler.filter,(payload)=>{
          if(!channel.active)return;
          try{handler.callback(payload);}catch(error){
            dispatch('nexlab:realtime-listener-error',{topic:channel.logicalTopic,table:handler.filter?.table||'',message:String(error?.message||error)});
          }
        });
      }
    }

    physicalChannel=next;
    currentStatus='SUBSCRIBING';
    for(const channel of channels){if(channel.status!=='SUBSCRIBED')notifyStatus(channel,'SUBSCRIBING');}
    dispatch('nexlab:realtime-core-status',{status:'SUBSCRIBING',virtualChannels:channels.length,subscriptions:subscriptionCount,version:VERSION,revision:REVISION});

    next.subscribe(async(status)=>{
      if(generation!==rebuildSequence||physicalChannel!==next){
        if(status==='SUBSCRIBED')await removePhysical(next);
        return;
      }
      if(status==='SUBSCRIBED'){
        currentStatus='SUBSCRIBED';retryAttempt=0;
        if(retryTimer){clearTimeout(retryTimer);retryTimer=null;}
        for(const channel of activeChannels())notifyStatus(channel,'SUBSCRIBED');
        if(old&&old!==next)await removePhysical(old);
        dispatch('nexlab:realtime-core-status',{status:'SUBSCRIBED',virtualChannels:activeChannels().length,subscriptions:subscriptionCount,version:VERSION,release:RELEASE,revision:REVISION});
        return;
      }
      if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)){
        if(old&&old!==next){
          physicalChannel=old;currentStatus='SUBSCRIBED';
          await removePhysical(next);scheduleReconnect();
          dispatch('nexlab:realtime-core-status',{status:'DEGRADED_REBUILD',virtualChannels:activeChannels().length,subscriptions:subscriptionCount,version:VERSION,revision:REVISION});
          return;
        }
        currentStatus=status;
        for(const channel of activeChannels())notifyStatus(channel,status,true);
        dispatch('nexlab:realtime-core-status',{status,virtualChannels:activeChannels().length,subscriptions:subscriptionCount,version:VERSION,revision:REVISION});
        if(physicalChannel===next){physicalChannel=null;await removePhysical(next);}
        scheduleReconnect();
      }
    });
  }

  class VirtualChannel{
    constructor(logicalTopic,options){
      this.logicalTopic=String(logicalTopic||'nexlab-realtime');
      this.topic=this.logicalTopic;
      this.options=options||{};
      this.handlers=[];
      this.statusCallback=null;
      this.status='CLOSED';
      this.active=false;
      this.__nexlabVirtualRealtime=true;
    }
    on(type,filter,callback){
      if(typeof callback==='function')this.handlers.push({type:String(type||'postgres_changes'),filter:filter||{},callback});
      return this;
    }
    subscribe(callback){
      if(typeof callback==='function')this.statusCallback=callback;
      if(!this.active){this.active=true;virtualChannels.add(this);notifyStatus(this,'SUBSCRIBING',true);scheduleRebuild();}
      else if(currentStatus==='SUBSCRIBED')notifyStatus(this,'SUBSCRIBED',true);
      return this;
    }
    unsubscribe(){
      if(!this.active)return Promise.resolve('ok');
      this.active=false;virtualChannels.delete(this);this.status='CLOSED';
      scheduleRebuild();
      return Promise.resolve('ok');
    }
    teardown(){return this.unsubscribe();}
  }

  function patchClient(value){
    if(!value||typeof value!=='object')return value;
    if(value.__nexlabRealtimeCoreRevision===REVISION){client=value;return value;}

    nativeChannel=typeof value.channel==='function'?value.channel.bind(value):null;
    nativeRemoveChannel=typeof value.removeChannel==='function'?value.removeChannel.bind(value):null;
    nativeRemoveAllChannels=typeof value.removeAllChannels==='function'?value.removeAllChannels.bind(value):null;
    if(!nativeChannel)return value;

    value.channel=function(topic,options){return new VirtualChannel(topic,options);};
    value.removeChannel=function(channel){
      if(channel?.__nexlabVirtualRealtime)return channel.unsubscribe();
      return nativeRemoveChannel?nativeRemoveChannel(channel):Promise.resolve('ok');
    };
    value.removeAllChannels=async function(){
      const channels=[...virtualChannels];
      for(const channel of channels)await channel.unsubscribe();
      const old=physicalChannel;physicalChannel=null;
      if(old)await removePhysical(old);
      if(nativeRemoveAllChannels){try{return await nativeRemoveAllChannels();}catch{}}
      return [];
    };
    try{Object.defineProperty(value,'__nexlabRealtimeCoreRevision',{value:REVISION,enumerable:false,configurable:false});}catch{}
    client=value;
    dispatch('nexlab:realtime-core-ready',{version:VERSION,release:RELEASE,revision:REVISION});
    return value;
  }

  function reset(){
    resetGeneration+=1;
    if(rebuildTimer){clearTimeout(rebuildTimer);rebuildTimer=null;}
    if(retryTimer){clearTimeout(retryTimer);retryTimer=null;}
    for(const channel of [...virtualChannels]){channel.active=false;channel.status='CLOSED';}
    virtualChannels.clear();
    const old=physicalChannel;physicalChannel=null;currentStatus='CLOSED';retryAttempt=0;
    if(old)removePhysical(old);
    dispatch('nexlab:realtime-core-reset',{generation:resetGeneration,version:VERSION,revision:REVISION});
  }

  const api=Object.freeze({
    version:VERSION,
    release:RELEASE,
    revision:REVISION,
    patchClient,
    reset,
    refresh:()=>scheduleRebuild(0,true),
    snapshot:()=>Object.freeze({
      version:VERSION,
      release:RELEASE,
      revision:REVISION,
      status:currentStatus,
      virtualChannels:activeChannels().length,
      subscriptions:activeChannels().reduce((sum,channel)=>sum+channel.handlers.length,0),
      physicalChannels:physicalChannel?1:0,
      retries:retryAttempt,
      generation:resetGeneration
    })
  });

  globalThis.__NEXLAB_REALTIME_CORE__=api;
  globalThis.__NEXLAB_RUNTIME_STABILITY_STABLE__=api;

  let currentClient=globalThis.__NEXLAB_SUPABASE__||null;
  if(currentClient)currentClient=patchClient(currentClient);
  try{
    const descriptor=Object.getOwnPropertyDescriptor(globalThis,'__NEXLAB_SUPABASE__');
    if(!descriptor||descriptor.configurable){
      Object.defineProperty(globalThis,'__NEXLAB_SUPABASE__',{
        configurable:true,enumerable:true,
        get(){return currentClient;},
        set(value){currentClient=patchClient(value);}
      });
    }
  }catch{}
})();
