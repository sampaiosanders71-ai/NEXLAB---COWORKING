/* NEXLAB Beta 0.26.18 — ponte leve de compatibilidade; não remover sem telemetria e período de carência. */
const __nexlabCompatibilityDetail=Object.freeze({group:"legacy-26-31-22",sourceVersion:"26.31.22",targetVersion:"0.26.18",assetPath:"assets/nexlab-vendor-r56022rc17.js",mode:'lightweight-bridge',usedAt:new Date().toISOString()});
try{sessionStorage.setItem('nexlab:compatibility-asset:last',JSON.stringify(__nexlabCompatibilityDetail));}catch{}
try{globalThis.dispatchEvent(new CustomEvent('nexlab:compatibility-asset-used',{detail:__nexlabCompatibilityDetail}));}catch{}
export * from './nexlab-vendor-beta-0-26-12.js?v=app-beta-0-26-18-contextual-visibility-by-role';
