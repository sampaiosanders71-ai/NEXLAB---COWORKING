(function(){
  'use strict';
  const BUILD_IDENTITY=window.__NEXLAB_BUILD_IDENTITY__||Object.freeze({version:'0.26.12',release:'Beta',revision:'beta-0-26-12-bookings-render-loop-recovery',assetRevision:'app-beta-0-26-12-bookings-render-loop-recovery',cacheName:'nexlab-beta-0-26-12-bookings-render-loop-recovery'});
  if (window.__NEXLAB_PWA_READINESS__?.revision === BUILD_IDENTITY.revision) return;

  const VERSION=BUILD_IDENTITY.version;
  const RELEASE=BUILD_IDENTITY.release;
  const REVISION=BUILD_IDENTITY.revision;
  const ASSET_REVISION=BUILD_IDENTITY.assetRevision;
  const CACHE_NAME=BUILD_IDENTITY.cacheName;
  const STORAGE_KEY='nexlab:pwa-readiness:'+VERSION;
  const DEVICE_EVIDENCE_KEY='nexlab:device-homologation:'+VERSION;
  const EXPECTED_CORE=['index.html','offline.html','manifest.webmanifest','assets/nexlab-release-identity.js','assets/index-beta-0-26-12.js','assets/nexlab-vendor-beta-0-26-12.js','assets/nexlab-app-shared-beta-0-26-12.js','assets/nexlab-dialogs.js','assets/nexlab-push-navigation.js','assets/nexlab-device-homologation.js'];
  const EXPECTED_OPTIONAL=['assets/nexlab-feature-modules-beta-0-26-12.js','assets/nexlab-export-vendor-beta-0-26-12.js','assets/nexlab-pwa-readiness.js','pwa-check.html'];
  const OPTIONAL_WARM=['assets/nexlab-feature-modules-beta-0-26-12.js','assets/nexlab-export-vendor-beta-0-26-12.js'];
  const OFFLINE_PROBE=['index.html','offline.html','assets/nexlab-release-identity.js','assets/index-beta-0-26-12.js','assets/nexlab-push-navigation.js','assets/nexlab-device-homologation.js'];

  const absolute=(value)=>new URL(value,document.baseURI).href;
  const timeout=(ms)=>new Promise((_,reject)=>setTimeout(()=>reject(new Error('Tempo excedido.')),ms));
  const expectedMime=(path)=>{
    if(/\.js$/i.test(path))return /(?:javascript|ecmascript)/i;
    if(/\.css$/i.test(path))return /text\/css/i;
    if(/\.html$/i.test(path))return /text\/html/i;
    if(/\.webmanifest$/i.test(path))return /(?:application\/manifest\+json|application\/json)/i;
    if(/\.json$/i.test(path))return /application\/json/i;
    if(/\.(?:png|webp|ico|jpe?g|svg)$/i.test(path))return /^image\//i;
    return /./;
  };
  const pathFromUrl=(value)=>{
    const url=new URL(value,document.baseURI);
    const base=new URL('./',document.baseURI);
    const relative=url.pathname.startsWith(base.pathname)?url.pathname.slice(base.pathname.length):url.pathname.replace(/^\//,'');
    return decodeURIComponent(relative||'index.html');
  };
  const sha256=async(buffer)=>{
    if(!globalThis.crypto?.subtle)return '';
    const digest=await crypto.subtle.digest('SHA-256',buffer);
    return [...new Uint8Array(digest)].map(value=>value.toString(16).padStart(2,'0')).join('');
  };
  const readJson=(key)=>{try{return JSON.parse(localStorage.getItem(key)||'{}')||{};}catch{return {};}};
  const readDeviceEvidence=()=>readJson(DEVICE_EVIDENCE_KEY);
  function writeDeviceEvidence(value){
    const current=readDeviceEvidence();
    const deviceSessionId=current.deviceSessionId||(globalThis.crypto?.randomUUID?.()||('device-'+Date.now()+'-'+Math.random().toString(16).slice(2)));
    const next={...current,deviceSessionId,version:VERSION,revision:REVISION,userAgent:navigator.userAgent,updatedAt:new Date().toISOString(),...value};
    try{localStorage.setItem(DEVICE_EVIDENCE_KEY,JSON.stringify(next));}catch{}
    return next;
  }
  async function fetchResource(url,{timeoutMs=10000,expected=null,parseJson=false}={}){
    const href=absolute(url);
    try{
      const response=await Promise.race([fetch(href,{cache:'no-store',credentials:'same-origin'}),timeout(timeoutMs)]);
      const contentType=response.headers.get('content-type')||'';
      const buffer=await response.arrayBuffer();
      const size=buffer.byteLength;
      const hash=await sha256(buffer);
      const path=pathFromUrl(href);
      const mimeOk=expectedMime(path).test(contentType);
      const sizeOk=!expected||Number(expected.size)===size;
      const hashOk=!expected||String(expected.sha256||'').toLowerCase()===hash;
      let json=null;
      let parseError='';
      if(parseJson){try{json=JSON.parse(new TextDecoder().decode(buffer));}catch(error){parseError=String(error?.message||error);}}
      return {ok:response.ok&&mimeOk&&sizeOk&&hashOk&&(!parseJson||Boolean(json)),status:response.status,url:href,path,contentType,size,sha256:hash,mimeOk,sizeOk,hashOk,json,parseError};
    }catch(error){return {ok:false,status:0,url:href,path:pathFromUrl(href),error:String(error?.message||error)};}
  }
  async function loadRelease(){
    const result=await fetchResource('./release.json',{parseJson:true});
    const data=result.json||{};
    const identityOk=data.version===VERSION&&data.revision===REVISION&&data.cache_name===CACHE_NAME;
    const fileMap=new Map((Array.isArray(data.files)?data.files:[]).map(item=>[String(item.path),item]));
    return {...result,ok:result.ok&&identityOk,identityOk,data,fileMap};
  }
  async function verifyUrl(url,release){
    const path=pathFromUrl(url);
    const expected=release?.fileMap?.get(path)||null;
    const result=await fetchResource(url,{expected});
    return {...result,metadataPresent:Boolean(expected)};
  }
  async function readManifest(release){
    const link=document.querySelector('link[rel="manifest"]');
    if(!link)return {ok:false,error:'Manifesto não vinculado ao documento.'};
    const network=await fetchResource(link.href,{expected:release.fileMap.get('manifest.webmanifest'),parseJson:true});
    if(!network.ok)return {...network,error:'Manifesto inválido ou diferente da release.'};
    const manifest=network.json||{};
    const icons=Array.isArray(manifest.icons)?manifest.icons:[];
    const iconResults=await Promise.all(icons.map(async(icon)=>({src:icon.src,sizes:icon.sizes,purpose:icon.purpose||'any',...(await verifyUrl(new URL(icon.src,link.href).href,release))})));
    const displayOk=['standalone','fullscreen','minimal-ui','window-controls-overlay'].includes(manifest.display)||Array.isArray(manifest.display_override)&&manifest.display_override.some(mode=>['standalone','fullscreen','minimal-ui','window-controls-overlay'].includes(mode));
    return {ok:Boolean(manifest.name&&manifest.start_url&&manifest.scope&&displayOk&&iconResults.length>=2&&iconResults.every(item=>item.ok)),href:link.href,name:manifest.name||'',startUrl:manifest.start_url||'',scope:manifest.scope||'',display:manifest.display||'',displayOverride:manifest.display_override||[],icons:iconResults,allIconsAvailable:iconResults.length>=2&&iconResults.every(item=>item.ok)};
  }
  async function workerIdentity(worker){
    if(!worker)return {ok:false,error:'Worker ativo não encontrado.'};
    try{
      const channel=new MessageChannel();
      const response=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error('Worker não respondeu.')),3000);channel.port1.onmessage=(event)=>{clearTimeout(timer);resolve(event.data||{});};});
      worker.postMessage({type:'NEXLAB_GET_VERSION'},[channel.port2]);
      const data=await response;
      return {ok:data.version===VERSION&&data.revision===REVISION&&data.cache===CACHE_NAME,...data};
    }catch(error){return {ok:false,error:String(error?.message||error)};}
  }
  async function serviceWorkerState(){
    if(!('serviceWorker' in navigator))return {supported:false,registered:false,controlled:false,active:false,identity:{ok:false},error:'Navegador sem Service Worker.'};
    try{
      const registration=await navigator.serviceWorker.getRegistration();
      const active=registration?.active||null;
      const identity=await workerIdentity(navigator.serviceWorker.controller||active);
      return {supported:true,registered:Boolean(registration),controlled:Boolean(navigator.serviceWorker.controller),installing:Boolean(registration?.installing),waiting:Boolean(registration?.waiting),active:Boolean(active),scope:registration?.scope||'',scriptURL:active?.scriptURL||registration?.waiting?.scriptURL||'',identity};
    }catch(error){return {supported:true,registered:false,controlled:false,active:false,identity:{ok:false},error:String(error?.message||error)};}
  }
  async function verifyCachedResponse(request,response,release){
    const path=pathFromUrl(request.url);
    const expected=release.fileMap.get(path)||null;
    if(!response)return {asset:path,cached:false,integrity:false,metadataPresent:Boolean(expected)};
    try{
      const contentType=response.headers.get('content-type')||'';
      const buffer=await response.clone().arrayBuffer();
      const hash=await sha256(buffer);
      const size=buffer.byteLength;
      const mimeOk=expectedMime(path).test(contentType);
      const sizeOk=Boolean(expected)&&Number(expected.size)===size;
      const hashOk=Boolean(expected)&&String(expected.sha256||'').toLowerCase()===hash;
      return {asset:path,cached:true,integrity:mimeOk&&sizeOk&&hashOk,metadataPresent:Boolean(expected),mimeOk,sizeOk,hashOk,size,sha256:hash};
    }catch(error){return {asset:path,cached:true,integrity:false,metadataPresent:Boolean(expected),error:String(error?.message||error)};}
  }
  async function cacheState(release){
    if(!('caches' in window))return {supported:false,current:false,names:[],core:[],optional:[],integrity:false};
    try{
      const names=await caches.keys();
      if(!names.includes(CACHE_NAME))return {supported:true,current:false,names,core:EXPECTED_CORE.map(asset=>({asset,cached:false,integrity:false})),optional:EXPECTED_OPTIONAL.map(asset=>({asset,cached:false,integrity:false})),entries:0,integrity:false};
      const cache=await caches.open(CACHE_NAME);
      const requests=await cache.keys();
      const byPath=new Map(requests.map(request=>[pathFromUrl(request.url),request]));
      const verifyList=async(list)=>Promise.all(list.map(async(asset)=>{
        const request=byPath.get(asset);
        return verifyCachedResponse(request,request?await cache.match(request):null,release);
      }));
      const core=await verifyList(EXPECTED_CORE);
      const optional=await verifyList(EXPECTED_OPTIONAL);
      return {supported:true,current:true,names,core,optional,entries:requests.length,integrity:core.every(item=>item.cached&&item.integrity)&&optional.every(item=>!item.cached||item.integrity)};
    }catch(error){return {supported:true,current:false,names:[],core:[],optional:[],entries:0,integrity:false,error:String(error?.message||error)};}
  }
  async function warmOptionalAssets(){
    const results=[];
    for(const path of OPTIONAL_WARM){
      try{const response=await fetch(absolute('./'+path),{cache:'reload',credentials:'same-origin'});results.push({path,ok:response.ok,status:response.status});}
      catch(error){results.push({path,ok:false,status:0,error:String(error?.message||error)});}
    }
    return results;
  }
  function displayState(){
    const standaloneMedia=Boolean(window.matchMedia?.('(display-mode: standalone)').matches);
    const overlay=Boolean(window.matchMedia?.('(display-mode: window-controls-overlay)').matches);
    const iosStandalone=navigator.standalone===true;
    const installed=standaloneMedia||overlay||iosStandalone;
    return {installed,standalone:installed,standaloneMedia,windowControlsOverlay:overlay,iosStandalone,mode:overlay?'window-controls-overlay':standaloneMedia||iosStandalone?'standalone':'browser'};
  }
  function objectiveEvidence(evidence){
    const sameRevision=evidence?.revision===REVISION;
    return {
      installedLaunch:sameRevision&&Boolean(evidence?.automaticInstalledLaunchAt),
      offlineNavigation:sameRevision&&Boolean(evidence?.automaticOfflineNavigationAt),
      pushDisplayed:sameRevision&&Boolean(evidence?.automaticPushDisplayedAt),
      pushDestination:sameRevision&&Boolean(evidence?.automaticPushDestinationAt),
      updateActivation:sameRevision&&Boolean(evidence?.automaticUpdateActivationAt),
      serverReceipt:sameRevision&&evidence?.serverReceiptRevision===REVISION&&evidence?.serverReceiptComplete===true&&Boolean(evidence?.serverReceiptId)
    };
  }
  async function run(){
    const releaseFile=await loadRelease();
    const [manifest,offlinePage,serviceWorker,cache]=await Promise.all([
      readManifest(releaseFile),verifyUrl('./offline.html',releaseFile),serviceWorkerState(),cacheState(releaseFile)
    ]);
    const display=displayState();
    const secureContext=window.isSecureContext||['localhost','127.0.0.1','::1'].includes(location.hostname);
    const coreCached=cache.core.length>0&&cache.core.every(item=>item.cached&&item.integrity);
    const featureCached=cache.optional.every(item=>item.asset!=='assets/nexlab-feature-modules-beta-0-26-12.js'||!item.cached||item.integrity);
    const exportCached=cache.optional.every(item=>item.asset!=='assets/nexlab-export-vendor-beta-0-26-12.js'||!item.cached||item.integrity);
    const technicalChecks={secureContext:Boolean(secureContext),online:navigator.onLine,manifest:manifest.ok,serviceWorker:serviceWorker.registered&&serviceWorker.active&&serviceWorker.identity.ok,controlled:serviceWorker.controlled,currentCache:cache.current,coreCached,featureCached,exportCached,cacheIntegrity:cache.integrity,releaseIntegrity:releaseFile.ok,offlinePageIntegrity:offlinePage.ok,standalone:display.installed};
    const technicalBlocking=['secureContext','manifest','serviceWorker','controlled','currentCache','coreCached','cacheIntegrity','releaseIntegrity','offlinePageIntegrity','standalone'];
    const technicalReady=technicalBlocking.every(key=>technicalChecks[key]===true);
    let evidence=readDeviceEvidence();
    const patch={};
    let activatedRevision='';
    try{activatedRevision=sessionStorage.getItem('nexlab:last-activated-revision')||'';}catch{}
    if(display.installed&&!evidence.automaticInstalledLaunchAt)patch.automaticInstalledLaunchAt=new Date().toISOString();
    if(activatedRevision===REVISION&&!evidence.automaticUpdateActivationAt){patch.automaticUpdateActivationAt=new Date().toISOString();patch.activatedRevision=activatedRevision;}
    if(technicalReady){patch.technicalReadyAt=new Date().toISOString();patch.technicalRevision=REVISION;}
    if(Object.keys(patch).length)evidence=writeDeviceEvidence(patch);
    const objective=objectiveEvidence(evidence);
    const checks={...technicalChecks,installedEvidence:objective.installedLaunch,updateActivationEvidence:objective.updateActivation,offlineNavigationEvidence:objective.offlineNavigation,pushDisplayedEvidence:objective.pushDisplayed,pushDestinationEvidence:objective.pushDestination,serverReceiptEvidence:objective.serverReceipt};
    const objectiveBlocking=['installedEvidence','updateActivationEvidence','offlineNavigationEvidence','pushDisplayedEvidence','pushDestinationEvidence','serverReceiptEvidence'];
    const readyForInstalledPresentation=technicalReady&&objectiveBlocking.every(key=>checks[key]===true);
    const result={version:VERSION,release:RELEASE,revision:REVISION,cacheName:CACHE_NAME,ok:technicalReady,readyForInstalledPresentation,blockingChecks:technicalBlocking,installedBlockingChecks:[...technicalBlocking,...objectiveBlocking],checks,objectiveEvidence:objective,display,manifest,serviceWorker,cache,releaseFile:{ok:releaseFile.ok,status:releaseFile.status,identityOk:releaseFile.identityOk,size:releaseFile.size,sha256:releaseFile.sha256},offlinePage,capturedAt:new Date().toISOString(),manualConfirmationRequired:!readyForInstalledPresentation,guidance:readyForInstalledPresentation?'Homologação técnica e evidências automáticas concluídas.':'A aprovação exige evidências automáticas de atualização confirmada, instalação, navegação offline e abertura correta de um Push; marcações manuais não aprovam a homologação.'};
    try{localStorage.setItem(STORAGE_KEY,JSON.stringify(result));}catch{}
    window.__NEXLAB_PWA_LAST_RESULT__=Object.freeze(result);
    window.dispatchEvent(new CustomEvent('nexlab:pwa-readiness-complete',{detail:result}));
    renderCheckPage(result);
    renderDeviceEvidence(result);
    return result;
  }
  function renderCheckPage(result){
    const target=document.getElementById('nexlab-pwa-results');
    if(!target)return;
    const labels={secureContext:'Contexto seguro',manifest:'Manifesto e ícones íntegros',serviceWorker:'Service Worker da revisão',controlled:'Página controlada',currentCache:'Cache da revisão',coreCached:'Núcleo offline íntegro',featureCached:'Módulos sob demanda íntegros',exportCached:'PDF e Excel sob demanda íntegros',cacheIntegrity:'Integridade completa do cache',releaseIntegrity:'Identidade da release',offlinePageIntegrity:'Página offline íntegra',standalone:'Modo aplicativo instalado',installedEvidence:'Abertura instalada detectada',updateActivationEvidence:'Atualização confirmada e ativada',offlineNavigationEvidence:'Navegação offline comprovada',pushDisplayedEvidence:'Clique em Push observado',pushDestinationEvidence:'Destino do Push confirmado pelo app',serverReceiptEvidence:'Evidência registrada no Supabase'};
    const rows=Object.entries(result.checks).filter(([key])=>key!=='online').map(([key,value])=>`<li class="${value?'ok':'pending'}"><strong>${labels[key]||key}</strong><span>${value?'Aprovado':'Pendente'}</span></li>`).join('');
    const presentationReady=result.readyForInstalledPresentation===true;
    target.innerHTML=`<section class="summary ${presentationReady?'ok':'pending'}"><h2>${presentationReady?'Homologação PWA aprovada':'Homologação PWA ainda pendente'}</h2><p>${result.guidance}</p></section><ul>${rows}</ul><p class="timestamp">Verificação: ${new Date(result.capturedAt).toLocaleString('pt-BR')}</p>`;
    document.body.dataset.pwaCheckComplete='true';
    document.body.dataset.pwaCheckOk=String(presentationReady);
    document.body.dataset.pwaTechnicalOk=String(result.ok);
    document.body.dataset.pwaStandalone=String(result.display.installed);
  }
  function renderDeviceEvidence(result){
    const section=document.getElementById('nexlab-device-homologation');if(!section)return;
    const evidence=readDeviceEvidence();
    const objective=objectiveEvidence(evidence);
    const labels={installedLaunch:objective.installedLaunch,updateActivation:objective.updateActivation,offlineNavigation:objective.offlineNavigation,pushDisplayed:objective.pushDisplayed,pushDestination:objective.pushDestination,serverReceipt:objective.serverReceipt};
    section.querySelectorAll('[data-evidence-status]').forEach(element=>{
      const ok=Boolean(labels[element.dataset.evidenceStatus]);
      element.className='evidence-pill '+(ok?'ok':'pending');
      element.textContent=ok?'Comprovado':'Pendente';
    });
    const complete=Boolean(result?.ok)&&Object.values(objective).every(Boolean);
    const status=document.getElementById('nexlab-device-homologation-status');
    if(status){status.className='device-status '+(complete?'ok':'pending');status.textContent=complete?'Homologação real concluída por evidências automáticas neste aparelho.':'A homologação não pode ser aprovada por declarações manuais; conclua as provas automáticas pendentes.';}
    section.dataset.deviceHomologationComplete=String(complete);
    section.dataset.technicalReady=String(Boolean(result?.ok));
  }
  async function verifyOfflineNavigation(){
    const button=document.getElementById('nexlab-verify-offline-navigation');
    if(button){button.disabled=true;button.textContent='Validando offline...';}
    try{
      if(navigator.onLine!==false)throw new Error('Desligue a internet antes de executar esta prova.');
      const display=displayState();
      if(!display.installed)throw new Error('Abra o diagnóstico pelo aplicativo instalado.');
      if(!navigator.serviceWorker?.controller)throw new Error('A página não está controlada pelo Service Worker.');
      const evidence=readDeviceEvidence();
      if(evidence.technicalRevision!==REVISION||!evidence.technicalReadyAt)throw new Error('Execute primeiro a verificação técnica online desta mesma versão.');
      if(!('caches' in window))throw new Error('A API de cache não está disponível.');
      const names=await caches.keys();
      if(!names.includes(CACHE_NAME))throw new Error('O cache da versão atual não foi encontrado.');
      const cache=await caches.open(CACHE_NAME);
      const requests=await cache.keys();
      const paths=new Set(requests.map(request=>pathFromUrl(request.url)));
      const missing=OFFLINE_PROBE.filter(path=>!paths.has(path));
      if(missing.length)throw new Error('Arquivos offline ausentes: '+missing.join(', '));
      for(const path of OFFLINE_PROBE){
        const response=await cache.match(requests.find(request=>pathFromUrl(request.url)===path));
        if(!response?.ok)throw new Error('Resposta offline inválida para '+path+'.');
      }
      writeDeviceEvidence({automaticOfflineNavigationAt:new Date().toISOString(),automaticOfflineProbe:OFFLINE_PROBE});
      renderDeviceEvidence(window.__NEXLAB_PWA_LAST_RESULT__||null);
      const status=document.getElementById('nexlab-device-homologation-status');
      if(status)status.textContent='Prova offline registrada. Reconecte a internet e execute novamente o diagnóstico completo.';
      return true;
    }catch(error){
      const status=document.getElementById('nexlab-device-homologation-status');
      if(status){status.className='device-status pending';status.textContent=String(error?.message||error);}
      return false;
    }finally{if(button){button.disabled=false;button.textContent='Validar navegação offline';}}
  }
  function installDeviceEvidenceActions(){
    document.getElementById('nexlab-verify-offline-navigation')?.addEventListener('click',verifyOfflineNavigation);
    document.getElementById('nexlab-reset-device-evidence')?.addEventListener('click',()=>{try{localStorage.removeItem(DEVICE_EVIDENCE_KEY);}catch{}renderDeviceEvidence(window.__NEXLAB_PWA_LAST_RESULT__||null);});
    document.getElementById('nexlab-sync-device-evidence')?.addEventListener('click',()=>{
      const evidence=readDeviceEvidence();
      const objective=objectiveEvidence(evidence);
      const localComplete=['installedLaunch','updateActivation','offlineNavigation','pushDisplayed','pushDestination'].every(key=>objective[key]===true);
      const status=document.getElementById('nexlab-device-homologation-status');
      if(!localComplete){if(status){status.className='device-status pending';status.textContent='Conclua primeiro as cinco evidências automáticas locais.';}return;}
      if(navigator.onLine===false){if(status){status.className='device-status pending';status.textContent='Reconecte a internet para registrar a evidência no Supabase.';}return;}
      location.href='./index.html?nexlabHomologationSync=1';
    });
    document.getElementById('nexlab-export-device-evidence')?.addEventListener('click',()=>{
      const evidence=readDeviceEvidence();
      const objective=objectiveEvidence(evidence);const payload={...evidence,objective,complete:Object.values(objective).every(Boolean)&&Boolean(window.__NEXLAB_PWA_LAST_RESULT__?.ok),pwa:window.__NEXLAB_PWA_LAST_RESULT__||null,exportedAt:new Date().toISOString()};
      const blob=new Blob([JSON.stringify(payload,null,2)],{type:'application/json'});const url=URL.createObjectURL(blob);const link=document.createElement('a');link.href=url;link.download='nexlab-homologacao-dispositivo-'+VERSION+'.json';document.body.appendChild(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
    });
    globalThis.addEventListener('nexlab:push-navigation-evidence',()=>renderDeviceEvidence(window.__NEXLAB_PWA_LAST_RESULT__||null));
    globalThis.addEventListener('nexlab:device-homologation-synced',()=>{void run();});
    renderDeviceEvidence(window.__NEXLAB_PWA_LAST_RESULT__||null);
  }
  function installPageActions(){
    const runButton=document.getElementById('nexlab-run-pwa-check');
    const integrityButton=document.getElementById('nexlab-warm-pwa-assets');
    installDeviceEvidenceActions();
    runButton?.addEventListener('click',()=>run());
    integrityButton?.addEventListener('click',async()=>{integrityButton.disabled=true;integrityButton.textContent='Carregando...';await warmOptionalAssets();await run();integrityButton.textContent='Carregar módulos opcionais';integrityButton.disabled=false;});
  }
  const api=Object.freeze({version:VERSION,release:RELEASE,revision:REVISION,cacheName:CACHE_NAME,run,verifyOfflineNavigation,getLast:()=>window.__NEXLAB_PWA_LAST_RESULT__||null});
  window.__NEXLAB_PWA_READINESS__=api;
  const isDiagnosticPage=Boolean(document.getElementById('nexlab-pwa-results'));
  if(isDiagnosticPage){
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>{installPageActions();run();},{once:true});
    else{installPageActions();run();}
  }
})();
