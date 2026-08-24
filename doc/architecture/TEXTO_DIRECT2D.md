# Texto no Direct2D: o que custa, o que foi trocado e onde a DirectWrite entra

**Data da medição:** 24 de agosto de 2026.
**Máquina:** Windows 11 Pro build 26200, x64.
**Como reproduzir:**

```
DART_UI_GPU_BENCHMARK=1 dart test test/backends/win32/d2d/d2d_text_cost_test.dart -j 1
```

Todos os números abaixo saem desse arquivo. Ele imprime, não falha em limiar —
a mesma regra que `gl_vector_cost_test.dart` e `d3d12_vector_cost_test.dart` já
seguem, porque limiar de duração em máquina compartilhada é ou instável ou
inútil. Mediana de 21 quadros, 5 de aquecimento.

## Resumo em três frases

1. O gargalo **não era o número de chamadas**. Era **trocar de bitmap a cada
   chamada**: dois terços do custo por glifo.
2. Um atlas único + `ID2D1SpriteBatch` deixou o texto do Direct2D **4 a 5×
   mais rápido**, à frente do renderizador de CPU e no mesmo patamar do
   caminho OpenGL, **com desvio 0 de paridade preservado**.
3. Com isso **não sobra argumento de desempenho para a DirectWrite**. Ela
   passou a existir só como **opção explícita de aparência nativa do Windows**,
   desligada por padrão.

---

## 1. A hipótese, e por que ela estava só meio certa

`d2d_raster_sink.dart` fazia **uma `FillOpacityMask` por glifo**, cada uma
lendo o bitmap daquele glifo. As máscaras já eram cacheadas por
(face, tamanho quantizado, glifo, bucket subpixel), então nada era
rasterizado por quadro — pagava-se uma *chamada* por caractere.

A hipótese a testar era "o gargalo é o número de chamadas". A medição separa as
duas variáveis que a hipótese confundia.

### 1.1 O custo fixo de uma chamada, isolado

512×512, a mesma área coberta nos dois casos:

| forma | tempo |
| --- | --- |
| 1024 chamadas de 16×16 | 1,40 – 2,92 ms |
| 1 chamada de 512×512 | 1,04 – 2,06 ms |

A diferença dividida por 1024 dá **≈ 0,3 a 0,8 µs de custo fixo por chamada** —
real, mas pequeno demais para explicar 1,1 a 1,4 µs por glifo de 13 px, cuja
máscara tem ~90 pixels.

### 1.2 As três formas possíveis, lado a lado

3400 quads do tamanho de um glifo (12×16) sobre 1280×720, mesmos alvos, mesma
corrida:

| forma | tempo | por quad |
| --- | --- | --- |
| uma `FillOpacityMask` por quad, **bitmap próprio** | 12,1 – 16,6 ms | 3,56 – 4,87 µs |
| uma `FillOpacityMask` por quad, **um atlas** | 5,36 – 8,04 ms | 1,58 – 2,36 µs |
| **uma `DrawSpriteBatch`** sobre o atlas | 4,50 – 5,57 ms | — |

**O atlas sozinho corta ~2,2×. O lote em cima disso corta mais ~15%.** A
hipótese estava certa na direção e errada na causa: o caro era o *rebind de
bitmap*, não a contagem de chamadas.

---

## 2. A rota escolhida, e por quê

**Atlas próprio + `ID2D1SpriteBatch`**, com degradação para o laço de
`FillOpacityMask` sobre o mesmo atlas.

O enunciado da tarefa apresentava as duas rotas como alternativas. **Elas não
são**: `DrawSpriteBatch` desenha de **exatamente um** bitmap, então a rota do
sprite batch *exige* o atlas de qualquer jeito. A escolha real era "atlas com
lote" contra "atlas sem lote", e a medição acima decide: as duas valem a pena,
na ordem em que valem.

Quatro razões, em ordem de peso:

