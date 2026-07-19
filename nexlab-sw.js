const APP_VERSION='26.31.22';
const APP_RELEASE='R56.0.22';
const APP_REVISION='rc17-performance-hardening-r56022';
const GENERATED_AT='2026-07-19T02:30:00Z';
const ASSET_REVISION='app-r263122-rc17-performance-hardening-r56022';
const CACHE_NAME='nexlab-v26-31-22-rc17-performance-hardening-r56022';
const CACHE_PREFIX='nexlab-';
const NETWORK_TIMEOUT_MS=6000;
const MAIN_BUNDLE='index-R56v263122rc17.js';
const VENDOR_BUNDLE='nexlab-vendor-r56022rc17.js';
const SHARED_BUNDLE='nexlab-app-shared-r56022rc17.js';
const FEATURE_BUNDLE='nexlab-feature-modules-r56022rc17.js';
const ALLOWED_TABS=new Set(['dashboard','pendencias','agenda','notificacoes','participantes','permissoes','equipes','perfil','projetos','inventario','patrimonio','estoque','reserva','marketing','eventos','mural','feedback','relatorios','saude-sistema','logs']);
const APP_SHELL=[
  './index.html',
  './offline.html',
  `./manifest.webmanifest?v=${ASSET_REVISION}`,
  `./assets/${MAIN_BUNDLE}?v=${ASSET_REVISION}`,
  `./assets/${VENDOR_BUNDLE}?v=${ASSET_REVISION}`,
  `./assets/${SHARED_BUNDLE}?v=${ASSET_REVISION}`,
  './assets/index-B1u8eynw.css?v=brand-r38',
  `./assets/nexlab-bootstrap.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-realtime-core-r56022rc17.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-update-manager.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-realtime-hub-r56022rc17.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-visual.css?v=${ASSET_REVISION}`,
  `./assets/nexlab-visual.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-vapid-rotation.js?v=${ASSET_REVISION}`,
  './icons/nexlab-favicon-rounded.png?v=brand-r38',
  './icons/apple-touch-icon.png?v=brand-r38',
  './icons/nexlab-192.png?v=brand-r38',
  './icons/nexlab-maskable-192.png?v=brand-r38',
  './brand/nexlab-icon.webp',
  './brand/nexlab-logo-dark.webp',
  './brand/nexlab-logo-light.webp'
];
const INDEX_URL=new URL('./index.html',self.registration.scope).href;
const OFFLINE_URL=new URL('./offline.html',self.registration.scope).href;
const SCOPE_URL=new URL(self.registration.scope);
const CORE_SHELL=new Set([
  INDEX_URL,
  OFFLINE_URL,
  new URL(`./assets/${MAIN_BUNDLE}?v=${ASSET_REVISION}`,self.registration.scope).href,
  new URL(`./assets/${VENDOR_BUNDLE}?v=${ASSET_REVISION}`,self.registration.scope).href,
  new URL(`./assets/${SHARED_BUNDLE}?v=${ASSET_REVISION}`,self.registration.scope).href,
  new URL('./assets/index-B1u8eynw.css?v=brand-r38',self.registration.scope).href
]);

function timeout(milliseconds){
  return new Promise((_,reject)=>setTimeout(()=>reject(new Error('Tempo de rede excedido.')),milliseconds));
}

function expectedKind(request,url){
  const destination=request.destination;
  if(destination==='script'||/\.js$/i.test(url.pathname))return 'script';
  if(destination==='style'||/\.css$/i.test(url.pathname))return 'style';
  if(destination==='manifest'||/\.webmanifest$/i.test(url.pathname))return 'manifest';
  if(destination==='image'||/\.(?:png|webp|ico|jpe?g|svg)$/i.test(url.pathname))return 'image';
  if(destination==='font'||/\.woff2?$/i.test(url.pathname))return 'font';
  if(request.mode==='navigate'||/\.html$/i.test(url.pathname))return 'html';
  return 'other';
}

