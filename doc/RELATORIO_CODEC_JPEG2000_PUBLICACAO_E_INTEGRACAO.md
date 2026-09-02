# Relatório — codec `jpeg2000`: o que falta para o pub.dev e para o `dart_ui`

Data da auditoria: 2 de setembro de 2026.
Repositório auditado: `C:\MyDartProjects\jpeg2000` (branch `main`, árvore limpa,
`547344c fix`).
Consumidor alvo: `C:\MyDartProjects\dart_ui`.

## Resposta curta

O codec **funciona e está bit-exato** nas fixtures versionadas: 284 testes
passam em série, `dart format` e `dart doc` estão limpos e o `dart pub publish
--dry-run` só reclama do `CHANGELOG.md`. Mas ele **ainda não pode ser publicado
nem consumido pelo `dart_ui`** por três motivos de peso, e uma lista longa de
motivos menores:

1. **O pub.dev vai marcar o pacote como incompatível com Web e com Wasm.** A
   fachada pública alcança `dart:io` por duas cadeias de import (ROI do encoder e
   a exceção de codestream corrompido). O `pana` deu 125/160 pontos e derrubou a
   tag Web por isso. Para o `dart_ui`, que compila o backend web por dart2js e
   dart2wasm, isso é bloqueante.
2. **A API pública perde informação que o `dart_ui` precisa.** Um JP2 com 4
   componentes (RGBA) sai com 3: o alfa é descartado em silêncio. Imagens de 16
   bits são reduzidas a 8 sem opção. Todo erro sai como `StateError` genérico.
   Não há como ler só o cabeçalho para aplicar o orçamento de pixels antes de
   alocar.
3. **Desempenho:** 768×512 leva cerca de 0,7 s no VM JIT e 0,9 s em AOT. Isso é
   1,7 a 2,2 µs por pixel, ou seja, uma foto de 12 MP levaria mais de 20 s no
   thread principal. Dá para integrar já, mas só atrás de isolate e com limite de
   pixels; para uso geral precisa da passada de otimização que o próprio README
   do codec já descreve.

O resto deste relatório é a lista completa, ordenada por bloqueio, com o que
fazer em cada repositório. A seção 8 é a ordem sugerida de execução.

## Estado em 2 de setembro de 2026, fim do dia

Os passos 1 a 7 da seção 8 foram executados no `jpeg2000` em quatro commits
na `main` (`4be1555`, `5b26250`, `bec62ed` e o anterior de docs). O que
mudou de fato:

| Item do relatório | Estado | Prova |
|---|---|---|
| 2.1 `dart:io` alcançável pela fachada | **feito** | `test/architecture/public_facade_imports_test.dart` percorre o grafo como o pana; `dart test -p chrome` passa; pana dá Web e Wasm |
| 4.3 exceções tipadas | **feito** | `Jpeg2000Exception` selada: `Format`, `Truncated`, `Corrupted`, `Unsupported`, `Budget`; `StateError` só para bug interno |
| 4.1 alfa descartado | **feito** | `barras_rgb.jp2` sai `rgba8` com 4 canais; `hasAlpha`, `alphaIsPremultiplied`, `colorComponents` |
| 4.4 probe e limites | **feito** | `probeJpeg2000`, `maxPixels`, `maxDimension`; SIZ hostil de 100000² é rejeitado sem alocar |
| 4.6 subamostragem em J2K cru | **guardado** | lança `Jpeg2000UnsupportedException` em vez de escrever fora do lugar |
| 4.7 assinaturas | **parcial** | `Jpeg2000Codec` removido, `bitsPerComponent` virou `sourceBitsPerComponent`; `Object source` e `extraParameters` ficaram como estavam |
| Seção 3, logger e `print` | **feito** | logger padrão silencioso; `onWarning`; CLIs registram o de stdout; restos de `print` removidos |
| Seção 3, 477 infos | **feito, 0 infos** | 224 identificadores renomeados com lexer que preserva strings e prosa; aliases Java removidos; chaves, super parameters, initializing formals, campos sobrescritos, `hashCode` |
| 2.2 e 2.3 arquivos de publicação | **feito** | `pubspec.yaml` sem `publish_to`, com `repository`, `topics`, `executables` (`jp2dec`, `jp2enc`); `CHANGELOG.md`; `example/main.dart`; `.pubignore`; `LICENSE-JJ2000.txt`; README reescrito; benchmarks em `doc/BENCHMARKS.md` |
| Licença Sun/JAI | **não se aplica** | ver a nota na seção 2.3 |
| `dart pub publish --dry-run` | 0 warnings | |
| `pana` | **160 / 160** (era 125) | medido depois do push; antes dele dava 150 porque o pana lê o `pubspec.yaml` no GitHub para verificar `repository` |
| Suíte do codec | 303 testes, 0 falhas, 13 s em série | `dart test -j 1` |

### Segunda rodada, mais tarde no mesmo dia

Decisões suas: o `dart_ui` consome o `jpeg2000` como **dependência** (não
vendoriza), e a publicação no pub.dev só acontece quando o codec estiver
completo. Até lá a dependência vem do Git (`pubspec.yaml` do `dart_ui`).

| Item | Estado | Prova |
|---|---|---|
| 4.2 saída de 16 bits | **feito** | `outputBitDepth: 16`, `bitsPerSample`, `pixels16`; fontes rasas são reescaladas (255 → 65535); enum de formato sem sufixo (`gray`, `rgba`...) |
| 4.5 e seção 7, encoder por pixels | **feito** | `encodeJpeg2000Pixels` com 1 a 16 bits, alfa gravado na caixa `cdef`; PNM de 16 bits; RGBA, gray+alfa, 16 bits e 12 bits fecham sem perdas |
| Bug achado no caminho | **corrigido** | acima de 12 bits o alocador descartava o último ponto de truncamento (inclinação estimada negativa) e perdia os bit-planes baixos; a MCT inversa indexava lista de 3 com 4 componentes |
| Seção 5, desempenho | **3,5×** | `file1.jp2` 768×512: 672 → 182 ms (JIT), 863 → 219 ms (AOT). 70% do tempo era interpolação de strings de trace dentro das passadas de entropia; o resto veio de listas tipadas. Perfil por `build/profile.dart` (VM service); o que sobra é o decodificador MQ (47%) |
| 6.2 sniff, enum, exceção, `switch`es | **feito** | `RasterImageFormat.jpeg2000`, `isJpeg2000`, `Jpeg2000DecodeException` com `kind` (format, truncated, corrupted, unsupported); WIC devolve `null` sem tentar; Web pede `image/jp2` e cai para o Dart |
| 6.3 adaptador | **feito** | `_fromJp2Image` em `raster_formats.dart`: gray replicado, alfa premultiplicado com o `premultiplyChannel` compartilhado, `cdef` premultiplicado respeitado, `multiComponent` mostra os três primeiros canais |
| 6.4 isolate e orçamento | **feito** | `decodeImageAsync` manda JPEG 2000 para `compute` na VM; `probeJpeg2000` aplica `RasterImageLimits` antes de alocar e o codec recebe o mesmo orçamento; `Image.jp2` e doc do `Image.memory` avisam do custo |
| 6.5 `/JPXDecode` | **feito** | `decodePdfImage` reconhece JP2/J2K, ignora o alfa sem `/SMaskInData`, usa com 1 ou 2; `/Decode` ignorado como manda a norma. Fora: `/ColorSpace` que contradiz o JP2 e `/Indexed` sobre JPX |
| 6.6 testes | **feito** | `test/graphics/image/jp2_test.dart` e `test/pdf/pdf_jpx_image_test.dart` geram os JP2 com o próprio encoder, sem fixture binária; 49 testes em série com `test/architecture` |
| Caminho ImageIO no macOS | **coberto pelo CI** | `test/graphics/image/jp2_native_test.dart` compara o decodificador nativo com o Dart quando há um (tolerância de 1 na cor, 0 no alfa); o workflow `framework.yml` roda `dart test test` em `macos-14`, que é onde a comparação vale. No Windows e no Linux o teste prova só o fallback |

