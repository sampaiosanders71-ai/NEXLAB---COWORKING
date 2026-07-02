# Changelog — NexLab v25.16.0

## Adicionado

- campos `avatar_url`, `avatar_path` e `avatar_updated_at` em perfis;
- bucket `profile-photos` com limite de 5 MB;
- políticas de Storage por pasta do usuário autenticado;
- RPC `nexlab_update_profile_avatar`;
- upload, troca e remoção de foto no módulo Meu Perfil;
- componente visual reutilizável de avatar com fallback por iniciais.

## Alterado

- identidade visual oficial aplicada no login, carregamento, menu lateral e demais pontos da marca;
- favicon, ícones PWA e manifesto passam a usar o símbolo oficial;
- cabeçalho, menu lateral e perfil pessoal exibem somente o primeiro nome;
- lista administrativa de usuários passa a exibir a foto quando disponível;
- diagnóstico de prontidão atualizado para a versão 25.16.0;
- v25.15.0 é promovida para `stable` durante a migration.

## Preservado

- nome completo armazenado em `profiles.nome`;
- nome completo nos relatórios e áreas administrativas;
- regras de perfis, permissões, notificações, relatórios e prontidão;
- Edge Function e jobs Cron atuais.
