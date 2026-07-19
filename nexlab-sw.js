importScripts('./assets/nexlab-release-identity.js');
const BUILD_IDENTITY=self.__NEXLAB_BUILD_IDENTITY__||Object.freeze({version:'0.26.12',release:'Beta',revision:'beta-0-26-12-bookings-render-loop-recovery',assetRevision:'app-beta-0-26-12-bookings-render-loop-recovery',cacheName:'nexlab-beta-0-26-12-bookings-render-loop-recovery',generatedAt:'2026-07-19T22:17:34Z'});
const APP_VERSION=BUILD_IDENTITY.version;
const APP_RELEASE=BUILD_IDENTITY.release;
const APP_REVISION=BUILD_IDENTITY.revision;
const GENERATED_AT=BUILD_IDENTITY.generatedAt;
const ASSET_REVISION=BUILD_IDENTITY.assetRevision;
const CACHE_NAME=BUILD_IDENTITY.cacheName;
const CACHE_PREFIX='nexlab-';
const NETWORK_TIMEOUT_MS=6000;
const MAIN_BUNDLE='index-beta-0-26-12.js';
const VENDOR_BUNDLE='nexlab-vendor-beta-0-26-12.js';
const SHARED_BUNDLE='nexlab-app-shared-beta-0-26-12.js';
const FEATURE_BUNDLE='nexlab-feature-modules-beta-0-26-12.js';
const EXPORT_BUNDLE='nexlab-export-vendor-beta-0-26-12.js';
const ALLOWED_TABS=new Set(['dashboard','pendencias','agenda','notificacoes','participantes','permissoes','equipes','perfil','projetos','inventario','patrimonio','estoque','reserva','marketing','eventos','mural','feedback','relatorios','saude-sistema','logs']);
const MANDATORY_SHELL=[
  './index.html','./offline.html',
  `./manifest.webmanifest?v=${ASSET_REVISION}`,
  `./assets/nexlab-release-identity.js?v=${ASSET_REVISION}`,
  `./assets/${MAIN_BUNDLE}?v=${ASSET_REVISION}`,
  `./assets/${VENDOR_BUNDLE}?v=${ASSET_REVISION}`,
  `./assets/${SHARED_BUNDLE}?v=${ASSET_REVISION}`,
  './assets/index-B1u8eynw.css?v=brand-r38',
  `./assets/nexlab-bootstrap.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-dialogs.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-realtime-core-beta-0-26-12.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-update-manager.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-realtime-hub-beta-0-26-12.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-visual.css?v=${ASSET_REVISION}`,
  `./assets/nexlab-visual.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-vapid-rotation.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-push-navigation.js?v=${ASSET_REVISION}`,
  `./assets/nexlab-device-homologation.js?v=${ASSET_REVISION}`,
  './icons/nexlab-favicon-rounded.png?v=brand-r38','./icons/apple-touch-icon.png?v=brand-r38',
  './icons/nexlab-192.png?v=brand-r38','./icons/nexlab-maskable-192.png?v=brand-r38',
  './icons/nexlab-512.png?v=brand-r38','./icons/nexlab-maskable-512.png?v=brand-r38',
  './brand/nexlab-icon.webp?v=brand-r38','./brand/nexlab-logo-dark.webp?v=brand-r38','./brand/nexlab-logo-light.webp?v=brand-r38'
];
const OPTIONAL_ASSETS=new Set([
  new URL(`./assets/${FEATURE_BUNDLE}?v=${ASSET_REVISION}`,self.registration.scope).href,
  new URL(`./assets/${EXPORT_BUNDLE}?v=${ASSET_REVISION}`,self.registration.scope).href,
  new URL(`./assets/nexlab-pwa-readiness.js?v=${ASSET_REVISION}`,self.registration.scope).href,
  new URL('./pwa-check.html',self.registration.scope).href
]);
const INDEX_URL=new URL('./index.html',self.registration.scope).href;
const OFFLINE_URL=new URL('./offline.html',self.registration.scope).href;
const SCOPE_URL=new URL(self.registration.scope);
const INSTALL_CACHE_NAME=`${CACHE_NAME}-installing`;
const REQUIRED_SHELL=new Set(MANDATORY_SHELL.map(url=>new URL(url,self.registration.scope).href));

function isRequiredShellRequest(request){
  return REQUIRED_SHELL.has(request.url);
}

function cacheVersionParts(name){
  const match=String(name||'').match(/^nexlab-beta-(\d+)-(\d+)-(\d+)-/);
  return match?match.slice(1).map(Number):[-1,-1,-1];
}