Terceira rodada de desempenho, AOT, melhor de 20 execuções quentes:
`file1.jp2` 863 → 219 → **202 ms**; `relax.jp2` 47 → 24 → **17 ms**. O
caminho rápido do decodificador MQ (símbolo mais provável sem
renormalização) ficou pequeno o bastante para o VM inlinar nas passadas;
helpers de sinal e refinamento sem `toSigned` redundante; closures de trace
que capturavam variáveis do laço removidas; wavelet 5x3 em `Int32List`. O
que sobra (MQ e as três passadas, ~75%) já está na estrutura da referência
Java; ganhos além disso pedem mudança de algoritmo, não de tipagem.

### Terceira rodada: o editor de imagem achou dois bugs de precincts

O exemplo `examples/image_editor_demo` (pincel, importar e salvar em PNG,
JPEG e JPEG 2000) abriu e salvou `cameraman.10.jp2`, mas recusou
`balloon.jp2` (Kakadu, 2717×3701, 12 tiles, RPCL, SOP, EPH, precincts
128/256, 6 camadas) com "expected EPH marker". Nenhuma fixture do codec tinha
precincts. Bissecção com o próprio encoder (que o ImageMagick decodifica
certo) isolou dois bugs no leitor de pacotes, ambos invisíveis sem precincts:

| Bug | Efeito | Correção |
|---|---|---|
| `Lblock` indexado pela linha do code-block *dentro do precinct* (`m`) em vez da linha no subband (`cbc.y`, como no Java) | precincts empilhados na mesma coluna compartilhavam o estado; o primeiro pacote de um precinct inferior que o alterava dessincronizava os comprimentos seguintes | `pkt_decoder.dart`, `readPktHead` |
| Tamanhos de precinct lidos do COD na ordem do codestream (r0 primeiro) enquanto `getPPX` indexa com `mrl - rl` (mais alta primeiro) | com tamanhos diferentes por nível, cada resolução recebia o tamanho da sua imagem espelhada | `header_decoder.dart`, `_buildPrecinctValue` inverte a lista |

Prova: `balloon.jp2` decodifica a 55 dB PSNR contra o ImageMagick/OpenJPEG
(9/7 irreversível, diferença de arredondamento em ponto flutuante); arquivos
RPCL, com tiles e com três camadas gerados pelo ImageMagick decodificam
idênticos (PSNR infinito). `test/precinct_test.dart` cobre precincts por
subband, tamanhos por resolução, tiles+SOP+EPH+segmentação+camadas, tudo sem
perdas. Também nesta rodada: o CI de macOS pegou o `ImageIO` devolvendo
imagens de cabeça para baixo (inversão de CTM indevida no `CGBitmapContext`),
corrigido com teste de orientação de duas linhas.

### Publicado: `j2k` 0.9.0

`dart pub publish` recusou o nome `jpeg2000`: já existe no pub.dev desde
2026-08-31 (0.1.4, de outro autor, port do `jpx.js` do pdf.js, só decoder).
Por decisão sua o package passou a se chamar **`j2k`** (o repositório continua
`github.com/insinfo/jpeg2000`), e foi publicado como 0.9.0 em
https://pub.dev/packages/j2k. A API não mudou: `import 'package:j2k/j2k.dart'`
e as mesmas funções `decodeJpeg2000`, `probeJpeg2000`, `encodeJpeg2000Pixels`.
O `dart_ui` consome `j2k: ^0.9.0` do pub.dev; a dependência Git acabou.

Também nesta rodada: `test/data/balloon.pdf` (Flate, 17 MB, sem JPEG 2000)
deu lugar a `test/data/balloon_jpx.pdf`, gerado por `tool/make_jpx_pdf.dart`
com `/JPXDecode` e sem `/ColorSpace`, e o leitor de PDF parou de redecodificar
as imagens da página a cada zoom (2,6 s → o resample de 20 a 200 ms).

Ainda em aberto no `j2k`: assinaturas 4.7 (`Object source`,
`extraParameters`) e componentes assinadas no encoder; decodificação do JPX
do PDF fora da thread da janela, que ainda trava a abertura de páginas
grandes.

Duas mudanças de API que o consumidor precisa saber: `Jpeg2000Image.components`
agora inclui o alfa (um JP2 RGBA devolve 4, não 3), e todo erro de entrada
sai como `Jpeg2000Exception`, nunca mais como `StateError`.

### Quarta rodada de desempenho: o caminho 9/7 em SIMD

O caminho reversível (5/3) já era dominado pelo decodificador MQ; o
irreversível (9/7 com ICT), que é o das fotos, não. Com `balloon.jp2`
(2717×3701 RGB, três tiles, 9/7) como cobaia, quente, melhor de seis:

| Build | `file1.jp2` | `relax.jp2` | `balloon.jp2` |
|---|---:|---:|---:|
| VM JIT, antes | 182 ms | 11 ms | 1236 ms |
| VM JIT, depois | 165 ms | 10 ms | **417 ms** |
| AOT, antes | 202 ms | 17 ms | 1436 ms |
| AOT, depois | 176 ms | 13 ms | **493 ms** |

Tudo bit-exato contra as fixtures do JJ2000 (52 testes de referência e
conformidade continuam passando com erro máximo zero).

