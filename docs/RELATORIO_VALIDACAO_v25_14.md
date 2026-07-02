# Relatório de validação local — NexLab v25.14.0

## Código

- `node --check src/app.bundle.js`: aprovado.
- Build Vite 8.1.2: aprovado.
- HTML único gerado com JavaScript e CSS incorporados.
- Nenhuma chave `service_role` adicionada ao frontend.

## Funcionalidade implementada

- aba Prontidão dentro de Saúde do Sistema;
- diagnóstico de versão, RLS, funções, triggers, Cron e integridade;
- contexto do navegador para HTTPS, domínio, Edge Function, e-mail e Web Push;
- checklist manual persistente;
- snapshots auditáveis;
- seleção e quarentena controlada de contas candidatas;
- exclusão permanente desativada.

## Pendente no ambiente do usuário

- executar a migration no Supabase;
- executar o SQL de validação;
- testar a aba Prontidão com perfil Administrador;
- validar o Web Push somente após publicação em HTTPS.
