# Data Crazy: evolução da guia

## Estado atual

- A sincronização consulta negócios, pipelines e leads, identifica o influenciador pela pipeline e cruza o **ID do Entregador** com o UUID da Performance.
- Uma coleta validada substitui a lista publicada de `indique_ganhe_influencer.referrals`. As tabelas temporárias de negócios e leads são limpas após a publicação. O `lead_id` e o `business_id` não permanecem ligados ao entregador publicado.
- `import_batches`, `import_activity` e `data_crazy_sync_runs` registram cargas, etapas, horários e responsáveis pelas execuções. `attribution_reviews` registra quem resolveu uma atribuição e quando. Isso é histórico operacional; não é um registro completo das edições de cada entregador.
- A guia agora mostra a base publicada e as últimas cargas Data Crazy. O log completo continua em **Importações**.

## Estrutura proposta para a guia

1. **Operação:** última coleta concluída, coleta em andamento, tamanho da base, erros, UUIDs inválidos, atribuições ambíguas e histórico de cargas. A sincronização segue como ação principal.
2. **Entregadores:** busca por nome/UUID, filtro por influenciador e situação do vínculo com a Performance. Uma ficha mostra apenas os campos úteis à campanha: nome, região, data de liberação, pipeline, UUID, corridas e meta. Contato e CPF ficam recolhidos e restritos à administração.
3. **Linha do tempo do entregador:** eventos do CRM e ações do painel em fontes separadas, com data, origem, descrição e autor **quando a origem o informar**. O texto deve distinguir “alteração feita por” de “mudança detectada na sincronização”.

## Base técnica necessária

1. Persistir um mapa `uuid ↔ lead_id ↔ business_id` dentro de `indique_ganhe_influencer`, atualizado antes de apagar as tabelas temporárias. Um UUID pode ter mais de um negócio/lead; não reduzir isso a um único ID sem regra explícita. Guardar primeira e última observação, execução de origem e se o vínculo ainda está ativo.
2. Fazer a ficha e o histórico por uma Edge Function autenticada para administradores. A chave Data Crazy permanece em segredo do servidor; o navegador recebe somente os campos necessários. Consultar o histórico do lead sob demanda, com paginação e cache curto, respeitando o limite documentado de **60 requisições por minuto por rota** e o cabeçalho `Retry-After`.
3. Unir essa resposta aos registros locais de sincronização, importação e revisão. Para mudanças detectadas entre coletas, guardar diffs de campos permitidos (por exemplo, nome, região, data de liberação, pipeline e influenciador) em um log imutável. Não copiar telefone, CPF, comentários livres ou todo o payload do CRM para esse log.
4. Validar com alguns leads reais quais tipos de evento o endpoint de histórico retorna. A documentação mostra `type`, `createdAt`, `history` e `attendant`, mas não garante que toda edição de campo venha com o autor e valores anterior/novo. Só depois dessa validação definir quais eventos podem ser apresentados como “quem editou”.
5. Aplicar RLS e RPCs administrativas apenas no schema do produto. O influenciador continua vendo somente seus indicados; o histórico completo do CRM não deve ser exposto a ele por padrão.

## Ordem recomendada

1. Salvar o vínculo durável com o CRM e conferir casos de UUID duplicado.
2. Criar a ficha do entregador com os dados já publicados e o cruzamento da Performance.
3. Integrar histórico do lead sob demanda e agrupar com os eventos locais.
4. Adicionar diffs entre sincronizações para campos da campanha; medir volume e política de retenção antes de ampliar o log.

Referências oficiais: [histórico do lead](https://docs.datacrazy.io/api-reference/hist%C3%B3rico-do-lead/buscar-hist%C3%B3rico-do-lead), [lead por ID](https://docs.datacrazy.io/api-reference/leads/buscar-lead-por-id), [atividades do lead](https://docs.datacrazy.io/api-reference/atividades-do-lead/buscar-as-atividades-do-lead), [limites da API](https://docs.datacrazy.io/essencials/rate-limit).
