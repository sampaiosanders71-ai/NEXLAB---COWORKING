const APP_VERSION='26.30.36';
const APP_REVISION='permission-confirmation-full-admin-r55624';
const CACHE_NAME='nexlab-v26-30-36-shell-r55624';
const CACHE_PREFIX='nexlab-';
const NETWORK_TIMEOUT_MS=6000;
const ALLOWED_TABS=new Set(['dashboard','pendencias','agenda','notificacoes','participantes','permissoes','equipes','perfil','projetos','inventario','patrimonio','estoque','reserva','marketing','eventos','mural','feedback','relatorios','saude-sistema','logs']);
const APP_SHELL=[
  './',
  './index.html',
  './offline.html',
  './manifest.webmanifest?v=app-r26336-permission-confirmation-full-admin-r55624',
  './assets/index-R55v26336.js?v=app-r26336-permission-confirmation-full-admin-r55624',
  './assets/index-B1u8eynw.css?v=brand-r38',
  './assets/nexlab-bootstrap.js?v=app-r26336-permission-confirmation-full-admin-r55624',
  './assets/nexlab-update-manager.js?v=app-r26336-permission-confirmation-full-admin-r55624',
  './assets/nexlab-realtime-hub-r55624.js?v=app-r26336-permission-confirmation-full-admin-r55624',
  './assets/nexlab-visual.css?v=app-r26336-permission-confirmation-full-admin-r55624',
  './assets/nexlab-visual.js?v=app-r26336-permission-confirmation-full-admin-r55624',
  './assets/nexlab-vapid-rotation.js?v=app-r26336-permission-confirmation-full-admin-r55624',
  './assets/nexlab-export-vendor.js',
  './icons/nexlab-favicon-rounded.png?v=brand-r38',
  './icons/apple-touch-icon.png?v=brand-r38',
  './icons/nexlab-192.png?v=brand-r38',
  './icons/nexlab-512.png?v=brand-r38',
  './icons/nexlab-maskable-192.png?v=brand-r38',
  './icons/nexlab-maskable-512.png?v=brand-r38',
  './brand/nexlab-icon.webp',
  './brand/nexlab-logo-dark.webp',
  './brand/nexlab-logo-light.webp'
];
const CORE_SHELL=new Set([
  new URL('./index.html',self.registration.scope).href,
  new URL('./offline.html',self.registration.scope).href,
  new URL('./assets/index-R55v26336.js?v=app-r26336-permission-confirmation-full-admin-r55624',self.registration.scope).href,
  new URL('./assets/index-B1u8eynw.css?v=brand-r38',self.registration.scope).href
]);

async function fetchFresh(url){
  const request=new Request(new URL(url,self.registration.scope).href,{cache:'reload',credentials:'same-origin'});
  const response=await fetch(request);
  if(!response||!response.ok)throw new Error(`Falha ao obter ${request.url}`);
  return {request,response};
}

async function precacheShell(){
  const cache=await caches.open(CACHE_NAME);
  const results=await Promise.allSettled(APP_SHELL.map(async(url)=>{
    const {request,response}=await fetchFresh(url);
    await cache.put(request,response.clone());
    return request.url;
  }));
  const cached=new Set(results.filter(result=>result.status==='fulfilled').map(result=>result.value));
  const missingCore=[...CORE_SHELL].filter(url=>!cached.has(url));
  if(missingCore.length)throw new Error(`Arquivos essenciais não foram armazenados: ${missingCore.join(', ')}`);
}

self.addEventListener('install',(event)=>{
  event.waitUntil(precacheShell());
});

self.addEventListener('activate',(event)=>{
  event.waitUntil((async()=>{
    const keys=await caches.keys();
    await Promise.all(keys.filter(key=>key.startsWith(CACHE_PREFIX)&&key!==CACHE_NAME).map(key=>caches.delete(key)));
    await self.clients.claim();
    const clients=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    for(const client of clients){
      try{client.postMessage({type:'NEXLAB_SW_ACTIVATED',version:APP_VERSION,revision:APP_REVISION});}catch{}
    }
  })());
});

function timeout(milliseconds){
  return new Promise((_,reject)=>setTimeout(()=>reject(new Error('Tempo de rede excedido.')),milliseconds));
}

async function cacheResponse(request,response){
  if(!response||!response.ok||response.type==='opaque')return response;
  const cache=await caches.open(CACHE_NAME);
  await cache.put(request,response.clone());
  return response;
}

async function networkFirst(request,{timeoutMs=NETWORK_TIMEOUT_MS,fallback}={}){
  try{
    const response=await Promise.race([fetch(new Request(request,{cache:'no-store'})),timeout(timeoutMs)]);
    return cacheResponse(request,response);
  }catch(error){
    const cached=await caches.match(request,{ignoreSearch:false});
    if(cached)return cached;
    if(fallback){
      const fallbackResponse=await caches.match(new URL(fallback,self.registration.scope).href,{ignoreSearch:false});
      if(fallbackResponse)return fallbackResponse;
    }
    throw error;
  }
}

async function cacheFirst(request){
  const cached=await caches.match(request,{ignoreSearch:false});
  if(cached){
    self.registration?.navigationPreload;
    fetch(request).then(response=>cacheResponse(request,response)).catch(()=>{});
    return cached;
  }
  const response=await fetch(request);
  return cacheResponse(request,response);
}

function isStaticAsset(request,url){
  if(['script','style','image','font','manifest'].includes(request.destination))return true;
  return /\.(?:js|css|png|webp|ico|woff2?|webmanifest)$/i.test(url.pathname);
}

self.addEventListener('fetch',(event)=>{
  const request=event.request;
  if(request.method!=='GET')return;
  const url=new URL(request.url);
  if(url.origin!==self.location.origin)return;

  if(url.pathname.endsWith('/release.json')){
    event.respondWith(fetch(new Request(request,{cache:'no-store'})));
    return;
  }

  if(request.mode==='navigate'){
    event.respondWith((async()=>{
      try{
        const response=await networkFirst(request,{fallback:'./index.html'});
        if(response&&response.ok){
          const cache=await caches.open(CACHE_NAME);
          await cache.put(new URL('./index.html',self.registration.scope).href,response.clone());
        }
        return response;
      }catch{
        return (await caches.match(new URL('./offline.html',self.registration.scope).href)) || new Response('<!doctype html><meta charset="utf-8"><title>NEXLAB offline</title><h1>NEXLAB offline</h1><p>Reconecte-se e tente novamente.</p>',{status:503,headers:{'Content-Type':'text/html; charset=utf-8'}});
      }
    })());
    return;
  }

  if(isStaticAsset(request,url)){
    event.respondWith(cacheFirst(request).catch(()=>new Response('',{status:503})));
    return;
  }

  event.respondWith(networkFirst(request).catch(()=>new Response('',{status:503})));
});

self.addEventListener('message',(event)=>{
  if(event.data?.type==='NEXLAB_SKIP_WAITING')event.waitUntil(self.skipWaiting());
  if(event.data?.type==='NEXLAB_GET_VERSION')event.ports?.[0]?.postMessage({type:'NEXLAB_VERSION',version:APP_VERSION,revision:APP_REVISION,cache:CACHE_NAME});
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
