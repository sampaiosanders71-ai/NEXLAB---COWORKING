/* NEXLAB Beta 0.26.22 — entrada legada redirecionada para o bundle atual. */
const __nexlabCompatibilityDetail=Object.freeze({group:"legacy-26-31-22",sourceVersion:"26.31.22",targetVersion:"0.26.22",assetPath:"assets/index-R56v263122rc17.js",mode:'lightweight-bridge',usedAt:new Date().toISOString()});
try{sessionStorage.setItem('nexlab:compatibility-asset:last',JSON.stringify(__nexlabCompatibilityDetail));}catch{}
try{globalThis.dispatchEvent(new CustomEvent('nexlab:compatibility-asset-used',{detail:__nexlabCompatibilityDetail}));}catch{}
import('./index-beta-0-26-12.js?v=app-beta-0-26-22-feedback-resolved-bulk-delete').catch((error)=>{
  try{globalThis.dispatchEvent(new CustomEvent('nexlab:module-render-error',{detail:{module:'compatibility',component:'legacy-entry-bridge',message:String(error?.message||error),stack:String(error?.stack||'')}}));}catch{}
});