1. **A medição.** O atlas é o que muda o patamar; o lote é o bônus barato em
   cima dele.
2. **`ID2D1DeviceContext3` está disponível sem trocar o alvo.** Era a dúvida
   aberta da tarefa: os alvos deste backend são criados por construtores
   Direct2D 1.0 (`CreateDCRenderTarget`, `CreateHwndRenderTarget`), mas o
   objeto por trás deles responde `QueryInterface` para toda a cadeia.
   `d2d_device_context_probe_test.dart` pergunta ao runtime e imprime a
   resposta; nesta máquina:

   ```
   ID2D1DCRenderTarget QueryInterface:
     ID2D1DeviceContext   yes
     ID2D1DeviceContext1  yes
     ID2D1DeviceContext2  yes
     ID2D1DeviceContext3  yes
     ID2D1DeviceContext4  yes
   ```

   **Nada precisou mudar em `d2d_targets.dart`.** Se um dia a resposta for
   "no" — um `d2d1.dll` anterior ao sprite batch — o sink cai no laço de
   `FillOpacityMask` sobre o mesmo atlas, que ainda é 2,2× melhor que o
   estado anterior.
3. **Não aumenta a divergência de pixel.** Era o critério de desempate
   declarado. `DrawSpriteBatch` compõe sprite a sprite, em ordem, com o mesmo
   `source-over` de antes: cada glifo continua sendo um blit de máscara
   independente. A alternativa de "compor o run inteiro numa máscara e emitir
   um `FillOpacityMask`" mudaria a aritmética onde dois glifos se sobrepõem
   (dois `over` de 8 bits contra um), o que é justamente o tipo de diferença
   que a tolerância não deve absorver.
4. **A degradação é o mesmo código.** As duas rotas montam os mesmos quads
   sobre os mesmos texels; só a emissão difere.

### 2.1 O que foi construído

- `d2d_glyph_atlas.dart` — um `ID2D1Bitmap` de 1024×1024 BGRA (4 MB de vídeo,
  4 MB de cópia de sistema para subir região suja), empacotado com o
  `ShelfGlyphPacker` **importado** de `gpu_glyph_atlas.dart`, não reescrito.
  Chave idêntica à do `GlyphCache`. Despejo por atacado quando o packer lota,
  como já é a política dos outros caches deste sink.
- `D2dDeviceContext3`, `D2dSpriteBatch` e `D2dBitmap` em `d2d1_interfaces.dart`,
  com a aritmética de slot escrita método a método (`CreateSpriteBatch` 106,
  `DrawSpriteBatch` 107, `CopyFromMemory` 10).
- Um caminho de escape para tipo grande demais para o atlas: bitmap próprio,
  que é exatamente a rota antiga, mantida para o caso que ainda precisa dela.

### 2.2 A regra de ordenação que o atlas carrega

Direct2D acumula comandos até `Flush`/`EndDraw`, e um comando acumulado lê o
atlas **como ele estiver quando o lote rodar**. Então:

- antes de subir texels novos que algo já desenhado neste quadro amostra, o
  sink dá `Flush`;
- antes de esvaziar o atlas, idem;
- o `ID2D1SpriteBatch` é preenchido pelo quadro inteiro e só é limpo **depois**
  do `EndDraw` — o `startIndex` de `DrawSpriteBatch` existe exatamente para
  isso.

---

## 3. Os números finais

`text` = quadro completo − quadro só com `Clear`, ambos medianas de 21 quadros.

### Tela cheia de texto — 6800 glifos, 13 px, 1280×720

| caminho | texto |
| --- | --- |
| **D2D antes** (uma máscara por glifo, um bitmap por glifo) | **7,58 – 9,64 ms** |
| D2D, atlas + laço de `FillOpacityMask` | 2,57 – 3,15 ms |
| **D2D, atlas + `DrawSpriteBatch`** | **1,31 – 2,16 ms** |
| renderizador de CPU | 4,92 – 6,26 ms |
| OpenGL | 1,29 – 3,91 ms |