- A síntese 9/7 inversa roda em `Float32x4`: na horizontal, a linha inteira
  em passadas vetoriais sobre as amostras pares e ímpares, com os vizinhos
  `x[j-1]`/`x[j+1]` montados por shuffles de lanes entre vetores adjacentes;
  na vertical, dezesseis colunas por passada (uma linha de cache por linha da
  imagem) em buffers contíguos. `Float32x4` calcula em precisão simples em
  cada operação, que é exatamente o que o `float` do Java faz.
- O ICT lê Y, Cb e Cr por views `Float32x4List` alinhadas; os planos
  reconstruídos têm o stride arredondado para múltiplo de quatro para que
  toda linha comece alinhada a 16 bytes.
- A coleta final escreve RGB pixel a pixel a partir dos três planos, em vez
  de três passadas com stride 3 sobre a saída.

Três achados sobre os compiladores do Dart (3.6.2, JIT e AOT) que moldaram o
código, e que valem para o `dart_ui` também:

- Montar um `Float32x4` a partir de quatro loads escalares é **mais lento**
  que o loop escalar; ler vetores inteiros por uma view `Float32x4List`
  alinhada é 2,5× mais rápido. Alinhamento se garante, não se torce.
- Um shift por quantidade variável (`x >> fixedPoint`) num loop quente em
  AOT custou três vezes o resto do loop; o caso comum (zero) ganhou loop
  próprio.
- Tirar uma lista tipada de um `List<Int32List?>` com `!` dentro da função
  do loop faz cada leitura virar chamada polimórfica em AOT (2,5× mais
  lento); os planos passam como parâmetros tipados.

Sobre as issues do SDK que você mandou (dart-lang/sdk#53662, #61087, #63217
e o CL 497000): o que era lento em AOT eram os operadores de `Int32x4`,
corrigidos em abril de 2026 e fora da SDK 3.6.2. `Float32x4` já era
especializado em AOT desde a 3.5, e é só isso que o codec usa. Os
microbenchmarks em AOT confirmaram: view `Float32x4List` 2,5× mais rápida
que o escalar também no executável.

Comparação com o `jpeg2000` do pub.dev (p3pp8), AOT, melhor de quatro:

| Arquivo | `j2k` | `jpeg2000` 0.1.4 |
|---|---:|---:|
| cameraman 256×256 | 2 ms | 4 ms |
| relax.jp2 400×300 | 14 ms | 13 ms |
| sample_jpxdecode 816×1056 | 24 ms | 38 ms |
| file1.jp2 768×512 | 184 ms | 263 ms |
| balloon.jp2 2717×3701 | 492 ms | falha (precincts) |

(`relax.jp2` é pequeno e quase só entropia, onde esta rodada não mexeu.)

O que sobra no perfil do 9/7 (AOT, balloon): entropia 45%, coleta final
12%, síntese vertical 12%, horizontal 11%, ICT 8%.

**Melhoria futura anotada (pendente):** o decodificador de entropia
(MQ + as três passadas de codificação) é o próximo alvo, para os dois
caminhos (5/3 e 9/7). Ele já é o custo dominante do `file1.jp2` (cerca de
85%) e passa a ser quase metade do `balloon.jp2`. As ideias registradas em
`doc/BENCHMARKS.md` do codec: decodificar vários símbolos por chamada na
passada de limpeza, atualização de contexto por tabela, e manter o
registro de código do MQ em local durante a passada inteira. Nenhuma versão
nova do `j2k` foi publicada com esta rodada; a 0.9.0 no pub.dev ainda é a
anterior ao SIMD, e publicar a 0.9.1 fica a critério do autor.

## 1. Estado medido

| Verificação | Resultado | Comando |
|---|---|---|
| Testes VM, em série | **284 passaram, 0 falharam** (16 s) | `dart test -j 1` |
| `dart format` | 310 arquivos, 0 mudanças | `dart format --output=none --set-exit-if-changed .` |
| `dart analyze` | **477 infos**, 0 warnings, 0 errors | `dart analyze` |
| `dart fix --dry-run` | só **40** dos 477 são corrigíveis automaticamente (36 `prefer_adjacent_string_concatenation`, 4 `prefer_spread_collections`) | `dart fix --dry-run` |
| `dart doc --dry-run` | 0 warnings, 0 errors | `dart doc --dry-run` |
| `dart pub publish --dry-run` | 1 warning: falta `CHANGELOG.md`; arquivo de 3 MB comprimido | `dart pub publish --dry-run` |
| `pana` | **125 / 160 pontos** (detalhe na seção 2) | `dart pub global run pana .` |
| Dartdoc na API pública | 11 de 38 símbolos (28,9 %) documentados | `pana` |
| Git | `main` sincronizada com `origin/main`, nada pendente | `git status` |

Decodificação das fixtures pela fachada pública (`decodeJpeg2000`), VM JIT,
primeira chamada fria:

| Fixture | Dimensão | Componentes no arquivo | Saída da API | Tempo |
|---|---|---|---|---|
| `barras_rgb.jp2` | 32×32 | **4** (RGB + alfa, MCT=0) | `rgb8`, 3 comps | 62 ms |
| `icon32.jp2` | 32×32 | 3 | `rgb8` | 2 ms |
| `grad_final.jp2` | 32×32 | 3 × **16 bits** | `rgb8` com `bitsPerComponent=[16,16,16]` mas pixels de 8 bits | 10 ms |
| `relax.jp2` | 400×300 | 3, 12 layers, ICC degenerado | `rgb8`, avisa no stdout | 77 ms |
| `file1.jp2` | 768×512 | 3, 5×3 reversível | `rgb8` | 777 ms |

Tempos quentes (cinco execuções seguidas, mesmo processo):

| Fixture | VM JIT (ms) | AOT `dart compile exe` (ms) |
|---|---|---|
| `file1.jp2` 768×512 | 797, 688, 672, 697, 683 | 873, 884, 884, 891, 863 |
| `relax.jp2` 400×300 | 63, 35, 36, 32, 30 | 52, 47, 47, 50, 47 |

Entradas hostis (bytes vazios, lixo, SOC truncado, `file1.jp2` cortado ao
meio): nenhuma trava ou estoura memória, mas **todas** saem como
`StateError: Bad state: Error while reading JP2 file format: ...`, inclusive as
que não têm nada a ver com o formato JP2 (a mensagem interna é
`EOFException` ou `Stream is neither a JP2 file nor a raw JPEG 2000 codestream`).

## 2. Bloqueadores para o pub.dev

Pontuação do `pana` por categoria, com a causa de cada ponto perdido:

