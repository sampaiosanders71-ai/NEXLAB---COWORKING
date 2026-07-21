/* NEXLAB Beta 0.26.21 — ponte leve de compatibilidade; não remover sem telemetria e período de carência. */
const __nexlabCompatibilityDetail=Object.freeze({group:"beta-0-26-11",sourceVersion:"0.26.11",targetVersion:"0.26.21",assetPath:"assets/nexlab-vendor-beta-0-26-11.js",mode:'lightweight-bridge',usedAt:new Date().toISOString()});
try{sessionStorage.setItem('nexlab:compatibility-asset:last',JSON.stringify(__nexlabCompatibilityDetail));}catch{}
try{globalThis.dispatchEvent(new CustomEvent('nexlab:compatibility-asset-used',{detail:__nexlabCompatibilityDetail}));}catch{}
export * from './nexlab-vendor-beta-0-26-12.js?v=app-beta-0-26-21-feedback-external-evidence-r2-ready';
