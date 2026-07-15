const APP_VERSION='26.30.12';
const APP_REVISION='pending-contract-dom-telemetry-r5552';
const RECOVERY_QUERY='26312';
const ALLOWED_TABS=new Set(['dashboard','pendencias','agenda','notificacoes','participantes','permissoes','equipes','perfil','projetos','patrimonio','estoque','reserva','marketing','eventos','mural','feedback','relatorios','saude-sistema','logs']);

self.addEventListener('install',(event)=>{
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate',(event)=>{
  event.waitUntil((async()=>{
    const keys=await caches.keys();
    await Promise.all(keys.filter((key)=>key.startsWith('nexlab-')).map((key)=>caches.delete(key)));
    await self.clients.claim();
    const clients=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    await Promise.allSettled(clients.map(async(client)=>{
      try{
        const url=new URL(client.url);
        if(url.origin!==self.location.origin)return;
        if(url.searchParams.get('nexlabRecovery')===RECOVERY_QUERY){
          client.postMessage({type:'NEXLAB_RECOVERY_ACTIVE',version:APP_VERSION});
          return;
        }
        url.searchParams.set('nexlabRecovery',RECOVERY_QUERY);
        await client.navigate(url.toString());
      }catch{}
    }));
  })());
});

self.addEventListener('fetch',(event)=>{
  if(event.request.method!=='GET')return;
  const url=new URL(event.request.url);
  if(url.origin!==self.location.origin)return;
  event.respondWith(fetch(new Request(event.request,{cache:'no-store'})).catch(()=>{
    if(event.request.mode==='navigate')return new Response('<!doctype html><meta charset="utf-8"><title>NEXLAB offline</title><body style="font-family:Arial;padding:32px"><h1>NEXLAB indisponível</h1><p>Verifique a conexão e tente novamente.</p></body>',{status:503,headers:{'Content-Type':'text/html; charset=utf-8'}});
    return new Response('',{status:503});
  }));
});

self.addEventListener('message',(event)=>{
  if(event.data?.type==='NEXLAB_SKIP_WAITING')event.waitUntil(self.skipWaiting());
  if(event.data?.type==='NEXLAB_GET_VERSION')event.ports?.[0]?.postMessage({type:'NEXLAB_VERSION',version:APP_VERSION,revision:APP_REVISION});
});

self.addEventListener('push',(event)=>{
  let payload={};
  try{payload=event.data?event.data.json():{};}catch{payload={body:event.data?.text()};}
  const requested=String(payload?.data?.targetTab||'notificacoes');
  const targetTab=ALLOWED_TABS.has(requested)?requested:'notificacoes';
  event.waitUntil(self.registration.showNotification(String(payload.title||'NEXLAB').slice(0,120),{
    body:String(payload.body||'Você recebeu uma nova notificação.').slice(0,500),
    icon:'./icons/nexlab-192.png?v=brand-r38',
    badge:'./icons/nexlab-192.png?v=brand-r38',
    tag:String(payload.tag||`nexlab-${Date.now()}`).slice(0,160),
    data:{targetTab}
  }));
});

self.addEventListener('notificationclick',(event)=>{
  event.notification.close();
  const requested=String(event.notification?.data?.targetTab||'notificacoes');
  const tab=ALLOWED_TABS.has(requested)?requested:'notificacoes';
  const url=new URL('./',self.location.href);
  url.searchParams.set('nexlabTab',tab);
  event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async(clients)=>{
    for(const client of clients){client.postMessage({type:'NEXLAB_NAVIGATE',tab});await client.focus();return;}
    return self.clients.openWindow?.(url.toString());
  }));
});