Por glifo: **1,11 – 1,42 µs antes**, **0,19 – 0,32 µs depois**.

### Parágrafo de interface — 620 glifos, 14 px, 512×256

| caminho | texto |
| --- | --- |
| **D2D antes** | **0,78 – 1,27 ms** |
| D2D, atlas + laço | 0,80 – 0,99 ms |
| **D2D, atlas + lote** | **0,19 – 0,52 ms** |
| CPU | 0,58 – 1,37 ms |
| OpenGL | 0,34 – 0,89 ms |

### Texto grande — 8 glifos, 96 px, 768×160

Abaixo do piso de ruído do relógio em todos os caminhos (≤ 0,3 ms), antes e
depois. **Não é o caso de que a mudança trata**, e está aqui para dizer isso:
poucos glifos grandes nunca foram o problema, e por isso o escape de "grande
demais para o atlas" pode continuar pagando uma chamada por glifo sem custo
mensurável.

### Preparação contra desenho

O arquivo separa três quadros por cena — só `Clear`; a mesma display list com
tinta transparente (o sink retorna antes de tocar em glifo, então isso mede o
caminhar do player e a decodificação da lista); e a cena real. A diferença
entre o segundo e o terceiro é o que o texto custa com as máscaras residentes,
e é o número das tabelas acima. O caminhar do player fica em ±0,1 ms nas três
cenas — ruído, não custo.

O **primeiro quadro** (rasterizar + subir todas as máscaras) fica entre 9 e
25 ms conforme a cena; depois disso, zero rasterização e zero upload, o que é
o que o modelo de custo sempre afirmou e agora está medido.

---

## 4. Paridade: intacta, e agora afirmada como 0

`d2d_glyph_transform_test.dart` declarava as tolerâncias medidas — alinhado
desvio 0; rotacionado até 53 níveis em ≤10% dos pixels. Depois da mudança:

- **o caso alinhado continua em desvio 0**, e o teste deixou de aceitar
  qualquer tolerância nele: passou a asserir `0` explicitamente, com a razão
  escrita — no caminho de máscara o Direct2D está copiando a cobertura que o
  `ScanlineFiller` produziu, então ali não são dois rasterizadores, são um
  rasterizador e duas formas de copiar a saída dele. Qualquer coisa acima de 0
  significa que a cópia deixou de ser cópia;
- **as duas rotas concordam entre si em desvio 0**: um teste novo desenha o
  mesmo run com `DrawSpriteBatch` e com o laço de `FillOpacityMask` na mesma
  máquina e compara os pixels;
- as tolerâncias do caminho de contorno (rotação, cisalhamento, espelho,
  escala não uniforme) **não foram tocadas** — aquele caminho não passa pelo
  atlas;
- o escape de tipo grande demais também é **desvio 0** contra a CPU
  (`d2d_glyph_atlas_test.dart`).

Os contadores que o teste usa mudaram de nome com a coisa que contam:
`glyphAtlasEntryCount` para o atlas, `glyphBitmapCount` para o escape. Um run
rotacionado tem que deixar **os dois** em 0, pela mesma razão de antes: a chave
não tem onde guardar um ângulo.

---

## 5. DirectWrite: a conclusão

### 5.1 O lote fecha a diferença de desempenho? **Fecha.**

Era essa a pergunta a registrar. Depois do atlas e do lote, o texto do Direct2D
está **~4 a 5× mais rápido** que antes, **~3× mais rápido que o renderizador de
CPU** na mesma cena e **no mesmo patamar do caminho OpenGL** — que é o teto
prático deste framework hoje. Não existe, nos números, um déficit de desempenho
que a DirectWrite fosse consertar.

Some-se a isso o que já se sabia e não mudou:

- o framework é dono da pilha de texto (shaping, OpenType, hinting, contornos),
  e rasterizar com DWrite faria o mesmo documento render diferente por
  plataforma, quebrando a paridade que é promessa declarada do projeto;
