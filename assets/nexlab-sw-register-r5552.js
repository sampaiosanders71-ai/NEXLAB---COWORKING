(function(){
  'use strict';
  if(!('serviceWorker' in navigator)||location.protocol==='file:')return;
  window.addEventListener('load',async()=>{
    try{
      const registration=await navigator.serviceWorker.register('./nexlab-sw.js?v=26312',{scope:'./',updateViaCache:'none'});
      await registration.update();
    }catch(error){console.error('Falha ao ativar a atualização do NEXLAB:',error);}
  },{once:true});
})();