| Categoria | Pontos | Causa |
|---|---|---|
| Convenções de arquivos | 25 / 30 | sem `CHANGELOG.md` (−5). O `pana` também não verifica o repositório porque `publish_to: none` está no pubspec. |
| Documentação | 10 / 20 | sem pasta `example/` (−10). Dartdoc passou por margem (28,9 % contra mínimo de 20 %). |
| Plataformas | 20 / 20 hoje, **mas sem a tag Web** e reprovado em Wasm | cadeia até `dart:io`, abaixo. O aviso do `pana` é explícito: "will not be rewarded full points in a future version of the scoring model". |
| Análise estática | 40 / 50 | lints (−10). O `pana` contou 101 na passada dele; `dart analyze` no repositório inteiro dá 477. |
| Dependências | 40 / 40 | `meta ^1.3.0` e `web ^1.1.1` estão atualizadas e o `pub downgrade` analisa limpo. |

### 2.1 `dart:io` alcançável pela fachada pública (bloqueante para Web e Wasm)

O `pana` encontrou esta cadeia:

```
package:jpeg2000/jpeg2000.dart
 → src/api/jpeg2000_codec.dart
 → src/api/memory_codestream_writer.dart
 → src/j2k/codestream/writer/header_encoder.dart
 → src/j2k/roi/encoder/roi_scaler.dart
 → src/j2k/roi/encoder/rect_roi_mask_generator.dart
 → src/j2k/roi/encoder/roi_mask_generator.dart
 → src/j2k/roi/encoder/roi.dart            (campo `final ImgReaderPGM? mask`)
 → src/j2k/image/input/img_reader_pgm.dart → dart:io
```

Há uma segunda cadeia que o `pana` não listou porque para na primeira:
`corrupted_codestream_exception.dart` faz `extends IOException` de `dart:io` e
é importada pelo leitor de codestream. E `jj2k_exception_handler.dart` também
importa `dart:io`.

O CI compila o benchmark com `dart compile js` e `dart compile wasm` e passa,
porque os compiladores aceitam `import 'dart:io'` e só falham se o código for
executado. O `pana` não executa nada: ele olha o grafo de imports, e é o grafo
que decide a tag de plataforma no pub.dev.

Correção:

- `roi.dart`: trocar `ImgReaderPGM? mask` por uma abstração sem `dart:io`
  (`BlkImgDataSrc? mask`, ou um `RoiMask` em memória). A leitura do PGM do
  disco fica só no CLI (`bin/encode.dart`).
- `corrupted_codestream_exception.dart`: parar de estender `IOException`.
  Vira `implements Exception` (ou estende a hierarquia nova da seção 4.3).
- `jj2k_exception_handler.dart`: mover para o CLI ou passar pelo
  `platform.dart` que já existe.
- Fixar com um teste: `dart test -p chrome` e `dart test -p node` do
  `jpeg2000_public_api_test.dart` já estão no CI, mas adicionar um teste de
  arquitetura que percorre os imports a partir de `lib/jpeg2000.dart` e falha
  se encontrar `dart:io` fora de `platform_io.dart`. O `dart_ui` tem esse
  padrão em [layering_test.dart](../test/architecture/layering_test.dart).

### 2.2 `pubspec.yaml`

| Campo | Hoje | O que fazer |
|---|---|---|
| `publish_to: none` | presente | remover, senão `dart pub publish` recusa |
| `homepage` | `https://github.com/insinfo/jpeg2000` | trocar por `repository:` (o pub.dev usa `repository` para verificar a origem e mostrar o link do código) e adicionar `issue_tracker:` |
| `description` | "Pure dart jpeg 2000" | 60 a 180 caracteres, em inglês, dizendo o que decodifica e codifica e que roda em VM, Web e Wasm |
| `version` | `1.0.0` | ok se a API da seção 4 for fechada antes; caso contrário publicar `0.9.0` e reservar `1.0.0` para a API estável |
| `topics` | ausente | `[jpeg2000, jp2, image, codec, decoder]` |
| `executables` | ausente | `decode:` e `encode:` apontando para `bin/`, senão `dart pub global activate` não instala os CLIs |
| `test: any` | sem limite | `^1.25.0` |
| `meta` | usada em 2 arquivos | manter, é só anotação |
| `web` | dependência normal | manter: é só alcançada atrás de `if (dart.library.js_interop)`, mesmo padrão do `dart_ui` |

### 2.3 Arquivos obrigatórios e recomendados

- **`CHANGELOG.md`**: obrigatório. Entrada `1.0.0` (ou `0.9.0`) com o que
  existe: decoder JP2/J2K bit-exato, encoder PGM/PPM lossless e por taxa, API de
  bytes, CLI.
- **`example/example.md`** ou **`example/main.dart`**: decodificar bytes,
  ler `width`, `height`, `pixels`, e codificar um PPM. O `pana` dá 10 pontos.
