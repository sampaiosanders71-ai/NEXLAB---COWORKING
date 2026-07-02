# Relatório de validação local — NexLab v25.15.0

## Verificações executadas

- `node --check src/app.bundle.js`: aprovado;
- build Vite de produção: aprovado;
- geração do HTML único: aprovada;
- sintaxe do JavaScript extraído do HTML único: aprovada;
- versão do pacote e metadados: atualizados para 25.15.0;
- cache do Service Worker: atualizado para `nexlab-v25-15-shell`;
- `service_role` no frontend: ausente;
- Edge Function, Secrets e Cron: preservados.

## Pendente no ambiente do usuário

- execução da migration no Supabase;
- validação das RPCs no banco;
- testes autenticados com os quatro perfis;
- revisão visual em computador e celular;
- teste final de HTTPS e Web Push após a publicação.
