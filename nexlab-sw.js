const APP_VERSION="26.29.5";
const APP_REVISION="activities-hotfix-r545";
const CACHE_NAME="nexlab-v26-29-5-shell-r545";
const RUNTIME_CACHE="nexlab-v26-29-5-runtime-r545";
const IMAGE_CACHE="nexlab-v26-29-5-images-r545";
const ASSET_VERSION="app-r26295-activities-hotfix-r545";
const SHELL_FILES=[
  "./","./index.html","./offline.html","./404.html","./homologacao.html",
  "./RELATORIO_NEXLAB_V26_29_5.html","./prontidao.html","./release.json",
  `./manifest.webmanifest?v=${ASSET_VERSION}`,
  `./assets/index-R54v26295.js?v=${ASSET_VERSION}`,
  "./assets/index-B1u8eynw.css?v=brand-r38",
  `./assets/nexlab-bootstrap.js?v=${ASSET_VERSION}`,
  `./assets/nexlab-visual.css?v=${ASSET_VERSION}`,
  `./assets/nexlab-update-manager.js?v=${ASSET_VERSION}`,
  `./assets/nexlab-visual.js?v=${ASSET_VERSION}`,
  `./assets/nexlab-permissions-r544.css?v=${ASSET_VERSION}`,
  `./assets/nexlab-permissions-r544.js?v=${ASSET_VERSION}`,
  `./assets/nexlab-activities-phase4.css?v=${ASSET_VERSION}`,
  `./assets/nexlab-activities-phase4.js?v=${ASSET_VERSION}`,
  `./assets/nexlab-vapid-rotation.js?v=${ASSET_VERSION}`,
  `./assets/nexlab-mural-sync-r544.css?v=${ASSET_VERSION}`,
  `./assets/nexlab-mural-sync-r544.js?v=${ASSET_VERSION}`,
  "./icons/nexlab-192.png?v=brand-r38","./icons/nexlab-512.png?v=brand-r38",
  "./icons/nexlab-maskable-192.png?v=brand-r38","./icons/nexlab-maskable-512.png?v=brand-r38",
  "./icons/apple-touch-icon.png?v=brand-r38","./icons/nexlab-favicon-rounded.png?v=brand-r38",
  "./brand/nexlab-logo-light.webp?v=brand-r38","./brand/nexlab-logo-dark.webp?v=brand-r38",
  "./brand/nexlab-icon.webp?v=brand-r38"
];
const ALLOWED_TABS=new Set(["dashboard","pendencias","agenda","notificacoes","participantes","permissoes","equipes","perfil","projetos","patrimonio","estoque","reserva","marketing","eventos","mural","feedback","relatorios","saude-sistema","logs"]);
async function notifyClients(message){const windows=await self.clients.matchAll({type:"window",includeUncontrolled:true});windows.forEach(client=>client.postMessage(message));}
function injectOverlays(html){
  let value=html
    .replace(/<link[^>]+nexlab-permissions-phase2\.css[^>]*>/gi,'')
    .replace(/<script[^>]+nexlab-permissions-phase2\.js[^>]*><\/script>/gi,'')
    .replace(/<link[^>]+nexlab-mural-sync-r543\.css[^>]*>/gi,'')
    .replace(/<script[^>]+nexlab-mural-sync-r543\.js[^>]*><\/script>/gi,'')
    .replace(/<link[^>]+nexlab-activities-phase3\.css[^>]*>/gi,'')
    .replace(/<script[^>]+nexlab-activities-phase3\.js[^>]*><\/script>/gi,'')
    .replace(/<link[^>]+nexlab-mural-governance-r541\.css[^>]*>/gi,'')
    .replace(/<script[^>]+nexlab-mural-governance-r541\.js[^>]*><\/script>/gi,'')
    .replace(/<link[^>]+nexlab-mural-integrity-r542\.css[^>]*>/gi,'')
    .replace(/<script[^>]+nexlab-mural-integrity-r542\.js[^>]*><\/script>/gi,'');
  if(!value.includes('nexlab-permissions-r544.js')){
    const permission=`<link rel="stylesheet" href="./assets/nexlab-permissions-r544.css?v=${ASSET_VERSION}"><script defer src="./assets/nexlab-permissions-r544.js?v=${ASSET_VERSION}"></script>`;
    value=value.replace(/<head([^>]*)>/i,`<head$1>${permission}`);
  }
  if(!value.includes('nexlab-activities-phase4.js')){
    const activities=`<link rel="stylesheet" href="./assets/nexlab-activities-phase4.css?v=${ASSET_VERSION}"><script defer src="./assets/nexlab-activities-phase4.js?v=${ASSET_VERSION}"></script>`;
    value=value.replace(/<head([^>]*)>/i,`<head$1>${activities}`);
  }
  if(!value.includes('nexlab-vapid-rotation.js')){
    value=value.replace(/<head([^>]*)>/i,`<head$1><script defer src="./assets/nexlab-vapid-rotation.js?v=${ASSET_VERSION}"></script>`);
  }
  if(!value.includes('nexlab-mural-sync-r544.js')){
    const mural=`<link rel="stylesheet" href="./assets/nexlab-mural-sync-r544.css?v=${ASSET_VERSION}"><script defer src="./assets/nexlab-mural-sync-r544.js?v=${ASSET_VERSION}"></script>`;
    value=value.replace(/<head([^>]*)>/i,`<head$1>${mural}`);
  }
  return value;
}
async function transformHtml(response){
  if(!response)return response;const type=response.headers.get('content-type')||'';if(!type.includes('text/html'))return response;
  const html=injectOverlays(await response.text()),headers=new Headers(response.headers);headers.set('content-type','text/html; charset=utf-8');
  return new Response(html,{status:response.status,statusText:response.statusText,headers});
}
self.addEventListener('install',event=>event.waitUntil((async()=>{
  const cache=await caches.open(CACHE_NAME);await cache.addAll(SHELL_FILES);
  if(!self.registration.active){await self.skipWaiting();return;}
  await notifyClients({type:'NEXLAB_UPDATE_READY',version:APP_VERSION,revision:APP_REVISION,cache:CACHE_NAME});
})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{
  const keys=await caches.keys();await Promise.all(keys.filter(key=>![CACHE_NAME,RUNTIME_CACHE,IMAGE_CACHE].includes(key)).map(key=>caches.delete(key)));
  await self.clients.claim();await notifyClients({type:'NEXLAB_UPDATE_ACTIVATED',version:APP_VERSION,revision:APP_REVISION,cache:CACHE_NAME});
})()));
async function navigation(request){
  try{
    const fresh=await fetch(request,{cache:'no-store'});if(!fresh.ok)throw new Error('navigation');
    const transformed=await transformHtml(fresh),cache=await caches.open(RUNTIME_CACHE);cache.put(request,transformed.clone()).catch(()=>{});return transformed;
  }catch{
    const cached=await caches.match(request,{ignoreSearch:true})||await caches.match('./index.html')||await caches.match('./offline.html');return transformHtml(cached);
  }
}
async function release(request){
  try{const response=await fetch(new Request(request,{cache:'no-store'}));if(!response.ok)throw new Error();const cache=await caches.open(CACHE_NAME);cache.put('./release.json',response.clone()).catch(()=>{});return response;}
  catch{return await caches.match('./release.json')||new Response('{}',{status:503,headers:{'Content-Type':'application/json'}});}
}
async function cacheFirst(request){
  const cached=await caches.match(request);if(cached)return cached;const response=await fetch(request);
  if(response?.ok){const cache=await caches.open(request.destination==='image'?IMAGE_CACHE:RUNTIME_CACHE);cache.put(request,response.clone()).catch(()=>{});}return response;
}
self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET')return;const url=new URL(event.request.url);if(url.origin!==self.location.origin)return;
  if(url.pathname.endsWith('/release.json'))return event.respondWith(release(event.request));
  if(event.request.mode==='navigate')return event.respondWith(navigation(event.request));
  if(['script','style','image','font','manifest'].includes(event.request.destination))return event.respondWith(cacheFirst(event.request));
  event.respondWith(fetch(event.request).catch(()=>caches.match(event.request)));
});
self.addEventListener('message',event=>{
  if(event.data?.type==='NEXLAB_SKIP_WAITING')event.waitUntil(self.skipWaiting());
  if(event.data?.type==='NEXLAB_GET_VERSION')event.ports?.[0]?.postMessage({type:'NEXLAB_VERSION',version:APP_VERSION,revision:APP_REVISION,cache:CACHE_NAME});
});
self.addEventListener('push',event=>{
  let payload={};try{payload=event.data?event.data.json():{};}catch{payload={body:event.data?.text()};}
  const requested=String(payload?.data?.targetTab||'notificacoes'),targetTab=ALLOWED_TABS.has(requested)?requested:'notificacoes';
  event.waitUntil(self.registration.showNotification(String(payload.title||'NEXLAB').slice(0,120),{
    body:String(payload.body||'Você recebeu uma nova notificação.').slice(0,500),icon:'./icons/nexlab-192.png?v=brand-r38',badge:'./icons/nexlab-192.png?v=brand-r38',
    tag:String(payload.tag||`nexlab-${Date.now()}`).slice(0,160),data:{targetTab}
  }));
});
self.addEventListener('notificationclick',event=>{
  event.notification.close();const requested=String(event.notification?.data?.targetTab||'notificacoes'),tab=ALLOWED_TABS.has(requested)?requested:'notificacoes',url=new URL('./',self.location.href);url.searchParams.set('nexlabTab',tab);
  event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async clients=>{
    for(const client of clients){client.postMessage({type:'NEXLAB_NAVIGATE',tab});await client.focus();return;}
    return self.clients.openWindow?.(url.toString());
  }));
});
