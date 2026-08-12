# ADR 0004 — Implementando hinting TrueType no núcleo

**Status:** aceito (reverte ADR 0003)
**Data:** 12 de agosto de 2026

## Contexto

O ADR 0003 documentou a decisão de descartar as instruções TrueType (`glyf.dart` lendo e pulando o bytecode) e não implementar o interpretador de hinting, optando por um pipeline mais simples focado em posicionamento subpixel, correção de gama e stem darkening.

No entanto, implementações puras e testes focados indicaram a necessidade ou desejo de testar a viabilidade de uma VM TrueType nativa 100% em Dart puro, de forma a preservar o design original das fontes para tamanhos de tela muito pequenos (onde o pixel snapping é estritamente necessário para nitidez extrema em telas de 1x de densidade). 

## Decisão

**O núcleo irá implementar o interpretador de bytecode TrueType.** 
Para isso, será construída a VM (Virtual Machine) baseada na semântica implementada pelo interpretador original do FreeType (`ttinterp.c`). 

A integração inclui:
1. Extração do bytecode das tabelas `glyf`.
2. Criação dos **phantom points** (pontos fantasmas adicionados ao final do contorno) para que o programa da fonte possa redefinir a largura de avanço e métricas laterais originais.
3. Leitura e processamento das tabelas `fpgm` (Font Program), `prep` (Control Value Program), `cvt ` (Control Value Table) e atributos estendidos da `maxp`.
4. Uma classe `TrueTypeInterpreter` que executa as instruções, mantendo um estado gráfico compatível.

## Consequências positivas

- O texto em telas de baixa densidade (1x) recuperará a nitidez total esperada pelos designers da fonte (pixel perfection).
- Mantemos a independência de bibliotecas C/C++ (`FreeType`), mas sem a perda da capacidade de ler as complexidades do TrueType.
- Compatibilidade absoluta com golden tests baseados no GDI do Windows se o renderizador for alinhado a subpixels e grid-fitting.

## Consequências negativas

- **Complexidade:** A manutenção aumenta drasticamente. O interpretador original tem cerca de 8.000 linhas de código altamente complexo (gerenciamento manual de pilhas, zonas crepusculares, aritmética de ponto fixo).
- **Desempenho:** Executar o bytecode fonte por glifo, por tamanho, penalizará o tempo de carregamento e inicialização das fontes.
- Superfície de ataque: Executar bytecode não confiável demanda verificações estritas nos limites das arrays de estado e pilhas para evitar falhas ou negação de serviço.
