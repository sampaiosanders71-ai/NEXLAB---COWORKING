# NEXLAB v26.4 — Supabase, segurança e integridade

## Implementado no aplicativo

- Painel de auditoria integrado à aba Saúde do Sistema.
- Resumo de falhas críticas, pontos de atenção e verificações aprovadas.
- Diagnóstico de RLS, policies, RPCs, índices, duplicidades e constraints.
- Botão para executar novamente a verificação.
- Mensagem clara quando a migration ainda não foi aplicada.

## Implementado no Supabase

- Função administrativa central.
- `search_path` fixado nas RPCs SECURITY DEFINER usadas pelo app.
- RPCs administrativas bloqueadas para a role `anon`.
- Alterações diretas de `profiles` bloqueadas para `anon` e `authenticated`.
- RLS habilitado automaticamente quando policies já existem.
- Índices para notificações, projetos, reservas, marketing, logs e outros módulos.
- Índices únicos contra participantes e preferências duplicadas, quando os dados atuais permitem.
- RPC administrativa `nexlab_security_audit_v26_4`.
- Registro da versão 26.4 na tabela de versões, quando disponível.

## Decisão de segurança

A migration não cria policies genéricas e não habilita RLS em tabelas sem policy. Fazer isso sem conhecer as regras reais de cada perfil poderia bloquear o app ou conceder acesso incorreto.

O painel informa quais tabelas ainda precisam de policies específicas.

## Arquivo SQL

`supabase/supabase_v26_4_seguranca_integridade.sql`

## Local de execução

Supabase Dashboard → SQL Editor → New query.

## Testes obrigatórios depois do SQL

- ADM: Saúde do Sistema, Usuários, Permissões, Logs e exclusões administrativas.
- Coordenador: módulos operacionais autorizados, sem acesso a Saúde/Logs.
- Bolsista: projetos, eventos e recursos permitidos.
- Coworking Júnior: módulos básicos e Mural conforme a matriz.
- Usuário pendente: somente Dashboard, Perfil e Notificações.

## Observação

A análise automática verifica configuração e integridade, mas não substitui testes reais com cada perfil e suas policies.