- **`LICENSE`**: hoje é só o MIT em nome de Isaque Neves Santana. O código é um
  port do JJ2000, e a licença do JJ2000 diz
  *"This copyright notice must be included in all copies or derivative works
  of this software module"* (`referencias/jai-imageio-jpeg2000/LICENSE-JJ2000.txt`).
  Adicionar um `LICENSE-JJ2000.txt` ao pacote (ou um bloco "Third-party
  notices" no `LICENSE`) e uma seção "Origem e licenças" no README. Sem isso
  a publicação viola a licença de origem.
  A licença Sun/BSD do JAI ImageIO **não** se aplica: conferido em 2 de
  setembro, os 147 arquivos `jj2000/**` da referência trazem só o cabeçalho
  JJ2000, e os 34 arquivos com cabeçalho Sun ficam em
  `com/github/jaiimageio/**` (leitor ImageIO, metadados, caixas no estilo
  `Box`), que o port não espelha. As caixas JP2 do port (`JP2Box`, `getNDefs`,
  `getCn`, `getTyp`, `getAsoc`) seguem a API do pacote `colorspace` do JJ2000
  original, não a da Sun. O JDeli em `referencias/` é proprietário e só serve
  como oráculo de conformidade; nada dele pode entrar no código.
- **`.pubignore`**: hoje o pacote publica `test/fixtures` (11 MB em disco,
  3 MB comprimidos), `DEBUG_FINDINGS.md` (diário de investigação, em
  português, já concluído) e `benchmark/JaiImageioBenchmark.java`. Nada disso
  serve ao consumidor. Sugestão de `.pubignore`: `test/fixtures/`, `benchmark/`,
  `DEBUG_FINDINGS.md`, `.github/`. O `referencias/` já está no `.gitignore` e
  por isso não entra.
- **README**: diz "The package is not published on pub.dev yet. Use the Git
  repository". Trocar pela instrução de `dart pub add jpeg2000` no dia da
  publicação. As seções "Performance Snapshot" e "Optimization Targets" são
  boas, mas o README ainda referencia `referencias/openjpeg` e caminhos
  `C:\maven-mvnd...` da sua máquina; mover para um `doc/BENCHMARKS.md`.
  A seção "Public API" deve ganhar a lista de limitações da seção 4 deste
  relatório para o usuário não descobrir do jeito difícil.

## 3. Padrões de código e documentação do Dart

`dart analyze` no repositório inteiro: **477 infos** (nenhum warning ou error).
O `analysis_options.yaml` inclui `package:lints/recommended.yaml` e relista
cinco regras que já fazem parte dele, o que é inócuo. O pub.dev analisa com o
mesmo conjunto `lints`, então cada info conta.

Distribuição por regra e como resolver:

| Regra | Ocorrências | Auto-fix | Como resolver |
|---|---:|:---:|---|
| `constant_identifier_names` | 262 | não | Constantes copiadas do Java em `UPPER_SNAKE` (`SOC`, `SIZ`, `W9X7`, `LY_RES_COMP_POS_PROG`, `SRGB00`, `M00`...). Renomear para `lowerCamelCase` com o rename do IDE, arquivo por arquivo. Concentração: `markers.dart` (43), `icc_profile.dart` e `matrix_based_transform_to_srgb.dart` (44 juntos), `color_space.dart`, `progression_type.dart`, `filter_types.dart`, `forward_wt.dart`. Alternativa aceitável para `markers.dart`: transformar em `enum` com valor. |
| `avoid_renaming_method_parameters` | 67 | não | Overrides usam `c`, `t`, `rl`, `comp`, `outblk`, `hfilter` onde a interface diz `component`, `tile`, `resLevel`, `out`, `hFilter`. Alinhar com o nome da interface (`channel_definition_mapper.dart`, `resampler.dart`, `palettized_color_space_mapper.dart`, `bitstream_reader_agent.dart`, `subband_an.dart`, `subband_syn.dart`). |
| `curly_braces_in_flow_control_structures` | 54 | não neste SDK | `if (...) return x;` sem chaves em `icc_profile.dart`, `icc_tag.dart`, `matrix_based_transform_to_srgb.dart`, `monochrome_transform_to_srgb.dart`. Mecânico. |
| `non_constant_identifier_names` | 38 | não | `in_io`, `ICC_PROFILED`, `GreyScale`, `DoubleToXYZ`, `synthetize_lpf`, `PCSIlluminant`. Renomear. Os construtores `super.in_io` nas seis caixas JP2 mudam com um rename só em `jp2_box.dart`. |
| `use_super_parameters` | 16 | não | `string_spec.dart`, `syn_wt_filter_spec.dart` e outros specs: trocar `Foo(int a, int b) : super(a, b)` por `Foo(super.a, super.b)`. |
| `prefer_adjacent_string_concatenation` | 11 | **sim** (36 fixes) | `dart fix --apply --code=prefer_adjacent_string_concatenation`. |
| `unintended_html_in_doc_comment` | 8 | não | `icc_profiler.dart:402-408`: envolver `<...>` em crases. |
| `prefer_initializing_formals` | 7 | não | `color_space_mapper.dart:153`, `monochrome_transform_to_srgb.dart:79`. |
| `overridden_fields` | 5 | não | `icc_curve_type.dart`, `icc_text_type.dart` e outros tags redeclaram um campo do `ICCTag`. Trocar por getter ou remover. |
| `library_private_types_in_public_api` | 5 | não | Tipo `_Foo` aparece em assinatura pública. Tornar o tipo público ou a API privada. |
| `hash_and_equals` | 1 | não | `an_wt_filter_float_lift9x7.dart:444` define `==` sem `hashCode`. |
| `slash_for_doc_comments` | 1 | não | `icc_profile_version.dart:9`. |
| `prefer_spread_collections` | 1 | **sim** | `test/j2k/codestream/test_utils.dart`. |
| `prefer_collection_literals` | 1 | não | `parameter_list.dart:20`. |

Ordem que compensa: `dart fix --apply` primeiro (40 fixes, 6 arquivos), depois
as chaves e os `super parameters` (mecânicos), depois os renames de parâmetro
de override, e por último as 300 constantes, um arquivo por commit para o
diff ficar revisável. O README já admite em "The source still contains many
JJ2000-style internal names".

Outros pontos de padrão que o analisador não pega:

- **Saída no stdout por padrão.** `FacilityManager._defaultLogger` é
  `StreamMsgLogger.stdout`. Durante os testes apareceram 19 linhas `[INFO]:`
  e a decodificação de `relax.jp2` imprime `[WARNING]: ICC profile has
  degenerate colorants` para quem chamou `decodeJpeg2000`. Uma biblioteca
  publicada não deve escrever no console sem ser pedida: o logger padrão deve
  ser silencioso, e a fachada deve aceitar um `void Function(String)? onWarning`
  ou expor `Jpeg2000Image.warnings`.
- **`print(e)` direto** em `icc_profiler.dart:359` e `:370`, e `print(`
  em `file_bitstream_reader_agent.dart:714` e `pkt_decoder.dart:500,552,667`.
  Trocar pelo logger ou remover. Há mais uma dúzia de `// print(...)`
  comentados em `pkt_decoder.dart` que são resto de depuração.
- **Estado global mutável**: `DecoderInstrumentation.configure(false)` é
  chamado dentro de `decodeJpeg2000`, e `FacilityManager` guarda loggers por
  `Zone` em um `static`. Dois decodes concorrentes em isolates não se afetam,
  mas dois no mesmo isolate compartilham a configuração. Passar a
  instrumentação por parâmetro.
- **Dartdoc da API pública**: `Jpeg2000Codec` e seus quatro métodos, os campos
  de `Jpeg2000Image`, `Jpeg2000DecodeOptions` e `Jpeg2000EncodeOptions` e o
  enum `Jpeg2000PixelFormat` estão sem `///`. É a lista inteira que o `pana`
  apontou. Ligar `public_member_api_docs` no `analysis_options.yaml` só para
  `lib/jpeg2000.dart` e `lib/src/api/` fecha isso de vez.
- **`bin/decode.dart` e `bin/encode.dart` importam `package:jpeg2000/src/...`**.
  Funciona, mas é o padrão que o próprio README diz não fazer. Ou os CLIs usam
  a fachada, ou a fachada ganha o que falta (saída PPM/PGM/BMP em bytes).
- **Nomes de testes em três idiomas** (`ArrayUtil - Casos Críticos`,
  `Decoder Reference Comparison Tests`). Não afeta pontuação; padronizar em
  inglês para quem for contribuir.

## 4. Lacunas da API pública que o `dart_ui` sente

O contrato de pixels do `dart_ui` está em
[decoded_image.dart](../lib/src/graphics/image/decoded_image.dart): RGBA ou
BGRA de 8 bits, **alfa premultiplicado**, ordem escolhida pelo chamador, com
`hasAlpha`. Comparando com o que `decodeJpeg2000` devolve:

### 4.1 Alfa descartado (bug)

`_collectImage` faz `outputComponents = components == 1 ? 1 : min(components, 3)`.
Um JP2 com 4 componentes (`barras_rgb.jp2` é exatamente isso) sai como `rgb8`
com 3 componentes: o quarto canal é lido do arquivo, decodificado e jogado
fora. A caixa `cdef` (channel definition), que diz qual componente é alfa e se
é premultiplicado, é lida pelo `ChannelDefinitionMapper` mas não chega na API.

Correção: `Jpeg2000PixelFormat` ganha `grayAlpha8` e `rgba8`; `Jpeg2000Image`
ganha `hasAlpha` e `alphaIsPremultiplied`; `_collectImage` devolve todos os
componentes que o `cdef` (ou a contagem, na falta dele) classifica como cor ou
alfa. Componentes além disso (CMYK, multiespectral) vão para
`multiComponent8` com `components` real, sem truncar.

### 4.2 16 bits reduzidos a 8 sem aviso

`grad_final.jp2` é 16 bits por canal. A API devolve `bitsPerComponent =
[16, 16, 16]` mas `pixels` já foi deslocado para 8 bits (`sample >> downShift`).
O campo descreve o arquivo, não o buffer, e isso confunde. Para o `dart_ui`
hoje 8 bits basta, mas para o PDF (seção 6.5) e para uso científico não.

Correção: `Jpeg2000DecodeOptions.outputDepth` (`8` padrão ou `16`) e `pixels`
como `TypedData` (`Uint8List` ou `Uint16List`), ou dois campos
`pixels8`/`pixels16`. `bitsPerComponent` passa a se chamar
`sourceBitsPerComponent`.

### 4.3 Exceções sem tipo

Tudo sai como `StateError` com prefixo "Error while reading JP2 file format",
inclusive quando o erro é EOF, lixo na entrada ou marcador não suportado. O
`dart_ui` tem uma hierarquia selada `ImageDecodeException` em
[image_errors.dart](../lib/src/graphics/image/image_errors.dart) e distingue
truncado, corrompido, não suportado e orçamento estourado, porque cada um tem
tratamento diferente na UI.

Correção: uma classe base `Jpeg2000Exception implements Exception` com
subclasses `Jpeg2000FormatException` (não é JP2 nem J2K),
`Jpeg2000TruncatedException` (EOF), `Jpeg2000CorruptedException` (o atual
`CorruptedCodestreamException`, sem `dart:io`),
`Jpeg2000UnsupportedException` (filtro wavelet custom, ordem de progressão,
`PPM`/`PPT`). Nunca `StateError` para entrada do usuário.

### 4.4 Sem leitura de cabeçalho e sem limites

Não existe `Jpeg2000Info probeJpeg2000(Uint8List)` que devolva largura, altura,
componentes, profundidade, tiles e se há alfa sem decodificar. O `dart_ui`
aplica `RasterImageLimits` (16 384 px de lado, 16 Mpx) **antes** de alocar,
para uma imagem hostil não derrubar o processo. Hoje `decodeJpeg2000` aloca
`width * height * comps` a partir do `SIZ` sem checar nada, e a estrutura
interna aloca bem mais que isso.

Correção: `probeJpeg2000` público (o `HeaderDecoder.readMainHeader` já faz o
trabalho) e `Jpeg2000DecodeOptions.maxPixels` / `maxDimension` com
`Jpeg2000BudgetException`.

### 4.5 Encoder só aceita PNM

`encodeJpeg2000` recebe bytes de PGM/PPM, não pixels. Quem tem um buffer RGBA
em memória (o caso do `dart_ui` e de qualquer app) precisa serializar um PPM
para o codec desserializar em seguida. Adicionar
`encodeJpeg2000Pixels(Uint8List pixels, {width, height, components,
bitsPerComponent, options})`, e o PNM vira um caso especial por cima.

### 4.6 Subamostragem em J2K cru

`_collectImage` calcula `tOffx` com `getCompSubsX` mas escreve
`pixels[(imageRow * width + imageCol) * outputComponents + component]` com o
`width` da imagem inteira. Com JP2, o `Resampler` da cadeia de cor sobe as
componentes para resolução plena antes disso. Com J2K cru (sem caixa de cor)
e componentes subamostradas (YCC 4:2:0), o índice não bate. Nenhuma fixture
cobre esse caso. Ou o resampler roda sempre, ou a API rejeita com
`Jpeg2000UnsupportedException` em vez de escrever fora do lugar.

### 4.7 Assinaturas frouxas

- `decodeJpeg2000Source(Object source)`: `Object` aceita qualquer coisa e falha
  em runtime. Melhor duas funções tipadas por plataforma, ou uma
  `Jpeg2000Source` selada.
- `Jpeg2000Codec` é uma classe com quatro métodos que só delegam para as
  funções soltas. Manter uma das duas formas.
- `Jpeg2000EncodeOptions.extraParameters: Map<String, String>` expõe os nomes
  de parâmetro do JJ2000 (`Clayers`, `Cblksiz`...) como API pública sem
  documentação. Ou documenta a lista, ou tira do contrato estável.
- `Jpeg2000Image` sem `==`, `toString`, e `pixels` mutável: ok, mas
  documentar que o buffer é do chamador.

### 4.8 Cobertura de decodificação a declarar no README

Encontrado no código: `UnsupportedError` para filtros wavelet custom
(`header_decoder.dart:426`), ordens de progressão fora das cinco padrão
(`file_bitstream_reader_agent.dart:1507`), e nenhuma menção a `PPM`/`PPT`
(cabeçalhos de pacote empacotados), `JPX` (Part 2), nem a JP2 com múltiplos
codestreams. O consumidor precisa saber disso na seção "Public API" do README.

## 5. Desempenho

| Cenário | Tempo | Custo por pixel |
|---|---|---|
| `file1.jp2` 768×512, VM JIT quente | ~0,68 s | 1,7 µs |
| `file1.jp2` 768×512, AOT | ~0,88 s | 2,2 µs |
| `relax.jp2` 400×300, VM JIT quente | ~32 ms | 0,27 µs |

A diferença entre as duas fixtures (6× por pixel) mostra que o custo não é só
da entropia: `file1.jp2` tem 1 layer e 5×3 reversível, então o que pesa é a
quantidade de code-blocks e o caminho de coleta. Dois pontos concretos:

- `_collectImage` pede **uma linha por vez por componente** com
  `getInternCompData(DataBlkInt(w: tileWidth, h: 1))`. Para 768×512×3 são
  1 536 chamadas que atravessam `ImgDataConverter → InvCompTransf →
  ImgDataConverter → InverseWT` a cada linha. Pedir o tile inteiro (ou
  faixas de 64 linhas) reduz a orquestração e permite copiar com
  `setRange`.
- O README já lista os alvos (MQ decoder, buffers de code-block, wavelet,
  conversão de cor) e mede 3 a 4× de distância para a referência Go. AOT mais
  lento que JIT é sinal de código genérico demais (dispatch virtual em laços
  quentes, `List<int>` em vez de `Int32List`, `num` em vez de `int`).

Para o `dart_ui` a consequência prática é: decodificar JPEG 2000 **sempre em
isolate** na VM (o pacote tem `compute_io.dart` em `foundation/`) e, no
navegador, aceitar o custo ou usar um Web Worker. E manter o orçamento de
pixels apertado até a otimização.

## 6. O que corrigir e adicionar no `dart_ui`

Hoje o `dart_ui` **não reconhece JPEG 2000 em lugar nenhum**. Um JP2 passado
para `decodeImage` cai em `UnsupportedImageFormatException('expected a PNG,
JPEG, or WebP signature')`, e um PDF com `/JPXDecode` mostra lixo (seção 6.5).

### 6.1 Decisão prévia: dependência ou vendorização

A regra do repositório é não adicionar dependências de terceiros ao
`pubspec.yaml`; JPEG e WebP foram vendorizados de `package:image` em
`lib/src/graphics/image/codecs/`. O `jpeg2000` é seu, 100 % Dart, sem
dependência além de `meta` e `web` (as mesmas duas do `dart_ui`). Há duas
saídas e a escolha é sua:

| Opção | Prós | Contras |
|---|---|---|
| **Dependência pub do próprio `jpeg2000`** (recomendada) | um único lugar para corrigir bugs e otimizar; 49 581 linhas não entram no `dart_ui`; o CI do codec já prova Web e Wasm | precisa publicar primeiro (seção 2); é a primeira dependência com código de runtime no `pubspec.yaml`; o teste de superfície pública deve garantir que `Jpeg2000Image` não vaze da API do `dart_ui` |
| Vendorizar em `lib/src/graphics/image/codecs/formats/jpeg2000/` | zero dependências, mesmo padrão do JPEG/WebP | 2,1 MB e 49 581 linhas duplicadas; os 477 lints entram no `dart analyze` do `dart_ui`; toda correção tem que ser feita duas vezes |

Nas duas opções vale a mesma regra do JPEG/WebP em
[raster_formats.dart](../lib/src/graphics/image/raster_formats.dart): "No
codec-internal type crosses this library's public API". O adaptador da seção
6.3 é a fronteira.

### 6.2 Reconhecimento do formato

Em [raster_formats.dart](../lib/src/graphics/image/raster_formats.dart):

- `isJpeg2000(bytes)`: assinatura JP2 (`00 00 00 0C 6A 50 20 20 0D 0A 87 0A`)
  **ou** codestream cru (`FF 4F FF 51`, SOC seguido de SIZ).
- `sniffImageFormat` devolve o novo `RasterImageFormat.jpeg2000`.
- Mensagem de `UnsupportedImageFormatException` atualizada nos dois pontos
  (`decodeImageWithCodec` e `decodeImageAsyncWithCodec`).

`RasterImageFormat` é usado em `switch` exaustivo em quatro lugares que
deixam de compilar até ganharem o caso novo:

| Arquivo | O que fazer |
|---|---|
| [raster_codec.dart](../lib/src/graphics/image/raster_codec.dart) `checkDimensions` | lançar a nova `Jpeg2000DecodeException` |
| [raster_formats.dart](../lib/src/graphics/image/raster_formats.dart) `decodeImageWithCodec` | `RasterImageFormat.jpeg2000 => _decodeJpeg2000Dart(...)` |
| [native_raster_codec_web.dart](../lib/src/graphics/image/native_raster_codec_web.dart) `_mimeType` | `image/jp2`. Só o Safari decodifica JP2 nativamente; Chrome e Firefox rejeitam o `createImageBitmap` e o código já cai para o Dart. |
| [turbojpeg_codec.dart](../lib/src/graphics/image/native/turbojpeg_codec.dart) | já devolve `null` para tudo que não é JPEG, nada a fazer |

Caminho nativo por plataforma (`native_raster_codec_io.dart`):

- Windows/WIC: não há codec JPEG 2000 no Windows por padrão; `tryDecodeWic`
  precisa devolver `null` para esse formato sem tentar (o `CreateDecoderFromStream`
  falha, mas custa uma chamada COM).
- macOS/ImageIO: decodifica JP2 nativamente. Vale ligar, com a fixture
  comparada byte a byte contra o Dart, seguindo a regra do repositório de que
  teste headless não prova o backend.
- Linux: sem caminho nativo; Dart puro.

### 6.3 Adaptador `Jpeg2000Image → DecodedImage`

Novo `_decodeJpeg2000Dart` ao lado de `_decodeJpegDart`:

1. `probeJpeg2000` (seção 4.4) e `limits.checkDimensions` **antes** de decodificar.
2. `decodeJpeg2000` dentro de `try` traduzindo `Jpeg2000Exception` para
   `Jpeg2000DecodeException` (nova subclasse selada em `image_errors.dart`,
   ao lado de `JpegDecodeException`).
3. Expandir para 4 bytes por pixel na ordem pedida (`order.redIndex`,
   `order.blueIndex`), `gray8` replicado nos três canais, alfa 255 quando não
   há.
4. Quando houver alfa e ele **não** for premultiplicado, passar cada canal
   por `premultiplyChannel`. Isso depende do 4.1 estar feito no codec; até
   lá, um JP2 com alfa vai ser tratado como opaco e o relatório deve dizer
   isso na doc do widget.
5. `hasAlpha` verdadeiro só se o alfa existir e não for 255 em todo pixel,
   como faz o caminho web.

### 6.4 Assíncrono e orçamento

- `decodeImageAsync` na VM completa síncrono. Para JPEG 2000 é aceitável só
  atrás de `compute_io.dart`; o widget de imagem
  ([widgets/image.dart](../lib/src/widgets/image.dart)) que chama
  `decodeImage` na linha 272 deve usar o caminho assíncrono quando o formato
  for `jpeg2000`, senão a UI trava por segundos em uma foto comum.
- `RasterImageLimits` padrão (16 Mpx) permite 40 s de decodificação com o
  codec atual. Até a otimização, um limite específico
  (`maxJpeg2000Pixels`, ou um `RasterImageLimits.jpeg2000` de 4 Mpx) é
  prudente.

### 6.5 PDF: `/JPXDecode`

Cadeia hoje:

1. [pdf_object.dart:331-335](../lib/src/pdf/format/pdf_object.dart#L331-L335):
   `JPXDecode` cai no `default` e passa os bytes adiante intactos (correto).
2. [pdf_image_decoder.dart:25-32](../lib/src/pdf/render/pdf_image_decoder.dart#L25-L32):
   `sniffImageFormat` não reconhece JP2, devolve `null`, e o decodificador
   trata o codestream **como amostras cruas** de `BitsPerComponent` bits:
   resultado é ruído, ou `null` se o tamanho não bater.

Depois do 6.2 o sniff passa a reconhecer e o caminho de pass-through
funciona, mas JPX em PDF tem regras próprias (ISO 32000-1, 7.4.9) que
precisam entrar em `decodePdfImage`:

- Se o dicionário **não** tem `/ColorSpace`, o espaço de cor vem do JP2
  (caixa `colr`), e `/Decode` deve ser ignorado.
- Se tem `/ColorSpace`, ele **substitui** o do JP2 e o número de componentes
  tem que bater; um `/Indexed` aqui usa as amostras como índices.
- `/SMaskInData 1` ou `2`: o alfa vem do próprio JPX (canal `cdef` de
  opacidade), `2` significa premultiplicado. Sem o 4.1 do codec isso não tem
  como funcionar.
- `BitsPerComponent` é opcional para JPX e a profundidade real vem do
  codestream, que pode ser 16 bits (4.2).
- O `Jpeg2000DecodeOptions.applyColorSpace` deve ficar `false` quando o PDF
  fornece `/ColorSpace`, para não aplicar ICC duas vezes.

O plano em
[PLANO_SUPORTE_PDF_E_CDR_PURO_DART.md](PLANO_SUPORTE_PDF_E_CDR_PURO_DART.md)
já lista JPX entre os decodificadores exigidos; este é o item que fecha aquele
compromisso.

### 6.6 Testes a adicionar no `dart_ui`

Rodar sempre com escopo e em série (`dart test test/graphics/image
--concurrency=1`):

- Sniff das duas assinaturas e de falsos positivos (PNG, lixo, `FF 4F` sozinho).
- Decodificação das fixtures pequenas (`icon32.jp2`, `barras_rgb.jp2`,
  `grad_final.jp2`) copiadas para `test/fixtures/`, comparadas contra o BMP
  de referência que o codec já tem, nas duas ordens de canal.
- Orçamento: um `SIZ` declarando 100 000 × 100 000 deve dar
  `ImageBudgetException` sem alocar.
- Entradas truncadas e corrompidas devem dar `Jpeg2000DecodeException`, nunca
  `StateError`.
- PDF com `/JPXDecode` sem `/ColorSpace`, com `/ColorSpace /DeviceGray`, e com
  `/SMaskInData 1`.
- Teste de arquitetura: `Jpeg2000Image` e qualquer tipo `package:jpeg2000`
  não aparecem em `lib/dart_ui.dart` nem em `lib/src/graphics/image/raster_formats.dart`
  exports.

## 7. Encoder: o que falta para valer como encoder

Não bloqueia o `dart_ui`, que só precisa decodificar, mas faz diferença no
pub.dev, onde "codec" promete os dois lados:

- Entrada por pixels (4.5).
- Alfa e `cdef` na escrita do JP2 (`_wrapJp2` só escreve `colr` sRGB ou
  cinza, sem `cdef`, então um RGBA vira RGB + componente sem significado).
- 16 bits e componentes assinadas (o PNM limita a 8 bits sem sinal; o
  `ImgReaderPGX` existe no CLI e não na API).
- Parâmetros de qualidade documentados (`rate`, `layers`, tamanho de
  code-block, precincts, progressão), hoje só por `extraParameters`.
- Tiles: `tileWidth`/`tileHeight` existem, mas sem teste na API pública.

## 8. Ordem sugerida

No `jpeg2000`, na ordem em que uma etapa destrava a seguinte:

1. **Quebrar as duas cadeias até `dart:io`** (2.1) e adicionar o teste de
   imports. Sem isso o pub.dev não dá a tag Web e o `dart_ui` não compila
   para o navegador com a dependência.
2. **Hierarquia de exceções** (4.3), aproveitando que
   `CorruptedCodestreamException` já muda no passo 1.
3. **Alfa** (4.1) e **`probeJpeg2000` com limites** (4.4). São os dois que
   mudam a forma de `Jpeg2000Image`, então antes de fixar `1.0.0`.
4. **Logger silencioso e `print` fora** (seção 3).
5. `dart fix --apply`, chaves, super parameters, renames (seção 3).
6. `pubspec.yaml`, `CHANGELOG.md`, `example/`, licenças JJ2000 e Sun,
   `.pubignore`, README (2.2 e 2.3).
7. `dart pub publish --dry-run` limpo e `pana` em 160/160; publicar.
8. Depois: 16 bits (4.2), encoder por pixels (4.5 e 7), e a passada de
   desempenho (5), cada uma como versão menor.

No `dart_ui`, depois do passo 7 (ou do passo 3, se for vendorizar):

1. Decidir dependência ou vendorização (6.1).
2. Sniff, enum, `Jpeg2000DecodeException`, os quatro `switch` (6.2).
3. Adaptador para `DecodedImage` (6.3) e testes de fixtures (6.6).
4. Isolate no widget e limite de pixels (6.4).
5. `/JPXDecode` com as regras do PDF (6.5).
6. Caminho ImageIO no macOS com prova contra o Dart (6.2).

## Anexo — comandos usados nesta auditoria

```bash
# no jpeg2000
dart test -j 1 --reporter=compact
dart analyze
dart fix --dry-run
dart format --output=none --set-exit-if-changed .
dart doc --dry-run
dart pub publish --dry-run
dart pub global activate pana && dart pub global run pana --json .
```

O `pana` foi instalado como ferramenta global do `pub`, não entrou em nenhum
`pubspec.yaml`. Os scripts temporários de medição foram executados a partir de
`jpeg2000/build/` (pasta ignorada pelo git) e removidos ao final; nenhum
arquivo dos dois repositórios foi alterado além deste relatório.
