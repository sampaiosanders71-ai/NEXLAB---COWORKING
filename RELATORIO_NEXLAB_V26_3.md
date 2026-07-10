# NEXLAB v26.3 — Desempenho

## Otimizações implementadas

- Logos e símbolo do app convertidos de PNG para WebP.
- Redução de aproximadamente 224.8 KB nos ativos usados pela interface.
- Remoção do SVG rasterizado não utilizado.
- Preconnect e DNS prefetch para o projeto Supabase.
- Module preload antecipado do JavaScript principal.
- CSS carregado antes dos scripts para acelerar a primeira pintura.
- Cache de consultas com limite de 80 entradas.
- Limpeza automática de consultas expiradas.
- TTL do cache adaptado à qualidade da conexão e ao modo de economia de dados.
- Cache do Service Worker limitado para evitar crescimento indefinido.
- Imagens abaixo da dobra recebem carregamento preguiçoso e decodificação assíncrona.
- Seções longas abaixo da dobra usam `content-visibility`.
- Modo econômico reduz blur e sombras em aparelhos com pouca memória, poucos núcleos ou rede lenta.
- Métricas de navegação, LCP e tarefas longas ficam disponíveis em `window.__NEXLAB_PERFORMANCE__`.

## Análise do bundle

O JavaScript principal permanece com aproximadamente 1.81 MB.

Ele ainda contém:

- jsPDF;
- jspdf-autotable;
- html2canvas;
- XLSX;
- código dos módulos do app.

## Limitação estrutural

A separação real de PDF/XLSX e a divisão dos módulos em arquivos independentes não foram executadas diretamente no bundle compilado. Isso exigiria reconstrução e recompilação pelo projeto-fonte React/Vite. Fazer essa extração manualmente no arquivo minificado colocaria relatórios e módulos em risco.

## Banco de dados

Nenhum SQL novo é necessário para a v26.3.
