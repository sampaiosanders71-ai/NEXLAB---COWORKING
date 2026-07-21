(function(){
  'use strict';
  const BUILD=globalThis.__NEXLAB_BUILD_IDENTITY__||Object.freeze({version:'0.26.21',revision:'beta-0-26-21-feedback-external-evidence-upload-fix'});
  if(globalThis.__NEXLAB_AUTH_SECURITY__?.revision===BUILD.revision)return;

  const CARD_ID='nexlab-auth-security-card';
  const STYLE_ID='nexlab-auth-security-style';
  const MODAL_ID='nexlab-auth-security-modal';
  let scheduled=false;
  let observer=null;

  function ensureStyle(){
    if(document.getElementById(STYLE_ID))return;
    const style=document.createElement('style');
    style.id=STYLE_ID;
    style.textContent=[
      '#'+CARD_ID+'{margin-top:18px;border:1px solid #dbe3ee;border-radius:20px;background:#fff;padding:20px;box-shadow:0 8px 28px rgba(15,35,65,.07);font:14px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#24364f}',
      '#'+CARD_ID+' .nexlab-auth-security-head{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;flex-wrap:wrap}',
      '#'+CARD_ID+' h2{margin:0 0 6px;font-size:18px;line-height:1.25;color:#10233f}',
      '#'+CARD_ID+' p{margin:0;max-width:720px;color:#5b6b82}',
      '#'+CARD_ID+' .nexlab-auth-security-note{margin-top:14px;padding:12px 14px;border-radius:14px;background:#f5f8fc;border:1px solid #e2e8f0;color:#42526a}',
      '#'+CARD_ID+' button,.nexlab-auth-security-actions button{appearance:none;border:0;border-radius:12px;padding:10px 15px;font-weight:800;cursor:pointer}',
      '#'+CARD_ID+' button{background:#0b2a63;color:#fff;min-height:42px}',
      '#'+CARD_ID+' button:hover{background:#143d7d}',
      '.nexlab-auth-security-backdrop{position:fixed;inset:0;z-index:2147483646;background:rgba(8,23,48,.56);display:flex;align-items:center;justify-content:center;padding:18px}',
      '.nexlab-auth-security-dialog{width:min(520px,100%);max-height:min(760px,calc(100vh - 36px));overflow:auto;border-radius:22px;background:#fff;padding:22px;box-shadow:0 24px 80px rgba(0,0,0,.3);font:14px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#24364f}',
      '.nexlab-auth-security-dialog h2{margin:0;color:#10233f;font-size:21px}',
      '.nexlab-auth-security-dialog .intro{margin:7px 0 18px;color:#5b6b82}',
      '.nexlab-auth-security-field{display:block;margin:0 0 14px}',
      '.nexlab-auth-security-field span{display:block;margin-bottom:6px;font-weight:750;color:#34465f}',
      '.nexlab-auth-security-field input{box-sizing:border-box;width:100%;min-height:44px;border:1px solid #cbd5e1;border-radius:12px;padding:10px 12px;background:#fff;color:#10233f;font:inherit}',
      '.nexlab-auth-security-field input:focus{outline:3px solid rgba(14,87,164,.18);border-color:#0e57a4}',
      '.nexlab-auth-security-error{min-height:22px;margin:2px 0 10px;color:#b42318;font-weight:700}',
      '.nexlab-auth-security-actions{display:flex;justify-content:flex-end;gap:9px;flex-wrap:wrap}',
      '.nexlab-auth-security-actions .cancel{background:#eef2f7;color:#263b58}',
      '.nexlab-auth-security-actions .save{background:#0b2a63;color:#fff}',
      '.nexlab-auth-security-actions button:disabled{cursor:wait;opacity:.6}',
      '@media(max-width:560px){#'+CARD_ID+'{padding:17px}.nexlab-auth-security-dialog{padding:19px}.nexlab-auth-security-actions button{flex:1}}'
    ].join('');
    document.head.appendChild(style);
  }

  function showMessage(title,message,variant='info'){
    if(typeof globalThis.nexlabShowModal==='function'){
      return globalThis.nexlabShowModal({title,message,variant,okLabel:'Entendi'});
    }
    alert(title+'\n\n'+message);
    return Promise.resolve(true);
  }

  function client(){return globalThis.__NEXLAB_SUPABASE__||null;}
  function cleanError(error){
    const code=String(error?.code||'').toLowerCase();
    const text=String(error?.message||error||'').toLowerCase();
    if(code.includes('invalid_credentials')||text.includes('invalid login')||text.includes('current password')||text.includes('password is incorrect'))return 'A senha atual está incorreta.';
    if(text.includes('same password')||text.includes('different from the old'))return 'A nova senha deve ser diferente da senha atual.';
    if(text.includes('weak')||text.includes('least')||text.includes('characters'))return 'A nova senha não atende aos requisitos de segurança.';
    if(text.includes('session')||text.includes('jwt')||text.includes('expired'))return 'Sua sessão expirou. Entre novamente e repita a alteração.';
    if(navigator.onLine===false)return 'Sem conexão com a internet. Reconecte e tente novamente.';
    return 'Não foi possível alterar a senha. Verifique os dados e tente novamente.';
  }

  function closeModal(value=false){
    const backdrop=document.getElementById(MODAL_ID);
    if(!backdrop)return;
    document.removeEventListener('keydown',backdrop.__nexlabKeyHandler,true);
    const previous=backdrop.__nexlabPreviousFocus;
    backdrop.remove();
    if(previous&&document.body.contains(previous))setTimeout(()=>previous.focus({preventScroll:true}),0);
    return value;
  }

  function openChangePassword(){
    if(document.getElementById(MODAL_ID))return;
    ensureStyle();
    const backdrop=document.createElement('div');
    backdrop.id=MODAL_ID;
    backdrop.className='nexlab-auth-security-backdrop';
    backdrop.setAttribute('role','dialog');
    backdrop.setAttribute('aria-modal','true');
    backdrop.setAttribute('aria-labelledby','nexlab-auth-security-title');
    backdrop.__nexlabPreviousFocus=document.activeElement instanceof HTMLElement?document.activeElement:null;
    backdrop.innerHTML='<section class="nexlab-auth-security-dialog" role="document"><h2 id="nexlab-auth-security-title">Alterar senha</h2><p class="intro">Confirme a senha atual e defina uma nova senha com pelo menos 8 caracteres.</p><form novalidate><label class="nexlab-auth-security-field"><span>Senha atual</span><input name="currentPassword" type="password" autocomplete="current-password" required /></label><label class="nexlab-auth-security-field"><span>Nova senha</span><input name="newPassword" type="password" autocomplete="new-password" minlength="8" required /></label><label class="nexlab-auth-security-field"><span>Confirmar nova senha</span><input name="confirmPassword" type="password" autocomplete="new-password" minlength="8" required /></label><p class="nexlab-auth-security-error" role="alert" aria-live="assertive"></p><div class="nexlab-auth-security-actions"><button type="button" class="cancel">Cancelar</button><button type="submit" class="save">Alterar senha</button></div></form></section>';
    const form=backdrop.querySelector('form');
    const current=form.elements.currentPassword;
    const next=form.elements.newPassword;
    const confirm=form.elements.confirmPassword;
    const errorNode=backdrop.querySelector('.nexlab-auth-security-error');
    const buttons=[...backdrop.querySelectorAll('button')];
    const setBusy=(busy)=>{buttons.forEach(button=>button.disabled=busy);current.disabled=busy;next.disabled=busy;confirm.disabled=busy;};
    const setError=(message)=>{errorNode.textContent=String(message||'');};
    backdrop.querySelector('.cancel').addEventListener('click',()=>closeModal(false));
    backdrop.addEventListener('click',event=>{if(event.target===backdrop)closeModal(false);});
    backdrop.__nexlabKeyHandler=(event)=>{
      if(event.key==='Escape'){event.preventDefault();closeModal(false);return;}
      if(event.key!=='Tab')return;
      const focusables=[current,next,confirm,...buttons].filter(item=>!item.disabled);
      const first=focusables[0],last=focusables[focusables.length-1];
      if(event.shiftKey&&document.activeElement===first){last.focus();event.preventDefault();}
      else if(!event.shiftKey&&document.activeElement===last){first.focus();event.preventDefault();}
    };
    document.addEventListener('keydown',backdrop.__nexlabKeyHandler,true);
    form.addEventListener('submit',async(event)=>{
      event.preventDefault();
      setError('');
      const currentPassword=String(current.value||'');
      const newPassword=String(next.value||'');
      const confirmation=String(confirm.value||'');
      if(!currentPassword)return setError('Informe a senha atual.');
      if(newPassword.length<8)return setError('A nova senha deve ter pelo menos 8 caracteres.');
      if(newPassword===currentPassword)return setError('A nova senha deve ser diferente da senha atual.');
      if(newPassword!==confirmation)return setError('As novas senhas não coincidem.');
      const supabase=client();
      if(!supabase?.auth?.updateUser)return setError('O serviço de autenticação ainda não está disponível.');
      setBusy(true);
      try{
        const sessionResult=await supabase.auth.getSession();
        if(sessionResult?.error)throw sessionResult.error;
        if(!sessionResult?.data?.session)throw new Error('session expired');
        const result=await supabase.auth.updateUser({password:newPassword,current_password:currentPassword});
        if(result?.error)throw result.error;
        let otherSessionsClosed=true;
        try{
          const signOutResult=await supabase.auth.signOut({scope:'others'});
          if(signOutResult?.error)otherSessionsClosed=false;
        }catch{otherSessionsClosed=false;}
        closeModal(true);
        await showMessage(
          'Senha alterada',
          otherSessionsClosed
            ? 'A senha foi atualizada e as outras sessões da conta foram encerradas.'
            : 'A senha foi atualizada, mas não foi possível confirmar o encerramento das outras sessões. Revise os dispositivos conectados.',
          otherSessionsClosed?'success':'warning'
        );
      }catch(error){
        console.error('Falha segura ao alterar senha:',error);
        setError(cleanError(error));
      }finally{
        if(document.body.contains(backdrop))setBusy(false);
      }
    });
    document.body.appendChild(backdrop);
    setTimeout(()=>current.focus(),0);
  }

  function pageIsProfile(){return document.body?.dataset?.nexlabPage==='perfil';}
  function findHost(){
    const main=document.querySelector('main');
    if(!main)return null;
    const candidates=[...main.querySelectorAll(':scope > div, :scope > section')].filter(node=>node.offsetParent!==null);
    return candidates.at(-1)||main;
  }
  function render(){
    scheduled=false;
    if(!pageIsProfile()){document.getElementById(CARD_ID)?.remove();return;}
    if(document.getElementById(CARD_ID))return;
    const host=findHost();
    if(!host)return;
    ensureStyle();
    const card=document.createElement('section');
    card.id=CARD_ID;
    card.setAttribute('aria-labelledby','nexlab-auth-security-card-title');
    card.innerHTML='<div class="nexlab-auth-security-head"><div><h2 id="nexlab-auth-security-card-title">Segurança da conta</h2><p>Altere sua senha com confirmação da senha atual. Depois da alteração, as outras sessões da conta serão encerradas.</p></div><button type="button">Alterar senha</button></div><div class="nexlab-auth-security-note"><strong>E-mails do NEXLAB:</strong> usados somente para recuperação de acesso e avisos de segurança relacionados à senha. Atividades de módulos continuam no aplicativo e por Push.</div>';
    card.querySelector('button').addEventListener('click',openChangePassword);
    host.appendChild(card);
  }
  function schedule(){if(scheduled)return;scheduled=true;requestAnimationFrame(render);}
  function boot(){
    schedule();
    observer=new MutationObserver(schedule);
    observer.observe(document.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['data-nexlab-page']});
    globalThis.addEventListener('nexlab:push-navigation',schedule);
    globalThis.addEventListener('popstate',schedule);
  }
  globalThis.__NEXLAB_AUTH_SECURITY__=Object.freeze({version:BUILD.version,revision:BUILD.revision,openChangePassword});
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
})();
