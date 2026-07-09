(function(){
  if (window.__NEXLAB_BOOTSTRAP_V25_16_11__) return;
  window.__NEXLAB_BOOTSTRAP_V25_16_11__ = true;

  const nativeFetch = window.fetch ? window.fetch.bind(window) : null;
  const nativeAlert = window.alert ? window.alert.bind(window) : function(){};
  const SUPABASE_RE = /https:\/\/[a-z0-9.-]+\.supabase\.co/i;
  const MUTATING_METHOD_RE = /^(POST|PUT|PATCH|DELETE)$/i;

  function methodFrom(input, init){
    try {
      if (init && init.method) return String(init.method).toUpperCase();
      if (input && input.method) return String(input.method).toUpperCase();
      return 'GET';
    } catch { return 'GET'; }
  }

  function urlFrom(input){
    try {
      if (typeof input === 'string') return input;
      if (input && typeof input.url === 'string') return input.url;
      return String(input || '');
    } catch { return ''; }
  }

  function emit(name, detail){
    try { window.dispatchEvent(new CustomEvent(name, { detail: detail || {} })); } catch {}
  }

  window.nexlabShowModal = function(options){
    return new Promise((resolve) => {
      emit('nexlab:modal', Object.assign({}, options || {}, { resolve }));
    });
  };

  window.alert = function(message){
    try {
      window.nexlabShowModal({
        title: 'Aviso do NEXLAB',
        message: String(message || ''),
        variant: 'info',
        okLabel: 'Entendi'
      });
      return;
    } catch {
      return nativeAlert(message);
    }
  };

  if (nativeFetch) {
    window.fetch = async function(input, init){
      const target = urlFrom(input);
      const method = methodFrom(input, init);
      const isSupabase = SUPABASE_RE.test(target);
      const isMutatingSupabase = isSupabase && MUTATING_METHOD_RE.test(method);
      const startedAt = Date.now();
      if (isMutatingSupabase) {
        emit('nexlab:action-start', { method, url: target, startedAt });
      }
      try {
        const response = await nativeFetch(input, init);
        if (isSupabase) {
          if (response.status === 0 || response.status === 502 || response.status === 503 || response.status === 504 || response.status >= 500) {
            emit('nexlab:connection-error', {
              title: 'Falha de conexão com o NEXLAB',
              message: 'O app não conseguiu confirmar a comunicação com o servidor. Verifique sua internet e tente novamente.',
              detail: `Servidor respondeu com status ${response.status}.`,
              status: response.status,
              url: target
            });
          } else if (response.ok) {
            emit('nexlab:connection-restored', { url: target });
          }
        }
        return response;
      } catch (error) {
        if (isSupabase || !navigator.onLine) {
          emit('nexlab:connection-error', {
            title: navigator.onLine ? 'Falha de conexão com o NEXLAB' : 'Você está sem internet',
            message: navigator.onLine ? 'Não foi possível conectar ao Supabase agora. Tente novamente em alguns instantes.' : 'A conexão caiu. O app pode exibir dados já carregados, mas novas alterações dependem de internet.',
            detail: error && error.message ? error.message : 'Erro de rede não identificado.',
            url: target
          });
        }
        throw error;
      } finally {
        if (isMutatingSupabase) {
          const elapsed = Date.now() - startedAt;
          window.setTimeout(() => emit('nexlab:action-end', { method, url: target, elapsed }), Math.max(120, 360 - elapsed));
        }
      }
    };
  }

  window.addEventListener('offline', function(){
    emit('nexlab:connection-error', {
      title: 'Você está sem internet',
      message: 'O NEXLAB entrou em modo offline. Dados já carregados podem continuar visíveis; salvamentos e sincronizações precisam de conexão.',
      detail: 'Evento offline detectado pelo navegador.'
    });
  });
})();
