# ADR 0003 — Hinting TrueType: proposta de omitir, revertida

**Status:** **revertido** — a proposta abaixo foi feita e recusada no mesmo dia
**Data da proposta:** 12 de agosto de 2026
**Data da reversão:** 12 de agosto de 2026

> **Leia isto antes do resto.** Este ADR foi escrito propondo *não* implementar
> hinting. A decisão do projeto foi a oposta: o interpretador de bytecode
> TrueType está sendo implementado em `lib/src/text/truetype/`. O texto original
> fica preservado abaixo porque o raciocínio ainda descreve corretamente o custo
> — e porque um ADR que muda de ideia sem deixar rastro é pior do que um ADR
> errado.

## O que muda por causa da reversão

A consequência que **não** é opcional: a proposta original dizia que os
**phantom points podiam ser ignorados**, e isso valia *apenas* enquanto não
houvesse interpretador. Com interpretador, eles voltam a ser obrigatórios,
porque existem precisamente para que o programa da fonte possa mover a largura
de avanço.

Três implicações concretas, que atravessam camadas:

1. **A largura de avanço deixa de vir só de `hmtx`.** Depois de rodar o
   programa do glifo, o avanço é a distância entre os phantom points 1 e 2,
   que o próprio programa pode ter deslocado. `ScaledTypeface.advanceOf` e o
   kerning em `LatinShaper` consultam `hmtx` diretamente; com hinting ligado
   eles precisam consultar o avanço *hinted*, ou o texto fica medido de um
   jeito e desenhado de outro.
2. **O cache de glifos passa a depender do tamanho de forma não linear.** Sem
   hinting, um glifo a 32px é o mesmo contorno de 16px escalado; com hinting
   não é, porque o programa recebe o ppem e decide diferente. A chave do cache
   em `lib/src/rendering/text/glyph_cache.dart` já inclui o tamanho, então isso
   está coberto — mas qualquer otimização futura que assuma escalabilidade
   linear passa a estar errada.
3. **O golden test deixa de ser trivialmente portátil.** Sem hinting o
   resultado é idêntico em toda plataforma por construção. Com hinting ele
   continua determinístico — é o mesmo interpretador em Dart — mas passa a
   depender da versão do interpretador, e é isso que os modos v35/v38/v40 do
   FreeType existem para gerenciar.

Segurança continua valendo o que valia: o interpretador executa programas de
fontes não confiáveis, e a seção 30.8 pede resistência a entrada malformada.
Limite de pilha, limite de contador de programa, limite de profundidade de
chamada e limite de laço não são refinamentos, são requisitos.

---

## Texto original da proposta (recusada)

### Contexto

A seção 30 do roteiro pede um pipeline de texto próprio, sem FreeType nem
HarfBuzz em runtime. Ao implementar o parser OpenType apareceu a pergunta que
decide o tamanho do resto da fase: implementar ou não o interpretador de
bytecode TrueType.

Hinting é o mecanismo pelo qual uma fonte carrega um programa que reposiciona
os pontos do contorno de acordo com o tamanho em pixels, para alinhar hastes à
grade e manter o texto nítido em telas de baixa densidade. O custo levantado
foi: o interpretador em si (no FreeType, uma máquina de pilha com cerca de cem
opcodes e cerca de oito mil linhas — o maior componente isolado daquele
projeto), o estado gráfico e a CVT, os três modos de compatibilidade de versão
que existem porque fontes reais dependem de bugs de versões específicas, os
phantom points, e executar tudo isso em Dart, por glifo, por tamanho.

O argumento contextual foi que telas de 1,5x ou mais são o caso comum, que o
macOS nunca fez hinting, que o Skia o desabilita por padrão na maioria das
configurações e que o Flutter entrega sem hinting em todas as plataformas.

### Proposta

Não implementar hinting, e obter qualidade em tamanhos pequenos por outros
quatro caminhos: antialiasing analítico exato (que já existe em
`ScanlineFiller`), posicionamento subpixel horizontal quantizado em quartos de
pixel, correção de gama aplicada à cobertura antes da composição, e stem
darkening opcional em tamanhos pequenos.

### Por que foi recusada

Um framework profissional que se propõe a substituir toolkits nativos no
Windows é julgado contra o que o Windows entrega, e o que o Windows entrega tem
hinting. Os quatro paliativos acima melhoram a aparência mas não produzem
alinhamento de haste à grade, que é o que faz texto pequeno em 1x parecer
nítido em vez de macio.

As três alternativas ao hinting continuam válidas e devem ser implementadas de
qualquer forma — elas são ortogonais, não substitutas.
