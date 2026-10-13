---
name: Indique e Ganhe
description: Painel de indicações, corridas e prêmios
colors:
  primary: "#2d70b8"
  primary-hover: "#205b9e"
  primary-deep: "#103b70"
  sidebar-ink: "#eaf3ff"
  amber: "#e7ac45"
  canvas: "#f3f5f7"
  paper: "#ffffff"
  heading: "#17304b"
  ink-strong: "#25445f"
  ink-mid: "#48627c"
  muted-ink: "#526b83"
  border: "#d9e2eb"
  border-subtle: "#e3e9ef"
  brand-soft: "#e8f1fa"
  surface-subtle: "#f6f8fa"
  progress-track: "#dce8f3"
  progress-fill: "#2d70b8"
  status-success: "#267353"
  status-success-surface: "#eaf2fc"
  status-warning: "#76531d"
  status-warning-surface: "#fff5e3"
  status-danger: "#a94b37"
  status-danger-surface: "#fff3ef"
  canvas-dark: "#0e1825"
  paper-dark: "#182636"
  surface-dark: "#203246"
  border-dark: "#34495e"
  ink-dark: "#edf4fb"
  muted-ink-dark: "#adbed0"
  primary-dark: "#397dc4"
  accent-dark: "#91bcf2"
typography:
  headline:
    fontFamily: "Aptos, Segoe UI, Arial, sans-serif"
    fontSize: "clamp(1.75rem, 6vw, 2.125rem)"
    fontWeight: 730
    lineHeight: 1.14
    letterSpacing: "-0.03em"
  body:
    fontFamily: "Aptos, Segoe UI, Arial, sans-serif"
    fontSize: "1rem"
    fontWeight: 450
    lineHeight: 1.5
  label:
    fontFamily: "Aptos, Segoe UI, Arial, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 650
    lineHeight: 1.4
rounded:
  control: "8px"
  surface: "11px"
  meter: "999px"
spacing:
  compact: "8px"
  regular: "16px"
  section: "24px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.paper}"
    rounded: "{rounded.control}"
    height: "52px"
  admin-sidebar:
    backgroundColor: "{colors.primary-deep}"
    textColor: "{colors.sidebar-ink}"
  portal-panel:
    backgroundColor: "{colors.paper}"
    rounded: "{rounded.surface}"
  route-meter:
    backgroundColor: "{colors.progress-track}"
    rounded: "{rounded.meter}"
---

# Design System: Indique e Ganhe

## Overview

**Direção criativa: “Rotas em pauta”.** O portal se comporta como um quadro operacional: cada faixa permite reconhecer responsável, situação, corridas e próximo passo sem percorrer cartões repetidos. A composição é precisa e calma, com densidade suficiente para consultar muitos entregadores.

O azul mantém a identidade EntreGO; o âmbar pontua o que pede atenção. Os dados reais, as permissões, os fluxos de sincronização e os estados de pagamento determinam o conteúdo. O desenho não promete acompanhamento em tempo real.

**Características:** faixas horizontais de progresso, agrupamentos claros, números alinhados, navegação lateral estável e detalhes secundários sob demanda.

## Colors

O azul profundo ancora a navegação e títulos; o azul de ação marca controles e progresso; o canvas frio separa os painéis. O âmbar é reservado a marcos, revisões e pagamentos pendentes. Sucesso e erro têm cores próprias e nunca dependem apenas da cor para comunicar estado.

**Regra da atenção.** O âmbar sinaliza uma ação ou um marco real; não é preenchimento decorativo. Uma tela pode ter vários valores, mas apenas uma ação principal visualmente dominante.

No tema escuro, canvas, superfícies e bordas usam a mesma hierarquia com tokens escuros. Texto, foco e estados conservam contraste legível.

## Typography

Aptos, Segoe UI e Arial formam a pilha do produto. Títulos são curtos e escaneáveis; nomes dos entregadores têm peso forte; números de corridas, metas e valores usam algarismos tabulares. Rótulos de ação usam linguagem direta em português.

