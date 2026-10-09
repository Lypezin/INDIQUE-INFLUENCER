# Indique e Ganhe

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Influenciadores que indicam entregadores acompanham suas próprias indicações, sobretudo pelo celular. Um administrador sincroniza a Data Crazy, importa a Performance, revisa atribuições e gerencia os acessos.

## Product Purpose

Mostrar as corridas acumuladas por entregador, o avanço até a meta e os prêmios conquistados por cada influenciador.

## Operating Context

Os indicados são sincronizados pela API da Data Crazy manualmente ou todos os dias às 06:00 de Brasília. Uma coleta completa substitui a lista atual; a importação de Performance por CSV ou Excel soma ao histórico. O vínculo é o ID do Entregador do Data Crazy com o UUID da Performance.

## Capabilities and Constraints

- Cada influenciador vê somente os próprios indicados e respectivos dados pessoais.
- A meta libera um prêmio por entregador, sem controle de pagamento.
- O primeiro acesso deve permitir criar senha sem exigir confirmação por e-mail.
- O projeto usa um schema próprio em um Supabase compartilhado com outro sistema.
- Os arquivos de exemplo servem para validar a importação e não são dados iniciais.

## Brand Commitments

- Nome: Indique e Ganhe.
- O usuário escolheu azul como base visual.
- Textos devem ser diretos e específicos do trabalho com indicações e corridas.

## Product Principles

- Mostrar primeiro o progresso dos indicados no celular.
- Deixar claro quando os dados foram atualizados por sincronização ou importação.
- Manter metas, corridas restantes e prêmios fáceis de consultar.
- Proteger o acesso individual sem depender de mudanças globais no projeto compartilhado.
