# ADR 0007 — Contorno transformado, em vez de bitmap, para texto não alinhado

**Status:** aceito
**Data:** 23 de agosto de 2026
**Relacionados:** ADR 0002 (transform 2D afim), ADR 0003 e ADR 0004 (hinting)

## Contexto

Os dois rasterizadores do framework desenhavam texto do mesmo jeito: uma
máscara de cobertura de 8 bits por (face, tamanho quantizado, glifo, bucket
subpixel), blitada em pixel inteiro. Na CPU a máscara vem de `GlyphCache`; na
GPU, do `GpuGlyphAtlas`, que usa deliberadamente a mesma chave.

Uma máscara é um retângulo de pixels. Ela só pode ser **movida** por um número
inteiro de pixels — não girada, não inclinada, não espelhada, e não esticada
sem reamostrar uma borda que já é antialiasada. Por isso os dois sinks
recusavam por nome, em `_deviceFont`, qualquer matriz com `b != 0`, `c != 0`,
`a <= 0`, `d <= 0` ou `a != d`:

> text under a rotated, skewed, mirrored or non-uniformly scaled transform is
> not implemented

A recusa era honesta — melhor que desenhar texto em pé sob uma matriz girada,
que é uma imagem errada com cara de deliberada — mas custava caro:

1. **`CollapsedTabStrip` empilhava caracteres.** O arquivo dizia isso no
   cabeçalho: um rótulo girado desenharia num backend de GPU e lançaria exceção
   no de software, então a tira empilhava `T`, `r`, `a`, `n`… um caractere por
   linha. Empilhar perde todo par de kerning e toda ligadura, e uma palavra
   composta assim é mensuravelmente mais lenta de ler que a mesma palavra
   girada.
2. **Nenhum objeto de texto podia ser girado no documento vetorial.** Um editor
   que não gira texto não é um editor vetorial.
3. **O pior tipo de divergência entre backends.** Uma cena que desenha num
   renderizador e lança exceção no outro não se parece com uma diferença de
   rendering: parece um bug de aplicação, e só aparece na máquina de quem não
   tem GPU.

## Decisão

**Quando uma máscara em cache não serve, o glifo é preenchido a partir do seu
contorno, sob a matriz completa, pelo mesmo `ScanlineFiller` que preenche
qualquer caminho.** A recusa deixa de existir nos dois lados.

O critério é uma única função, `glyphMasksFit`, em
`lib/src/rendering/text/glyph_raster.dart`, importada pelos dois sinks. Ela é
deliberadamente conservadora — tudo que ela rejeita é desenhado corretamente
pelo caminho geral, então um falso negativo custa tempo e um falso positivo
custaria a imagem — e a comparação `a == d` é **exata**: não existe epsilon
correto a 8px e a 200px ao mesmo tempo.

A matriz do caminho geral é `glyphOutlineTransform`, no mesmo arquivo: unidades
de fonte → pixels com y invertido, depois a parte linear da transform do
dispositivo, depois a caneta como translação. Sob uma matriz que `glyphMasksFit`
aceita ela se reduz exatamente à matriz que `GlyphRasterizer.render` constrói,
o que faz os dois caminhos concordarem na fronteira por construção e não por
coincidência — importante porque uma escala animada cruza essa fronteira.

Na GPU o caminho geral **não** é o atlas de glifos: é o `GpuMaskAtlas`, o mesmo
por onde passa um `drawPath`. E o atlas de máscara roda esse mesmo
`ScanlineFiller` na CPU e sobe a cobertura — é por isso que a paridade medida
entre CPU e GPU para texto girado é **desvio 0**, e não uma tolerância.

### Por que não reamostrar a máscara

Girar um bitmap já rasterizado significa reamostrar uma borda antialiasada. O
resultado é o texto mole e borrado que dá fama aos caches de bitmap de fonte,
visivelmente pior a 45° que a 0° — um artefato de rendering disfarçado de
problema de fonte. Rasterizar o contorno na matriz de destino é a razão de o
contorno ter sido guardado.

### Por que o caminho rápido continua existindo

Porque ele é o caminho comum: todo rótulo, todo item de menu, toda linha de
lista, em todo quadro. Um preenchimento de caminho por glifo custa cerca de
2,4x um blit por glifo neste framework — 5,5 ms contra 2,3 ms para 2160 glifos
de DejaVu 14px numa superfície de 480x760, com cache quente — e trocar o caso
dominante por isso para ganhar uniformidade seria pagar a conta errada.

O caso alinhado **não regrediu**: mediana de 2,32–2,35 ms antes da mudança e
2,31–2,37 ms depois, p05 de 2,09 ms nos dois. Os dois casos ficaram versionados
em `benchmark/text_benchmark.dart` como `draw a line, upright` e `draw a line,
rotated`, com orçamentos folgados pela política daquele arquivo.

### O que é cacheado, e o que não é

- **O contorno é cacheado**, pela própria `Typeface`, com chave só de glifo: é
  a forma de design e não depende da matriz. Uma animação de rotação decodifica
  cada glifo uma vez, para sempre. `ScanlineFiller.fill` aplica a matriz durante
  o achatamento, então nem uma cópia transformada do contorno é alocada.
