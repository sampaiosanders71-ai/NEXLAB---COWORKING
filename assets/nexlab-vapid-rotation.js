(function(){
  'use strict';
  if(window.__NEXLAB_VAPID_ROTATION_BETA_0264__) return;
  window.__NEXLAB_VAPID_ROTATION_BETA_0264__={version:'0.26.12',status:'idle'};
  const PROJECT_REF='eahldhabwulnwhuwrhvc';
  const EXPECTED_KEY='BIwuvqKRH2PipAjpAMTwmVM6kUgN0XycoLCD99uuKJQcO3e0rXWZWBNBaMZaqFxGHBL90aKQrTbMZaNLb_xblLE';
  const API=(window.__NEXLAB_CONFIG__?.supabaseUrl||`https://${PROJECT_REF}.supabase.co`).replace(/\/$/,'');
  const ANON=window.__NEXLAB_CONFIG__?.supabaseAnonKey||'sb_publishable_hr-WTQUBbBE0Ei3Lr2hkhQ_XSKG_PXa';
  const MARKER='nexlab:vapid-generation';

  function decode(value){
    const normalized=String(value||'').replace(/-/g,'+').replace(/_/g,'/');
    const padded=normalized+'='.repeat((4-normalized.length%4)%4);
    const raw=atob(padded);const bytes=new Uint8Array(raw.length);
    for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);return bytes;
  }
  function equal(a,b){if(!a||!b||a.byteLength!==b.byteLength)return false;const x=new Uint8Array(a),y=new Uint8Array(b);for(let i=0;i<x.length;i++)if(x[i]!==y[i])return false;return true}
  function token(){
    const keys=[`sb-${PROJECT_REF}-auth-token`,...Object.keys(localStorage).filter(k=>k.includes(PROJECT_REF)&&k.includes('auth-token'))];
    for(const key of keys){try{const p=JSON.parse(localStorage.getItem(key)||'null');const t=p?.access_token||p?.currentSession?.access_token||p?.session?.access_token;if(t)return t}catch{}}
    return null;
  }
  function subject(){
    try{
      const value=token();if(!value)return 'anonymous';
      const payload=value.split('.')[1]||'';
      const normalized=payload.replace(/-/g,'+').replace(/_/g,'/');
      const json=JSON.parse(atob(normalized+'='.repeat((4-normalized.length%4)%4)));
      return String(json.sub||'anonymous');
    }catch{return 'anonymous'}
  }
  function markerKey(){return `${MARKER}:${subject()}`}
  function markerValue(subscription){return `0.26.12:${subscription?.endpoint||''}`}
  async function rpc(name,body){
    const access=token();if(!access)throw new Error('Sessão não localizada.');
    const response=await fetch(`${API}/rest/v1/rpc/${name}`,{method:'POST',cache:'no-store',headers:{apikey:ANON,Authorization:`Bearer ${access}`,'Content-Type':'application/json'},body:JSON.stringify(body||{})});
    const text=await response.text();let data=null;try{data=text?JSON.parse(text):null}catch{data=text}
    if(!response.ok)throw new Error(data?.message||data?.hint||`Falha ${response.status}`);return data;
  }
  async function save(subscription){
    const json=subscription.toJSON();
    return rpc('save_push_subscription',{p_endpoint:subscription.endpoint,p_p256dh:json.keys?.p256dh||'',p_auth:json.keys?.auth||'',p_expiration_time:subscription.expirationTime||null,p_user_agent:navigator.userAgent||null,p_platform:navigator.userAgentData?.platform||navigator.platform||null});
  }
  async function rotate(){
    const state=window.__NEXLAB_VAPID_ROTATION_BETA_0264__;state.status='checking';
    if(location.protocol!=='https:'||!('serviceWorker'in navigator)||!('PushManager'in window)||!('Notification'in window)){state.status='unsupported';return}
    if(Notification.permission!=='granted'){state.status=Notification.permission;return}
    for(let i=0;i<20&&!token();i++)await new Promise(r=>setTimeout(r,750));
    if(!token()){state.status='no-session';return}
    const registration=await Promise.race([navigator.serviceWorker.ready,new Promise((_,reject)=>setTimeout(()=>reject(new Error('Service Worker do NEXLAB não ficou pronto.')),15000))]);
    let subscription=await registration.pushManager.getSubscription();
    const expected=decode(EXPECTED_KEY);
    const current=subscription?.options?.applicationServerKey||null;
    const same=Boolean(subscription&&equal(current,expected.buffer));
    let changed=false;
    if(subscription&&!same){
      const endpoint=subscription.endpoint;
      try{await rpc('disable_push_subscription',{p_endpoint:endpoint})}catch{}
      await subscription.unsubscribe();subscription=null;changed=true;
    }
    if(!subscription){
      subscription=await registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:expected});changed=true;
    }
    const key=markerKey(),value=markerValue(subscription);
    if(changed||localStorage.getItem(key)!==value){
      await save(subscription);localStorage.setItem(key,value);
      state.status=changed?'rotated':'refreshed';
    }else state.status='current';
    state.endpoint=subscription.endpoint;state.completedAt=new Date().toISOString();
    window.dispatchEvent(new CustomEvent('nexlab:vapid-rotated',{detail:{status:state.status,version:'0.26.12'}}));
  }
  const start=()=>rotate().catch(error=>{window.__NEXLAB_VAPID_ROTATION_BETA_0264__.status='error';window.__NEXLAB_VAPID_ROTATION_BETA_0264__.error=String(error?.message||error)});
  if(document.readyState==='complete')setTimeout(start,1200);else window.addEventListener('load',()=>setTimeout(start,1200),{once:true});
  document.addEventListener('visibilitychange',()=>{const state=window.__NEXLAB_VAPID_ROTATION_BETA_0264__;if(document.visibilityState==='visible'&&['error','no-session'].includes(state.status))start()});
})();