function contentTypeMatches(kind,contentType){
  const value=String(contentType||'').toLowerCase();
  if(kind==='script')return /(?:javascript|ecmascript)/.test(value);
  if(kind==='style')return value.includes('text/css');
  if(kind==='manifest')return /(?:application\/manifest\+json|application\/json)/.test(value);
  if(kind==='image')return value.startsWith('image/');
  if(kind==='font')return /(?:font\/|application\/font|application\/octet-stream)/.test(value);
  if(kind==='html')return value.includes('text/html');
  return true;
}

function responseIsCacheable(request,response,kind=expectedKind(request,new URL(request.url))){
  if(!response||!response.ok||response.type==='opaque')return false;
  let responseUrl;
  try{responseUrl=new URL(response.url||request.url);}catch{return false;}
  if(responseUrl.origin!==self.location.origin)return false;
  return contentTypeMatches(kind,response.headers.get('content-type'));
}

async function isCanonicalAppShell(response){
  if(!response||!response.ok||response.type==='opaque')return false;
  const contentType=response.headers.get('content-type')||'';
  if(!contentType.toLowerCase().includes('text/html'))return false;
  let responseUrl;
  try{responseUrl=new URL(response.url);}catch{return false;}
  const scopePath=SCOPE_URL.pathname.endsWith('/')?SCOPE_URL.pathname:`${SCOPE_URL.pathname}/`;
  const responsePath=responseUrl.pathname.endsWith('/')?responseUrl.pathname:`${responseUrl.pathname}`;
  if(responseUrl.origin!==self.location.origin)return false;
  if(responsePath!==scopePath&&responsePath!==`${scopePath}index.html`)return false;
  try{
    const html=await response.clone().text();
    return /<div[^>]+id=["']root["']/i.test(html)
      && /name=["']nexlab-version["']/i.test(html)
      && html.includes(MAIN_BUNDLE)
      && html.includes(VENDOR_BUNDLE)
      && html.includes(SHARED_BUNDLE);
  }catch{return false;}
}

async function fetchFresh(url){
  const request=new Request(new URL(url,self.registration.scope).href,{cache:'reload',credentials:'same-origin'});
  const response=await fetch(request);
  if(!responseIsCacheable(request,response))throw new Error(`Resposta inválida para ${request.url}`);
  if(expectedKind(request,new URL(request.url))==='html'&&request.url===INDEX_URL&&!(await isCanonicalAppShell(response))){
    throw new Error('O index.html recebido não corresponde ao shell desta revisão.');
  }
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
    const previousCaches=keys.filter(key=>key.startsWith(CACHE_PREFIX)&&key!==CACHE_NAME);
    const isUpgrade=previousCaches.length>0;
    await self.clients.claim();
    const clients=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    for(const client of clients){
      try{client.postMessage({type:'NEXLAB_SW_ACTIVATED',version:APP_VERSION,release:APP_RELEASE,revision:APP_REVISION,generatedAt:GENERATED_AT,cache:CACHE_NAME,reloadByWorker:isUpgrade});}catch{}
    }
    if(isUpgrade){
      await Promise.all(clients.map(async(client)=>{
        try{await client.navigate(client.url);}catch{}
      }));
    }
    await Promise.all(previousCaches.map(key=>caches.delete(key)));
  })());
});

async function cacheValidResponse(request,response,kind){
  if(!responseIsCacheable(request,response,kind))return false;
  const cache=await caches.open(CACHE_NAME);
  await cache.put(request,response.clone());
  return true;
}