**Regra do número útil.** Cada número vem com seu significado: “24 de 30 corridas”, “faltam 6” ou “R$ 50 liberados”.

## Layout

No desktop, a administração tem barra lateral fixa e recolhível, dividida em Acompanhar, Fontes de dados e Administrar. A visão geral começa pelo quadro de operações e depois apresenta contexto e totais. A guia de indicados começa pelas situações Em progresso, A pagar e Pagos, seguida de métricas, busca e filtros por influenciador. Listas longas usam faixas compactas com separadores, não cartões altos repetidos.

A entrada segue a mesma moldura do portal: no desktop, usa uma faixa de marca azul estreita com largura próxima à navegação lateral e um formulário centralizado no canvas claro. Em telas pequenas, a faixa vira uma marca acima do formulário; não há uma segunda metade da tela com chamada de marketing.

No painel do influenciador, o progresso dos indicados aparece antes dos totais no celular. Cada faixa reúne nome, localidade, corridas acumuladas, meta, restante e prêmio. Contato, CPF e identificadores ficam em detalhes expansíveis conforme a permissão da conta. Em telas estreitas, a navegação vira menu móvel e as faixas se reorganizam sem rolagem horizontal obrigatória. Controles de decisão mantêm alvo de toque de ao menos 44 px.

**Regra da primeira dobra.** A pessoa identifica seu trabalho imediato e entra na lista principal sem atravessar uma parede de métricas.

## Elevation & Depth

A hierarquia vem principalmente de cor de fundo, bordas finas e espaçamento. A tela de entrada pode usar sombra suave para separar o formulário; listas operacionais permanecem planas. Evitar cartões dentro de cartões e sombras em cada linha de indicado.

## Shapes

Controles são discretamente arredondados, superfícies têm cantos moderados e medidores são arredondados para mostrar preenchimento. Pílulas de estado podem ser compactas, mas o texto do estado permanece visível. A geometria das faixas cria ritmo horizontal estável.

## Components

- **Faixa de indicado:** nome e região à esquerda; progresso, quantidade e situação juntos; ações e detalhes somente quando relevantes. A versão administrativa expõe transferência e registro/reabertura de pagamento quando permitidos.
- **Medidor de rotas:** preenchimento azul com valores explícitos e semântica de progresso acessível. Não usar cor como única indicação de conclusão.
- **Guias de situação:** Em progresso, A pagar e Pagos exibem contagens e estado selecionado perceptível ao teclado e ao toque.
- **Resumo operacional:** revisões e fontes de dados têm caminho direto para a ação. Totais ficam agrupados e não competem com essas tarefas.
- **Fontes e histórico:** Data Crazy e Performance apresentam origem, período dos dados quando disponível, última operação, andamento e erro de forma legível. Sincronização completa mantém confirmação; a prévia de Performance mostra dados interpretados antes da soma.
- **Barra lateral:** permanece fixa no desktop, recolhe sem perder nomes acessíveis e preserva a seção ativa. Perfil abre pelo avatar; o menu móvel oferece os mesmos destinos.
- **Estados vazios e falhas:** explicar se faltam dados, filtros não encontram registros ou houve erro de carregamento; oferecer a ação correspondente quando existir.

Movimento é breve e funcional. O medidor pode transicionar em 280 ms e a navegação entrar discretamente; `prefers-reduced-motion` remove deslocamentos e animações não essenciais.

## Do's and Don'ts

- **Do** manter corridas, meta, restante e prêmio próximos do nome do entregador.
- **Do** diferenciar sincronização da Data Crazy e importação acumulativa de Performance com textos e estados reais.
- **Do** manter foco visível, estados anunciáveis e contraste adequado nos temas claro e escuro.
- **Don't** inventar dados, eventos, taxas de cobertura ou sensação de atualização ao vivo.
- **Don't** usar cartões repetidos, ícones decorativos ou âmbar sem uma ação ou marco correspondente.
