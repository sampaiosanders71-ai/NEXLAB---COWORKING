# Relatório de validação — v25.12.0 RC1

## Validações locais concluídas

- `node --check src/app.bundle.js`: aprovado.
- `npm ci`: aprovado.
- `npm run build`: aprovado com Vite 8.1.2.
- HTML único com JavaScript e CSS incorporados: aprovado.
- Ausência de chave `service_role` no frontend: verificada.

## Validações pendentes no ambiente Supabase

- execução da migration;
- confirmação das quatro tabelas;
- confirmação das seis funções RPC/auxiliares;
- confirmação dos dois triggers de recálculo;
- teste de alteração de padrão por perfil;
- teste de exceção individual e restauração;
- teste com Administrador, Coordenador, Bolsista e Coworking Júnior.