- **O resultado rasterizado não é cacheado**, e isso é decisão, não omissão:
  ele é função da matriz inteira e da fração da caneta. Uma chave sobre isso
  erraria em todo quadro que não fosse repetição exata, e ainda cobraria a
  chave em todos eles.
- **Nada é admitido no cache de glifos nem no atlas de glifos** por um run
  girado. A chave deles não tem onde guardar um ângulo, e uma entrada feita ali
  seria entregue depois a um chamador em pé. Há teste para isso nos dois lados.

## Hinting: desligado sob rotação, e por quê

O ADR 0004 reverteu o ADR 0003 e pôs um interpretador de bytecode TrueType no
núcleo. Este ADR diz **onde ele pode rodar**.

Hinting é um programa que move pontos de controle para cima da grade de
*pixels*. Ele é escrito nos eixos do próprio glifo e assume que esses eixos são
os da tela. Sob rotação eles não são: alinhar uma haste à grade passa a
alinhá-la a uma linha que os pixels não percorrem, e o resultado é pior que
nenhum hinting — hastes de peso visivelmente desigual ao longo de uma linha de
base girada, mudando enquanto o ângulo anima. Toda engine que faz hinting o
desliga assim que a matriz deixa de ser reta.

Concretamente:

- o caminho da máscara chama `Typeface.outlineOf(glifo, ppem)` — e é o único
  lugar do framework que passa um ppem;
- o caminho do contorno chama `Typeface.outlineOf(glifo)`, sem ppem, o que
  entrega o contorno de design;
- `Typeface.shouldHint` continua limitando hinting a `ppem <= 24`, pela razão
  que já estava lá: acima disso alinhar hastes à grade não muda nada visível.

Custo aceito: para tamanhos pequenos e alinhados, o contorno passa a ser
guardado por (glifo, ppem) em vez de só por glifo, limitado a
`_maxHintedOutlines`. É o preço de a política estar correta no dia em que o
interpretador de fato mover pontos.

## Consequências

**Positivas**

- Software e GPU produzem o mesmo resultado para texto sob qualquer transform
  2D afim, com paridade medida de desvio 0 em rotação de 90°, 45°, espelhamento
  e escala não uniforme (`test/rendering/gpu/gl_glyph_device_test.dart`).
- **Nenhum backend recusa mais essas matrizes.** O Direct2D passou a preencher
  o contorno do glifo com `FillGeometry`, e a divergência que este ADR tinha
  deixado aberta nele — desenha na CPU e no OpenGL, lança exceção no Direct2D
  — acabou. A paridade dele contra a CPU está medida em
  `test/backends/win32/d2d/d2d_glyph_transform_test.dart`, com tolerência
  declarada e não com desvio 0; a razão está nas consequências negativas.
- Texto e caminho passam a compartilhar cobertura analítica, regra de
  preenchimento e span sink. Uma letra girada e um caminho girado ao lado dela
  antialiasam igual porque *são* o mesmo código — asserido em
  `test/rendering/text/text_rendering_test.dart`, desvio 0.
- `CollapsedTabStrip` gira o rótulo de verdade, como no sK1 — um único run
  moldado, com kerning, em vez de uma pilha de caracteres.
- O renderizador deixou de ser o motivo pelo qual um objeto de texto não pode
  ser rotacionado no documento vetorial. Ligar isso no editor é trabalho da
  camada de cima e não foi feito aqui.

**Negativas**

- Um preenchimento de caminho por glifo por quadro no caminho geral, sem cache
  entre quadros além do contorno. Texto girado é um rótulo de eixo de gráfico
  ou uma aba recolhida, não um parágrafo; se um dia for um parágrafo, a
  resposta é um cache de máscara com a matriz na chave, não reamostrar bitmap.
- Duas rotas para a mesma operação, com a fronteira entre elas dependendo de
  uma comparação exata de ponto flutuante. Mitigado por `glyphMasksFit` ser uma
  função única importada pelos dois sinks, e por um teste que verifica que as
  duas rotas coincidem na fronteira.
- Texto com stroke continua recusado nos três lados. O contorno agora existe no
  caminho geral e tornaria isso possível; não foi feito nesta mudança, e a
  recusa segue simétrica entre CPU, GPU e Direct2D.
- O sink Direct2D toma a rota de contorno com `FillGeometry` sobre um
  `ID2D1PathGeometry` por glifo, e não com o `ScanlineFiller`. O critério e a
  matriz são as mesmas duas funções compartilhadas — então os três backends
  sempre concordam sobre *qual* run vai por *qual* rota e sobre onde cada
  glifo cai —, mas a cobertura embaixo é o rasterizador analítico do
  `d2d1.dll`. Por isso a paridade medida contra a CPU ali é uma tolerância
  declarada em bordas antialiasadas e **não** o desvio 0 de CPU contra OpenGL,
  que compartilham uma implementação de cobertura. Medido em
  `test/backends/win32/d2d/d2d_glyph_transform_test.dart`: desvio máximo por
  canal de 53 níveis (giro de 45°), sobre no máximo 6,7% da superfície
  (espelhamento); o caso alinhado, que continua blitando as máscaras do mesmo
  `GlyphCache` da CPU, dá desvio 0.
