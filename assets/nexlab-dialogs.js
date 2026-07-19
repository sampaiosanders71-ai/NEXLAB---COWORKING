(function(){
  'use strict';
  if(window.__NEXLAB_DIALOGS_BETA_0266__)return;
  window.__NEXLAB_DIALOGS_BETA_0266__=true;
  let active=null;
  function close(value){
    if(!active)return;
    const current=active;active=null;
    document.removeEventListener('keydown',current.onKey,true);
    current.el.remove();
    if(current.previousFocus&&document.body.contains(current.previousFocus))requestAnimationFrame(()=>current.previousFocus.focus({preventScroll:true}));
    current.resolve(value);
  }
  window.nexlabPrompt=function(message,options={}){
    if(active)close(null);
    return new Promise(resolve=>{
      const mode=String(options.mode||'textarea');
      const title=String(options.title||'Informação obrigatória');
      const label=String(options.label||'Detalhes');
      const placeholder=String(options.placeholder||'Digite aqui...');
      const initialValue=String(options.initialValue||'');
      const minLength=Math.max(0,Number(options.minLength??1));
      const maxLength=Math.max(minLength,Number(options.maxLength??1000));
      const pattern=options.pattern?new RegExp(String(options.pattern)):null;
      const patternMessage=String(options.patternMessage||'O valor informado não possui o formato esperado.');
      const confirmLabel=String(options.confirmLabel||'Confirmar');
      const cancelLabel=String(options.cancelLabel||'Cancelar');
      const backdrop=document.createElement('div');
      backdrop.className='nexlab-confirm-backdrop';
      backdrop.setAttribute('role','dialog');
      backdrop.setAttribute('aria-modal','true');
      backdrop.setAttribute('aria-labelledby','nexlab-prompt-title');
      backdrop.setAttribute('aria-describedby','nexlab-prompt-description');
      backdrop.innerHTML='<div class="nexlab-confirm-card" role="document"><div class="nexlab-confirm-head"><div class="nexlab-confirm-icon" aria-hidden="true">i</div><div><h2 id="nexlab-prompt-title" class="nexlab-confirm-title"></h2><p id="nexlab-prompt-description" class="nexlab-confirm-text"></p></div></div><div class="nexlab-prompt-body"><label class="nexlab-prompt-label" for="nexlab-prompt-field"></label><div class="nexlab-prompt-field-host"></div><p class="nexlab-prompt-help"></p><p class="nexlab-prompt-error" role="alert" aria-live="assertive"></p></div><div class="nexlab-confirm-actions"><button type="button" class="nexlab-confirm-btn nexlab-confirm-cancel"></button><button type="button" class="nexlab-confirm-btn nexlab-confirm-ok"></button></div></div>';
      backdrop.querySelector('.nexlab-confirm-title').textContent=title;
      backdrop.querySelector('.nexlab-confirm-text').textContent=String(message||'Preencha o campo para continuar.');
      backdrop.querySelector('.nexlab-prompt-label').textContent=label;
      const host=backdrop.querySelector('.nexlab-prompt-field-host');
      const field=mode==='textarea'?document.createElement('textarea'):document.createElement('input');
      field.id='nexlab-prompt-field';field.className='nexlab-prompt-field';field.maxLength=maxLength;field.placeholder=placeholder;field.value=initialValue;
      if(mode==='textarea'){field.rows=Math.max(3,Number(options.rows||5));}
      else{field.type=options.sensitive?'password':'text';field.dataset.mode=mode;field.autocomplete=mode==='code'?'one-time-code':'off';field.inputMode=mode==='code'?'numeric':String(options.inputMode||'text');}
      host.appendChild(field);
      const help=backdrop.querySelector('.nexlab-prompt-help');
      help.textContent=minLength===maxLength?`${minLength} caracteres obrigatórios.`:`Entre ${minLength} e ${maxLength} caracteres.`;
      const error=backdrop.querySelector('.nexlab-prompt-error');
      const cancel=backdrop.querySelector('.nexlab-confirm-cancel');
      const confirm=backdrop.querySelector('.nexlab-confirm-ok');
      cancel.textContent=cancelLabel;confirm.textContent=confirmLabel;
      const validate=()=>{
        const value=field.value.trim();
        if(value.length<minLength){error.textContent=`Informe pelo menos ${minLength} caracteres.`;field.setAttribute('aria-invalid','true');field.focus();return;}
        if(value.length>maxLength){error.textContent=`Informe no máximo ${maxLength} caracteres.`;field.setAttribute('aria-invalid','true');field.focus();return;}
        if(pattern&&!pattern.test(value)){error.textContent=patternMessage;field.setAttribute('aria-invalid','true');field.focus();return;}
        error.textContent='';field.removeAttribute('aria-invalid');close(value);
      };
      const previousFocus=document.activeElement instanceof HTMLElement?document.activeElement:null;
      const onKey=(event)=>{
        if(event.key==='Escape'){event.preventDefault();close(null);return;}
        if(event.key==='Enter'&&(mode!=='textarea'||event.ctrlKey||event.metaKey)){event.preventDefault();validate();return;}
        if(event.key!=='Tab')return;
        const focusables=[field,cancel,confirm];const first=focusables[0],last=focusables[focusables.length-1];
        if(event.shiftKey&&document.activeElement===first){last.focus();event.preventDefault();}
        else if(!event.shiftKey&&document.activeElement===last){first.focus();event.preventDefault();}
      };
      active={el:backdrop,resolve,onKey,previousFocus};
      cancel.addEventListener('click',()=>close(null));confirm.addEventListener('click',validate);
      backdrop.addEventListener('click',event=>{if(event.target===backdrop)close(null);});
      document.addEventListener('keydown',onKey,true);document.body.appendChild(backdrop);setTimeout(()=>field.focus(),0);
    });
  };
  window.nexlabCodePrompt=function(message,options={}){
    return window.nexlabPrompt(message,{title:'Confirmação em duas etapas',label:'Código de 6 dígitos',placeholder:'000000',mode:'code',sensitive:true,minLength:6,maxLength:6,pattern:'^\\d{6}$',patternMessage:'Informe exatamente os 6 dígitos do aplicativo autenticador.',confirmLabel:'Verificar',...options});
  };
})();