function compareCacheVersions(left,right){
  const a=cacheVersionParts(left);
  const b=cacheVersionParts(right);
  for(let index=0;index<3;index+=1){
    if(a[index]!==b[index])return a[index]-b[index];
  }
  return String(left).localeCompare(String(right));
}

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
  await caches.delete(INSTALL_CACHE_NAME);
  const staging=await caches.open(INSTALL_CACHE_NAME);
  try{
    const fetched=await Promise.all(MANDATORY_SHELL.map(async(url)=>{
      const {request,response}=await fetchFresh(url);
      await staging.put(request,response.clone());
      return request.url;
    }));
    const available=new Set(fetched);
    const missing=[...REQUIRED_SHELL].filter(url=>!available.has(url));
    if(missing.length)throw new Error(`Arquivos obrigatórios não foram armazenados: ${missing.join(', ')}`);
    const finalCache=await caches.open(CACHE_NAME);
    const stagedRequests=await staging.keys();
    if(stagedRequests.length!==REQUIRED_SHELL.size)throw new Error(`Precache incompleto: ${stagedRequests.length}/${REQUIRED_SHELL.size}.`);
    await Promise.all(stagedRequests.map(async(request)=>{
      const response=await staging.match(request);
      if(!response)throw new Error(`Resposta ausente no cache temporário: ${request.url}`);
      await finalCache.put(request,response);
    }));
  }catch(error){
    await caches.delete(CACHE_NAME);
    throw error;
  }finally{
    await caches.delete(INSTALL_CACHE_NAME);
  }
}

self.addEventListener('install',(event)=>{
  event.waitUntil((async()=>{
    // A nova revisão permanece em waiting. A ativação só ocorre após
    // NEXLAB_SKIP_WAITING, enviado pelo botão "Atualizar agora".
    await precacheShell();
  })());
});

