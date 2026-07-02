# Checklist funcional — NexLab v25.15.0

1. Executar a migration da v25.15 no Supabase.
2. Confirmar `25.14.0 = stable` e `25.15.0 = rc`.
3. Abrir Saúde do Sistema → Prontidão e conferir versão 25.15.0.
4. Abrir Saúde do Sistema → Revisão final.
5. Executar a auditoria no Dashboard, Usuários e vínculos, Permissões, Relatórios e Notificações.
6. Repetir a auditoria no celular com um formulário e um modal longo abertos.
7. Testar navegação por teclado e o link “Pular para o conteúdo principal”.
8. Testar perda e retorno da conexão para validar o aviso de rede.
9. Confirmar que cliques duplos rápidos não repetem ações.
10. Validar Administrador, Coordenador, Bolsista e Coworking Júnior.
11. Conferir os logs do PostgreSQL e das Edge Functions após os testes.
12. Exportar o diagnóstico JSON e confirmar a presença de `frontend_audit`.