async function networkFirst(request,{timeoutMs=NETWORK_TIMEOUT_MS,fallback,kind}={}){
  try{
    const response=await Promise.race([fetch(new Request(request,{cache:'no-store'})),timeout(timeoutMs)]);
    await cacheValidResponse(request,response,kind);
    return response;
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

async function cacheFirst(request,kind){
  const cached=await caches.match(request,{ignoreSearch:false});
  if(cached){
    fetch(request).then(async(response)=>{await cacheValidResponse(request,response,kind);}).catch(()=>{});
    return cached;
  }
  const response=await fetch(request);
  if(!(await cacheValidResponse(request,response,kind)))throw new Error(`Ativo inválido: ${request.url}`);
  return response;
}

function isStaticAsset(request,url){
  if(['script','style','image','font','manifest'].includes(request.destination))return true;
  return /\.(?:js|css|png|webp|ico|jpe?g|svg|woff2?|webmanifest)$/i.test(url.pathname);
}

function isAppEntryNavigation(url){
  const scopePath=SCOPE_URL.pathname.endsWith('/')?SCOPE_URL.pathname:`${SCOPE_URL.pathname}/`;
  return url.pathname===scopePath||url.pathname===`${scopePath}index.html`;
}

async function appEntryNavigation(request,event){
  try{
    const response=await Promise.race([fetch(new Request(request,{cache:'no-store'})),timeout(NETWORK_TIMEOUT_MS)]);
    if(await isCanonicalAppShell(response)){
      const cache=await caches.open(CACHE_NAME);
      await cache.put(INDEX_URL,response.clone());
    }
    return response;
  }catch{
    return (await caches.match(INDEX_URL,{ignoreSearch:true}))
      || (await caches.match(OFFLINE_URL,{ignoreSearch:true}))
      || new Response('<!doctype html><meta charset="utf-8"><title>NEXLAB offline</title><h1>NEXLAB offline</h1><p>Reconecte-se e tente novamente.</p>',{status:503,headers:{'Content-Type':'text/html; charset=utf-8'}});
  }
}

async function documentNavigation(request,event){
  try{
    const response=await Promise.race([fetch(new Request(request,{cache:'no-store'})),timeout(NETWORK_TIMEOUT_MS)]);
    if(responseIsCacheable(request,response,'html')){
      const cache=await caches.open(CACHE_NAME);
      await cache.put(request,response.clone());
    }
    return response;
  }catch{
    return (await caches.match(request,{ignoreSearch:false}))
      || (await caches.match(OFFLINE_URL,{ignoreSearch:true}))
      || new Response('',{status:503,headers:{'Content-Type':'text/html; charset=utf-8'}});
  }
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
    event.respondWith(isAppEntryNavigation(url)?appEntryNavigation(request,event):documentNavigation(request,event));
    return;
  }

  if(isStaticAsset(request,url)){
    const kind=expectedKind(request,url);
    event.respondWith(cacheFirst(request,kind).catch(()=>new Response('',{status:503})));
    return;
  }

  event.respondWith(networkFirst(request).catch(()=>new Response('',{status:503})));
});

self.addEventListener('message',(event)=>{
  if(event.data?.type==='NEXLAB_GET_VERSION'){
    event.ports?.[0]?.postMessage({type:'NEXLAB_VERSION',version:APP_VERSION,release:APP_RELEASE,revision:APP_REVISION,generatedAt:GENERATED_AT,cache:CACHE_NAME});
    return;
  }
  if(event.data?.type==='NEXLAB_SKIP_WAITING'){
    const expectedVersion=String(event.data.expectedVersion||'').trim();
    const expectedRevision=String(event.data.expectedRevision||'').trim();
    if(expectedVersion&&expectedVersion!==APP_VERSION){
      event.ports?.[0]?.postMessage({ok:false,error:'Versão do worker diferente da versão confirmada.'});
      return;
    }
    if(expectedRevision&&expectedRevision!==APP_REVISION){
      event.ports?.[0]?.postMessage({ok:false,error:'Revisão do worker diferente da revisão confirmada.'});
      return;
    }
    event.ports?.[0]?.postMessage({ok:true,version:APP_VERSION,revision:APP_REVISION});
    event.waitUntil(self.skipWaiting());
  }
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
