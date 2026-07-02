# Relatório de validação — NexLab v25.13.0

## Resultado local

- `npm ci`: aprovado;
- vulnerabilidades do npm: 0;
- `node --check src/app.bundle.js`: aprovado;
- `vite build`: aprovado;
- HTML único com CSS e JavaScript incorporados: gerado;
- `service_role` no frontend: não utilizado;
- Edge Function, Secrets e Cron: sem alteração.

## Itens que dependem do Supabase do projeto

- execução da migration v25.13;
- recarga do cache PostgREST;
- registro da primeira exportação;
- leitura do histórico como Administrador, Coordenador e usuário autorizado;
- validação final no computador e no celular.
