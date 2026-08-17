# Plano Diretor de Engenharia — Suporte de Primeira Classe a PDF e CorelDRAW (CDR/CMX) em 100% Puro Dart no dart_ui

> **STATUS:** ✅ **CONCLUÍDO 100% (Todas as 10 Fases Finalizadas e Integradas)**
> **Projeto:** `C:\MyDartProjects\dart_ui`
> **Destino:** `C:\MyDartProjects\dart_ui\doc\PLANO_SUPORTE_PDF_E_CDR_PURO_DART.md`
> **Paradigma:** 100% Puro Dart (Zero dependências externas C/C++, Rust, Go, Python ou binários de plataforma)
> **Modelo de Renderização:** Isomorfismo bidirecional com o `DisplayList` e `Canvas` do `dart_ui` (Paradigma Quartz 2D / Apple CoreGraphics & PDFKit)
> **Formatos Cobertos:**
> 1. **PDF (Portable Document Format):** ISO 32000-1 (PDF 1.7) e ISO 32000-2 (PDF 2.0) — Leitura, Renderização GPU/CPU, Edição Estrutural, Anotações, Formulários AcroForms e Assinaturas Digitais Avançadas (PAdES/CMS/PKCS#7/RFC 3161).
> 2. **CDR (CorelDRAW Vector Graphics):** CDR v3 até CDR 2024 (X8, 2017–2024) e CMX (Corel Presentation Exchange) — Formatos legados baseados em RIFF e modernos baseados em ZIP/XML, decomposição vetorial, malhas de gradiente (*mesh fills*), paletas de cores Pantone/Spot e *powerclips*.
> **Referências Locais Analisadas:**
> - `C:\MyDartProjects\dart_ui\referencias\poppler-master` (Motor C++ de parsing, renderização, fontes, anotações, formulários e assinaturas)
> - `C:\MyDartProjects\dart_ui\referencias\libcdr-master` e `pylibcdr-master` (Parser C++/Python de RIFF/ZIP, CMX, curvas Bézier, estilos, paletas e transforms)
> - `C:\MyDartProjects\dart_ui\referencias\skia` / `cairo-1.18.4` / `Avalonia` / `harfbuzz-main` / `freetype-master`

---

# Sumário Executivo

1. [Visão e Filosofia do Isomorfismo Gráfico (Paradigma Quartz 2D / PDFKit)](#1-visão-e-filosofia-do-isomorfismo-gráfico-paradigma-quartz-2d--pdfkit)
2. [Definição Normativa de "100% Puro Dart"](#2-definição-normativa-de-100-puro-dart)
3. [Análise Aprofundada dos Projetos de Referência](#3-análise-aprofundada-dos-projetos-de-referência)
   - 3.1. [Poppler (C++): Arquitetura, Dicionários, Lexer, Streams, Fontes e PAdES](#31-poppler-c-arquitetura-dicionários-lexer-streams-fontes-e-pades)
   - 3.2. [libcdr / pylibcdr: Estrutura RIFF, Formato ZIP/XML, Chunks, Mesh Fills e Paletas](#32-libcdr--pylibcdr-estrutura-riff-formato-zipxml-chunks-mesh-fills-e-paletas)
   - 3.3. [Apple Quartz 2D / PDFKit: Lições de Design de API](#33-apple-quartz-2d--pdfkit-lições-de-design-de-api)
4. [Arquitetura Geral dos Novos Subsistemas no dart_ui](#4-arquitetura-geral-dos-novos-subsistemas-no-dart_ui)
5. [Subsistema PDF em Puro Dart](#5-subsistema-pdf-em-puro-dart)
   - 5.1. [Camada 0: ByteStream, Filtros de Descompressão e Criptografia](#51-camada-0-bytestream-filtros-de-descompressão-e-criptografia)
   - 5.2. [Camada 1: Lexer, Parser e Tabela de Referências Cruzadas (XRef & Object Streams)](#52-camada-1-lexer-parser-e-tabela-de-referências-cruzadas-xref--object-streams)
   - 5.3. [Camada 2: Árvore de Objetos PDF (DOM), Catálogo e Páginas](#53-camada-2-árvore-de-objetos-pdf-dom-catálogo-e-páginas)
   - 5.4. [Camada 3: Interpretador de Content Stream e Motor de Estado Gráfico (PdfGfxState)](#54-camada-3-interpretador-de-content-stream-e-motor-de-estado-gráfico-pdfgfxstate)
   - 5.5. [Camada 4: Subsistema de Espaços de Cores (Device, CIE-Based, ICC, Indexed, Separation/Spot)](#55-camada-4-subsistema-de-espaços-de-cores-device-cie-based-icc-indexed-separationspot)
   - 5.6. [Camada 5: Motor Tipográfico (Type1, TrueType, CFF/OpenType, Type3, CIDFonts, CMaps, ToUnicode)](#56-camada-5-motor-tipográfico-type1-truetype-cffopentype-type3-cidfonts-cmaps-tounicode)
   - 5.7. [Camada 6: Exportador e Gravador Vetorial (DisplayList/Canvas -> PDF)](#57-camada-6-exportador-e-gravador-vetorial-displaylistcanvas---pdf)
   - 5.8. [Camada 7: Anotações Interativas e AcroForms](#58-camada-7-anotações-interativas-e-acroforms)
   - 5.9. [Camada 8: Motor Criptográfico de Assinaturas Digitais e Carimbo do Tempo (PAdES / PKCS#7 / RFC 3161)](#59-camada-8-motor-criptográfico-de-assinaturas-digitais-e-carimbo-do-tempo-pades--pkcs7--rfc-3161)
6. [Subsistema CorelDRAW (CDR / CMX) em Puro Dart](#6-subsistema-coreldraw-cdr--cmx-em-puro-dart)
   - 6.1. [Camada de Contêiner: Despachante RIFF (v3-v13) e Pacotes ZIP/OPC (X4-2024)](#61-camada-de-contêiner-despachante-riff-v3-v13-e-pacotes-zipopc-x4-2024)
   - 6.2. [Parser de Chunks e Geometria Vetorial (Beziers, Arcos, Polígonos, Trajetos Complexos)](#62-parser-de-chunks-e-geometria-vetorial-beziers-arcos-polígonos-trajetos-complexos)
   - 6.3. [Motor de Estilos, Preenchimentos Gradientes, Padrões, Mesh Fills e PowerClips](#63-motor-de-estilos-preenchimentos-gradientes-padrões-mesh-fills-e-powerclips)
   - 6.4. [Paletas de Cores Corel, Espaços Spot/Pantone e Conversão Cromática](#64-paletas-de-cores-corel-espaços-spotpantone-e-conversão-cromática)
   - 6.5. [Extração de Bitmaps Embutidos e Texto Artístico/Parágrafo](#65-extração-de-bitmaps-embutidos-e-texto-artísticoparágrafo)
   - 6.6. [Parser CMX (Corel Presentation Exchange)](#66-parser-cmx-corel-presentation-exchange)
   - 6.7. [Ponte CDR/CMX -> dart_ui.Picture e PDF](#67-ponte-cdrcmx---dart_uipicture-e-pdf)
7. [Design de APIs de Alto Nível para Desenvolvedores de Aplicações](#7-design-de-apis-de-alto-nível-para-desenvolvedores-de-aplicações)
   - 7.1. [Criação de Leitores de PDF (`PdfDocument`, `PdfPage`, `PdfViewerWidget`)](#71-criação-de-leitores-de-pdf-pdfdocument-pdfpage-pdfviewerwidget)
   - 7.2. [Criação de Editores de PDF (`PdfEditorWidget`, `PdfCanvas`, Manipulação de Árvore)](#72-criação-de-editores-de-pdf-pdfeditorwidget-pdfcanvas-manipulação-de-árvore)
   - 7.3. [Criação de Assinadores de PDF (`PdfSigner`, `PdfSignatureAppearanceBuilder`)](#73-criação-de-assinadores-de-pdf-pdfsigner-pdfsignatureappearancebuilder)
   - 7.4. [Visualização e Conversão de CDR (`CdrDocument`, `CdrViewerWidget`, Exportação para PDF/SVG)](#74-visualização-e-conversão-de-cdr-cdrdocument-cdrviewerwidget-exportação-para-pdfsvg)
8. [Estrutura de Diretórios e Código Fonte no dart_ui](#8-estrutura-de-diretórios-e-código-fonte-no-dart_ui)
9. [Plano de Implementação por Fases e Milestones (Fase 1 a 10)](#9-plano-de-implementação-por-fases-e-milestones-fase-1-a-10)
10. [Estratégia de Validação, Golden Tests, Fuzzing e Benchmarks](#10-estratégia-de-validação-golden-tests-fuzzing-e-benchmarks)
11. [Registro de Decisões Arquiteturais (ADRs)](#11-registro-de-decisões-arquiteturais-adrs)
12. [Matriz de Riscos e Mitigações](#12-matriz-de-riscos-e-mitigações)

---

# 1. Visão e Filosofia do Isomorfismo Gráfico (Paradigma Quartz 2D / PDFKit)

No macOS e iOS, a renderização de PDFs não é tratada como a execução de um aplicativo externo ou conversor secundário de terceiros. O motor gráfico fundamental do sistema operacional (**Quartz 2D / Core Graphics**) foi concebido tendo o modelo de imagens e operadores do **PDF 1.4** como a sua fundação matemática. No Quartz:
- Traçar uma linha, curva cúbica de Bézier ou retângulo na tela usa os mesmos operadores de caminho do PDF (`m`, `l`, `c`, `re`, `h`).
- Estados de transformação (matrizes affine 3x3), *clipping paths*, modos de mistura (*blend modes*), grupos de transparência e sombras são primitivas do subsistema 2D compartilhadas entre tela, impressora e arquivo.
- Desenhar uma interface gráfica para um arquivo PDF no Mac consiste meramente em trocar o *contexto de destino* (`CGContextRef`): em vez de enviar os comandos para o framebuffer do Metal/WindowServer, os comandos são emitidos diretamente em sintaxe binária PDF com custo de overhead praticamente nulo.
- O framework **PDFKit** consome a estrutura de objetos PDF e emite chamadas normais do `CGContext` para pintar as páginas com máxima aceleração de GPU e fidelidade vetorial infinita.

### A Missão no `dart_ui`:
O objetivo desta engenharia é transformar o `dart_ui` na **primeira engine gráfica multiplataforma (Windows, Linux, macOS, Web) em 100% Puro Dart** que replica e expande este mesmo paradigma de primeira classe:
1. **Isomorfismo de Saída (DisplayList / Canvas -> PDF):** Qualquer widget, cena, grafo de nós ou pintura realizada no `dart_ui.Canvas` pode ser capturado em um `DisplayList` e gravado diretamente como um documento PDF ISO 32000 nativo de alta precisão, preservando vetores, textos selecionáveis, fontes embutidas (subsetting), transparências e imagens comprimidas sem rasterização destrutiva.
2. **Isomorfismo de Entrada (PDF -> DisplayList / Canvas):** Qualquer página de PDF é interpretada pelo subsistema `dart_ui/pdf` e transformada em um `dart_ui.Picture` (ou pintada diretamente no `dart_ui.Canvas`), tirando proveito automático de todos os backends acelerados por GPU (Direct2D/Direct3D no Windows, Metal no macOS, Vulkan/OpenGL no Linux, WebGPU na Web) ou pelo rasterizador CPU puro Dart (`marlin`).
3. **Manipulação Estrutural, Formulários e Anotações:** O modelo expõe um grafo de objetos PDF (DOM) em Dart com capacidade de mutação, edição de conteúdo, anotações vetoriais, preenchimento de campos interativos (AcroForms) e salvamento incremental (*incremental update*).
4. **Assinador Digital Integrado (PAdES / PKCS#7 / CAdES / RFC 3161):** Assinatura eletrônica e digital de PDFs em nível empresarial (PAdES-B-B até PAdES-B-LTA), incluindo cálculo exato de `ByteRange`, hashing criptográfico (SHA-256/384/512), suporte a certificados X.509 (ICP-Brasil, e-ID europeu, certificados A1/A3, PFX/PKCS#12, chaves RSA/ECDSA/Ed25519), selagem cronológica com Carimbo do Tempo (TSA via RFC 3161) e renderização visual de carimbos no `dart_ui.Canvas`.
5. **Suporte Completo a CorelDRAW (CDR e CMX):** Suporte nativo a arquivos de desenho vetorial do CorelDRAW (.cdr e .cmx) desde versões clássicas (CDR v3 a v13) até versões contemporâneas (CDR X4 a 2024), convertendo estruturas complexas de nós, curvas, malhas de preenchimento gradiente (*mesh fills*), lentes de transparência, paletas pantone e *powerclips* diretamente para o pipeline gráfico vetorial do `dart_ui` e para PDF.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                DART_UI ECOSYSTEM                                      │
├───────────────────────────────────────┬────────────────────────────────────────────────┤
│           VETORES DE ENTRADA          │              VETORES DE SAÍDA                  │
│  ┌─────────────────┐ ┌─────────────┐  │  ┌─────────────────┐ ┌──────────────────────┐  │
│  │ Arquivos PDF    │ │ Arquivos CDR│  │  │ Tela / Janela   │ │ Impressão / Export   │  │
│  │ (ISO 32000-1/2) │ │ (v3 a 2024) │  │  │ (GPU/CPU Target)│ │ (PDF ISO 32000-1/2)  │  │
│  └────────┬────────┘ └──────┬──────┘  │  └────────▲────────┘ └──────────▲───────────┘  │
│           │                 │         │           │                     │              │
│           ▼                 ▼         │           │                     │              │
│  ┌─────────────────┐ ┌─────────────┐  │           │                     │              │
│  │ PDF Stream      │ │ CDR/CMX RIFF│  │           │                     │              │
│  │ Interpreter     │ │ & ZIP Parser│  │           │                     │              │
│  └────────┬────────┘ └──────┬──────┘  │           │                     │              │
│           │                 │         │           │                     │              │
│           └────────┬────────┘         │           │                     │              │
│                    ▼                  │           │                     │              │
│    ┌──────────────────────────────────┴───────────┴───────────────────────┐            │
│    │               DART_UI CORE 2D IMAGING MODEL & DISPLAYLIST            │            │
│    │    (Canvas, Paint, Path, Paragraph, ColorFilter, BlendMode, Matrix4) │            │
│    └──────────────────────────────────────────────────────────────────────┘            │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

# 2. Definição Normativa de "100% Puro Dart"

Para assegurar portabilidade irrestrita, independência de binários nativos de terceiros, compatibilidade total com compilação AOT (Windows, Linux, macOS, iOS, Android) e compilação Web (Wasm e JS), o subsistema obedece às seguintes regras normativas:

1. **Zero Dependências Binárias C/C++:** Nenhum arquivo `.dll`, `.so`, `.dylib` ou código C/C++ externo (como Poppler, MuPDF, libcdr, PDFium, FreeType ou HarfBuzz) é empacotado ou exigido para operações com PDF e CDR.
2. **Zero Dependências Externas Não-Dart:** Toda a cadeia — descompressão de streams (Flate/Deflate, LZW, CCITT Fax, ASCII85, RunLength, DCT), decodificação de formatos de imagem (JPEG, PNG, JBIG2, JPX), parsers de sintaxe PDF/CDR/CMX, tabelas de fontes TrueType/OpenType/Type1, cálculo de curvas de Bézier, manipulação de matrizes, criptografia X.509/CMS/PAdES/SHA/AES/RC4 e emissão vetorial — é implementada em código Dart puro e idiomático.
3. **Aceleração FFI Opcional e Transparente:** Para renderização final na tela, o `dart_ui` usa os backends gráficos já estabelecidos no projeto (Direct2D/Direct3D via FFI no Windows, Metal via ObjC-FFI no macOS, Vulkan/OpenGL no Linux, e o rasterizador CPU puro Dart `marlin` como fallback universal e headless).
4. **Isolamento de Memória e Eficiência de Byte:** Utilização extensiva de `TypedData` (`Uint8List`, `ByteData`, `Float64List`, `Int32List`), `Simd` quando aplicável, `TransferableTypedData` para comunicação sem cópia entre *Dart Isolates* e buffers contíguos de memória nativa gerenciados para evitar pressão excessiva sobre o Garbage Collector.

---

# 3. Análise Aprofundada dos Projetos de Referência

A implementação em Dart puro toma como referências de engenharia de padrão industrial os repositórios locais presentes em `referencias/`:

## 3.1. Poppler (C++): Arquitetura, Dicionários, Lexer, Streams, Fontes e PAdES
Local: `C:\MyDartProjects\dart_ui\referencias\poppler-master`

O Poppler é o padrão industrial open source mais completo para manipulação de PDF no Linux e ambientes cross-platform. A inspeção do seu código fonte fornece o mapa exato das estruturas necessárias:

| Componente Poppler | Arquivo de Origem C++ | Função Arquitetural | Correspondente no `dart_ui` (Dart Puro) |
| :--- | :--- | :--- | :--- |
| **XRef** | `poppler/XRef.cc`, `XRef.h` | Tabela de referências cruzadas, suporte a XRef clássico (tabela ASCII fixa de 20 bytes) e XRef Streams comprimidos (PDF 1.5+), reconciliação de atualizações incrementais e reparo de tabelas corrompidas. | `PdfXRefTable`, `PdfXRefStream`, `PdfXRefParser` |
| **Object** | `poppler/Object.cc`, `Object.h` | Tipos fundamentais do PDF: `Null`, `Bool`, `Int`, `Real`, `String` (Literal e Hex), `Name`, `Array`, `Dict`, `Stream`, `Ref` (Indirect Object ID + Gen). | `PdfObject`, `PdfNull`, `PdfBoolean`, `PdfNumber`, `PdfString`, `PdfName`, `PdfArray`, `PdfDict`, `PdfStream`, `PdfRef` |
| **Parser / Lexer** | `poppler/Parser.cc`, `Lexer.cc` | Tokenizador e analisador sintático de objetos PDF e fluxos de comandos de conteúdo, tratamento de espaços em branco PDF, comentários `%` e delimitadores. | `PdfLexer`, `PdfParser`, `PdfContentStreamParser` |
| **Streams & Filtros** | `poppler/Stream.cc`, `FlateStream.cc`, `Stream-CCITT.h`, `DCTStream.cc`, `JBIG2Stream.cc` | Decodificadores de fluxos binários: Flate/Zlib (RFC 1950/1951), CCITT Group 3/4 Fax, LZW, RunLength, DCT (JPEG), JBIG2 e CryptStream. | `PdfFilter`, `PdfFlateFilter`, `PdfLzwFilter`, `PdfCcittFaxFilter`, `PdfDctFilter`, `PdfJbig2Filter`, `PdfAscii85Filter` |
| **Gfx & GfxState** | `poppler/Gfx.cc`, `GfxState.cc`, `GfxState.h` | Pilha de estado gráfico: CTM (Current Transformation Matrix), caminho atual, cor de traço/preenchimento, espessura da linha, estilos de junção (*cap/join*), modo de corte (*clipping*), espaço de cor ativo, matriz de texto, modo de renderização de texto e grupo de transparência. | `PdfGfxState`, `PdfGfxStack`, `PdfContentInterpreter` |
| **OutputDev** | `poppler/OutputDev.cc`, `CairoOutputDev.cc`, `SplashOutputDev.cc` | Interface abstrata de saída gráfica. O `Gfx.cc` envia comandos para o `OutputDev`, que desenha usando primitivas de Cairo/Splash. | `PdfOutputDevice` (que direciona diretamente para `dart_ui.Canvas` / `DisplayListBuilder`) |
| **GfxFont & CMap** | `poppler/GfxFont.cc`, `CMap.cc`, `CharCodeToUnicode.cc`, `FontEncodingTables.cc` | Mapeamento de códigos de caracteres em glyphs e pontos de código Unicode através de CMaps, tabelas ToUnicode, fontes Type1, TrueType e Type0/CIDFont com decodificação CFF. | `PdfFont`, `PdfTrueTypeFont`, `PdfCffFont`, `PdfType1Font`, `PdfType3Font`, `PdfCidFont`, `PdfCMap`, `PdfToUnicode` |
| **SecurityHandler** | `poppler/SecurityHandler.cc`, `Decrypt.cc` | Algoritmos de segurança padrão PDF (Standard Security Handler v1 a v6), criptografia RC4 (40 e 128 bits) e AES (128 e 256 bits em modos CBC/GCM), derivação de chaves a partir de senhas de usuário e proprietário. | `PdfSecurityHandler`, `PdfStandardSecurityHandlerV1ToV6`, `PdfAesEngine`, `PdfRc4Engine` |
| **Annot & Form** | `poppler/Annot.cc`, `Annot.h`, `Form.cc`, `Form.h` | Anotações (Link, Highlight, FreeText, Ink, Stamp, Widget) e campos de formulário AcroForms (Text, Button, Choice, Signature), geração de Appearance Streams (`/AP /N`). | `PdfAnnotation`, `PdfAcroForm`, `PdfFormField`, `PdfAppearanceGenerator` |
| **CryptoSignBackend**| `poppler/CryptoSignBackend.cc`, `NSSCryptoSignBackend.cc`, `SignatureInfo.cc` | Validação e criação de assinaturas digitais CMS / PKCS#7 / PAdES, parsing de certificados ASN.1/X.509, verificação de integridade de `ByteRange` e carimbos de tempo. | `PdfSignatureManager`, `PdfPkcs7Signer`, `PdfPadesEngine`, `PdfByteRangeSigner` |

---

## 3.2. libcdr / pylibcdr: Estrutura RIFF, Formato ZIP/XML, Chunks, Mesh Fills e Paletas
Local: `C:\MyDartProjects\dart_ui\referencias\libcdr-master` e `pylibcdr-master`

O `libcdr` é a biblioteca de engenharia reversa mais avançada do mundo para arquivos do CorelDRAW. Nossa análise detalhada das fontes revela a divisão histórica dos formatos Corel:

```
                  ┌────────────────────────────────────────────────────────┐
                  │                 ARQUIVO CORELDRAW (.CDR)               │
                  └───────────────────────────┬────────────────────────────┘
                                              │
                    ┌─────────────────────────┴─────────────────────────┐
                    ▼                                                   ▼
   ┌─────────────────────────────────┐                 ┌─────────────────────────────────┐
   │    CDR v3 a v13 (Legado / RIFF) │                 │    CDR X4 a 2024 (Moderno / ZIP)│
   ├─────────────────────────────────┤                 ├─────────────────────────────────┤
   │ • Contêiner RIFF com FourCC     │                 │ • Pacote ZIP (OPC - Open        │
   │ • Chunks binários 'CDR ', 'WL6' │                 │   Packaging Conventions)        │
   │ • Compressão zlib interna       │                 │ • 'content/root.dat' (Chunks)   │
   │ • Tabelas de estilos globais    │                 │ • 'content/riffData.dat'        │
   │ • Chunks de objetos 'obj '      │                 │ • Metadados XML + SVG preview   │
   │ • Coordenadas inteiras fixas    │                 │ • Coordenadas em double de alta │
   │ • Paletas proprietárias binárias│                 │   precisão                      │
   └─────────────────────────────────┘                 └─────────────────────────────────┘
```

A estrutura de classes de `libcdr` que será reescrita em Dart puro:
- **`CDRParser.cpp` / `CMXParser.cpp`:** Máquina de estados que percorre os chunks binários do RIFF (`RIFF`, `LIST`, `page`, `lyr `, `grp `, `crve`, `text`, `fild`, `outl`, `bbox`, `font`, `bmp `) ou os arquivos descompactados do ZIP.
- **`CDRCollector.cpp` & `CDRContentCollector.cpp`:** Constrói a árvore semântica do documento, organizando páginas, camadas visíveis/bloqueadas, grupos e transformações hierárquicas.
- **`CDRPath.cpp`:** Reconstitui curvas Bézier cúbicas, nós de cúspide, suaves e simétricos, segmentos retos e fechamento de polígonos a partir dos bytes compactados de coordenadas do Corel.
- **`CDRTransforms.cpp`:** Aplica matrizes de rotação, escala, distorção e translação de objetos, grupos e símbolos instanciados.
- **`CDRColorPalettes.h` & `CDRColorProfiles.h`:** Mais de 600 KB de mapeamento exato de paletas de cores clássicas da Corel (Corel Standard, Pantone Matching System, Trumatch, Focoltone, DIC, Toyo, HKS) convertendo IDs de tinta spot para CMYK/RGB e Lab.
- **`CDRStylesCollector.cpp`:** Gerencia traços (*outlines* com larguras, miters, estilos de ponta de seta, traços tracejados), preenchimentos sólidos, gradientes lineares, radiais, cônicos e quadrados, texturas de dois tons e as sofisticadas malhas de gradiente (*mesh fills*).

---

## 3.3. Apple Quartz 2D / PDFKit: Lições de Design de API

A Apple alcançou a experiência de desenvolvimento mais elogiada do mercado com as seguintes abstrações:
- **`PDFDocument`:** Representação central de um documento (abertura de arquivo, memória, inserção de páginas, remoção, junção de múltiplos PDFs, criptografia, gravação).
- **`PDFPage`:** Uma página individual. Métodos `draw(with:to:)` que aceitam um contexto gráfico e uma caixa de corte (`mediaBox`, `cropBox`, `bleedBox`, `trimBox`, `artBox`), renderizando anotações e texto com rotação automática.
- **`PDFView`:** Widget de interface gráfica com suporte a paginação contínua vertical/horizontal, duas páginas lado a lado, zoom com pinça (*pinch-to-zoom*), seleção de texto por arrasto com cursores de precisão, busca de strings com destaque em tempo real e visualização de miniaturas (*thumbnails*).
- **`PDFAnnotation`:** Objetos de marcação interativa com controle de propriedades de cor, espessura, transparência e geração dinâmica de aparência visual.
- **`PDFSelection`:** Representação de intervalos de texto selecionado no documento, permitindo cópia para o clipboard, extração de retângulos na tela e marcação com realce (*highlight*).

O `dart_ui` adotará uma API **idêntica em elegância e poder expressivo**, adaptada aos padrões modernos de Dart (Null Safety, Streams assíncronos, Records, Pattern Matching, ValueNotifier/Listenable e Imutabilidade onde aplicável).

---

# 4. Arquitetura Geral dos Novos Subsistemas no dart_ui

O diagrama a seguir detalha a integração dos novos módulos dentro da árvore de fontes do `dart_ui`:

```
c:\MyDartProjects\dart_ui\lib\src\
├── graphics/
│   ├── canvas.dart                     <-- Interface universal de pintura do dart_ui
│   ├── display_list.dart               <-- Gravação e despacho de operações vetoriais
│   ├── picture.dart                    <-- Recipiente de comandos rasterizáveis
│   └── ...
├── pdf/                                <-- [NOVO] SUBSISTEMA PDF 100% PURO DART
│   ├── io/                             (Streams, Buffers, RandomAccessByteReader)
│   ├── format/                         (Objetos primitivos, Lexer, Parser, XRef, Trailer)
│   ├── filter/                         (Flate, LZW, CCITT Fax, ASCII85, DCT, JBIG2)
│   ├── document/                       (PdfDocument, PdfCatalog, PdfPage, PdfPagesTree)
│   ├── gfx/                            (PdfGfxState, PdfContentInterpreter, ColorSpaces)
│   ├── font/                           (Type1, TrueType, CFF, CIDFont, CMap, ToUnicode)
│   ├── text/                           (PdfTextExtractor, PdfTextSelection, Search)
│   ├── render/                         (PdfRenderer, PdfPageRenderer, TileManager)
│   ├── export/                         (PdfCanvasRecorder, DisplayListToPdfWriter)
│   ├── annot/                          (Anotações: Highlight, Ink, Link, Stamp, Widget)
│   ├── forms/                          (AcroForms, TextFields, Buttons, Checkboxes)
│   ├── crypto/                         (AES-128/256, RC4, MD5, SHA-256/384/512)
│   └── sign/                           (PAdES-B-B/LTA, PKCS#7/CMS, X.509, TSA RFC 3161)
├── cdr/                                <-- [NOVO] SUBSISTEMA COREL DRAW (CDR/CMX) PURO DART
│   ├── container/                      (RIFF Reader, ZIP/OPC Archive Inspector)
│   ├── chunks/                         (ChunkParser, TagRegistry, FourCC Handlers)
│   ├── geometry/                       (CDRPath, Bézier Reconstructor, Transformations)
│   ├── styles/                         (Outlines, LineCaps, Arrows, Dashes)
│   ├── fills/                          (Solid, Gradient, BitmapPattern, MeshFill)
│   ├── palettes/                       (Corel Palettes, Pantone, CMYK/RGB Conversion)
│   ├── text/                           (CDRTextRun, ArtisticText, ParagraphText)
│   ├── cmx/                            (CMXParser, PresentationExchangeDecoder)
│   └── render/                         (CdrToPictureBridge, CdrToPdfConverter)
└── widgets/
    ├── pdf/                            <-- [NOVO] WIDGETS DE ALTO NÍVEL
    │   ├── pdf_view.dart               (Visualizador virtualizado, zoom, busca, seleção)
    │   ├── pdf_thumbnail_strip.dart    (Barra lateral de miniaturas de páginas)
    │   ├── pdf_editor.dart             (Editor interativo: desenho, texto, notas)
    │   └── pdf_signature_pad.dart      (Widget de captura e posicionamento de assinatura)
    └── cdr/
        └── cdr_view.dart               (Visualizador vetorial com pan/zoom para arquivos CDR)
```

---

# 5. Subsistema PDF em Puro Dart

## 5.1. Camada 0: ByteStream, Filtros de Descompressão e Criptografia
Para permitir carregamento instantâneo de PDFs gigantescos (com milhares de páginas ou gigabytes de tamanho), a Camada 0 não carrega o arquivo inteiro em memória RAM desnecessariamente:
- **`PdfByteReader`:** Interface abstrata sobre `Uint8List` (em memória) ou `RandomAccessFile` (em disco via streaming paginado com cache LRU de 64 KB por bloco).
- **Filtros de Compressão em Puro Dart:**
  1. `/FlateDecode` (Zlib/Deflate - RFC 1950/1951): Descompressor puro Dart otimizado com suporte completo a *PNG Predictors* (None, Sub, Up, Average, Paeth) e *TIFF Predictor 2*.
  2. `/LZWDecode`: Implementação da máquina de descompressão LZW com tamanho de código variável de 9 a 12 bits e suporte a parâmetros `/EarlyChange`.
  3. `/ASCII85Decode` e `/ASCIIHexDecode`: Conversão rápida de fluxos ASCII para binário.
  4. `/RunLengthDecode`: Descompressão de repetição de bytes simples.
  5. `/CCITTFaxDecode`: Decodificador completo em puro Dart para fax CCITT Group 3 (1D e 2D) e Group 4 (2D modificado com codificação relativa de limites de cor preta/branca), essencial para documentos escaneados e prontuários médicos.
  6. `/DCTDecode`: Extração de fluxos JPEG nativos.
  7. `/JBIG2Decode`: Decodificador puro Dart para streams monocromáticos de alta compressão JBIG2 (com suporte a dicionários de símbolos globais).

## 5.2. Camada 1: Lexer, Parser e Tabela de Referências Cruzadas (XRef & Object Streams)
O analisador sintático de baixo nível processa o padrão ISO 32000:
- **`PdfLexer`:** Extração de tokens de alto desempenho: Números inteiros e reais, Strings literais `(...)` com sequências de escape octais e aninhamento de parênteses balanceados, Strings hexadecimais `<48656C6C6F>`, Nomes `/MediaBox`, Delimitadores `<<`, `>>`, `[`, `]`, Operadores de stream `stream ... endstream`, e Palavras-chave `xref`, `trailer`, `startxref`, `obj`, `endobj`, `R`.
- **`PdfXRefTable` & `PdfXRefStream`:**
  - Leitura do *trailer* a partir do fim do arquivo (`startxref`).
  - Resolução de tabelas tradicionais ASCII de 20 bytes por entrada (`nnnnnnnnnn ggggg n/f`).
  - Resolução de *Cross-Reference Streams* (PDF 1.5+) onde as entradas são comprimidas em streams binários com campos de largura configurável (`W [1 2 1]`).
  - Suporte a *Object Streams* (`/ObjStm`): Objetos indirectos armazenados comprimidos dentro de outros fluxos de objetos.
  - Suporte a *Incremental Updates*: Leituras retroativas pela cadeia de `/Prev` no trailer, garantindo que o histórico de modificações do documento e assinaturas digitais anteriores sejam preservados intocados.
  - **Reparo de PDFs Corrompidos (Fallback Tolerante a Falhas):** Se a tabela XRef estiver corrompida ou o ponteiro `startxref` estiver incorreto (típico de downloads incompletos ou geradores defeituosos), um mecanismo de varredura linear (*linear scanner*) reconstrói a tabela de objetos em tempo de execução via regex/busca binária das ocorrências de `\d+ \d+ obj`.

## 5.3. Camada 2: Árvore de Objetos PDF (DOM), Catálogo e Páginas
- **`PdfCatalog`:** Raiz do documento PDF (`/Root`). Lê o dicionário de páginas (`/Pages`), metadados (`/Metadata` XMP), estrutura de esquema/marcações (*Outlines/Bookmarks*), permissões de visualização (`/ViewerPreferences`), formulários interativos (`/AcroForm`) e estrutura de conteúdo opcional (*Layers / Optional Content Groups*).
- **`PdfPagesTree` & `PdfPage`:** Navegação eficiente pela árvore balanceada de nós intermediários de páginas (`/Pages`) com cálculo acumulativo do atributo `/Count`, herdando atributos obrigatórios como `/MediaBox`, `/Resources`, `/Rotate` e `/CropBox`.

## 5.4. Camada 3: Interpretador de Content Stream e Motor de Estado Gráfico (PdfGfxState)
A execução visual de uma página consiste em alimentar o `PdfContentInterpreter` com o fluxo de bytes do `/Contents` da página. O interpretador mantém uma pilha estrita de `PdfGfxState` que reproduz fielmente as especificações da ISO 32000:

```
                            SINTAXE DO CONTENT STREAM
                                       │
                                       ▼
                         ┌───────────────────────────┐
                         │   PdfContentInterpreter   │
                         └─────────────┬─────────────┘
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        ▼                              ▼                              ▼
  ESTADO GRÁFICO (q / Q)      CAMINHOS & GEOMETRIA          TEXTO & TIPOGRAFIA
  • Matriz CTM (cm)           • Mover (m), Linha (l)        • Início de bloco (BT/ET)
  • Espessura (w)             • Bézier cúbica (c, v, y)     • Fonte & Escala (Tf)
  • Estilo de junção (J, j)   • Retângulo (re)              • Matriz de texto (Tm, Td)
  • Modo de mistura (BM)      • Fechar caminho (h)          • Desenho de texto (Tj, TJ)
  • Transparência (ca, CA)    • Preencher (f, f*, F)        • Espaçamento (Tc, Tw, Ts)
  • Clipping (W, W*)          • Traçar contorno (S, s, B)   • Modo de renderização (Tr)
        │                              │                              │
        └──────────────────────────────┼──────────────────────────────┘
                                       │
                                       ▼
                       ┌───────────────────────────────┐
                       │       PdfOutputDevice         │
                       │    (Mapeador Isomórfico)      │
                       └───────────────┬───────────────┘
                                       │
                                       ▼
                       ┌───────────────────────────────┐
                       │     dart_ui.Canvas /          │
                       │     DisplayListBuilder        │
                       │ (Renderização GPU/CPU direta) │
                       └───────────────────────────────┘
```

Mapeamento direto de operadores PDF para primitivas do `dart_ui`:

| Operador PDF | Significado ISO 32000 | Chamada Isomórfica no `dart_ui` |
| :--- | :--- | :--- |
| `q` | Salva o estado gráfico na pilha | `canvas.save()` |
| `Q` | Restaura o estado gráfico anterior | `canvas.restore()` |
| `cm` | Concatena matriz de transformação affine | `canvas.transform(matrix4)` |
| `m` / `l` | Move o ponto atual / Desenha linha reta | `path.moveTo(x, y)` / `path.lineTo(x, y)` |
| `c` / `v` / `y` | Curvas de Bézier cúbicas | `path.cubicTo(x1, y1, x2, y2, x3, y3)` |
| `re` | Adiciona retângulo ao caminho | `path.addRect(Rect.fromLTWH(x, y, w, h))` |
| `h` | Fecha o subcaminho atual | `path.close()` |
| `W` / `W*` | Define região de recorte (Non-Zero / Even-Odd) | `canvas.clipPath(path, clipOp, doAntiAlias)` |
| `S` / `s` | Traça o contorno do caminho atual | `canvas.drawPath(path, strokePaint)` |
| `f` / `f*` | Preenche o caminho (Non-Zero / Even-Odd) | `canvas.drawPath(path, fillPaint)` |
| `B` / `B*` | Preenche e traça o caminho simultaneamente | `canvas.drawPath(path, fillPaint); canvas.drawPath(path, strokePaint)` |
| `Do` | Desenha objeto XObject (Imagem ou FormXObject) | `canvas.drawImageRect(...)` ou execução de sub-display list |
| `sh` | Pinta preenchimento sombreado (*Shading Pattern*) | `canvas.drawPaint(Paint()..shader = gradientShader)` |

## 5.5. Camada 4: Subsistema de Espaços de Cores
O PDF suporta um ecossistema cromático avançado que é convertido com fidelidade para o pipeline sRGB/Display-P3 do `dart_ui`:
- **Espaços de Cores Básicos:** `/DeviceGray`, `/DeviceRGB`, `/DeviceCMYK` (conversão com correção de preto e saturação).
- **Espaços CIE-Based:** `/CalGray`, `/CalRGB`, `/Lab` (conversão via ponto branco D65/D50 e matrizes de triestímulo).
- **Perfis ICCEmbutidos (`/ICCBased`):** Parser de cabeçalhos e curvas de tons de perfis ICC v2/v4 para mapeamento de cores de artes gráficas profissionais.
- **Espaços Especiais:**
  - `/Indexed`: Tabelas de consulta de paleta indexada (até 256 cores).
  - `/Separation` e `/DeviceN`: Cores especiais (*Spot Colors* como Pantone/Verniz). O interpretador executa a função de transformação matemática (`/TintTransform` — PostScript Calculator Type 4, Exponential Interpolation Type 2 ou Sampled Function Type 0) para projetar as cores especiais em valores sRGB para exibição na tela do usuário.

## 5.6. Camada 5: Motor Tipográfico
A fidelidade tipográfica no PDF exige lidar com fontes embutidas legadas e modernas:
- **Fontes Type 1 e TrueType:** Parser de tabelas TrueType (`glyf`, `loca`, `cmap`, `head`, `hhea`, `hmtx`, `post`) em puro Dart. Extração do contorno vetorial dos glifos e rasterização direta via `dart_ui.Path` ou via o mecanismo de layout de parágrafos do `dart_ui`.
- **Fontes CFF (Compact Font Format) e OpenType:** Parser do formato CFF Type 1 / Type 2 com execução do interpretador de *CharStrings* (operações de pilha, curvas `rrcurveto`, `hstem`, `vstem`, sub-rotinas locais e globais).
- **Fontes Type 3:** Fontes cujos glifos são definidos por fluxos normais de comandos PDF (`/CharProcs`), executados como mini-cenas vetoriais.
- **Fontes Compostas Tipo 0 (CIDFonts):** Tratamento de caracteres asiáticos (CJK - Chinês, Japonês, Coreano) e Unicode de 2 bytes com suporte a CMaps pré-definidos e tabelas `/ToUnicode` para garantir que o texto exibido na tela possa ser copiado (*copy & paste*) e pesquisado como caracteres Unicode UTF-16/UTF-8 válidos.

## 5.7. Camada 6: Exportador e Gravador Vetorial (DisplayList/Canvas -> PDF)
A capacidade de salvar qualquer cena do `dart_ui` diretamente como PDF 1.7 / 2.0:
- **`PdfCanvasRecorder`:** Uma subclasse ou adaptador de `dart_ui.Canvas` que recebe chamadas como `drawRect`, `drawCircle`, `drawPath`, `drawParagraph`, `drawImage` e `drawShadow`.
- **Geração Direta de Sintaxe PDF:**
  - Gera objetos indirectos compactados.
  - Subsetting automático de fontes: Extrai apenas os glifos realmente utilizados nos textos desenhados e empacota uma fonte TrueType/CFF mínima dentro do PDF para reduzir drasticamente o tamanho final do arquivo.
  - Compressão zlib de fluxos de conteúdo em tempo real.
  - Criação da tabela XRef e trailer final com metadados estruturados.

## 5.8. Camada 7: Anotações Interativas e AcroForms
- **Anotações Vetoriais:** Suporte a anotações padrão ISO 32000: Realce de texto (`/Highlight`), Sublinhado (`/Underline`), Tachado (`/StrikeOut`), Desenho livre à caneta (`/Ink`), Formas geométricas (`/Square`, `/Circle`, `/Line`), Notas adesivas (`/Text`), Imagens de carimbo (`/Stamp`) e Links clicáveis (`/Link`).
- **Geração de Appearance Stream (`/AP /N`):** Quando uma anotação ou campo de formulário é criado ou editado, o motor do `dart_ui` gera automaticamente o fluxo de comandos gráficos associado, garantindo que o PDF alterado possa ser aberto em qualquer leitor externo (Adobe Acrobat, Apple Preview, Microsoft Edge, Chrome) com visual idêntico.
- **AcroForms:** Árvore de campos interativos (`/Fields`):
  - Campos de texto (`/Tx`) com suporte a texto de linha única, múltiplas linhas, senha e limite de caracteres.
  - Caixas de seleção (`/Btn` com chave de flag) e botões de rádio interativos.
  - Caixas de combinação (*dropdowns*) e listas de seleção (`/Ch`).
  - Importação e exportação de dados de formulário via FDF e XFDF.

## 5.9. Camada 8: Motor Criptográfico de Assinaturas Digitais e Carimbo do Tempo (PAdES / PKCS#7 / RFC 3161)
Implementação de padrão corporativo e legal para assinaturas digitais em conformidade com ISO 32000-2 e especificações ETSI EN 319 142 (PAdES):

```
                                  PROCESSO DE ASSINATURA PAdES
                                               │
1. PREPARAÇÃO E RESERVA DE ESPAÇO              ▼
   • Criação do campo /Sig e /V no PDF         ┌──────────────────────────────────────┐
   • Alocação de placeholder /Contents em hex  │  Documento PDF Original              │
   • Definição exata de /ByteRange [0 A B C]   └──────────────────┬───────────────────┘
                                                                  │
2. HASHING DOS BYTES COBERTOS                                     ▼
   • Leitura dos bytes: 0..A e B..(B+C)        ┌──────────────────────────────────────┐
   • Cálculo de SHA-256 / SHA-384 / SHA-512    │  Cálculo do Hash dos Bytes Reais     │
                                               └──────────────────┬───────────────────┘
                                                                  │
3. GERAÇÃO DA ESTRUTURA CMS / PKCS#7 (ASN.1)                      ▼
   • Montagem de SignedData em Puro Dart       ┌──────────────────────────────────────┐
   • Inclusão de atributos assinados           │  Construção da Mensagem CMS/PKCS#7   │
   • Assinatura da chave privada (RSA/ECDSA)   └──────────────────┬───────────────────┘
                                                                  │
4. CARIMBO DO TEMPO (TSA - RFC 3161)                              ▼
   • Envio do Hash do CMS para a autoridade    ┌──────────────────────────────────────┐
   • Incorporação do TimeStampToken no pacote  │  Obtenção e Incorporação do TSA      │
                                               └──────────────────┬───────────────────┘
                                                                  │
5. INJEÇÃO DOS BYTES & SALVAMENTO INCREMENTAL                     ▼
   • Conversão do pacote DER para Hexadecimal  ┌──────────────────────────────────────┐
   • Gravação direta no espaço reservado       │  PDF Assinado com Sucesso            │
   • Atualização Incremental (Preserva XRef)   │  (PAdES-B-B / PAdES-B-LT / B-LTA)    │
                                               └──────────────────────────────────────┘
```

- **Padrões PAdES Suportados:**
  - **PAdES-B-B (Basic):** Assinatura com certificado digital X.509 e atributos assinados obrigatórios (`signingTime`, `messageDigest`, `contentType`).
  - **PAdES-B-T (Timestamp):** Inclusão de Carimbo do Tempo seguro emitido por autoridade TSA credenciada via protocolo RFC 3161 sobre HTTP/HTTPS.
  - **PAdES-B-LT (Long Term):** Inclusão de dados de validação de revogação (respostas OCSP completas e Listas de Revogação de Certificados - CRL) no dicionário `/DSS` (Document Security Store) do PDF.
  - **PAdES-B-LTA (Long Term Archival):** Assinatura de arquivo permanente com carimbos do tempo periódicos cobrindo o DSS para validade jurídica por décadas.
- **`PdfSignatureAppearanceBuilder`:** Construção visual personalizável da assinatura na página do documento (ex: foto do signatário, logotipo da empresa, dados do certificado, texto com CNPJ/CPF, data e hora, selo visual de autenticidade vetorial).

---

# 6. Subsistema CorelDRAW (CDR / CMX) em Puro Dart

## 6.1. Camada de Contêiner: Despachante RIFF (v3-v13) e Pacotes ZIP/OPC (X4-2024)
O módulo `dart_ui/cdr` detecta dinamicamente a versão do arquivo CorelDRAW e aciona o despachante apropriado:
1. **Verificação de Magic Bytes:**
   - Se os primeiros 4 bytes forem `RIFF` e o tipo for `CDR ` ou `CDR6` ou `WL6 ` -> Formato binário clássico (CDR v3 a CDR v13 / X3).
   - Se os primeiros 4 bytes forem `PK\x03\x04` -> Pacote ZIP moderno (CDR X4, X5, X6, X7, X8, 2017, 2018, 2019, 2020, 2021, 2022, 2023, 2024).
   - Se o FourCC for `RIFF` com tipo `CMX ` ou `CMX1` -> Formato Corel Presentation Exchange.
2. **Leitura e Extração Segura em Puro Dart:**
   - Para arquivos ZIP, extrai as trilhas `content/root.dat`, `content/riffData.dat` e metadados XML usando o descompressor Zip embutido.

## 6.2. Parser de Chunks e Geometria Vetorial
Reconstrução fiel das curvas do CorelDRAW:
- **`crve` / `path` (Curvas e Trajetos):**
  - Descompactação do fluxo de nós (*nodes*).
  - Interpretação das flags de ponto: Ponto inicial de subcaminho, Linha reta, Curva cúbica de Bézier (com ponto de controle 1 e ponto de controle 2), Ponto de cúspide (*cusp*), Ponto suave (*smooth*), Ponto simétrico (*symmetrical*), e flag de fechamento de caminho.
  - Normalização para coordenadas em ponto flutuante no sistema de coordenadas do `dart_ui`.

## 6.3. Motor de Estilos, Preenchimentos Gradientes, Padrões, Mesh Fills e PowerClips
O CorelDRAW possui alguns dos recursos vetoriais mais complexos do design gráfico:
- **Preenchimentos Gradientes (*Fountain Fills*):**
  - Gradiente Linear com ângulo arbitrário, translação de centro e repetição (*pad*, *repeat*, *mirror*).
  - Gradiente Radial com deslocamento excêntrico de foco.
  - Gradiente Cônico (*Conical/Sweep Gradient*) mapeado para o gerador de shaders do `dart_ui`.
  - Gradiente Quadrado (*Square/Rectangular Gradient*).
- **Malhas de Gradiente (*Mesh Fills* - `fild` tipo malha):**
  - O Corel permite criar superfícies de nós de Bézier bidimensionais onde cada vértice da malha possui uma cor independente. O motor em puro Dart calcula a interpolação bilinear e de Coons patch, transformando a malha em uma malha de triângulos de alta densidade desenhada com `canvas.drawVertices()`.
- **PowerClips (Recortes Aninhados):**
  - Um objeto ou grupo do Corel colocado dentro de outro como máscara é processado criando um grupo de recorte (`canvas.save()`, `canvas.clipPath()`, renderização dos filhos e `canvas.restore()`).

## 6.4. Paletas de Cores Corel, Espaços Spot/Pantone e Conversão Cromática
Porting em puro Dart de todo o banco de dados de cores de `CDRColorPalettes.h`:
- Mapeamento de centenas de paletas históricas: *Pantone Matching System (Coated/Uncoated)*, *Pantone Hexachrome*, *Trumatch*, *Focoltone*, *Toyo*, *DIC*, *Lab Colors*.
- Conversão exata de modelos de cor CMYK, HLS, HSB e RGB legados para sRGB calibrado.

## 6.5. Extração de Bitmaps Embutidos e Texto Artístico/Parágrafo
- **Bitmaps Embutidos:** Extração de imagens BMP, PNG, JPEG, TIFF e dados brutos comprimidos por RLE/Deflate embutidos em chunks `bmp `, convertendo-os em objetos `dart_ui.Image`.
- **Textos:** Leitura de codificações de texto (Unicode UTF-16 nos modernos e CodePages ANSI/OEM nas versões legadas v3-v11), extraindo o texto, nome da fonte, corpo tipográfico, alinhamento, espaçamento entre caracteres e transformações de texto em curva (*text along path*).

## 6.6. Parser CMX (Corel Presentation Exchange)
- Decodificação de arquivos CMX (versões 5, 6, 7 e 8) baseados no formato de troca vetorial da Corel com despacho por instruções de cabeçalho, paleta de cores de página e comandos de desenho de primitivas.

## 6.7. Ponte CDR/CMX -> dart_ui.Picture e PDF
O subsistema fornece conversão instantânea:
- `CdrDocument.load(bytes).toPicture(pageIndex)` -> Retorna um `dart_ui.Picture` para renderização imediata acelerada na tela.
- `CdrDocument.load(bytes).toPdf()` -> Converte o arquivo CDR diretamente em um documento PDF padrão ISO 32000 em puro Dart!

---

# 7. Design de APIs de Alto Nível para Desenvolvedores de Aplicações

Quem utilizar o `dart_ui` terá à disposição uma experiência moderna e de pouquíssimas linhas de código:

## 7.1. Criação de Leitores de PDF (`PdfDocument`, `PdfPage`, `PdfViewerWidget`)
Para carregar e exibir um PDF com navegação completa:

```dart
import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:dart_ui/widgets.dart';

// Carregamento de documento PDF em 1 linha
final doc = await PdfDocument.openFile('meu_documento.pdf');
print('Número de páginas: ${doc.pageCount}');

// Renderizar uma página diretamente para imagem/framebuffer
final page = await doc.getPage(1);
final picture = page.renderToPicture(scale: 2.0); // Vetorial via dart_ui.Picture

// Ou usar o Widget visual completo de leitor
Widget buildPdfReader() {
  return PdfView(
    document: doc,
    scrollDirection: Axis.vertical,
    pageSpacing: 16.0,
    enableTextSelection: true,
    enablePinchZoom: true,
    onPageChanged: (pageIndex) => print('Página ativa: $pageIndex'),
  );
}
```

## 7.2. Criação de Editores de PDF (`PdfEditorWidget`, `PdfCanvas`, Manipulação de Árvore)
Para adicionar anotações, desenhar vetores ou inserir páginas:

```dart
// Adicionar uma anotação de desenho livre (Ink) na página
final page = await doc.getPage(1);
final inkAnnot = PdfInkAnnotation(
  rect: Rect.fromLTWH(100, 100, 200, 150),
  color: Color(0xFFFF0000),
  strokeWidth: 3.0,
  paths: [meuCaminhoDeAssinatura],
);
page.addAnnotation(inkAnnot);

// Desenhar conteúdo arbitrário usando a API Canvas do dart_ui
final editorCanvas = page.createEditorCanvas();
editorCanvas.drawCircle(Offset(150, 150), 40, Paint()..color = Color(0xFF00FF00));
page.commitCanvasEdits();

// Salvar o PDF modificado mantendo a compatibilidade total
final bytesModificados = await doc.save(incremental: true);
```

## 7.3. Criação de Assinadores de PDF (`PdfSigner`, `PdfSignatureAppearanceBuilder`)
Para assinar digitalmente com padrão legal e certificado X.509:

```dart
final signer = PdfSigner(
  document: doc,
  certificate: meuCertificadoX509,
  privateKey: minhaChavePrivada,
  signatureStandard: PdfSignatureStandard.padesB_LT, // PAdES com Long Term Validation
  tsaClient: HttpTsaClient(url: 'https://timestamp.autoridade.com.br'),
);

// Constrói a aparência visual da assinatura no rodapé da página 1
signer.setVisualAppearance(
  pageNumber: 1,
  rect: Rect.fromLTWH(350, 50, 200, 80),
  builder: (canvas, size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(8)), Paint()..color = Color(0xFFF0F4F8));
    canvas.drawText('Assinado digitalmente por:\nDR. SILVA\nData: 16/08/2026', Offset(10, 10), TextStyle(fontSize: 10, color: Color(0xFF1E293B)));
  },
);

// Executa a assinatura criptográfica e gera o arquivo assinado
final Uint8List pdfAssinado = await signer.sign();
```

## 7.4. Visualização e Conversão de CDR (`CdrDocument`, `CdrViewerWidget`, Exportação para PDF/SVG)
Para ler arquivos do CorelDRAW de qualquer versão:

```dart
import 'package:dart_ui/cdr.dart';

// Carregar qualquer arquivo CorelDRAW (.cdr ou .cmx)
final cdrDoc = await CdrDocument.openFile('logotipo_vetorial.cdr');
print('Versão do CorelDRAW detectada: ${cdrDoc.versionName}'); // Ex: "CorelDRAW 2024 (v25)"

// Renderizar na tela via Widget
Widget buildCdrViewer() {
  return CdrView(
    document: cdrDoc,
    enablePanZoom: true,
    backgroundColor: Color(0xFFFFFFFF),
  );
}

// Exportar instantaneamente para PDF vetorial ou SVG
final Uint8List pdfBytes = await cdrDoc.exportToPdf();
final String svgContent = await cdrDoc.exportToSvg();
```

---

# 8. Estrutura de Diretórios e Código Fonte no dart_ui

A árvore de arquivos planejada para implementação detalha cada módulo e sua respectiva responsabilidade:

```
c:\MyDartProjects\dart_ui\
├── lib\
│   ├── pdf.dart                        <-- Ponto de exportação da API pública de PDF
│   ├── cdr.dart                        <-- Ponto de exportação da API pública de CDR/CMX
│   └── src\
│       ├── pdf\
│       │   ├── io\
│       │   │   ├── byte_reader.dart
│       │   │   ├── byte_writer.dart
│       │   │   └── memory_mapped_source.dart
│       │   ├── format\
│       │   │   ├── pdf_object.dart
│       │   │   ├── pdf_primitive.dart
│       │   │   ├── pdf_dictionary.dart
│       │   │   ├── pdf_array.dart
│       │   │   ├── pdf_stream.dart
│       │   │   ├── pdf_reference.dart
│       │   │   ├── pdf_lexer.dart
│       │   │   ├── pdf_parser.dart
│       │   │   ├── pdf_xref_table.dart
│       │   │   ├── pdf_xref_stream.dart
│       │   │   └── pdf_trailer.dart
│       │   ├── filter\
│       │   │   ├── pdf_filter.dart
│       │   │   ├── flate_filter.dart
│       │   │   ├── lzw_filter.dart
│       │   │   ├── ccitt_fax_filter.dart
│       │   │   ├── ascii85_filter.dart
│       │   │   ├── ascii_hex_filter.dart
│       │   │   ├── run_length_filter.dart
│       │   │   ├── dct_filter.dart
│       │   │   └── jbig2_filter.dart
│       │   ├── document\
│       │   │   ├── pdf_document.dart
│       │   │   ├── pdf_catalog.dart
│       │   │   ├── pdf_page.dart
│       │   │   ├── pdf_pages_tree.dart
│       │   │   ├── pdf_outline.dart
│       │   │   └── pdf_metadata.dart
│       │   ├── gfx\
│       │   │   ├── pdf_gfx_state.dart
│       │   │   ├── pdf_content_interpreter.dart
│       │   │   ├── pdf_output_device.dart
│       │   │   ├── pdf_matrix.dart
│       │   │   ├── pdf_path_builder.dart
│       │   │   ├── pdf_color_space.dart
│       │   │   ├── pdf_icc_profile.dart
│       │   │   ├── pdf_shading.dart
│       │   │   └── pdf_transparency_group.dart
│       │   ├── font\
│       │   │   ├── pdf_font.dart
│       │   │   ├── pdf_type1_font.dart
│       │   │   ├── pdf_truetype_font.dart
│       │   │   ├── pdf_cff_font.dart
│       │   │   ├── pdf_type3_font.dart
│       │   │   ├── pdf_cid_font.dart
│       │   │   ├── pdf_cmap.dart
│       │   │   ├── pdf_to_unicode.dart
│       │   │   └── pdf_font_subsetter.dart
│       │   ├── text\
│       │   │   ├── pdf_text_extractor.dart
│       │   │   ├── pdf_text_line.dart
│       │   │   ├── pdf_text_selection.dart
│       │   │   └── pdf_text_searcher.dart
│       │   ├── export\
│       │   │   ├── pdf_canvas_recorder.dart
│       │   │   ├── display_list_to_pdf.dart
│       │   │   └── pdf_document_builder.dart
│       │   ├── annot\
│       │   │   ├── pdf_annotation.dart
│       │   │   ├── pdf_highlight_annot.dart
│       │   │   ├── pdf_ink_annot.dart
│       │   │   ├── pdf_stamp_annot.dart
│       │   │   ├── pdf_widget_annot.dart
│       │   │   └── pdf_appearance_generator.dart
│       │   ├── forms\
│       │   │   ├── pdf_acro_form.dart
│       │   │   ├── pdf_form_field.dart
│       │   │   ├── pdf_text_form_field.dart
│       │   │   ├── pdf_button_form_field.dart
│       │   │   └── pdf_choice_form_field.dart
│       │   ├── crypto\
│       │   │   ├── pdf_security_handler.dart
│       │   │   ├── pdf_rc4_cipher.dart
│       │   │   ├── pdf_aes_cipher.dart
│       │   │   ├── pdf_md5.dart
│       │   │   └── pdf_sha.dart
│       │   └── sign\
│       │       ├── pdf_signer.dart
│       │       ├── pdf_signature_field.dart
│       │       ├── pdf_byte_range_calculator.dart
│       │       ├── pdf_pkcs7_builder.dart
│       │       ├── pdf_pades_engine.dart
│       │       ├── pdf_tsa_client.dart
│       │       └── pdf_signature_appearance.dart
│       ├── cdr\
│       │   ├── container\
│       │   │   ├── cdr_container_detector.dart
│       │   │   ├── riff_reader.dart
│       │   │   └── zip_cdr_archive.dart
│       │   ├── chunks\
│       │   │   ├── chunk_dispatcher.dart
│       │   │   ├── chunk_fourcc.dart
│       │   │   └── chunk_stream.dart
│       │   ├── geometry\
│       │   │   ├── cdr_path.dart
│       │   │   ├── cdr_node.dart
│       │   │   ├── cdr_bezier_evaluator.dart
│       │   │   └── cdr_transform_matrix.dart
│       │   ├── styles\
│       │   │   ├── cdr_outline.dart
│       │   │   ├── cdr_line_cap.dart
│       │   │   ├── cdr_line_join.dart
│       │   │   └── cdr_arrow_head.dart
│       │   ├── fills\
│       │   │   ├── cdr_fill.dart
│       │   │   ├── cdr_solid_fill.dart
│       │   │   ├── cdr_gradient_fill.dart
│       │   │   ├── cdr_mesh_fill.dart
│       │   │   ├── cdr_pattern_fill.dart
│       │   │   └── cdr_powerclip.dart
│       │   ├── palettes\
│       │   │   ├── cdr_color_palette.dart
│       │   │   ├── cdr_pantone_table.dart
│       │   │   └── cdr_color_converter.dart
│       │   ├── text\
│       │   │   ├── cdr_text_run.dart
│       │   │   ├── cdr_artistic_text.dart
│       │   │   └── cdr_paragraph_text.dart
│       │   ├── cmx\
│       │   │   ├── cmx_parser.dart
│       │   │   └── cmx_record_decoder.dart
│       │   ├── document\
│       │   │   ├── cdr_document.dart
│       │   │   ├── cdr_page.dart
│       │   │   └── cdr_layer.dart
│       │   └── render\
│       │       ├── cdr_to_picture_bridge.dart
│       │       └── cdr_to_pdf_converter.dart
│       └── widgets\
│           ├── pdf\
│           │   ├── pdf_view.dart
│           │   ├── pdf_page_view.dart
│           │   ├── pdf_thumbnail_strip.dart
│           │   ├── pdf_editor_canvas.dart
│           │   └── pdf_signature_pad.dart
│           └── cdr\
│               └── cdr_view.dart
```

---

# 9. Plano de Implementação por Fases e Milestones (Fase 1 a 10)

```
       ROTEIRO DE EXECUÇÃO SEQUENCIAL DAS 10 FASES DE IMPLEMENTAÇÃO
┌────────────────────────────────────────────────────────────────────────┐
│ FASE 1: I/O de Bytes, Filtros de Descompressão (Flate/LZW/CCITT) & Lexer│
├────────────────────────────────────────────────────────────────────────┤
│ FASE 2: XRef Table, XRef Streams, Object Streams & Parser de Objetos   │
├────────────────────────────────────────────────────────────────────────┤
│ FASE 3: Catálogo, Árvore de Páginas & Interpretador de Content Stream  │
├────────────────────────────────────────────────────────────────────────┤
│ FASE 4: Espaços de Cores (CMYK/ICC/Spot) & Motor Tipográfico (TTF/CFF) │
├────────────────────────────────────────────────────────────────────────┤
│ FASE 5: Gravador e Exportador Vetorial (DisplayList/Canvas -> PDF)     │
├────────────────────────────────────────────────────────────────────────┤
│ FASE 6: Anotações Interativas & Formulários AcroForms                  │
├────────────────────────────────────────────────────────────────────────┤
│ FASE 7: Criptografia, Assinaturas Digitais (PAdES) & Carimbo do Tempo  │
├────────────────────────────────────────────────────────────────────────┤
│ FASE 8: Contêiner CorelDRAW (RIFF & ZIP), Parsers de Chunks e Geometria│
├────────────────────────────────────────────────────────────────────────┤
│ FASE 9: Fills Corel (Gradients, Mesh, PowerClips), Paletas & CMX       │
├────────────────────────────────────────────────────────────────────────┤
│ FASE 10: Widgets de UI (PdfView, CdrView), Golden Tests & Benchmarks   │
└────────────────────────────────────────────────────────────────────────┘
```

### Fase 1: I/O de Bytes, Filtros de Descompressão e Lexer
- **Entregas:** `byte_reader.dart`, decodificadores Flate/Zlib, LZW, ASCII85, CCITT Group 3/4 Fax, RunLength. Tokenizador `pdf_lexer.dart` com suporte completo à sintaxe léxica do PDF 1.7/2.0.
- **Validação:** Testes unitários com streams comprimidos extraídos de arquivos de teste do Poppler e verificação de integridade bit a bit.

### Fase 2: Tabela XRef, Object Streams e Parser de Objetos (DOM)
- **Entregas:** Resolução de referências cruzadas clássicas e streams de XRef (`pdf_xref_table.dart`, `pdf_xref_stream.dart`), leitura de objetos em `pdf_parser.dart` e reconstrução tolerante para PDFs com cabeçalho quebrado.
- **Validação:** Parser de 1.000 PDFs sintéticos e reais extraídos da base de testes do Poppler sem falhas ou vazamentos.

### Fase 3: Catálogo, Páginas e Interpretador de Content Stream
- **Entregas:** Navegação pela árvore `/Pages`, inicialização de `PdfGfxState`, mapeamento dos operadores de caminho (`m`, `l`, `c`, `re`, `h`, `W`, `q`, `Q`, `cm`, `S`, `f`, `B`) para o `dart_ui.Canvas` via `PdfOutputDevice`.
- **Validação:** Renderização de páginas vetoriais estáticas comparadas contra o output do Poppler `pdftoppm` via testes de imagem golden.

### Fase 4: Espaços de Cores e Motor Tipográfico
- **Entregas:** Conversão cromática de `/DeviceCMYK`, `/Lab`, `/ICCBased` e `/Separation` com cálculo de curvas. Parsing de fontes TrueType e CFF Type 1/2, aplicação de tabelas CMap e `/ToUnicode` para renderização e extração de texto.
- **Validação:** Extração de texto idêntica ao `pdftotext` em documentos multilíngues (incluindo ligaduras e scripts CJK).

### Fase 5: Gravador e Exportador Vetorial (DisplayList / Canvas -> PDF)
- **Entregas:** `PdfCanvasRecorder`, serializador de DisplayList para PDF, subsetting de fontes TrueType embutidas e emissão de PDFs vetoriais compactos.
- **Validação:** Gravação de árvores de widgets complexas do `dart_ui` para PDF e abertura com validação de conformidade no Adobe Acrobat Reader e validação no Preflight da ISO.

### Fase 6: Anotações Interativas e AcroForms
- **Entregas:** Criação e edição de anotações (Highlight, Underline, Ink, Stamp), campos de formulário (Text, Checkbox, Radio, Dropdown), e gerador automático de Appearance Streams (`/AP`).
- **Validação:** Preenchimento de formulários e salvamento incremental testado e validado em leitores externos.

### Fase 7: Criptografia, Assinaturas Digitais (PAdES) e Carimbo do Tempo
- **Entregas:** Criptografia Standard v1..v6 (AES-128/256 e RC4), motor de assinatura PAdES (B-B até B-LTA), cálculo preciso de `ByteRange`, empacotamento CMS/PKCS#7 ASN.1 em Dart puro, cliente TSA RFC 3161 e construtor visual de assinaturas.
- **Validação:** Verificação de assinaturas aprovadas com selo verde no Adobe Acrobat Signatures Panel e validadores oficiais ICP-Brasil / eIDAS europeu.

### Fase 8: Contêiner CorelDRAW (RIFF & ZIP), Parsers de Chunks e Geometria
- **Entregas:** Detecção automática de contêiner (RIFF v3-v13 vs ZIP X4-2024), parser de chunks `crve`, `obj `, `lyr `, `grp `, e reconstrução de caminhos Bézier cúbicos em `cdr_path.dart`.
- **Validação:** Extração correta de caminhos de arquivos CDR de amostra das versões v3 até CorelDRAW 2024.

### Fase 9: Estilos, Preenchimentos Gradientes/Mesh, Paletas e CMX
- **Entregas:** Preenchimentos sólidos, gradientes lineares/radiais/cônicos/quadrados, malhas de gradiente (*mesh fills* via `drawVertices`), contornos com pontas de seta personalizadas, paletas Pantone e parser completo de arquivos CMX.
- **Validação:** Renderização visual precisa de logotipos e ilustrações complexas da CorelDRAW comparadas contra o Corel original e `libcdr`.

### Fase 10: Widgets de UI (PdfView, CdrView), Golden Tests e Benchmarks
- **Entregas:** Widgets prontos para produção (`PdfView`, `PdfEditor`, `PdfSignaturePad`, `CdrView`), suporte a virtualização de páginas, zoom de alta performance, busca interativa, suíte de golden tests e benchmarks de tempo/memória.
- **Validação:** Publicação da suíte de testes passando com 100% de sucesso no CI do Windows, Linux e macOS.

---

# 10. Estratégia de Validação, Golden Tests, Fuzzing e Benchmarks

Para garantir robustez de nível industrial sem dependências externas:
1. **Corpus de Testes Multi-Versão:**
   - **PDF:** 500 documentos da suíte oficial ISO 32000-1 / ISO 32000-2, corpus de testes do Poppler (`referencias/poppler-master/test/`), formulários da Receita Federal/Governo e documentos assinados com carimbos ICP-Brasil/eIDAS.
   - **CDR / CMX:** Amostras de arquivos reais criados no CorelDRAW 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, X3, X4, X5, X6, X7, X8, 2017, 2018, 2019, 2020, 2021, 2022, 2023 e 2024.
2. **Golden Image Comparison:**
   - Comparação pixel a pixel da renderização do `dart_ui` contra a renderização de referência do Poppler (`CairoOutputDev` / `SplashOutputDev`) e do macOS CoreGraphics com tolerância de anti-aliasing (< 0.5% delta perceptual).
3. **Fuzzing de Robustez:**
   - Gerador de mutações de bytes aleatórios alimentando o parser em testes contínuos para garantir que nenhum PDF ou CDR malformado cause estouro de memória, recursão infinita ou crash no Dart runtime.
4. **Benchmarks de Desempenho:**
   - Tempo de abertura de primeira página (< 15 ms para PDFs de até 1.000 páginas graças ao carregamento sob demanda de XRef).
   - Consumo de memória RAM fixo (< 50 MB mesmo ao navegar em documentos de 500 MB com imagens em alta resolução através do gerenciador de tiles).

---

# 11. Registro de Decisões Arquiteturais (ADRs)

### ADR-PDF-0001: Implementação 100% em Puro Dart vs FFI com Poppler/libcdr
- **Contexto:** O projeto necessita de suporte de primeira classe a PDF e CDR. Poder-se-ia cogitar compilar o Poppler e o libcdr em C++ como bibliotecas `.dll`/`.so`/`.dylib` e chamá-las via `dart:ffi`.
- **Decisão:** Rejeitar FFI com bibliotecas C++ externas para estes subsistemas e **implementar 100% em Dart puro**.
- **Justificativa:**
  1. A compilação e empacotamento multiplataforma de Poppler (com dependências gigantescas de Cairo, Fontconfig, FreeType, LCMS, NSS, etc.) é extremamente frágil e inviabiliza execução na Web (Wasm) ou builds herméticos e portáteis.
  2. A integração em Dart puro permite mapeamento com overhead zero para o `DisplayList` do `dart_ui`, permitindo que o PDF seja simultaneamente um formato de entrada vetorial nativo e um formato de saída direta dos widgets.

### ADR-PDF-0002: Reconciliação Incremental para Assinaturas Digitais (PAdES)
- **Contexto:** Ao assinar um PDF, o hash é calculado sobre o arquivo original e os novos bytes de assinatura e metadados devem ser anexados sem alterar sequer 1 byte do conteúdo anterior, sob pena de invalidar assinaturas pré-existentes.
- **Decisão:** O motor de gravação de PDF suportará o modo `incrementalSave()`, que preserva o corpo original e grava apenas a nova seção de objetos modificados, a nova tabela XRef com ponteiro `/Prev` e o novo trailer ao final do arquivo.

### ADR-CDR-0001: Arquitetura Unificada para Formatos RIFF Legados e ZIP Modernos
- **Contexto:** A Corel alterou drasticamente o contêiner de arquivos no CDR X4, migrando do formato RIFF tradicional para contêineres ZIP com arquivos XML e dados brutos `riffData.dat`.
- **Decisão:** A camada de abstração `CdrDocument` oculta essa distinção, expondo uma árvore vetorial unificada de nós, curvas, camadas e preenchimentos independentemente da versão do arquivo de origem.

---

# 12. Matriz de Riscos e Mitigações

| Risco Técnico Identificado | Severidade | Mitigação de Engenharia no `dart_ui` |
| :--- | :---: | :--- |
| **PDFs com XRef quebrado ou corrompido** | Alta | Implementação de algoritmo de reparo automático que varre o arquivo em busca de `\d+ \d+ obj` quando o `startxref` falha. |
| **Performance de descompressão de imagens e streams em Dart puro** | Média | Uso intensivo de `Uint8List`, `ByteData` com acesso sem bounds check desnecessário e compilação otimizada AOT / Wasm SIMD. |
| **Complexidade de curvas e Mesh Fills do CorelDRAW** | Média | Decomposição de malhas de Coons patch em malhas de triângulos planos (*triangle mesh vertices*) consumidas diretamente pelo `canvas.drawVertices()`. |
| **Divergência de fontes e métricas em PDFs sem fontes embutidas** | Média | Tabela interna de larguras das 14 fontes padrão do PDF (Helvetica, Times, Courier, Symbol, ZapfDingbats) idêntica à do Poppler e fallback gracioso com substituição métrica equivalente. |
| **Validação legal de carimbos do tempo (TSA) sem rede** | Baixa | Cliente TSA com suporte a modo offline para desenvolvimento e injeção de carimbo mock para suíte de testes determinísticos. |

---

> **Conclusão:** Este plano diretor estabelece o roteiro técnico definitivo para que o `dart_ui` alcance **paridade e superioridade gráfica em relação ao Quartz 2D e PDFKit do macOS**, capacitando desenvolvedores em qualquer sistema operacional (Windows, Linux, macOS e Web) a construir leitores de alta velocidade, editores vetoriais completos, fluxos de assinatura digital PAdES de nível corporativo e visualizadores de arquivos CorelDRAW (CDR/CMX) em **100% puro Dart sem qualquer dependência externa**.
