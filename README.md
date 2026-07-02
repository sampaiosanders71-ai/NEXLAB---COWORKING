# NexLab v25.16.0 — Identidade Visual e Foto de Perfil

Versão RC baseada na v25.15.0 validada.

## Principais mudanças

- substitui a marca provisória pela identidade visual oficial enviada para o NexLab;
- utiliza a versão clara da logo em telas brancas e a versão apropriada para o menu escuro;
- atualiza favicon, ícones do aplicativo e manifesto PWA com o símbolo oficial;
- adiciona foto de perfil em JPG, PNG ou WebP, limitada a 5 MB;
- protege o upload no Supabase Storage para que cada usuário edite apenas a própria pasta;
- exibe a foto ao lado do nome no cabeçalho, menu lateral, Meu Perfil e gestão de usuários;
- exibe somente o primeiro nome nas áreas pessoais da interface;
- preserva o nome completo no banco, relatórios, auditorias e telas administrativas;
- mantém fallback com iniciais quando não houver foto ou a imagem falhar.

## Instalação

1. Execute `supabase/migrations/20260702_v25_16_identidade_avatar.sql` no Supabase SQL Editor.
2. Execute `docs/NexLab_v25_16_VALIDACAO.sql`.
3. Abra o HTML da v25.16.
4. Entre em `Meu Perfil → Editar Perfil` e envie uma foto.
5. Confirme a exibição no cabeçalho e no menu lateral.
6. Exporte um relatório de usuários e confirme que o nome completo foi preservado.

Não exige alteração em Edge Functions, Secrets ou Cron.