self.addEventListener('activate',(event)=>{
  event.waitUntil((async()=>{
    const keys=await caches.keys();
    const previousCaches=keys
      .filter(key=>key.startsWith(CACHE_PREFIX)&&key!==CACHE_NAME&&key!==INSTALL_CACHE_NAME)
      .sort(compareCacheVersions);
    const retainedPrevious=previousCaches.length?previousCaches[previousCaches.length-1]:null;
    const obsoleteCaches=previousCaches.filter(key=>key!==retainedPrevious);
    await self.clients.claim();
    const clients=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    for(const client of clients){
      try{
        client.postMessage({
          type:'NEXLAB_SW_ACTIVATED',
          version:APP_VERSION,
          release:APP_RELEASE,
          revision:APP_REVISION,
          generatedAt:GENERATED_AT,
          cache:CACHE_NAME,
          reloadByWorker:false,
          previousCacheRetained:retainedPrevious
        });
      }catch{}
    }
    // Mantém a revisão imediatamente anterior para abas que escolheram "Depois".
    // O worker nunca navega ou recarrega janelas por conta própria.
    await Promise.all(obsoleteCaches.map(key=>caches.delete(key)));
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
  if(cached)return cached;
  if(isRequiredShellRequest(request)){
    throw new Error(`Arquivo obrigatório ausente no cache imutável: ${request.url}`);
  }
  const response=await fetch(new Request(request,{cache:'no-store'}));
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
  const cachedIndex=await caches.match(INDEX_URL,{ignoreSearch:true});
  try{
    const response=await Promise.race([
      fetch(new Request(request,{cache:'no-store'})),
      timeout(NETWORK_TIMEOUT_MS)
    ]);
    if(!(await isCanonicalAppShell(response))){
      throw new Error('O index.html da rede é inválido ou pertence a outra revisão.');
    }
    // O shell instalado é imutável: uma resposta válida da rede não sobrescreve
    // nem substitui o index da revisão que controla esta página.
    return cachedIndex||response;
  }catch{
    return cachedIndex
      || (await caches.match(OFFLINE_URL,{ignoreSearch:true}))
      || new Response('<!doctype html><meta charset="utf-8"><title>NEXLAB offline</title><h1>NEXLAB offline</h1><p>Reconecte-se e tente novamente.</p>',{status:503,headers:{'Content-Type':'text/html; charset=utf-8'}});
  }
}

async function documentNavigation(request,event){
  const cached=await caches.match(request,{ignoreSearch:false});
  if(isRequiredShellRequest(request)&&cached)return cached;
  try{
    const response=await Promise.race([fetch(new Request(request,{cache:'no-store'})),timeout(NETWORK_TIMEOUT_MS)]);
    if(!responseIsCacheable(request,response,'html'))throw new Error('Documento HTML inválido.');
    if(!isRequiredShellRequest(request)){
      const cache=await caches.open(CACHE_NAME);
      await cache.put(request,response.clone());
    }
    return response;
  }catch{
    return cached
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
    event.ports?.[0]?.postMessage({type:'NEXLAB_VERSION',version:APP_VERSION,release:APP_RELEASE,revision:APP_REVISION,generatedAt:GENERATED_AT,cache:CACHE_NAME,cachePolicy:'core-precache-lazy-on-demand'});
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

function createPushRequestId(){
  try{return crypto.randomUUID();}catch{return `push-${Date.now()}-${Math.random().toString(16).slice(2)}`;}
}

function safePushDestination(raw,tab,notificationId,entityId,entityType,pushRequestId){
  let url;
  try{url=new URL(String(raw||''),self.registration.scope);}catch{url=new URL('./',self.registration.scope);}
  const scope=new URL(self.registration.scope);
  if(url.origin!==scope.origin||!url.pathname.startsWith(scope.pathname))url=new URL('./',self.registration.scope);
  url.searchParams.set('nexlabTab',tab);
  if(notificationId)url.searchParams.set('notification',notificationId);
  if(entityId)url.searchParams.set('entity',entityId);
  if(entityType)url.searchParams.set('entityType',entityType);
  if(pushRequestId)url.searchParams.set('nexlabPushRequest',pushRequestId);
  return url.toString();
}

async function postNavigationAndWaitForAck(client,message,timeoutMs=5200){
  if(!client)return {ok:false,error:'Cliente indisponível.'};
  const channel=new MessageChannel();
  const response=new Promise((resolve)=>{
    let settled=false;
    const finish=(value)=>{if(settled)return;settled=true;clearTimeout(timer);try{channel.port1.close();}catch{}resolve(value);};
    const timer=setTimeout(()=>finish({ok:false,error:'O aplicativo não confirmou a navegação Push.'}),timeoutMs);
    channel.port1.onmessage=(event)=>{
      const data=event.data&&typeof event.data==='object'?event.data:{};
      const requestMatches=!message.pushRequestId||String(data.requestId||'')===message.pushRequestId;
      finish(requestMatches&&data.type==='NEXLAB_NAVIGATE_ACK'&&data.ok===true
        ?{ok:true,ack:data}
        :{ok:false,error:String(data.error||'Confirmação Push inválida.'),ack:data});
    };
  });
  try{client.postMessage({...message,handledByBridge:true,requiresAck:true},[channel.port2]);}
  catch(error){return {ok:false,error:String(error?.message||error)};}
  return response;
}

self.addEventListener('push',(event)=>{
  let payload={};
  try{payload=event.data?event.data.json():{};}catch{payload={body:event.data?.text()};}
  const source=payload?.data&&typeof payload.data==='object'?payload.data:{};
  const requested=String(source.targetTab||source.target_tab||'notificacoes');
  const targetTab=ALLOWED_TABS.has(requested)?requested:'notificacoes';
  const notificationId=String(source.notificationId||source.notification_id||'').trim().slice(0,80);
  const entityId=String(source.entityId||source.entity_id||'').trim().slice(0,100);
  const entityType=String(source.entityType||source.entity_type||'').trim().slice(0,80);
  const url=safePushDestination(source.url,targetTab,notificationId,entityId,entityType,'');
  event.waitUntil(self.registration.showNotification(String(payload.title||'NEXLAB').slice(0,120),{
    body:String(payload.body||'Você recebeu uma nova notificação.').slice(0,500),
    icon:'./icons/nexlab-192.png?v=brand-r38',
    badge:'./icons/nexlab-192.png?v=brand-r38',
    tag:String(payload.tag||`nexlab-${notificationId||Date.now()}`).slice(0,160),
    data:{url,targetTab,notificationId,entityId,entityType}
  }));
});

self.addEventListener('notificationclick',(event)=>{
  event.notification.close();
  const data=event.notification?.data&&typeof event.notification.data==='object'?event.notification.data:{};
  const requested=String(data.targetTab||'notificacoes');
  const tab=ALLOWED_TABS.has(requested)?requested:'notificacoes';
  const notificationId=String(data.notificationId||'').trim().slice(0,80);
  const entityId=String(data.entityId||'').trim().slice(0,100);
  const entityType=String(data.entityType||'').trim().slice(0,80);
  const pushRequestId=createPushRequestId();
  const destination=safePushDestination(data.url,tab,notificationId,entityId,entityType,pushRequestId);
  const message={type:'NEXLAB_NAVIGATE',tab,targetTab:tab,notificationId,entityId,entityType,pushRequestId,url:destination,source:'push'};
  event.waitUntil((async()=>{
    const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    const scope=new URL(self.registration.scope);
    const eligible=windows.filter(item=>{try{const url=new URL(item.url);return url.origin===scope.origin&&url.pathname.startsWith(scope.pathname);}catch{return false;}});
    const client=eligible.find(item=>item.focused)||eligible.find(item=>item.visibilityState==='visible')||eligible[0]||null;
    if(client){
      try{await client.focus();}catch{}
      const acknowledgment=await postNavigationAndWaitForAck(client,message);
      if(acknowledgment.ok)return client;
      try{
        const navigated=typeof client.navigate==='function'?await client.navigate(destination):null;
        const targetClient=navigated||client;
        try{await targetClient.focus();}catch{}
        return targetClient;
      }catch{
        // A confirmação falhou e a janela não pôde ser redirecionada; abrir uma nova é o último fallback.
      }
    }
    if(self.clients.openWindow){
      const opened=await self.clients.openWindow(destination);
      if(opened)return opened;
    }
    throw new Error('Não foi possível abrir nem confirmar o destino da notificação Push.');
  })());
});