- **sob rotação a DWrite também preenche contornos**, então lá não haveria
  ganho nenhum.

**Portanto: DirectWrite não é, e não deve virar, o caminho padrão.**

### 5.2 O único cenário que ainda a justifica

**Aparência nativa do Windows, como opção explícita do usuário da
biblioteca.** Um aplicativo que quer parecer um aplicativo do Windows quer o
hinting e o ClearType da Microsoft, e isso nenhum rasterizador portátil entrega
por definição. Esse é um pedido legítimo, é sobre gosto e não sobre velocidade,
e agora está implementado — **desligado por padrão**.

### 5.3 O que foi implementado: nível 1, e só

`RenderPolicy.glyphRasterization`, um `GlyphRasterization` de dois valores:

- `portable` (padrão): o rasterizador deste framework, em todo lugar;
- `platformNative`: o Direct2D entrega o run já resolvido para
  `ID2D1RenderTarget::DrawGlyphRun`.

**O que é delegado:** a cobertura dentro do glifo. Hinting da Microsoft e, onde
o alvo permitir, ClearType.

**O que não é delegado, e é o desenho todo da opção:** shaping, métricas,
quebra de linha e posicionamento. Cada glifo vai com `glyphAdvances[i] = 0` e um
`DWRITE_GLYPH_OFFSET` carregando o deslocamento que *nós* calculamos, então a
DirectWrite nunca avança caneta própria e nunca opina sobre onde uma letra fica.
`DWRITE_MEASURING_MODE_NATURAL` pelo mesmo motivo: os modos compatíveis com GDI
re-encaixam os avanços na grade pelas regras *deles*, que é exatamente a
substituição de métrica que essa forma existe para evitar.

Consequência prática, e é o argumento de venda do nível 1: **o layout continua
idêntico em todas as plataformas** — largura de widget, quebra de linha,
hit-test, seleção. Só os pixels dentro do glifo mudam. Está medido: o teste
compara a caixa de tinta das duas rotas e exige que os quatro lados fiquem
dentro de 2 px.

#### Como a fonte chega até a DWrite

Pelo nome de família, na coleção de fontes do sistema, e mais nada.
`dwrite_font_faces.dart` resolve `Typeface.familyName` → `IDWriteFontFace`
usando peso, largura e inclinação da própria OS/2 da fonte.

**Depois disso vem a verificação que segura tudo:** os índices de glifo têm que
coincidir. Nós shapeamos com o nosso motor sobre os nossos bytes; se o Windows
resolver "Segoe UI" para um arquivo cuja `cmap` ou cuja ordem de glifos difere —
outra versão, outra instância variável, uma fonte que o usuário trocou — o
glifo 42 nosso é o glifo 42 dele por coincidência, e o texto sai como **absurdo
corretamente espaçado**. É a falha silenciosa mais provável dessa integração,
então ela é *checada*: contagem de glifos igual, e `GetGlyphIndices` do Windows
igual ao nosso `glyphForCodePoint` numa amostra de 15 code points espalhados
por ASCII, Latin-1, pontuação, moeda e setas. Quem falha é **recusado por
nome** e o run cai na rota portátil. `dwrite_probe_test.dart` afirma os dois
lados: uma fonte instalada tem que ser aceita, uma não instalada tem que ser
recusada com uma razão que a nomeie.

Fonte empacotada pelo aplicativo: **não suportada**, por decisão de orçamento.
Precisaria de `IDWriteFontFileLoader`/`IDWriteFontCollectionLoader` customizados
sobre os nossos bytes. O comportamento hoje é recusar por nome e desenhar
portátil, e não desenhar com *outra* face — que seria pior que não desenhar
nativo.

#### ClearType: quando entrega e quando degrada sozinho

