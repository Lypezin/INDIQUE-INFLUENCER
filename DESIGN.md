---
name: Indique e Ganhe
description: Consulta de indicações, corridas e prêmios
colors:
  primary: "#185aa9"
  primary-deep: "#123f78"
  ink: "#172a40"
  muted-ink: "#60758b"
  canvas: "#f6f8fc"
  paper: "#ffffff"
  border: "#dfe6f0"
  progress-track: "#e8eef7"
  progress-fill: "#2f6fc2"
  canvas-dark: "#0c1420"
  paper-dark: "#141e2b"
  surface-dark: "#1a2737"
  border-dark: "#2b3a4d"
  ink-dark: "#dce6f2"
  muted-ink-dark: "#a9bbce"
  text-muted-dark: "#c3d1e0"
  primary-dark: "#185aa9"
  accent-dark: "#91bcf2"
  success-dark: "#8edbb5"
  danger-dark: "#f2a89b"
  input-dark: "#34455a"
  input-focus-dark: "#1c3e65"
  accent-surface-dark: "#1a2c40"
  danger-surface-dark: "#38231f"
typography:
  headline:
    fontFamily: "Aptos, Segoe UI, Arial, sans-serif"
    fontSize: "clamp(1.75rem, 6vw, 2.15rem)"
    fontWeight: 730
    lineHeight: 1.14
    letterSpacing: "-0.03em"
  body:
    fontFamily: "Aptos, Segoe UI, Arial, sans-serif"
    fontSize: "1rem"
    fontWeight: 450
    lineHeight: 1.5
rounded:
  control: "8px"
  surface: "12px"
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
---

# Design System: Indique e Ganhe

## Overview

Um painel de trabalho para consultar o avanço de entregadores indicados. O azul identifica ações e progresso; a informação vem antes da decoração.

## Colors

O azul escuro organiza a área de entrada, o azul médio marca ações e barras de progresso, e o fundo quase branco mantém listas longas legíveis. Âmbar fica reservado a avisos e revisão.

## Typography

Títulos curtos e diretos. Números de corridas, metas e valores usam algarismos tabulares. Rótulos e instruções mantêm tamanho legível em telas pequenas.

## Layout

No celular, o progresso dos entregadores aparece antes dos totais. Campos e ações têm alvo de toque de pelo menos 44 px. A lista revela dados pessoais somente ao expandir uma linha. No desktop, a administração usa navegação lateral e painéis mais largos.

## Elevation & Depth

Divisórias finas separam linhas e seções. Sombras leves aparecem sobretudo na tela de entrada; listas de dados permanecem planas.

## Shapes

Controles usam 8 px; seções e superfícies usam aproximadamente 12 px. Barras de progresso são arredondadas apenas para comunicar preenchimento.

## Components

Botões primários são azuis com texto branco; foco visível usa contorno azul. Campos são brancos com borda azul acinzentada e foco mais forte. Cartões de entregador colocam nome, região e corridas antes do estado do prêmio.

## Do's and Don'ts

- **Do** apresentar corridas, meta, corridas restantes e valor do prêmio perto de cada entregador.
- **Do** avisar que os dados mudam por importação, sem prometer tempo real.
- **Don't** usar ícones decorativos, frases promocionais vagas ou cartões aninhados para preencher espaço.