Subpixel RGB não sobrevive a rotação, a transparência, nem a composição em
layer, e o **próprio Direct2D** cai para escala de cinza nesses casos. Então a
opção entrega ClearType **só** num alvo opaco (`D2D1_ALPHA_MODE_IGNORE`, que é
o do alvo de janela deste backend), sem transformação de rotação, fora de
layer. No alvo offscreen deste projeto — DIB pré-multiplicado — ela degrada
para cinza, e isso está **afirmado em teste**: texto cinza tem que sair cinza,
zero pixels com canais divergentes. O sink pede
`D2D1_TEXT_ANTIALIAS_MODE_DEFAULT` e não ClearType por nome, justamente porque
quem sabe o que o alvo aguenta é o runtime.

### 5.4 O que **não** foi implementado, e por quê

**Nível 2 — texto totalmente nativo, com `IDWriteTextLayout` fazendo shaping,
quebra de linha e desenho — está deliberadamente fora.** Não é esquecimento.

Ele daria fidelidade máxima com o Windows, mas **as métricas mudam**, e com elas
todo o layout: o mesmo aplicativo passaria a ter tamanhos diferentes por
plataforma, e o resto do framework — que posiciona tudo a partir das *nossas*
métricas — passaria a discordar do que foi desenhado. Divergência de geometria
é categoricamente pior que divergência de pixel: a segunda é uma escolha
estética, a primeira quebra hit-test, seleção, rolagem e golden de layout de uma
vez só.

Por isso `IDWriteTextFormat`, `IDWriteTextLayout` e `IDWriteTextAnalyzer` não
estão sequer vinculados em `dwrite_interfaces.dart`, com essa razão escrita lá.

### 5.5 O que um aplicativo assume ao ligar isso

Está na documentação da própria API (`GlyphRasterization.platformNative`), não
só aqui:

- o texto no Windows deixa de bater pixel a pixel com o das outras
  plataformas, e **goldens que contenham texto passam a ser específicos de
  Windows**;
- um run cuja fonte não está instalada, ou cuja cópia instalada numera glifos
  diferente, é desenhado pela rota portátil — recusa por nome, registrada em
  `D2dRasterSink.nativeTextRefusal`;
- ClearType não é garantido, pelas razões de 5.3.

---

## 6. Arquivos

| arquivo | papel |
| --- | --- |
| `lib/src/backends/win32/d2d/d2d_glyph_atlas.dart` | o atlas, o packer, a política de despejo |
| `lib/src/backends/win32/d2d/d2d1_interfaces.dart` | `D2dDeviceContext3`, `D2dSpriteBatch`, `D2dBitmap`, `DrawGlyphRun`, `queryDeviceContext3` |
| `lib/src/backends/win32/d2d/d2d_raster_sink.dart` | as duas rotas de emissão, o escape de tipo grande, a rota nativa opcional |
| `lib/src/backends/win32/d2d/dwrite_interfaces.dart` | as cinco interfaces DWrite, e as três que não estão lá de propósito |
| `lib/src/backends/win32/d2d/dwrite_font_faces.dart` | resolução por família + a verificação de índice de glifo |
| `lib/src/rendering/render_policy.dart` | `GlyphRasterization`, a opção pública |
| `test/backends/win32/d2d/d2d_text_cost_test.dart` | a medição (atrás de `DART_UI_GPU_BENCHMARK=1`) |
| `test/backends/win32/d2d/d2d_device_context_probe_test.dart` | o que o alvo responde a `QueryInterface` |
| `test/backends/win32/d2d/d2d_glyph_atlas_test.dart` | cheio, grande demais, em branco, reset, e o escape ponta a ponta |
| `test/backends/win32/d2d/d2d_glyph_transform_test.dart` | paridade: desvio 0 alinhado, as duas rotas entre si, contorno sob matriz |
| `test/backends/win32/d2d/dwrite_probe_test.dart` | a aritmética de vtable e a verificação de identidade de fonte |
| `test/backends/win32/d2d/d2d_native_text_test.dart` | desligado não muda nada; ligado desenha, não move o layout, não faz franja |
