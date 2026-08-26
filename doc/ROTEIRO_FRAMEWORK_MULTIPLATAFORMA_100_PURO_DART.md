# Roteiro de Engenharia — Framework de Interface Gráfica Multiplataforma em 100% Dart

> **Projeto-alvo:** `C:\MyDartProjects\dart_ui`  
> **Destino solicitado:** `C:\MyDartProjects\dart_ui\doc\ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md`  
> **Plataformas iniciais:** Windows, Linux e macOS  
> **Linguagem do framework:** Dart nativo  
> **Integração nativa:** `dart:ffi`, sem biblioteca intermediária escrita pelo projeto em C, C++, Objective-C ou Swift  
> **Modelo de widgets:** widgets, layout, estilos, eventos, composição e acessibilidade implementados em Dart  
> **Backends planejados:** Win32, GDI, Direct2D, Direct3D 11, DirectComposition, X11/XCB, Wayland, GTK opcional, OpenGL, Vulkan, AppKit, Core Graphics e Metal  
> **Referências arquiteturais principais:** Avalonia, OpenJFX/JavaFX, Flutter, `dart_graphics`, `marlin`, `win32` e demais referências locais

---

# Sumário

- [Roteiro de Engenharia — Framework de Interface Gráfica Multiplataforma em 100% Dart](#roteiro-de-engenharia-framework-de-interface-grafica-multiplataforma-em-100-dart)
- [0.1 Estado auditado em 23 de agosto de 2026](#01-estado-auditado-em-23-de-agosto-de-2026)
- [1. Visão executiva](#1-visao-executiva)
- [2. Definição normativa de “100% puro Dart”](#2-definicao-normativa-de-100-puro-dart)
- [3. Lições das referências](#3-licoes-das-referencias)
- [4. Escopo do produto](#4-escopo-do-produto)
- [5. Matriz inicial de plataformas](#5-matriz-inicial-de-plataformas)
- [6. Princípios arquiteturais](#6-principios-arquiteturais)
- [7. Estrutura recomendada do monorepo](#7-estrutura-recomendada-do-monorepo)
- [8. Camadas do framework](#8-camadas-do-framework)
- [9. Contratos centrais](#9-contratos-centrais)
- [10. Modelo de runtime e threads](#10-modelo-de-runtime-e-threads)
- [11. Engenharia FFI](#11-engenharia-ffi)
- [12. Inventário obrigatório das referências locais](#12-inventario-obrigatorio-das-referencias-locais)
- [13. Backend Windows — Win32, GDI, Direct2D, Direct3D e DirectComposition](#13-backend-windows-win32-gdi-direct2d-direct3d-e-directcomposition)
- [14. Backend Linux — arquitetura comum](#14-backend-linux-arquitetura-comum)
- [15. Backend X11 preferencialmente por XCB](#15-backend-x11-preferencialmente-por-xcb)
- [16. Backend Wayland](#16-backend-wayland)
- [17. GTK como backend opcional de integração](#17-gtk-como-backend-opcional-de-integracao)
- [18. OpenGL](#18-opengl)
- [19. Vulkan](#19-vulkan)
- [20. Backend macOS — Objective-C Runtime, AppKit e Core Foundation](#20-backend-macos-objective-c-runtime-appkit-e-core-foundation)
- [21. Metal](#21-metal)
- [22. Integração de dart_graphics e marlin](#22-integracao-de-dart-graphics-e-marlin)
- [23. Motor de renderização portátil](#23-motor-de-renderizacao-portatil)
- [24. Sistema de widgets](#24-sistema-de-widgets)
- [25. Layout](#25-layout)
- [26. Pintura, hit-test e composição](#26-pintura-hit-test-e-composicao)
- [27. Input e eventos](#27-input-e-eventos)
- [28. Estilos, temas e templates](#28-estilos-temas-e-templates)
- [29. Controles](#29-controles)
- [30. Texto, fontes e edição](#30-texto-fontes-e-edicao)
- [31. Acessibilidade e semântica](#31-acessibilidade-e-semantica)
- [32. Animações](#32-animacoes)
- [33. Internacionalização](#33-internacionalizacao)
- [34. Backend headless](#34-backend-headless)
- [35. Testes](#35-testes)
- [36. Benchmarks](#36-benchmarks)
- [37. Diagnóstico e DevTools](#37-diagnostico-e-devtools)
- [38. Segurança e robustez](#38-seguranca-e-robustez)
- [39. Empacotamento](#39-empacotamento)
- [40. CI](#40-ci)
- [41. Política de compatibilidade](#41-politica-de-compatibilidade)
- [42. ADRs obrigatórios](#42-adrs-obrigatorios)
- [ADR-0001: Título](#adr-0001-titulo)
- [43. Registro de riscos](#43-registro-de-riscos)
- [44. Definition of Done geral](#44-definition-of-done-geral)
- [45. Roteiro de execução por fases](#45-roteiro-de-execucao-por-fases)
  - [Fase 0 — Governança, inventário e licenças](#fase-0-governanca-inventario-e-licencas)
  - [Fase 1 — Foundation, geometria e contratos](#fase-1-foundation-geometria-e-contratos)
  - [Fase 2 — Scheduler, dispatcher abstrato e backend headless](#fase-2-scheduler-dispatcher-abstrato-e-backend-headless)
  - [Fase 3 — Backend CPU integrado a dart_graphics/marlin](#fase-3-backend-cpu-integrado-a-dart-graphicsmarlin)
  - [Fase 4 — Spike Win32 mínimo](#fase-4-spike-win32-minimo)
  - [Fase 5 — Win32 CPU vertical slice](#fase-5-win32-cpu-vertical-slice)
  - [Fase 6 — Núcleo de widgets profissional](#fase-6-nucleo-de-widgets-profissional)
  - [Fase 7 — Texto, shaping e IME Windows](#fase-7-texto-shaping-e-ime-windows)
  - [Fase 8 — Backend X11/XCB CPU](#fase-8-backend-x11xcb-cpu)
  - [Fase 9 — Backend AppKit CPU](#fase-9-backend-appkit-cpu)
  - [Fase 10 — Direct2D/D3D11/DXGI](#fase-10-direct2dd3d11dxgi)
  - [Fase 11 — OpenGL/EGL](#fase-11-openglegl)
  - [Fase 12 — Metal](#fase-12-metal)
  - [Fase 13 — Wayland CPU](#fase-13-wayland-cpu)
  - [Fase 14 — Vulkan](#fase-14-vulkan)
  - [Fase 15 — GTK e integração de desktop](#fase-15-gtk-e-integracao-de-desktop)
  - [Fase 16 — Acessibilidade profissional](#fase-16-acessibilidade-profissional)
  - [Fase 17 — Hardening, performance e release](#fase-17-hardening-performance-e-release)
- [46. Ordem crítica de implementação](#46-ordem-critica-de-implementacao)
- [47. Primeiros marcos executáveis](#47-primeiros-marcos-executaveis)
- [48. Plano dos primeiros commits](#48-plano-dos-primeiros-commits)
- [49. Backlog técnico por domínio](#49-backlog-tecnico-por-dominio)
- [50. Critérios para promover backends](#50-criterios-para-promover-backends)
- [51. Política de não regressão](#51-politica-de-nao-regressao)
- [52. Mapeamento de arquivos do bootstrap](#52-mapeamento-de-arquivos-do-bootstrap)
- [53. API pública proposta](#53-api-publica-proposta)
- [54. Cenários de conformidade obrigatórios](#54-cenarios-de-conformidade-obrigatorios)
- [55. Matriz de capacidades por backend](#55-matriz-de-capacidades-por-backend)
- [56. Matriz de APIs nativas e ownership](#56-matriz-de-apis-nativas-e-ownership)
- [57. Estratégia de geração de bindings](#57-estrategia-de-geracao-de-bindings)
- [58. Regras de performance Dart](#58-regras-de-performance-dart)
- [59. Erros a evitar](#59-erros-a-evitar)
- [60. Questões técnicas que precisam de spike](#60-questoes-tecnicas-que-precisam-de-spike)
- [61. Checklist para cada backend nativo](#61-checklist-para-cada-backend-nativo)
- [62. Checklist do primeiro release interno](#62-checklist-do-primeiro-release-interno)
- [63. Comandos locais sugeridos](#63-comandos-locais-sugeridos)
- [64. Referências técnicas primárias](#64-referencias-tecnicas-primarias)
- [65. Decisão final recomendada](#65-decisao-final-recomendada)
- [66. Resultado esperado da arquitetura](#66-resultado-esperado-da-arquitetura)
- [67. Próxima ação concreta](#67-proxima-acao-concreta)
- [68. Limitações conhecidas — auditoria de 2026-08-23](#68-limitacoes-conhecidas-auditoria-de-2026-08-23)

---

## 0. Nota de rastreabilidade desta versão

Os diretórios locais informados — `C:\MyDartProjects\dart_ui\referencias`, `C:\MyDartProjects\`, `C:\MyDartProjects\marlin\referencias` e `C:\MyDartProjects\dart_graphics\referencias` — não estavam montados no ambiente em que este documento foi gerado. Portanto:

1. foram analisadas as cópias públicas/conectadas disponíveis dos repositórios `insinfo/dart_graphics`, `insinfo/marlin`, `insinfo/win32`, `insinfo/dart_tkui` e `insinfo/freetype_dart`;
2. foram analisadas as estruturas públicas atuais de `AvaloniaUI/Avalonia` e `openjdk/jfx`;
3. o roteiro inclui uma fase obrigatória de inventário local para reconciliar este plano com todos os códigos e documentos que existem apenas nos diretórios do Windows;
4. nenhuma afirmação abaixo pressupõe que todos os arquivos locais já foram auditados;
5. antes de iniciar o desenvolvimento, o inventário local deverá produzir uma matriz “referência → conceito → arquivo de destino → licença → teste de paridade”.

Este documento foi deliberadamente escrito para continuar válido mesmo após essa auditoria: o inventário poderá enriquecer os mapeamentos sem mudar os contratos arquiteturais centrais.

---

## 0.1 Estado auditado em 23 de agosto de 2026

Este roteiro é a **intenção**. Quando ele e o código divergirem, **o código
vence** e o roteiro é corrigido — foi o que esta auditoria fez, e as correções
estão marcadas em cada seção. Dois documentos vizinhos completam o quadro:

- [`architecture/overview.md`](architecture/overview.md#estado-executivo--23-de-agosto-de-2026)
  — **o que funciona hoje, por plataforma**, em uma tabela de dois minutos;
- [§68, *Limitações conhecidas*](#68-limitações-conhecidas--auditoria-de-2026-08-23)
  — **onde cada frente parou**, nomeada por arquivo.

O que mudou desde a última auditoria, em uma tela:

1. **Wayland deixou de ser POC e é o backend mais completo escrito do zero
   aqui** — protocolo wire em Dart puro sobre socket, sem `libwayland`, sem
   `xkbcommon` e sem `libxcursor`. As seções 16.1 a 16.14 foram reescritas
   porque **pressupunham `libwayland-client` e `wl_proxy`**, que o código não
   usa. Ver §16;
2. **Direct2D existe e é escolhível no Windows**, com COM em Dart puro e sem
   `package:win32`. Ver §13.12. Junto com ele existem D3D11, D3D12, OpenGL/WGL
   e a DIB de GDI — mas **D3D12 e Vulkan não estão no seletor** de produção;
3. **WebGPU e WebGL2** existem como backends de produção no navegador, por
   `dart:js_interop`. A §4.2 os listava como escopo posterior;
4. **Vulkan** tem SPIR-V emitido em Dart e swapchain/WSI **em andamento** —
   dois arquivos de teste não compilam hoje. Ver §19;
5. **Aceleração vetorial**: seletor por custo com seis estratégias reais,
   rasterizador de strips nativo, cache de plano retido, binning de segmentos
   por tile e compute tiles no D3D12. O documento canônico é
   [`architecture/ACELERACAO_GPU_VETORIAL.md`](architecture/ACELERACAO_GPU_VETORIAL.md);
   este roteiro **não o duplica** e registra só o que mudou de decisão — ver
   §23.13;
6. **Drag-and-drop cross-backend** existe nos três backends nativos de desktop,
   nos dois sentidos, com widgets `DropTarget`/`DragSource`. Ver §56 e §55;
7. **IME**: Win32 (IMM32) e Wayland (`text-input-v3`) ligados ao mesmo
   contrato; o X11 **ganhou teclado em 26/08/2026** pelo core protocol
   (`GetKeyboardMapping`), com teclas mortas e clipboard, e **continua sem
   IME** — XIM precisa de Xlib e de um input context, e CJK segue fora dele.
   Ver §15.2.1 e §68.1;
8. **APIs de sistema operacional**: `StandardPaths`, `Shell`, `Trash`,
   `SystemInfo`, `NativeMessageBox`, `FileWatcher` e `FilePicker` existem, com
   cobertura muito desigual por plataforma. Ver §56.1;
9. **Controles**: TreeView, DataGrid, Calendar/DatePicker, NumberBox,
   InfoBar/Toast, Badge/Chip/Avatar/Card e Docking com faixa de abas
   recolhidas. Ver §29.2;
10. **PDF, assinatura PAdES e CorelDRAW** entraram no repositório e não estavam
    previstos em nenhuma fase deste roteiro. Ver §4.4;
11. **Uma nova seção §68 registra as limitações conhecidas** com nome e
    evidência. Ela é a parte deste documento que mais importa manter honesta.

**Medido nesta máquina hoje** (Windows 11 build 26200, Dart 3.6.2, Intel UHD),
e a medição **se move**: `dart analyze` deu 38 issues, todos `info`, numa
passada, e 21 issues com **três `error`** numa passada minutos depois — os três
da frente de swapchain do Vulkan. `dart test` roda **5.562 testes** com 28
`skip`, e as falhas foram 5 numa execução e 12 na seguinte. A árvore está sendo
editada enquanto os testes rodam. A lista nomeada das falhas está em §68.6;
**não trate o número como medição, trate a lista.**

---

# 1. Visão executiva

O objetivo é construir um framework desktop completo, comparável em ambição a Avalonia e JavaFX, porém com estas restrições:

- o código mantido pelo projeto será Dart;
- não haverá um “shim” próprio em C/C++/Objective-C/Swift;
- as bibliotecas do sistema operacional serão chamadas diretamente por FFI;
- widgets serão desenhados e comportados pelo framework em Dart;
- controles nativos poderão ser hospedados apenas como recurso opcional e explícito;
- o mesmo modelo de layout, estilo, eventos, texto, acessibilidade e composição será usado nos três sistemas;
- cada backend nativo ficará isolado atrás de contratos comuns;
- o motor gráfico existente em `dart_graphics`/`marlin` será aproveitado/copiado, estabilizado e modularizado em vez de reescrito.

A decisão mais importante é **não começar tentando implementar Win32, X11, Wayland, GTK, Direct3D, Direct2D, OpenGL, Vulkan, AppKit e Metal simultaneamente**. Isso criaria dezenas de frentes incompletas sem uma única aplicação funcional.

A execução deverá seguir fatias verticais:

1. núcleo headless;
2. superfície CPU;
3. uma janela Win32;
4. eventos de entrada;
5. um botão desenhado em Dart;
6. layout, foco e texto;
7. X11;
8. AppKit;
9. aceleração por GPU;
10. Wayland;
11. Vulkan e recursos avançados.

A primeira definição de sucesso não é “ter bindings para todas as APIs”. É:

> Uma aplicação compilada com Dart cria uma janela real, executa o loop da plataforma, desenha uma árvore de widgets em Dart, recebe mouse/teclado, atualiza o estado, repinta apenas a região danificada e fecha todos os recursos sem vazamentos.

---

# 2. Definição normativa de “100% puro Dart”

A expressão precisa ser objetiva para evitar discussões durante a implementação.

## 2.1 Permitido

É considerado compatível com o objetivo:

- código-fonte do framework em `.dart`;
- uso de `dart:ffi`;
- uso de `DynamicLibrary.open`, `lookup`, `lookupFunction` e `@Native` quando estabilizado;
- structs, unions, ponteiros, callbacks e vtables representados em Dart;
- bindings Dart gerados por `ffigen`;
- geradores próprios escritos em Dart;
- leitura de XML de protocolos Wayland e geração de stubs Dart;
- uso direto de DLLs, `.so` e `.dylib` fornecidos pelo sistema;
- uso direto de COM, WinRT, GObject, Objective-C Runtime e Core Foundation;
- shaders HLSL, GLSL, SPIR-V ou Metal Shading Language como ativos de renderização;
- compilação de shaders no processo de build por ferramentas oficiais da plataforma;
- ferramentas de empacotamento, assinatura e notarização da plataforma;
- executável AOT gerado pelo compilador Dart;
- bibliotecas de terceiros escritas em Dart;
- uso de APIs nativas do sistema operacional já instaladas.

## 2.2 Não permitido no runtime do framework principal

- DLL, `.so`, `.dylib` ou framework próprio compilado de C/C++;
- ponte intermediária Objective-C/Swift para AppKit;
- ponte JNI/JNA;
- processo auxiliar escrito em outra linguagem para abrir janelas ou renderizar;
- dependência obrigatória de Flutter Engine, Chromium, Electron ou Java;
- widgets implementados primariamente por controles GTK/AppKit/Win32;
- gerar uma biblioteca C durante a instalação;
- copiar partes nativas de Avalonia/OpenJFX e apenas expô-las por FFI.

## 2.3 Exceções que precisam de ADR

Qualquer exceção futura deverá:

1. ser opcional;
2. ficar em pacote separado;
3. não ser requisito para executar o backend básico;
4. ter justificativa técnica mensurável;
5. ter uma alternativa pura em Dart, ainda que mais lenta;
6. ser aprovada em um ADR — Architecture Decision Record.

Exemplo aceitável: um pacote opcional que usa uma biblioteca do fabricante para decodificar vídeo. Exemplo não aceitável: exigir um shim C para receber o `WndProc`.

---

# 3. Lições das referências

## 3.1 Avalonia: o que aproveitar

Avalonia é uma referência especialmente útil para:

- separar `IWindowingPlatform` da renderização;
- representar uma janela por uma interface de plataforma;
- expor uma lista de superfícies consumíveis pelos renderizadores;
- manter compositor separado da árvore de controles;
- manter backends distintos para Win32, X11 e macOS;
- possuir backend headless para testes;
- separar árvore lógica, visual, layout, input e composição;
- tratar escala de desktop e escala de renderização explicitamente;
- normalizar eventos nativos em eventos brutos independentes de plataforma;
- usar interfaces pequenas no limite com o sistema operacional;
- suportar fallback de framebuffer.

### Não copiar cegamente

- Avalonia usa um componente Objective-C nativo no backend macOS;
- a implementação e os tipos estão em C#/.NET e precisam ser reinterpretados para o modelo de memória do Dart;
- a hierarquia completa do projeto é grande demais para ser portada em bloco;
- nem todo detalhe da arquitetura atual é necessário para o primeiro release;
- nomes e APIs públicas devem ser próprios;
- copiar arquivos exige preservar a licença MIT isso não é problema pois este projeto sera de codigo aberto então pode copiar a vontade 

## 3.2 OpenJFX/JavaFX: o que aproveitar

OpenJFX oferece três divisões conceituais valiosas:

- **Glass:** janelas, eventos, cursor, clipboard, drag-and-drop e integração nativa;
- **Prism:** pipeline gráfico e recursos de GPU;
- **Quantum Toolkit:** coordenação entre toolkit, cena, renderizador e pulso de frame.

Também são referências úteis:

- `Toolkit` como ponto de abstração;
- `QuantumRenderer` como executor de renderização;
- `PaintCollector` como coletor de cenas sujas;
- `PresentingPainter`/`UploadingPainter` como estratégias diferentes de apresentação;
- backends D3D e OpenGL;
- organização separada do código de janela e do código gráfico;
- conceito de “pulse” para layout, CSS, animação e renderização.



## 3.3 `dart_graphics`: papel no novo framework

`dart_graphics` já declara o objetivo de biblioteca gráfica 2D em Dart e contém dependências úteis para:

- buffers de imagem;
- geometria vetorial;
- matrizes;
- XML/CSS/SVG;
- tipografia;
- FFI e geração de bindings;
- benchmarks.

O roteiro existente mostra trabalho em:

- Anti-Grain Geometry;
- rasterização scanline;
- clipping;
- buffers RGBA/BGRA;
- parsing OpenType;
- `cmap`, `glyf`, `loca`, `GSUB`, `GPOS` e `GDEF`;
- layout de glifos;
- SVG.



## 3.4 `marlin`: papel no novo framework

`marlin` contém uma base de pesquisa e implementação importante para:

- rasterização vetorial;
- regras `nonzero` e `evenodd`;
- múltiplos contornos;
- antialiasing;
- composição;
- gradientes;
- patterns;
- strokes;
- parsing e rasterização de fontes;
- caches;
- comparação com Blend2D, Skia, AGG e Marlin Renderer;
- benchmarks repetidos e análise de regressão.



## 3.5 `win32`: papel no novo framework

A biblioteca demonstra que é possível:

- chamar APIs Win32 sem C;
- modelar structs e constantes;
- registrar callbacks;
- acessar DLLs do sistema;
- tratar ponteiros e handles em Dart.

### Decisão

O novo backend Win32 poderá reaproveitar conceitos, geradores e tipos, mas deverá:

- atualizar os bindings para o Dart atual;
- separar bindings crus de wrappers seguros;
- gerar testes de `sizeof`, `alignment` e offsets;
- implementar COM e DirectX em pacotes próprios;
- evitar que tipos Win32 vazem para a API pública.

## 3.6 Matriz de aproveitamento

| Referência | Aproveitar | Não importar diretamente |
|---|---|---|
| Avalonia | contratos de plataforma, compositor, headless, árvore visual, input | backend Objective-C nativo, dependências .NET, API pública |
| OpenJFX | Glass/Prism/Quantum, pulse, coleta de dirty regions | código GPL sem análise, JNI, native shims |
| `dart_graphics` | geometria, imagem, SVG, tipografia, raster | dependências acopladas e APIs ainda instáveis |
| `marlin` | algoritmos, testes visuais, benchmarks, Blend2D-like | classes experimentais diretamente em widgets |
| `win32` | padrão de FFI e constantes | bindings antigos sem auditoria |
| `dart_tkui` | experiência com FFI e loop de toolkit | Tcl/Tk como base do framework |
| `freetype_dart` | referência de bindings e comparação de saída | FreeType como requisito do modo 100% Dart |

---

# 4. Escopo do produto

## 4.1 Escopo obrigatório do primeiro ciclo estável

- aplicações desktop AOT em Windows, Linux e macOS;
- uma ou mais janelas;
- janelas modais, popups e menus implementados em Dart;
- DPI por monitor;
- mouse, teclado e rolagem;
- foco e navegação por teclado;
- clipboard textual e imagens básicas;
- drag-and-drop;
- composição de texto/IME;
- layout bidimensional;
- texto Unicode, fallback de fonte e bidi;
- widgets básicos;
- temas claro e escuro;
- renderização CPU em todas as plataformas;
- ao menos um backend acelerado por plataforma;
- acessibilidade básica;
- backend headless;
- testes de pixel, layout, input e semântica;
- pacote de aplicação por plataforma.

## 4.2 Escopo posterior

- 3D;
- **vídeo** — *começado em 08/2026, e só a metade de cima*: existe o contrato de
  frame (`lib/src/graphics/video/`, planos NV12/I420/YUY2, espaço e faixa de
  cor) e um allocator de textura em GL (`GlVideoDevice`). **Nada decodifica**, e
  o allocator não é referenciado por ninguém em `lib/`. Ver §68;
- ~~WebGPU~~ — **entregue**: `lib/src/rendering/gpu/webgpu/` é um backend de
  produção por `dart:js_interop`, com WGSL, pipelines por modo de blend e porte
  sparse. A lacuna declarada é a **ausência de alvo de readback**, então não há
  paridade medida contra a CPU;
- iOS/Android;
- ~~navegador~~ — **entregue**: backend web com WebGL2 (o mais completo dos
  dois) e WebGPU, compilando por dart2js **e** dart2wasm, com teste que proíbe
  `dart:ffi` de aparecer;
- renderização remota;
- controles nativos embutidos;
- editor visual — *começado como exemplo*, ver §4.4;
- hot reload avançado;
- acessibilidade completa de todos os padrões;
- internacionalização avançada;
- suporte a HDR amplo;
- múltiplas GPUs;
- **interop de textura com engines externas** — contrato desenhado
  (`GpuForeignTextureImporter`, `ForeignTextureDescriptor` para handle DXGI,
  `EGLImage` e `IOSurface`), **sem nenhuma implementação**:
  `RendererCapabilities.supportsExternalTextures` é falso em todos os backends.

## 4.3 Fora de escopo

- portar integralmente Avalonia;
- portar integralmente JavaFX;
- reproduzir todas as APIs do Flutter;
- criar um sistema operacional gráfico;
- implementar drivers de GPU;
- substituir o compositor do desktop;
- criar uma ABI binária estável para plugins nativos no primeiro release;
- oferecer pixel idêntico entre plataformas quando as fontes instaladas diferem.

## 4.4 Escopo que entrou sem estar previsto (registro de 2026-08-23)

Três frentes existem no repositório e **não aparecem em nenhuma fase da §45**.
Registrar isso é o ponto: um roteiro que finge que elas não existem deixa de
descrever o projeto.

- **PDF**: leitura, renderização e um leitor interativo (`lib/src/pdf/`,
  `lib/pdf.dart`, widgets `PdfView`/`PdfPageView`, exemplo
  `examples/pdf_reader_demo/`), mais **assinatura PAdES B-B** com chaves de
  token, smart card e HSM por PKCS#11, loja de certificados do Windows
  (CNG/KSP e CSP legado) e Keychain do macOS (`lib/crypto.dart`, exemplo
  `examples/pdf_signer_demo/`). Documentos: `doc/PDF_SIGNING.md`,
  `doc/PLANO_SUPORTE_PDF_E_CDR_PURO_DART.md`;
- **CorelDRAW (`.cdr`)**: contêiner RIFF e ZIP, tradutor bidirecional para o
  DOM vetorial (`lib/src/cdr/`, `lib/cdr.dart`), especificação em
  `doc/file_format_specifications/CDR-specification.md`;
- **motor e editor vetorial**: DOM de documento, geometria de Bézier, contorno
  de traço, codec SVG, exportador PDF e os widgets de editor
  (`lib/src/graphics/vector/`, `lib/src/widgets/vector_editor/`), com o exemplo
  `examples/vector_editor_demo/` no layout do sK1. Documento:
  `doc/vector_editor.md` — que **precisa de correção**: ele descreve o exemplo
  como `examples/sk1_editor_demo/`, diretório que não existe.

Custo já cobrado por elas: quatro das arestas de camada que
`test/architecture/layering_test.dart` acusa hoje vêm daqui —
`geometry/bezier.dart`, `geometry/contour.dart` e `geometry/shaping.dart`
importam `graphics`, e o exportador PDF vetorial importa `pdf`. Ou a regra da
§8.2 muda com justificativa registrada, ou esse código sobe de camada.

---

# 5. Matriz inicial de plataformas

| Plataforma | Janela primária | Janela alternativa | CPU | GPU primária | GPU alternativa |
|---|---|---|---|---|---|
| Windows 10/11 x64/arm64 | Win32 | — | GDI/DIB + `dart_graphics` | Direct2D sobre D3D11/DXGI | OpenGL/Vulkan |
| Linux X11 x64/arm64 | XCB | GTK shell opcional | XCB SHM | OpenGL/EGL ou Vulkan | upload de CPU |
| Linux Wayland x64/arm64 | Wayland + xdg-shell | GTK shell opcional | `wl_shm` | Vulkan ou EGL/OpenGL | upload de CPU |
| macOS x64/arm64 | AppKit por Objective-C Runtime | — | Core Graphics | Metal + `CAMetalLayer` | upload CPU para Metal |

**Estado medido em 2026-08-26** — o que o `default_platform_resolver.dart`
realmente oferece, em ordem de tentativa:

| Plataforma | Backend de janela | Caminhos de apresentação, na ordem |
|---|---|---|
| Windows | `win32` | D3D11 → OpenGL/WGL → **Direct2D** → **D3D12** → **Vulkan** (experimental) → DIB de GDI |
| Linux | `wayland`, depois `x11` | OpenGL/EGL no X11 → `wl_shm` → `PutImage` no X11 |
| macOS | `macos` | IOSurface/CoreGraphics |
| qualquer | `headless` | renderer de CPU em memória |

Duas divergências entre a tabela normativa acima e o que existe, e o código
vence as duas:

1. **Vulkan no Linux ainda não está no seletor**, e no Windows entra marcado
   `experimental` — nunca por *fallback*, só pelo nome — porque
   `VulkanWindowTarget` não tem atlas de glifos e recusa qualquer texto. Ver
   §68.2;
2. **Wayland não tem GPU alguma** — nem EGL, nem `linux-dmabuf`, nem Vulkan. A
   linha "Vulkan ou EGL/OpenGL" é intenção, não estado;
3. **Metal não apresenta.** Não há `CAMetalLayer`, e `supportsSurface` só
   aceita `MemorySurfaceDescriptor`. A linha "Metal + `CAMetalLayer`" é
   intenção. Além disso, o caminho GL de janela no X11 está registrado no
   seletor e **nunca foi executado**.

## 5.1 Política de seleção em runtime

O usuário poderá configurar preferências:

```dart
const config = DartUiConfig(
  renderers: [
    RendererKind.direct2d,
    RendererKind.metal,
    RendererKind.vulkan,
    RendererKind.opengl,
    RendererKind.cpu,
  ],
  linuxWindowSystems: [
    LinuxWindowSystem.wayland,
    LinuxWindowSystem.x11,
  ],
);
```

O runtime deverá:

1. detectar o sistema operacional;
2. detectar sessão X11/Wayland;
3. carregar bibliotecas;
4. consultar símbolos obrigatórios;
5. verificar versão/capacidade;
6. tentar o backend preferido;
7. registrar motivo de falha;
8. cair para o próximo;
9. garantir sempre o backend CPU quando o sistema suporta uma janela.

---

# 6. Princípios arquiteturais

## 6.1 Portas e adaptadores

O núcleo não conhece Win32, XCB, Wayland, GTK ou AppKit. Ele depende de interfaces:

- `PlatformBackend`;
- `WindowingBackend`;
- `NativeWindow`;
- `UiDispatcher`;
- `InputBackend`;
- `ClipboardBackend`;
- `DragDropBackend`;
- `TextInputBackend`;
- `AccessibilityBackend`;
- `RendererBackend`;
- `RenderSurface`;
- `SystemThemeBackend`;
- `FileDialogBackend`.

## 6.2 Backend de janela não é backend gráfico

Uma janela pode expor várias superfícies:

```dart
sealed class NativeSurfaceDescriptor {}

final class Win32HwndSurface extends NativeSurfaceDescriptor {
  final int hwnd;
}

final class XcbWindowSurface extends NativeSurfaceDescriptor {
  final int connection;
  final int window;
  final int visualId;
}

final class WaylandSurfaceDescriptor extends NativeSurfaceDescriptor {
  final int display;
  final int surface;
}

final class MetalLayerSurface extends NativeSurfaceDescriptor {
  final int caMetalLayer;
}

final class CpuFramebufferSurface extends NativeSurfaceDescriptor {
  final PixelBuffer buffer;
  final int stride;
}
```

O renderizador escolhe a superfície compatível. Essa separação permite:

- Win32 + GDI;
- Win32 + Direct2D;
- Win32 + Vulkan;
- X11 + CPU;
- X11 + OpenGL;
- Wayland + Vulkan;
- AppKit + Core Graphics;
- AppKit + Metal.

## 6.3 Núcleo determinístico

Layout, hit-test, estilos, seleção de controle, eventos roteados e geração de `DisplayList` devem ser reproduzíveis em backend headless. Isso reduz o custo de depuração nativa.

## 6.4 Estado nativo encapsulado

Handles nativos nunca devem ser `int` públicos soltos. Usar wrappers de ciclo de vida:

```dart
abstract interface class NativeResource {
  bool get isDisposed;
  void dispose();
}

final class NativeWindowHandle implements NativeResource {
  final int address;
  final NativeHandleKind kind;
  // ...
}
```

## 6.5 Sem alocações no hot path

As seguintes rotas devem evitar alocações por evento/pixel:

- despacho de ponteiro;
- hit-test;
- serialização de comandos;
- rasterização;
- processamento de frame;
- callbacks nativos;
- conversão de coordenadas;
- resolução de estilos durante frame estável.

## 6.6 Falhas explícitas

Cada backend expõe um relatório:

```dart
final class BackendProbeResult {
  final bool supported;
  final List<Capability> capabilities;
  final List<BackendDiagnostic> diagnostics;
}
```

Nunca capturar exceção silenciosamente e apenas escolher outro backend. O log precisa explicar:

- biblioteca ausente;
- símbolo ausente;
- dispositivo incompatível;
- criação de swapchain falhou;
- extensão Wayland ausente;
- conexão X11 falhou;
- Metal indisponível;
- DPI API não suportada.

---

# 7. Estrutura recomendada do monorepo

A estrutura abaixo é o alvo final. No início, pacotes pequenos podem permanecer em um único package para evitar custo administrativo.

```text
dart_ui/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── melos.yaml
├── analysis_options.yaml
├── doc/
│   ├── ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md
│   ├── architecture/
│   │   ├── overview.md
│   │   ├── threading.md
│   │   ├── rendering.md
│   │   ├── input.md
│   │   ├── text.md
│   │   └── accessibility.md
│   ├── adr/
│   ├── api-matrices/
│   └── licenses/
├── packages/
│   ├── dart_ui_foundation/
│   ├── dart_ui_geometry/
│   ├── dart_ui_graphics_api/
│   ├── dart_ui_text/
│   ├── dart_ui_scheduler/
│   ├── dart_ui_platform/
│   ├── dart_ui_rendering/
│   ├── dart_ui_composition/
│   ├── dart_ui_layout/
│   ├── dart_ui_input/
│   ├── dart_ui_semantics/
│   ├── dart_ui_widgets/
│   ├── dart_ui_controls/
│   ├── dart_ui_styles/
│   ├── dart_ui_animation/
│   ├── dart_ui_headless/
│   ├── dart_ui_test/
│   ├── dart_ui_devtools/
│   ├── dart_ui_backend_win32/
│   ├── dart_ui_backend_x11/
│   ├── dart_ui_backend_wayland/
│   ├── dart_ui_backend_gtk/
│   ├── dart_ui_backend_macos/
│   ├── dart_ui_renderer_cpu/
│   ├── dart_ui_renderer_direct2d/
│   ├── dart_ui_renderer_opengl/
│   ├── dart_ui_renderer_vulkan/
│   ├── dart_ui_renderer_metal/
│   ├── dart_ui_bindings_win32/
│   ├── dart_ui_bindings_com/
│   ├── dart_ui_bindings_d3d11/
│   ├── dart_ui_bindings_d2d/
│   ├── dart_ui_bindings_xcb/
│   ├── dart_ui_bindings_wayland/
│   ├── dart_ui_bindings_glib/
│   ├── dart_ui_bindings_gtk/
│   ├── dart_ui_bindings_opengl/
│   ├── dart_ui_bindings_vulkan/
│   ├── dart_ui_bindings_objc/
│   ├── dart_ui_bindings_appkit/
│   └── dart_ui_bindings_metal/
├── tools/
│   ├── reference_inventory/
│   ├── ffi_codegen/
│   ├── wayland_codegen/
│   ├── shader_build/
│   ├── golden_diff/
│   ├── input_trace/
│   └── package_app/
├── examples/
│   ├── hello_window/
│   ├── hello_button/
│   ├── controls_gallery/
│   ├── text_editor/
│   ├── gpu_interop/
│   └── accessibility_demo/
├── benchmark/
│   ├── layout/
│   ├── rendering/
│   ├── text/
│   ├── input/
│   └── startup/
└── test/
    ├── integration/
    ├── platform/
    ├── golden/
    └── conformance/
```

## 7.1 Divisão mínima para o primeiro bootstrap

Para não criar dezenas de pacotes vazios, começar com:

```text
packages/
├── dart_ui/
├── dart_ui_platform/
├── dart_ui_graphics_api/
├── dart_ui_renderer_cpu/
├── dart_ui_backend_win32/
└── dart_ui_headless/
```

Separar novos pacotes somente quando:

- o módulo tiver contrato estável;
- houver consumidor real;
- houver testes próprios;
- o módulo não criar dependência circular;
- existir benefício claro de versionamento ou isolamento.

---

# 8. Camadas do framework

```text
Aplicação
  ↓
Widgets declarativos / controles
  ↓
Elements / estado / binding / estilos
  ↓
Layout + árvore visual + semântica
  ↓
RenderObjects
  ↓
DisplayList
  ↓
Scene / compositor / damage tracking
  ↓
RendererBackend
  ↓
RenderSurface
  ↓
WindowingBackend
  ↓
Win32 | XCB | Wayland | AppKit
```

## 8.1 Árvores distintas

O framework deverá documentar e testar quatro árvores:

1. **árvore de widgets/configuração:** objetos imutáveis ou quase imutáveis;
2. **árvore de elements:** identidade, estado, reconciliação e ciclo de vida;
3. **árvore de renderização:** layout, pintura e hit-test;
4. **árvore semântica:** acessibilidade e automação.

Opcionalmente, controles templated podem manter uma árvore lógica separada da visual.

## 8.2 Regra de dependências

- plataforma depende de foundation, nunca de widgets;
- renderer depende de graphics API, nunca de controls;
- widgets dependem de rendering/layout/input, nunca de Win32;
- accessibility converte semantics para adaptadores;
- `dart_graphics`/`marlin` entram por interfaces do renderer CPU e do texto;
- nenhum package comum importa um package `backend_*`.

---

# 9. Contratos centrais

## 9.1 Inicialização

```dart
abstract interface class DartUiApplication {
  Future<void> initialize();
  void run();
  Future<void> shutdown();
}

final class DartUi {
  static Future<void> run({
    required DartUiConfig config,
    required Widget Function() builder,
  }) async {
    // Seleção de plataforma, criação do dispatcher e montagem da raiz.
  }
}
```

## 9.2 Plataforma

```dart
abstract interface class PlatformBackend {
  String get name;
  PlatformCapabilities get capabilities;
  UiDispatcher get dispatcher;
  WindowingBackend get windowing;
  ClipboardBackend get clipboard;
  DragDropBackend get dragDrop;
  TextInputBackend get textInput;
  SystemThemeBackend get systemTheme;
  AccessibilityBackend? get accessibility;

  Future<void> initialize(PlatformInitOptions options);
  Future<void> shutdown();
}
```

## 9.3 Janela

```dart
abstract interface class NativeWindow {
  NativeWindowId get id;
  NativeHandle get handle;
  Size get clientSize;
  double get renderScale;
  double get desktopScale;
  WindowState get state;
  List<NativeSurfaceDescriptor> get surfaces;
  Stream<PlatformWindowEvent> get events;

  void show();
  void hide();
  void close();
  void setTitle(String value);
  void setBounds(Rect bounds);
  void setCursor(SystemCursor cursor);
  void requestRedraw(Rect? dirtyRect);
  Point screenToClient(PixelPoint point);
  PixelPoint clientToScreen(Point point);
}
```

## 9.4 Dispatcher

```dart
abstract interface class UiDispatcher {
  bool get hasThreadAccess;
  void post(void Function() callback, {DispatcherPriority priority});
  TimerHandle schedule(Duration delay, void Function() callback);
  void wake();
  void run();
  void stop();
}
```

Prioridades mínimas:

- immediate;
- input;
- animation;
- layout;
- render;
- normal;
- idle.

## 9.5 Renderizador

```dart
abstract interface class RendererBackend {
  RendererInfo get info;
  RendererCapabilities get capabilities;

  Future<RenderDevice> createDevice(RenderDeviceOptions options);
  bool supportsSurface(NativeSurfaceDescriptor surface);
}

abstract interface class RenderDevice {
  RenderTarget createTarget(NativeSurfaceDescriptor surface);
  Texture createTexture(TextureDescriptor descriptor);
  void dispose();
}

abstract interface class RenderTarget {
  Frame beginFrame(FrameRequest request);
  Future<PresentResult> present(Frame frame);
  void resize(PixelSize size, double scale);
  void dispose();
}
```

## 9.6 Display list

A `DisplayList` deverá ser independente de GPU e serializável:

```dart
sealed class DrawCommand {}

final class SaveCommand extends DrawCommand {}
final class RestoreCommand extends DrawCommand {}
final class TransformCommand extends DrawCommand {
  final Matrix4 transform;
}
final class ClipPathCommand extends DrawCommand {
  final PathHandle path;
  final ClipOperation operation;
}
final class DrawRectCommand extends DrawCommand {
  final Rect rect;
  final PaintHandle paint;
}
final class DrawPathCommand extends DrawCommand {
  final PathHandle path;
  final PaintHandle paint;
}
final class DrawGlyphRunCommand extends DrawCommand {
  final GlyphRunHandle run;
  final PaintHandle paint;
}
```

Implementação de alta performance:

- buffers `Uint8List`, `Uint32List`, `Float32List` ou `Float64List`;
- opcode compacto;
- tabelas de recursos por ID;
- deduplicação de paints, paths e imagens;
- arena reutilizável por frame;
- sem objetos Dart por comando no caminho final;
- modo de depuração que expande opcodes em objetos legíveis.

## 9.7 Superfície e capacidades

```dart
final class RendererCapabilities {
  final bool supportsPartialPresent;
  final bool supportsMsaa;
  final bool supportsCompute;
  final bool supportsExternalTextures;
  final bool supportsLinearColor;
  final int maxTextureSize;
  final Set<PixelFormat> formats;
}
```

O controle nunca consulta Direct3D ou Metal diretamente. Ele consulta capacidades abstratas.

---

# 10. Modelo de runtime e threads

## 10.1 Isolate principal

O primeiro release deverá usar:

- um isolate de UI;
- esse isolate na thread principal exigida pelo sistema;
- event loop da plataforma integrado ao dispatcher;
- renderização no mesmo isolate inicialmente;
- processamento assíncrono de arquivos/imagens em isolates auxiliares;
- nenhum callback nativo acessando objetos de outro isolate.

Isso reduz o número de variáveis durante o bootstrap.

## 10.2 Render isolate futuro

Somente depois de estabilizar a versão single-thread:

```text
UI isolate
  - widgets
  - layout
  - input
  - DisplayList
        ↓ mensagem imutável
Render isolate
  - scene diff
  - GPU device
  - resource cache
  - present
```

Regras:

- o dispositivo GPU pertence a um único isolate;
- nenhuma referência Dart comum cruza isolates;
- comandos usam `TransferableTypedData` ou buffers nativos com ownership explícito;
- recursos possuem IDs geracionais;
- fences evitam reutilização prematura;
- resize/device-loss volta como evento;
- input nunca espera o renderer;
- máximo de frames em voo configurável.

## 10.3 Callbacks FFI

Três categorias:

### Callback síncrono na thread do isolate

Usar `NativeCallable.isolateLocal` quando:

- o SO chama na mesma thread;
- o retorno é necessário;
- o callback não sobrevive ao objeto que o criou.

Exemplos:

- `WndProc`;
- certos callbacks de enumeração;
- função de comparação nativa chamada durante a mesma operação.

No Win32, a janela, o message pump e o `WndProc` devem pertencer à thread
mutadora do isolate de UI. `DispatchMessage` chama o procedimento
sincronamente e o Windows entrega mensagens entre threads na thread que criou
a janela. Nesse arranjo, `NativeCallable.isolateLocal` satisfaz tanto a
afinidade de thread quanto o retorno imediato de `LRESULT`.

`Pointer.fromFunction` não é um fallback para chamadas em outra thread: ele
possui a mesma restrição à thread mutadora. Deve ser reservado para callbacks
top-level/estáticos que precisam viver até o fim do isolate; `isolateLocal` é
preferível no backend porque aceita closures/métodos e possui lifecycle
explícito com `close()`.

### Callback assíncrono de qualquer thread

Usar `NativeCallable.listener` quando:

- o retorno C é `void`;
- o evento pode vir de thread externa;
- a execução pode ser enfileirada.

Exemplos:

- notificação de dispositivo;
- callback de biblioteca que não exige resposta imediata.

`listener` não pode implementar `WndProc`: o chamador nativo não espera o Dart
e a assinatura precisa retornar `void`, enquanto o Win32 exige um `LRESULT`
síncrono. Para uma notificação originada em thread externa, o padrão permitido
é `listener` → atualização/enfileiramento Dart → `PostMessage(WM_APP + n)`; o
`WndProc` continua sendo `isolateLocal` e processa a mensagem na thread de UI.

### Callback experimental entre threads

Não depender de API experimental no núcleo estável. Se `isolateGroupBound` for avaliado:

- colocar em feature flag;
- testar por versão do SDK;
- oferecer fallback;
- não usá-lo para contratos públicos.

O construtor não está disponível no SDK Dart 3.6.2 usado atualmente. Em SDKs
mais novos ele aceita retorno e chamadas de qualquer thread, mas callback e
`exceptionalReturn` precisam ser trivialmente compartilháveis, e o código não
pode depender de estado global/estático específico de um isolate. Mesmo quando
disponível, não será usado como `WndProc` principal: não oferece vantagem para
uma janela que já possui afinidade com a thread de UI e acrescenta concorrência
e dependência experimental.

| Contrato nativo | Callable adotado | Regra |
|---|---|---|
| `WndProc` e callback síncrono na UI | `NativeCallable.isolateLocal` | mesma thread, retorno imediato |
| Notificação `void` de thread externa | `NativeCallable.listener` | entrega assíncrona e ponte por `PostMessage` |
| Callback top-level com vida do isolate | `Pointer.fromFunction` | mesma restrição de thread de `isolateLocal` |
| Callback síncrono de qualquer thread | `isolateGroupBound` | experimental; fora do núcleo e ausente no SDK 3.6.2 |

## 10.4 Registro de callbacks

Criar uma infraestrutura única:

```dart
final class NativeCallbackRegistry {
  final Map<int, Object> _owners = {};
  final Map<int, NativeCallable<dynamic>> _callbacks = {};

  CallbackToken register(...);
  void unregister(CallbackToken token);
  void disposeAll();
}
```

Garantias:

- callback não é coletado enquanto o nativo pode chamá-lo;
- `close()` acontece só após desregistro nativo;
- callbacks tardios são descartados com segurança;
- tokens possuem geração para evitar use-after-free;
- exceptions nunca atravessam a fronteira FFI;
- cada callback captura erro e publica diagnóstico no dispatcher.
- no Win32, `close()` só ocorre após destruir as janelas, processar
  `WM_NCDESTROY`, remover referências nativas e desregistrar a classe.

---

# 11. Engenharia FFI

## 11.1 Separar binding cru e wrapper seguro

Estrutura de cada API:

```text
lib/src/
├── raw/
│   ├── constants.dart
│   ├── structs.dart
│   ├── functions.dart
│   └── generated/
├── abi/
│   ├── library_loader.dart
│   ├── symbol_table.dart
│   └── version_probe.dart
└── safe/
    ├── handles.dart
    ├── resources.dart
    ├── errors.dart
    └── services.dart
```

`raw/`:

- espelha a ABI;
- não possui política;
- usa nomes próximos aos headers;
- pode ser gerado;
- não lança exceções descritivas.

`safe/`:

- valida argumentos;
- converte erros;
- possui ownership;
- usa strings Dart;
- evita ponteiros crus na camada superior;
- implementa `dispose`.

## 11.2 Carregamento de biblioteca

```dart
final class NativeLibrarySpec {
  final List<String> candidates;
  final Set<String> requiredSymbols;
  final Set<String> optionalSymbols;
}

final class NativeLibraryLoader {
  NativeLibraryLoadResult load(NativeLibrarySpec spec);
}
```

Requisitos:

- aceitar nomes por plataforma;
- não confiar apenas em caminho absoluto;
- validar arquitetura;
- consultar símbolos obrigatórios antes de inicializar;
- armazenar ponteiros de função uma vez;
- não fazer `lookup` a cada frame;
- registrar versão e caminho efetivamente carregado;
- suportar bibliotecas já carregadas pelo processo quando apropriado.

## 11.3 ABI e calling convention

Testar explicitamente:

- `cdecl`;
- `stdcall`/WinAPI;
- tamanho de ponteiro;
- `long` diferente entre Windows e Unix;
- alignment de structs;
- unions;
- bitfields convertidos manualmente;
- callbacks;
- wchar UTF-16 no Windows;
- UTF-8 em APIs Unix;
- `BOOL`, `HRESULT`, `LRESULT`, `WPARAM`, `LPARAM`;
- `size_t`, `ssize_t`, `off_t`;
- ObjC `BOOL` e `NSInteger`;
- enums com tamanho ABI;
- structs retornadas por valor.

## 11.4 Geração e verificação

Cada pacote de binding deverá ter:

- arquivo de configuração do gerador;
- versão/commit do header;
- script reproduzível;
- lista de overrides manuais;
- teste de símbolo;
- teste de tamanho;
- teste de offset;
- teste mínimo de chamada;
- relatório de APIs ignoradas;
- documentação de ownership.

## 11.5 Memória

Regras:

- arenas de curta duração para uma chamada;
- alocações persistentes encapsuladas;
- UTF-16/UTF-8 temporário em arena;
- não guardar ponteiro para memória de arena após a chamada;
- buffers compartilhados com owner claro;
- `Finalizer` apenas como rede de segurança, nunca como mecanismo primário;
- `dispose` idempotente;
- contadores de recursos ativos em debug;
- stack trace opcional da alocação em modo leak-check.

## 11.6 COM

Implementar um núcleo COM reutilizável:

```text
dart_ui_bindings_com/
├── guid.dart
├── hresult.dart
├── iunknown.dart
├── com_ptr.dart
├── vtable.dart
├── apartment.dart
├── query_interface.dart
└── diagnostics.dart
```

`ComPtr<T>` deverá:

- chamar `AddRef` ao copiar ownership;
- chamar `Release` em `dispose`;
- distinguir borrowed/owned;
- validar ponteiro nulo;
- oferecer `queryInterface`;
- traduzir `HRESULT`;
- registrar apartment/thread;
- impedir uso após dispose.

Nunca gerar uma classe Dart por método de COM manualmente sem uma estratégia de geração. Criar gerador a partir de WinMD/headers ou metadados controlados.

## 11.7 GObject

Para GTK/GLib:

- modelar `g_object_ref/unref`;
- registrar conexão de signal e token de desconexão;
- encapsular `GError`;
- converter `GVariant`;
- documentar transfer annotations;
- não depender de introspecção dinâmica no hot path;
- usar GObject Introspection como fonte para gerar Dart, não como camada obrigatória de despacho em produção.

## 11.8 Objective-C Runtime

Criar pacote base:

```text
dart_ui_bindings_objc/
├── objc_runtime.dart
├── selector.dart
├── objc_class.dart
├── objc_object.dart
├── message_send.dart
├── block.dart
├── autorelease_pool.dart
├── method_signature.dart
├── class_builder.dart
└── ownership.dart
```

Requisitos:

- cache de `SEL`;
- cache de `Class`;
- variantes corretas de `objc_msgSend`;
- tratamento de structs retornadas conforme arquitetura;
- ARC não existe automaticamente para Dart: ownership precisa ser explícito;
- autorelease pool por iteração/evento;
- registro dinâmico de classes Dart-backed;
- IMPs baseadas em callbacks FFI;
- ponte segura entre ponteiro ObjC e objeto Dart;
- remoção segura de associação no `dealloc`;
- nenhum callback após destruição;
- testes Intel e Apple Silicon.

---

# 12. Inventário obrigatório das referências locais

Antes do primeiro commit funcional, gerar:

```text
doc/reference-inventory/
├── files.csv
├── licenses.csv
├── symbols.csv
├── architecture-map.md
├── candidates.md
└── rejected.md
```

## 12.1 Campos do inventário

| Campo | Exemplo |
|---|---|
| caminho | `referencias/avalonia/src/...` |
| projeto | Avalonia |
| linguagem | C# |
| licença | MIT |
| subsistema | windowing |
| conceito | top-level surface |
| relevância | alta |
| destino provável | `dart_ui_platform` |
| copiar? | não |
| abordagem | reimplementação por contrato |
| teste de paridade | resize/DPI |
| observações | possui backend nativo no macOS |

## 12.2 Script local sugerido

Criar `tools/reference_inventory/bin/inventory.dart` para:

- percorrer os quatro diretórios;
- ignorar `.git`, `build`, binários e caches configuráveis;
- calcular SHA-256;
- detectar extensão/linguagem;
- localizar arquivos de licença;
- indexar classes, interfaces e nomes de API;
- produzir JSON/CSV;
- permitir tags manuais;
- comparar duas execuções;
- não enviar código para serviços externos.

## 12.3 Saída esperada

Ao final da auditoria, cada referência importante deverá estar classificada em:

- portar conceito;
- portar algoritmo;
- reutilizar package Dart;
- gerar binding;
- usar apenas como teste comparativo;
- rejeitar por licença;
- rejeitar por dependência nativa;
- manter para pesquisa futura.

---


# 13. Backend Windows — Win32, GDI, Direct2D, Direct3D e DirectComposition

O Windows será a primeira plataforma porque:

- é o ambiente principal de desenvolvimento do projeto;
- a ABI Win32 é amplamente documentada;
- já existe experiência no repositório `win32`;
- é possível obter uma janela e um framebuffer CPU cedo;
- o mesmo `HWND` permite evoluir para Direct2D, D3D11, DXGI e DirectComposition.

## 13.1 Submódulos

```text
dart_ui_backend_win32/
├── win32_platform.dart
├── win32_dispatcher.dart
├── win32_window.dart
├── win32_window_class.dart
├── win32_message_router.dart
├── win32_input.dart
├── win32_keyboard.dart
├── win32_pointer.dart
├── win32_ime.dart
├── win32_clipboard.dart
├── win32_drag_drop.dart
├── win32_screens.dart
├── win32_theme.dart
├── win32_cursor.dart
├── win32_dialogs.dart
├── win32_accessibility.dart
└── win32_diagnostics.dart
```

## 13.2 Bootstrap mínimo Win32

Ordem exata:

1. carregar `kernel32.dll`, `user32.dll`, `gdi32.dll`, `shell32.dll`;
2. definir DPI awareness antes de criar janelas;
3. obter `HINSTANCE`;
4. registrar `WNDCLASSEXW`;
5. criar `NativeCallable` para `WndProc`;
6. registrar classe única do framework;
7. criar janela com `CreateWindowExW`;
8. associar `HWND` a um ID Dart;
9. mostrar janela;
10. processar mensagens;
11. lidar com `WM_PAINT`;
12. destruir janela;
13. desregistrar classe;
14. fechar callback.

### Gate de aceite

- janela aparece;
- redimensiona;
- título Unicode funciona;
- fechamento por botão e Alt+F4 funciona;
- não há crash após abrir/fechar mil janelas em sequência;
- callback permanece válido durante todo o ciclo;
- nenhuma mensagem usa um objeto já destruído.

## 13.3 Roteamento de `WndProc`

Não armazenar ponteiro Dart diretamente em `GWLP_USERDATA`. Armazenar um ID nativo geracional:

```dart
final class Win32WindowRegistry {
  static int attach(Win32Window window);
  static Win32Window? resolve(int token);
  static void detach(int token);
}
```

Fluxo:

- `WM_NCCREATE`: extrair token de `CREATESTRUCT`;
- associar token ao `HWND`;
- mensagens seguintes: resolver objeto;
- `WM_NCDESTROY`: remover associação;
- mensagem desconhecida: `DefWindowProcW`;
- exception: capturar, registrar e usar fallback seguro;
- nunca deixar uma exception Dart atravessar o callback.

## 13.4 Loop de mensagens

### Bootstrap

Começar com `GetMessageW`/`TranslateMessage`/`DispatchMessageW`.

### Integração com tarefas Dart

Evoluir para:

- `MsgWaitForMultipleObjectsEx`;
- evento nativo de wakeup;
- fila Dart protegida;
- `PostMessageW(WM_APP + n)` para acordar;
- timers de alta precisão quando necessário;
- prioridade de input antes de render;
- limite de tarefas por iteração para não bloquear mensagens.

### Reentrância

Documentar cenários:

- diálogo modal;
- COM/OLE;
- drag-and-drop;
- menu nativo opcional;
- `SendMessage`;
- acessibilidade;
- IME.

Criar `ReentrancyGuard` e permitir loops aninhados controlados. Não pressupor que “um callback termina antes de qualquer outro”.

## 13.5 DPI

Implementar desde o início:

- `SetProcessDpiAwarenessContext`;
- `GetDpiForWindow`;
- `AdjustWindowRectExForDpi`;
- `WM_DPICHANGED`;
- escalas lógicas e físicas;
- tamanho mínimo/máximo em unidades lógicas;
- movimentação entre monitores;
- rounding determinístico.

Modelo:

```dart
logical = physical / scale;
physical = round(logical * scale);
```

Testes em 100%, 125%, 150%, 175%, 200% e mistura de monitores.

## 13.6 Input Windows

### Mouse

Mensagens mínimas:

- `WM_MOUSEMOVE`;
- `WM_MOUSELEAVE`;
- botões;
- wheel vertical/horizontal;
- double click;
- captura;
- cursor;
- coordenadas negativas e múltiplos monitores.

### Pointer API

Depois do mouse básico:

- `WM_POINTERDOWN/UP/UPDATE`;
- `GetPointerInfo`;
- touch;
- pen;
- pressão;
- tilt;
- contato;
- histórico/coalescing;
- IDs estáveis;
- captura por ponteiro.

### Teclado

Separar:

- tecla física;
- tecla lógica;
- texto gerado;
- composição;
- modificadores;
- repeat.

Mensagens:

- `WM_KEYDOWN/UP`;
- `WM_SYSKEYDOWN/UP`;
- `WM_CHAR`;
- `WM_UNICHAR`;
- dead keys;
- layouts internacionais;
- AltGr;
- teclado numérico;
- scan code;
- extended flag.

Não derivar texto apenas de keycode.

## 13.7 IME e edição

Fases:

1. suporte `WM_IME_*` com IMM32 — **feito** (`lib/src/backends/win32/win32_ime.dart`);
2. composição, candidato e caret — **feito**;
3. integração com `TextInputClient` — **feito** (`RenderTextField` implementa o
   contrato; `TextInputScope` publica o backend e a janela na árvore);
4. evolução opcional para TSF — **não feita**, e continua opcional: IMM32 é a
   camada de compatibilidade que o próprio TSF emula, e cobre composição,
   candidatos e teclas mortas. O que só o TSF alcança é painel de escrita à mão
   e ditado.

Contrato comum, como ficou em `lib/src/platform/text_input.dart` — mais próximo
do esboço abaixo do que dele, com três diferenças que são achados e não gosto:

```dart
abstract interface class TextInputClient {
  TextInputConfiguration get textInputConfiguration;
  ImeSurroundingText get surroundingText;  // sem a pré-edição dentro
  Rect get caretRect;                      // coordenadas do cliente, lógicas

  void updateComposition(ImeComposition composition);
  void commitText(String text);
  void deleteSurroundingText({required int beforeLength, required int afterLength});
}
```

1. **Não há `updateEditingValue` nem `setComposingRegion` separados.** Uma
   `ImeComposition` carrega texto, cláusulas de estilo e o cursor *dentro* da
   pré-edição de uma vez, porque as três só significam alguma coisa juntas —
   é o mesmo argumento que fez `TextEditingValue` ser um valor e não três
   campos.
2. **`caretRect` é do cursor e em coordenadas do cliente**, não da tela. O
   Wayland nunca informa a posição de uma surface no desktop, então um
   retângulo de tela lá não é inconveniente: é inexprimível. E `CANDIDATEFORM`
   do Win32 já é relativo ao cliente, então a conversão que se evitaria é
   nenhuma nos dois lados.
3. **`deleteSurroundingText` fica no contrato mesmo sem existir no Win32 nem no
   XIM**, porque no Wayland ela não é opcional: um método que a pede e é
   ignorado duplica os caracteres que queria substituir.

O que **não** entrou, cada um com motivo: reconversão (`IMR_RECONVERTSTRING` só
existe no Win32; um porte com uma implementação não é porte), desenhar a janela
de candidatos (é da plataforma nas três), e "começar a compor" (nenhum dos três
protocolos tem essa operação — a composição começa porque o usuário apertou uma
tecla que o método reivindicou).

Testar:

- português com acentos;
- dead keys;
- chinês;
- japonês;
- coreano;
- emoji;
- surrogate pairs;
- seleção;
- reconversão;
- movimentação da janela de candidatos.

## 13.8 Clipboard

Implementar:

- texto Unicode;
- HTML;
- PNG;
- bitmap;
- lista de arquivos;
- formatos customizados;
- delayed rendering quando necessário;
- observação de mudanças.

Regras:

- abrir/fechar clipboard com retry limitado;
- ownership claro de `HGLOBAL`;
- não liberar memória transferida ao sistema;
- validar tamanhos;
- normalizar line endings apenas na API de alto nível;
- impedir acesso após fechamento.

## 13.9 Drag-and-drop/OLE

Fase inicial:

- `WM_DROPFILES` para arquivos.

Fase profissional:

- `IDropTarget`;
- `IDropSource`;
- `IDataObject`;
- `FORMATETC`;
- `STGMEDIUM`;
- efeitos copy/move/link;
- formatos assíncronos;
- feedback visual;
- drag image;
- cancelamento;
- COM apartment correto.

Criar gerador de vtables para implementar interfaces COM em Dart. Esse é um dos maiores testes da estratégia “sem wrapper”.

## 13.10 Janelas e chrome

Recursos:

- normal, minimized, maximized, fullscreen;
- owner/owned;
- modal;
- borderless;
- transparent;
- always-on-top;
- taskbar visibility;
- icon;
- min/max size;
- resize regions;
- hit-test do chrome customizado;
- shadow;
- system menu;
- snap layouts;
- dark title bar;
- backdrop opcional;
- acrylic/mica como capacidade opcional.

Mensagens críticas:

- `WM_NCCALCSIZE`;
- `WM_NCHITTEST`;
- `WM_GETMINMAXINFO`;
- `WM_WINDOWPOSCHANGING`;
- `WM_SIZE`;
- `WM_MOVE`;
- `WM_ACTIVATE`;
- `WM_SETFOCUS`;
- `WM_KILLFOCUS`;
- `WM_CLOSE`;
- `WM_DESTROY`;
- `WM_NCDESTROY`;
- `WM_THEMECHANGED`;
- `WM_SETTINGCHANGE`;
- `WM_DISPLAYCHANGE`.

## 13.11 Backend CPU por GDI

### Objetivo

Validar toda a pilha sem depender de GPU.

### Implementação

- `CreateDIBSection` em BGRA premultiplicado;
- buffer acessível por ponteiro;
- `dart_graphics` desenha diretamente;
- `BitBlt`/`StretchDIBits` no paint;
- dirty rectangles;
- recreação no resize;
- double buffering;
- proteção contra buffer em uso;
- alinhamento de stride;
- fallback de formato.

### Gate de aceite

- 60 FPS em uma cena básica;
- resize contínuo sem tearing grosseiro;
- texto e paths corretos;
- comparação de pixel com backend headless;
- zero cópia entre rasterizador e DIB quando possível;
- paint parcial;
- nenhum acesso ao buffer após resize.

## 13.12 Direct2D

### Estado auditado em 2026-08-23 — implementado

Direct2D existe em `lib/src/backends/win32/d2d/` (nove arquivos:
`d2d1_library.dart`, `d2d1_interfaces.dart`, `d2d1_structs.dart`,
`d2d_backend.dart`, `d2d_targets.dart`, `d2d_raster_sink.dart`,
`d2d_glyph_atlas.dart`, `dwrite_interfaces.dart`, `dwrite_font_faces.dart`) e
**está ligado ao seletor**: `_win32Direct2d()` entra em `defaultPresentations()` depois de
D3D11 e OpenGL — para não mudar a imagem padrão de uma máquina comum enquanto é
novo — e **antes** da DIB, para que uma máquina cujos probes de D3D11/GL
falhem ainda receba um caminho acelerado. `--presentation=direct2d` ou
`DART_UI_PRESENTATION=direct2d` fixam por nome.

- **COM é em Dart puro, sem `package:win32`**: vtable por índice
  (`comMethod<...>(pointer, N)`), com os helpers compartilhados de
  `d3d12_com.dart` (`ComObject`, `comFailed`, `writeGuid`, `Guid`). A aritmética
  de slot está documentada por interface;
- ligados: factory single-threaded, `ID2D1PathGeometry` + `ID2D1GeometrySink`,
  brushes sólidos, `CreateGradientStopCollection` com brushes linear e radial,
  `CreateLayer`/`PushLayer`/`PopLayer` com pool de `ID2D1Layer` por
  profundidade, `ID2D1HwndRenderTarget` para janela e um DC render target sobre
  DIB top-down para leitura de volta;
- caches: geometria por identidade de path (`kD2dGeometryCacheLimit = 512`) e
  **um atlas de glifos de 1024×1024** (`d2d_glyph_atlas.dart`) chaveado por
  (face, tamanho quantizado, glifo, bucket subpixel), com bitmap próprio só
  para tipo grande demais para o atlas (`kD2dGlyphCacheLimit = 64`).

### Custo de texto — medido em 2026-08-24, e o que mudou por causa disso

O caminho de texto fazia **uma `FillOpacityMask` por glifo, cada uma de um
bitmap diferente**. A medição
(`test/backends/win32/d2d/d2d_text_cost_test.dart`, atrás de
`DART_UI_GPU_BENCHMARK=1`) mostrou que **o gargalo não era a contagem de
chamadas e sim o rebind de bitmap**: 3400 quads do tamanho de um glifo custam
12,1–16,6 ms com um bitmap cada, 5,4–8,0 ms com um atlas só e as mesmas
chamadas, e 4,5–5,6 ms como um único `DrawSpriteBatch`.

O sink passou a usar **atlas único + `ID2D1SpriteBatch`**. Os alvos deste
backend, embora criados por construtores Direct2D 1.0, respondem
`QueryInterface` até `ID2D1DeviceContext4` (verificado em
`d2d_device_context_probe_test.dart`), então **nada mudou em `d2d_targets.dart`**;
onde o runtime não oferecer o sprite batch, o sink emite um laço de
`FillOpacityMask` sobre o mesmo atlas, que ainda é 2,2× melhor que o estado
anterior.

Numa tela cheia de texto (6800 glifos, 13 px, 1280×720), a parcela de texto do
quadro:

| caminho | texto |
| --- | --- |
| **D2D antes** | **7,58 – 9,64 ms** |
| D2D, atlas + laço | 2,57 – 3,15 ms |
| **D2D, atlas + `DrawSpriteBatch`** | **1,31 – 2,16 ms** |
| renderizador de CPU | 4,92 – 6,26 ms |
| OpenGL | 1,29 – 3,91 ms |

**Paridade preservada, e endurecida:** o caso alinhado continua em **desvio 0**
contra a CPU e o teste passou a asserir `0` em vez de aceitar a tolerância do
caminho de contorno; as duas rotas de emissão concordam entre si em desvio 0; o
escape de tipo grande também. Detalhes, tabelas completas e a justificativa da
rota em **`doc/architecture/TEXTO_DIRECT2D.md`**.

**Correção ao *Mapeamento* abaixo:** a linha `glyph run → DrawGlyphRun` **não é
o caminho padrão**. Por padrão os glifos vêm do `GlyphCache` compartilhado — o
mesmo rasterizador da CPU — e são desenhados a partir do atlas de glifos do
backend, com uma `DrawSpriteBatch` por run.

**DirectWrite: conclusão registrada em 2026-08-24.** O lote **fecha a diferença
de desempenho sem DWrite** — o texto do Direct2D ficou ~4–5× mais rápido, ~3×
mais rápido que o renderizador de CPU e no mesmo patamar do caminho OpenGL —
então **não sobra argumento de desempenho para ela**. Somado ao que já se sabia
(o framework é dono de shaping, OpenType, hinting e contornos, e rasterizar com
DWrite faria o mesmo documento render diferente por plataforma; e sob rotação a
DWrite também preenche contornos, sem ganho nenhum), **DirectWrite não é o
caminho padrão e não deve virar**.

O único cenário que ainda a justifica é **aparência nativa do Windows como
opção explícita do usuário da biblioteca**, e é assim que ela existe:
`RenderPolicy.glyphRasterization = GlyphRasterization.platformNative`,
**desligada por padrão**, em **nível 1** — só a rasterização é nativa
(`ID2D1RenderTarget::DrawGlyphRun` com os glifos, o tamanho e os deslocamentos
que *nós* calculamos, `glyphAdvances` todos 0), então **o layout continua
idêntico em todas as plataformas** e só os pixels dentro do glifo mudam. A face
é resolvida pelo nome de família na coleção do sistema e **só é aceita se os
índices de glifo coincidirem com os nossos**; caso contrário é **recusada por
nome** e o run cai na rota portátil. **Nível 2** (`IDWriteTextLayout` fazendo
shaping e quebra de linha) está **deliberadamente não implementado**, porque
mudaria as métricas e com elas o layout — divergência de geometria, não de
pixel. Tudo em **`doc/architecture/TEXTO_DIRECT2D.md`**.

**Recusado por nome neste sink:** modos de blend além de source-over (exigem o
blend primitivo de `ID2D1DeviceContext`, não vinculado) e texto com traço.
**Texto sob rotação, cisalhamento, espelhamento ou escala não uniforme deixou
de ser recusado**: o sink usa as mesmas `glyphMasksFit` e
`glyphOutlineTransform` que a CPU e a GPU, mantém o blit de máscara no caso
alinhado e, no caso geral, preenche o contorno do glifo com `FillGeometry`
sobre um `ID2D1PathGeometry`. A paridade contra a CPU está medida em
`test/backends/win32/d2d/d2d_glyph_transform_test.dart` — ver §68.4 para a
tolerância e por que ela não é desvio 0.

### Estratégia

Direct2D será o primeiro backend acelerado Windows. Ele pode:

- desenhar primitivas;
- paths;
- gradientes;
- imagens;
- texto via DirectWrite;
- integrar com DXGI/D3D11;
- apresentar em swapchain;
- cooperar com DirectComposition.

### Pacotes

```text
dart_ui_bindings_d2d/
dart_ui_bindings_dwrite/
dart_ui_renderer_direct2d/
```

### Sequência

1. COM base;
2. factory D2D;
3. factory DirectWrite;
4. device D3D11;
5. DXGI device;
6. D2D device/context;
7. swapchain;
8. bitmap target;
9. begin/end draw;
10. present;
11. device loss;
12. resize.

### Mapeamento

| DisplayList | Direct2D |
|---|---|
| rect/path | geometries |
| solid paint | solid color brush |
| gradient | gradient stop collection + brush |
| image | bitmap |
| clip rect | axis-aligned clip |
| clip path | layer/geometry mask |
| transform | context transform |
| glyph run | `DrawGlyphRun` |
| layer/opacity | layer/command list |

### Caches

- brushes por paint;
- geometries por path hash;
- bitmaps por image ID;
- text formats;
- glyph runs;
- command lists;
- stroke styles.

## 13.13 Direct3D 11 e DXGI

Não iniciar por D3D12. D3D11 tem:

- menor complexidade;
- ampla disponibilidade;
- integração madura com Direct2D;
- swapchain e device-loss conhecidos;
- suporte suficiente para UI.

### Componentes

- `ID3D11Device`;
- `ID3D11DeviceContext`;
- DXGI adapter/factory;
- swapchain;
- render target view;
- textures;
- upload buffers;
- shaders;
- blend/raster/depth states;
- fences/queries conforme necessário.

### Uso no framework

Dois modos:

1. **Direct2D sobre D3D11:** caminho principal 2D;
2. **renderer D3D11 próprio:** fase posterior, para controle completo e paridade com Metal/Vulkan.

## 13.14 DirectComposition

Usar depois que swapchain e device estiverem estáveis.

Objetivos:

- composição eficiente;
- animações independentes;
- superfícies;
- transparência;
- integração com compositor do Windows;
- melhor redimensionamento.

O backend cria:

- dispositivo DirectComposition;
- target associado ao `HWND`;
- visual raiz;
- conteúdo da swapchain;
- commit;
- sincronização e device-loss.

Não misturar o modelo de visual DirectComposition com a árvore pública de widgets. Criar um adaptador interno de composição.

## 13.15 GDI como backend e ferramenta

GDI não será apenas fallback. Também servirá para:

- validar janela;
- medir comportamento de DPI;
- desenhar overlay de debug;
- capturar screenshots;
- comparar output;
- fornecer modo safe;
- imprimir diagnóstico quando GPU falha.

Não usar GDI como motor final de texto/layout do framework.

## 13.16 Acessibilidade Windows

Criar uma árvore semântica independente e adaptá-la para UI Automation.

Fases:

1. root provider;
2. fragment providers;
3. bounding boxes;
4. nome, role, estado;
5. invoke;
6. value;
7. range value;
8. selection;
9. text;
10. focus;
11. live regions;
12. notificações de estrutura/propriedade.

Regras:

- chamadas podem ocorrer reentrantes;
- provider pode ser chamado por outra thread;
- snapshots semânticos devem ser seguros;
- objetos nativos devem sobreviver enquanto expostos;
- automação não deve acessar árvore em mutação;
- usar IDs estáveis;
- validar com Narrator, Inspect e testes automatizados.

## 13.17 Critérios de conclusão do backend Windows

Revisto em 2026-08-23 contra `lib/src/backends/win32/`.

- [x] janela e múltiplas janelas;
- [x] DPI por monitor (`Capability.perMonitorDpi`, condicionado a `GetDpiForWindow`);
- [x] CPU/GDI (DIB retida + `BitBlt`, com damage e resize);
- [x] mouse, teclado, pointer;
- [x] IME (IMM32: composição, cláusulas, posicionamento de candidatos, cancelamento; `WM_IME_REQUEST`/`IMR_DOCUMENTFEED` **não** respondida, então o método não lê texto ao redor. **TSF não implementada**);
- [x] clipboard (**texto apenas**: `Clipboard` não tem imagem nem arquivo);
- [x] drag-and-drop (OLE, **nos dois sentidos** — `IDropTarget` e `DoDragDrop`; a imagem de arraste de `DragRequest.feedback` é **ignorada**);
- [x] cursor;
- [ ] monitores — enumeração e mudança em runtime não verificadas;
- [x] temas (claro/escuro/alto contraste no framework; o tema do SO é lido por `SystemInfo.isDarkMode`);
- [x] Direct2D (§13.12);
- [x] D3D11/DXGI;
- [ ] DirectComposition opcional — **não existe**;
- [~] acessibilidade básica — ponte UIA escrita (`backends/win32/uia/`), e o próprio probe diz "accessibility is partial"; `Capability.accessibility` **não é reivindicada**;
- [x] device-loss (`gpu_recovery.dart` é o orquestrador, chamado por GL e D3D11);
- [ ] leak-check;
- [x] AOT x64 (gate de CI);
- [ ] AOT arm64;
- [ ] testes em Windows 10 e 11 — só 11 (build 26200) aqui.

Fora da lista original, mas entregues no Windows: **D3D12** (com o primeiro
executor de compute tiles) e um **backend Vulkan**, nenhum dos dois no seletor
de produção; e as APIs de SO da §56.1, que no Windows são as mais completas das
três plataformas.

---

# 14. Backend Linux — arquitetura comum

Linux não é uma única plataforma gráfica. O framework deverá distinguir:

- X11;
- Wayland;
- ambiente desktop;
- compositor;
- toolkit disponível;
- bibliotecas de input/texto;
- portal;
- renderizador.

## 14.1 Detecção

Ordem sugerida:

1. configuração explícita;
2. `WAYLAND_DISPLAY`;
3. `XDG_SESSION_TYPE`;
4. tentativa de conexão Wayland;
5. `DISPLAY`;
6. tentativa XCB;
7. modo headless;
8. erro diagnóstico.

Nunca assumir Wayland apenas porque a variável existe. Testar conexão.

## 14.2 Pacote comum Linux

```text
dart_ui_backend_linux_common/
├── linux_environment.dart
├── linux_library_probe.dart
├── linux_desktop_portal.dart
├── linux_font_config.dart
├── linux_xkb.dart
├── linux_cursor_theme.dart
├── linux_system_theme.dart
└── linux_diagnostics.dart
```

## 14.3 Bibliotecas e capacidades

Possíveis bibliotecas:

- `libxcb`;
- extensões XCB;
- `libwayland-client`;
- `libxkbcommon`;
- `libxkbcommon-x11`;
- `libEGL`;
- `libGL`;
- loader Vulkan;
- `libglib-2.0`;
- `libgobject-2.0`;
- `libgtk-4`;
- D-Bus/GIO;
- fontconfig;
- freetype apenas como backend opcional de comparação.

Cada uma terá probe independente.

---

# 15. Backend X11 preferencialmente por XCB

## 15.1 Por que XCB

- API assíncrona;
- protocolo explícito;
- melhor adequação para geração de bindings;
- integração por file descriptor;
- menos estado implícito que Xlib;
- extensões separadas;
- bom controle de round trips.

Xlib poderá existir apenas para compatibilidade pontual, não como base.

## 15.2 Submódulos

```text
dart_ui_backend_x11/
├── x11_platform.dart
├── x11_dispatcher.dart
├── x11_connection.dart
├── x11_window.dart
├── x11_atoms.dart
├── x11_ewmh.dart
├── x11_icccm.dart
├── x11_input.dart
├── x11_xkb.dart
├── x11_xinput2.dart
├── x11_clipboard.dart
├── x11_drag_drop.dart
├── x11_screens.dart
├── x11_cursor.dart
├── x11_shm_surface.dart
├── x11_ime.dart          (não escrito — ver abaixo)
├── x11_accessibility.dart
└── x11_diagnostics.dart
```

### 15.2.1 IME no X11: decisão registrada

**Revisada em 26/08/2026.** A razão original desta decisão caiu: o backend
X11 **tem teclado** desde essa data. `x11_keyboard.dart` decodifica
`GetKeyboardMapping` e `GetModifierMapping` do core protocol,
`X11EventTranslator.translateKey` emite `KeyDownEvent`/`KeyUpEvent` e o
`TextInputEvent` correspondente, e `x11_backend.dart` reivindica
`Capability.keyboardInput` quando o servidor respondeu. Ver §68.1 para o que a
rota do core protocol não cobre.

`x11_ime.dart` **continua não escrito**, e agora pela razão que sempre foi a
verdadeira para o IME em si: XIM precisa de Xlib (não tem equivalente em XCB) e
de um input context com um servidor de método de entrada separado. O que isso
custa está nomeado: **CJK indisponível neste backend**. Não custa acentuação —
ver o parágrafo seguinte.

Foi implementada a metade que serve às duas plataformas Linux:
`lib/src/platform/compose_sequences.dart` lê as tabelas Compose do próprio X11
(`$XCOMPOSEFILE`, `~/.XCompose`, `/usr/share/X11/locale/<locale>/Compose`, com
`include` e as substituições `%L`/`%H`/`%S`) e resolve teclas mortas e a tecla
Compose. Está **ligada no Wayland** — onde o teclado existe e o `wl_keyboard`
entrega keysyms sem compor — e apenas quando o compositor não oferece
`zwp_text_input_v3`, porque um método de entrada já compõe teclas mortas e rodar
os dois aplicaria o acento duas vezes. **No X11 ela foi ligada em 26/08/2026**,
sem a condicional do Wayland: não há método de entrada neste backend que já
pudesse compor, então não há como aplicar o acento duas vezes.

**Fica de fora no X11, explicitamente:** CJK (chinês, japonês, coreano) e
qualquer pré-edição. A acentuação por tecla morta **saiu desta lista**: `´`
seguido de `a` produz um `TextInputEvent` com `á`, e o teste que prova isso
monta os bytes de dois `xcb_key_press_event_t` de verdade.

## 15.3 Conexão e setup

1. `xcb_connect`;
2. verificar erro;
3. obter setup;
4. localizar screen;
5. escolher visual/depth;
6. internar atoms essenciais;
7. criar janela;
8. configurar event masks;
9. definir propriedades ICCCM/EWMH;
10. mapear;
11. flush;
12. integrar FD ao dispatcher.

## 15.4 Event loop X11

O dispatcher deverá combinar:

- fila Dart;
- FD da conexão XCB;
- timer;
- wake FD/eventfd;
- opcional GLib main context.

Opções:

- `poll`;
- `ppoll`;
- `epoll`;
- wrapper seguro em Dart FFI.

Fluxo:

1. drenar eventos já enfileirados;
2. processar tarefas prioritárias;
3. calcular próximo deadline;
4. aguardar FD/timer/wakeup;
5. chamar `xcb_poll_for_event`;
6. normalizar;
7. liberar evento;
8. flush quando necessário.

Evitar round trips no input.

## 15.5 ICCCM/EWMH

Implementar:

- `WM_PROTOCOLS`;
- `WM_DELETE_WINDOW`;
- título UTF-8;
- classe;
- tamanho mínimo/máximo;
- estado normal/minimized/maximized/fullscreen;
- `_NET_WM_STATE`;
- `_NET_ACTIVE_WINDOW`;
- `_NET_WM_WINDOW_TYPE`;
- `_NET_WM_PID`;
- `_NET_FRAME_EXTENTS`;
- hints de usuário;
- transient/owner;
- urgency;
- startup ID quando aplicável.

## 15.6 Input X11

### Core input

Bootstrap para mouse/teclado básico.

### XInput2

Obrigatório para qualidade profissional:

- múltiplos devices;
- touch;
- pen;
- smooth scroll;
- raw motion opcional;
- hierarchy changes;
- IDs;
- valuators;
- capture/grab.

### XKB

**Estado em 26/08/2026:** o teclado foi implementado pelo **core protocol**
(`GetKeyboardMapping` + `GetModifierMapping`), não por `xkbcommon` — a
justificativa da escolha, e o que ela não cobre, estão no topo de
`lib/src/backends/x11/x11_keyboard.dart` e resumidos na §68.1. Não há tabela de
teclado manual: as regras aplicadas são as do próprio protocolo sobre a resposta
do servidor. O que segue continua valendo como plano para a rota XKB, que é a
resposta para três ou mais grupos, para grupo por evento e para
`DetectableAutoRepeat`:

- keymap;
- state;
- modifiers;
- compose;
- locale;
- layout change;
- key repeat;
- nome físico/lógico;
- texto separado.

Não implementar tabela de teclado manual completa.

## 15.7 Clipboard X11

Clipboard em X11 é protocolo de selections, não memória global.

**Estado em 26/08/2026:** `x11_clipboard.dart` existe e cobre `CLIPBOARD`,
ownership, `TARGETS`, `TIMESTAMP`, `UTF8_STRING`, `STRING`, `TEXT`,
`SelectionRequest`, `SelectionNotify`, timeout, perda de ownership e **INCR na
leitura**. Fora, e nomeado: `PRIMARY`, `text/html`, `image/png`, URI list,
formatos customizados, **INCR como dono** (payload acima de 200 KiB é recusado
em vez de truncado) e clipboard manager (`CLIPBOARD_MANAGER`/`SAVE_TARGETS`).
A máquina de estados é testável sem servidor real, como esta seção pedia:
`test/backends/x11/x11_clipboard_test.dart`.

Implementar:

- PRIMARY;
- CLIPBOARD;
- ownership;
- TARGETS;
- UTF8_STRING;
- STRING;
- text/html;
- image/png;
- URI list;
- formatos customizados;
- `SelectionRequest`;
- `SelectionNotify`;
- transferências grandes com INCR;
- timeout;
- perda de ownership;
- clipboard manager.

Criar máquina de estados testável sem servidor real.

## 15.8 Drag-and-drop XDND

Implementar:

- `XdndAware`;
- enter;
- position;
- status;
- drop;
- finished;
- leave;
- selection de dados;
- MIME types;
- actions;
- source e target;
- cancelamento;
- coordenadas globais;
- janela proxy.

## 15.9 Monitores

Usar RandR:

- outputs;
- CRTCs;
- geometria;
- scale inferido;
- primary;
- hotplug;
- refresh;
- orientação;
- work area via EWMH.

A escala em X11 é inconsistente. Política:

1. override do usuário;
2. configuração do desktop;
3. Xft DPI;
4. dimensão física com sanity checks;
5. fallback 1.0.

## 15.10 Backend CPU X11

Preferência:

- MIT-SHM;
- `xcb_shm_put_image`;
- buffers duplos/triplos;
- fallback `xcb_put_image`.

Requisitos:

- detectar extensão;
- ownership do segmento;
- sincronizar reutilização;
- dirty rect;
- formato compatível;
- byte order;
- depth/visual;
- evitar conversão por frame.

## 15.11 OpenGL no X11

Opções:

- EGL com plataforma X11;
- GLX como fallback.

Preferir EGL para reduzir diferenças com Wayland.

Fluxo:

- escolher config;
- criar surface;
- criar context;
- make current;
- resolver funções;
- swap interval;
- render;
- swap;
- resize;
- context loss;
- teardown.

## 15.12 Vulkan no X11

- loader Vulkan;
- instance;
- extensões Xlib/XCB surface;
- preferir XCB surface;
- physical device;
- queue;
- swapchain;
- present;
- resize/out-of-date;
- synchronization;
- validation layers em debug;
- fallback claro.

## 15.13 Acessibilidade X11/Linux

Usar árvore semântica e expor AT-SPI por D-Bus.

Primeiro escopo:

- application;
- window;
- button;
- text;
- checkbox;
- list;
- focus;
- bounds;
- name/description;
- actions;
- value;
- events.

Não acoplar AT-SPI a X11: o mesmo adaptador deverá servir Wayland.

## 15.14 Critérios de conclusão X11

Revisto em 2026-08-23 contra `lib/src/backends/x11/`.

- [x] XCB sem Xlib obrigatória;
- [x] janela (criação checked, `WM_PROTOCOLS`/`WM_DELETE_WINDOW`, ICCCM/EWMH);
- [x] resize/move/focus (coalescidos no pump, com generation de surface);
- [~] CPU SHM — a apresentação é **`PutImage` do core**, dividida em bandas ou tiles por um planner puro, **não `MIT-SHM`**. Validada sob Xvfb no CI;
- [ ] **XKB — não existe, e é o bloqueio central**: `xcbKeyPress`/`xcbKeyRelease` são consumidos e descartados, o backend não emite `KeyEvent` nem `TextInputEvent` e não reivindica `Capability.keyboardInput`. Sem isso não há teclado, atalho, tecla morta nem IME (§15.2.1, §68);
- [x] mouse/wheel (botões 1/2/3/8/9, roda 4/5/6/7 em linhas);
- [ ] XInput2;
- [ ] **clipboard INCR — não existe**: não há `x11_clipboard.dart` e o backend não implementa `ClipboardProvider`;
- [x] XDND — **nos dois sentidos**: `X11DragDropManager` recebe e `X11XdndSource` inicia. A imagem de arraste é **ignorada**. *(Cuidado: a string de diagnóstico do probe ainda diz "dragging out is not implemented"; ela é que está velha — o caminho de `initialize` diz "XDND is available in both directions" e liga a fonte.)*;
- [ ] RandR;
- [~] OpenGL/EGL — `x11_gl_surface.dart` e a entrada `_x11OpenGl()` existem no seletor, e o teste correspondente diz por escrito que este caminho **nunca foi executado**;
- [ ] Vulkan opcional — há `VK_KHR_xcb_surface`/`VK_KHR_xlib_surface` no lado do Vulkan, sem nada que produza o descriptor a partir deste backend;
- [ ] AT-SPI básico;
- [ ] GNOME/KDE/Xfce;
- [~] Xorg e XWayland — só Xvfb no CI;
- [ ] x64 e arm64.

---

# 16. Backend Wayland

Wayland deverá ser tratado como protocolo, não como uma coleção de funções equivalentes ao Win32.

## 16.0 Estado auditado em 2026-08-23 — e a decisão que esta seção não previa

**O backend não usa `libwayland-client`.** Ele fala o protocolo direto no
socket, em Dart, e isso invalida a premissa das seções 16.1, 16.4 e 16.7 como
estavam escritas. Elas foram corrigidas abaixo; o que segue é o estado.

- **Wire próprio** (`wayland_wire.dart`): cabeçalho de 8 bytes, ponto fixo 24.8,
  alinhamento em palavra, strings terminadas em NUL, arrays, e `fd` ocupando
  zero bytes de wire. `WaylandWireDecoder` remonta o stream;
- **Transporte por FFI de libc, não `dart:io`** (`wayland_libc.dart`,
  `wayland_transport.dart`): `socket(AF_UNIX, SOCK_STREAM|SOCK_CLOEXEC)`,
  `connect`, `sendmsg`, `recvmsg`, `poll`, `pipe2`, `fcntl`, `read`, `write`,
  `close`, `ftruncate`, `mmap`, `munmap`, `memfd_create`, `__errno_location`.
  **`SCM_RIGHTS` nos dois sentidos**, com o `cmsghdr` montado à mão, até 32 fds
  por mensagem. Só três arquivos importam `dart:ffi`. **Restrição declarada:
  apenas ABIs LP64** — os layouts de `msghdr` (56), `cmsghdr` (16) e
  `sockaddr_un` (110) estão fixados;
- **`wl_shm` com swapchain**: `WaylandShmSurface`, até três slots
  (`defaultMaximumSlots = 3`), crescendo sob demanda; a ordem de escolha é alvo
  atual → último commitado se livre → slot livre → novo slot → e, em último
  caso, reusar o mais antigo ocupado **contando isso** em `busyReuseCount`, em
  vez de fazer em silêncio. `wl_buffer.release` limpa `busy`, e destruir um
  buffer ocupado é adiado até o release;
- **Frame pacing por `wl_surface.frame`**: `present()` coalesce enquanto há
  callback pendente, unindo o damage e contando em `throttledFrameCount`;
- **xdg-shell** com o latch de duas fases correto — `xdg_toplevel.configure`
  só *encena*, `xdg_surface.configure` **lata e faz o ack**, e vários configures
  num pump colapsam no serial mais novo. `ping`/`pong` respondidos
  automaticamente. Estados `maximized`, `fullscreen` e `activated` aplicados;
- **popups com `xdg_positioner`**, incluindo os seis bits de constraint
  adjustment, gravidade deliberadamente invertida no mapeamento, retângulo de
  âncora degenerado alargado para 1 px, e `grab` recusado sem serial de input;
- **cursores com parser XCursor próprio** (`wayland_xcursor.dart`): magic
  `Xcur`, TOC, chunks de imagem, hotspot e delay, pré-multiplicando ARGB→BGRA
  no parse e devolvendo `null` em vez de lançar num arquivo corrompido. O tema
  é resolvido por `XCURSOR_PATH`/`XCURSOR_THEME`/`XCURSOR_SIZE` e pelos
  diretórios XDG, **e a cadeia de herança do `index.theme` não é lida**.
  Cursores animados tocam todos os quadros;
- **clipboard** por `wl_data_device` (texto apenas, quatro tipos MIME, com
  curto-circuito quando somos donos da seleção para não travar o isolate);
- **key repeat** como máquina de estados pura com relógio injetado
  (`repeat_info`, rate 0 desliga, uma tecla por vez, burst máximo 8);
- **drag-and-drop nos dois papéis**, com versão 3 gateada;
- **`text-input-v3`** com a ordem de aplicação obrigatória do protocolo e o
  gate do `done` por contagem de commits;
- **xdg-decoration** negociada — e nada desenha decoração própria se o
  compositor recusar.

**Não existe, e é o que decide se este backend serve:** GPU de qualquer espécie
(sem EGL, sem `linux-dmabuf`, sem Vulkan), touch, escala fracionária, seleção
primária, ícone de arraste, ação `link`, movimento/redimensionamento
interativo, `set_maximized`/`set_fullscreen`/`set_minimized`, posição de
janela, e CSD. Ver §16.14 e §68.

**Nenhuma linha deste backend jamais falou com um compositor real.** As 14
suítes (6.709 linhas) rodam contra um compositor **falso em memória** que
decodifica as mensagens do cliente com o wire de verdade e sintetiza eventos de
volta — o que é um bom teste, e não é a mesma coisa. A camada FFI
(`sendmsg`/`recvmsg`/`SCM_RIGHTS`/`memfd`) **não tem cobertura automatizada
nenhuma**. Também não existe `tool/wayland_backend_smoke.dart`, que X11 e macOS
têm.

## 16.1 Protocolo em Dart — gerador previsto, transcrição feita

**Previsto:** as funções inline geradas em C não fazem parte da ABI de
`libwayland-client`, então o projeto geraria seus próprios stubs Dart a partir
dos XMLs, com wrappers de `wl_proxy` e marshalling por APIs não variádicas.

```text
tools/wayland_codegen/          <- NÃO existe
├── bin/wayland_codegen.dart
├── lib/src/xml_parser.dart
├── lib/src/model.dart
├── lib/src/dart_emitter.dart
└── test/
```

**Feito:** nada disso. Como o backend não carrega `libwayland`, não há
`wl_proxy` para envolver, e a decisão foi **transcrever à mão** os opcodes,
eventos, enums e versões de `wayland.xml` e `xdg-shell.xml` para 513 linhas de
constantes em `wayland_protocol.dart`. Não há XML no repositório e não há
gerador em `tool/`.

Interfaces cobertas: `wl_display`, `wl_registry`, `wl_callback`,
`wl_compositor`, `wl_shm`, `wl_shm_pool`, `wl_buffer`, `wl_surface`, `wl_seat`,
`wl_pointer`, `wl_keyboard`, `wl_output`, `wl_data_device_manager`/`device`/
`source`/`offer`, `xdg_wm_base`, `xdg_surface`, `xdg_toplevel`,
`xdg_positioner`, `xdg_popup`, `zxdg_decoration_manager_v1`,
`zwp_text_input_manager_v3`/`zwp_text_input_v3`.

Versões de bind, deliberadamente conservadoras: `wl_compositor` 4, `wl_shm` 1,
`wl_seat` 5, `wl_output` 2, `xdg_wm_base` **1**, `wl_data_device_manager` 1 (3
para DnD). Consequência do `xdg_wm_base` 1: `configure_bounds` e
`wm_capabilities` estão declarados e **nunca chegam**.

**O gerador continua valendo a pena** — a transcrição escala mal e cada
protocolo novo é trabalho manual auditável linha a linha —, mas ele deixou de
ser pré-requisito, e o roteiro não deve mais afirmar que é.

## 16.2 Protocolos mínimos

### Core

- `wl_display`;
- `wl_registry`;
- `wl_compositor`;
- `wl_surface`;
- `wl_shm`;
- `wl_shm_pool`;
- `wl_buffer`;
- `wl_seat`;
- `wl_pointer`;
- `wl_keyboard`;
- `wl_touch`;
- `wl_output`;
- `wl_data_device_manager`.

### XDG shell

- `xdg_wm_base`;
- `xdg_surface`;
- `xdg_toplevel`;
- `xdg_popup`;
- positioner;
- configure/ack;
- ping/pong.

### Extensões importantes

- xdg-decoration;
- xdg-activation;
- fractional-scale;
- viewporter;
- presentation-time;
- cursor-shape;
- relative-pointer;
- pointer-constraints;
- text-input-v3;
- primary-selection;
- idle-inhibit;
- tablet-v2;
- linux-dmabuf — posterior.

## 16.3 Regras fundamentais do backend

- não desenhar antes do primeiro configure válido;
- sempre responder ping;
- confirmar configure;
- respeitar serials;
- commits são transacionais;
- damage em coordenadas corretas;
- buffers só podem ser reutilizados após release;
- escala e viewport precisam ser consistentes;
- popup depende de serial/posição;
- cliente não escolhe posição absoluta de toplevel;
- clipboard e drag dependem de serial de input;
- round trips devem ser minimizados.

## 16.4 Event loop Wayland

**Corrigido em 2026-08-23.** A dança de `prepare_read`/`cancel_read` abaixo
existe porque `libwayland` compartilha uma fila entre threads e precisa
anunciar a intenção de ler antes de dormir. **Este backend não a usa**: sem
`libwayland` não há fila compartilhada, e o loop é o simples e correto —
`poll` sobre o fd do socket mais o fd do self-pipe de wake, `recvmsg` quando
legível, decodificação pelo `WaylandWireDecoder`, despacho, fila Dart, e render
quando o `wl_surface.frame` permitir.

O fluxo original fica registrado como **o que seria necessário se um dia o
projeto voltar a `libwayland`**:

1. `dispatch_pending`;
2. tentar `prepare_read`;
3. se falhar, drenar pendentes e tentar novamente;
4. flush de requests;
5. aguardar FD + wakeup + timers;
6. se FD legível, `read_events`;
7. senão `cancel_read`;
8. `dispatch_pending`;
9. processar fila Dart;
10. renderizar quando frame callback permitir.

Os testes de máquina de estados existem, contra um compositor falso em memória.

## 16.5 Janela e frame callbacks

- criar `wl_surface`;
- obter `xdg_surface`;
- obter `xdg_toplevel`;
- configurar título/app-id;
- commit inicial vazio;
- aguardar configure;
- `ack_configure`;
- alocar superfície;
- desenhar;
- attach;
- damage;
- solicitar frame callback;
- commit;
- só agendar próximo frame conforme callback, salvo input urgente.

## 16.6 Backend CPU `wl_shm`

- escolher formato ARGB8888/XRGB8888;
- criar arquivo/memfd;
- `ftruncate`;
- `mmap`;
- `wl_shm_pool`;
- múltiplos buffers;
- listener de release;
- buffer state: free/drawing/submitted/released;
- damage parcial;
- resize com geração;
- liberar geração antiga após todos os buffers retornarem.

## 16.7 Teclado e input

**Corrigido em 2026-08-23: não há `xkbcommon`.** O keymap chega por FD, é
mapeado `MAP_PRIVATE`, copiado, e **parseado em Dart** — `wayland_keymap.dart`
lê o formato *texto* do keymap xkb v1, extraindo `xkb_keycodes` e
`xkb_symbols` por balanceamento de chaves e expressões regulares.

O subconjunto é declarado, e é pequeno o bastante para importar:

- **primeiro grupo apenas**, **dois níveis de shift apenas** — sem AltGr, sem
  nível 3, sem troca de layout;
- sem `types`, sem `compat`, sem ações;
- **as posições dos bits de modificador são assumidas** como as convencionais
  (Shift=0, Lock=1, Control=2, Mod1=3, Mod4=6) em vez de lidas do keymap;
- CapsLock só maiúsculiza letras;
- `usFallback()` quando nenhum keymap utilizável chega; o offset evdev→xkb de 8
  está em `evdevToXkbKeycodeOffset`.

O resto da lista original está feito, com uma exceção nomeada:

- [x] keymap recebido por FD;
- [x] modifiers;
- [x] repeat info e repeat timer (máquina de estados pura, relógio injetado);
- [x] pointer enter/leave/motion/button/axis;
- [x] serials registrados;
- [x] cursor surface;
- [ ] **touch frames — `wl_touch` nunca é vinculado**;
- [ ] axis source/discrete/value120 e high-resolution scroll — não verificado;
- [ ] tablet protocol.

## 16.8 IME

Priorizar `text-input-v3`:

- enable/disable;
- surrounding text;
- cursor rectangle;
- content type;
- preedit;
- commit;
- delete surrounding;
- done serial.

Manter fallback por teclado/compose quando compositor não oferece protocolo.

## 16.9 Clipboard e drag-and-drop

- data source;
- offers;
- MIME negotiation;
- pipes/FDs;
- leitura assíncrona;
- escrita assíncrona;
- cancelamento;
- actions;
- enter/motion/drop/leave;
- serials;
- limites de tamanho;
- não bloquear UI em I/O.

## 16.10 Scaling

Suportar:

- `wl_output.scale`;
- buffer scale inteiro;
- fractional scale;
- viewporter;
- múltiplos outputs;
- enter/leave;
- escolha de escala;
- redimensionamento de target;
- preservação de tamanho lógico.

## 16.10.1 Estado do scaling em 2026-08-23

Feito: `wl_output.scale` é lido e vira `bufferScale` inteiro, aplicado por
`set_buffer_scale` quando o compositor é v≥3, e o damage usa `damage_buffer`
em v≥4 ou `damage` escalado abaixo disso.

Não feito, e cada um tem consequência visível: **escala fracionária**
(`wp_fractional_scale_v1`) e **viewporter** não existem; a escala é a **maior**
entre os outputs, e não por superfície; `wl_surface.leave` é ignorado (só
`enter` é tratado); e `wl_registry.global_remove` de um output **não** retira a
escala daquele output da conta.

## 16.11 OpenGL/EGL no Wayland

- EGL display de Wayland;
- config;
- `wl_egl_window` pode exigir biblioteca auxiliar. Como o projeto não permite wrapper próprio, verificar se `libwayland-egl` fornece ABI utilizável diretamente;
- criar/resize window EGL;
- surface;
- context;
- swap;
- frame callback;
- teardown.

Se uma função só existe como helper não exportado, documentar e escolher Vulkan ou CPU até haver solução Dart direta.

## 16.12 Vulkan no Wayland

**Estado em 2026-08-23: nenhum dos dois caminhos existe.** Não há EGL nem
Vulkan neste backend, e a única superfície que uma janela Wayland expõe é a de
`wl_shm`. O lado do Vulkan **tem** a plumbing genérica
(`VK_KHR_wayland_surface` em `vulkan_wsi_platform.dart`), e ela não pode ser
usada daqui por um motivo estrutural, não por falta de tempo:
`VkWaylandSurfaceCreateInfoKHR` exige um `wl_display*`, e um backend que
deliberadamente não carrega `libwayland` **não tem esse ponteiro para dar**.

Fechar isto é uma decisão de arquitetura, não uma tarefa: ou o backend passa a
abrir `libwayland-client` só para obter o display (perdendo a pureza que é o
ponto dele), ou o caminho GPU no Wayland espera uma rota que aceite o fd do
socket.

- `VK_KHR_wayland_surface`;
- criar surface;
- verificar suporte de present;
- swapchain;
- image count;
- format/color space;
- present mode;
- resize/configure;
- out-of-date/suboptimal;
- frame callback/latência;
- fallback para CPU.

## 16.13 Portais

Em Wayland e ambientes sandboxed, diálogos e integração deverão preferir xdg-desktop-portal:

- file chooser;
- open URI;
- print;
- notification;
- settings;
- inhibit;
- screenshot quando permitido.

Criar interface comum e backend D-Bus. A primeira versão pode usar FFI para GIO/D-Bus, desde que não haja shim próprio. Uma implementação Dart do protocolo D-Bus pode ser avaliada separadamente.

## 16.14 Critérios de conclusão Wayland

Revisto em 2026-08-23 contra `lib/src/backends/wayland/`.

- [–] ~~gerador XML~~ — **substituído** por transcrição manual, §16.1. Continua desejável e deixou de ser pré-requisito;
- [x] xdg-shell (configure/ack em duas fases, ping/pong, estados, min/max, popups com `xdg_positioner`, xdg-decoration negociada);
- [x] `wl_shm` (swapchain de até 3 buffers, `memfd_create` + `mmap`, `wl_buffer.release`, destruição adiada de buffer ocupado);
- [x] frame callback (coalesce com união de damage e contador de frames engolidos);
- [~] **teclado — sem `xkbcommon`**: parser próprio do keymap texto v1, primeiro grupo e dois níveis, bits de modificador assumidos. Repeat do lado do cliente. Teclas mortas pela tabela Compose do X11, e só quando não há IME (§16.7);
- [~] pointer sim; **touch não** — `wl_touch` nunca é vinculado;
- [x] clipboard (`wl_data_device`, **texto apenas**; **sem seleção primária**);
- [~] drag-and-drop nos dois papéis; **sem ícone de arraste** (`TODO(wayland)` no código) e **sem ação `link`**;
- [x] text-input-v3 (enable/disable, surrounding text, content type, cursor rectangle, commit com contagem de serial; preedit/commit/delete_surrounding aplicados na ordem do protocolo, com o `done` atrasado descartando só a deleção. **Sem cláusulas de pré-edição** — o v3 removeu `preedit_styling` — e **sem fallback para v1/v2**);
- [~] scaling **inteiro** sim, **fracionário não** (§16.10.1);
- [ ] **EGL ou Vulkan — nenhum dos dois** (§16.12);
- [ ] portais;
- [ ] **GNOME/KDE/wlroots — nunca executado contra compositor real algum**;
- [~] protocolo sem deadlock — provado contra o compositor falso, incluindo o curto-circuito de clipboard que evitaria travar o isolate;
- [x] buffers sem use-after-release — o release limpa `busy`, a destruição é adiada, e a exaustão do swapchain reusa um buffer ocupado **contando** em `busyReuseCount` em vez de em silêncio;
- [ ] **CSD** (novo item): quando o compositor recusa decoração de servidor — o caso do GNOME — **ninguém desenha uma barra de título**. `hasServerSideDecorations` não tem um único consumidor em `lib/`.

---

# 17. GTK como backend opcional de integração

GTK não deverá desenhar os widgets principais. Seu papel:

- bootstrap alternativo;
- integração com GLib;
- file picker quando portal não estiver disponível;
- tema do desktop;
- clipboard/drag fallback;
- IME;
- tray/status quando aplicável;
- hospedagem opcional de controle nativo;
- comparação de comportamento.

## 17.1 Motivo para não basear a UI inteira em GTK

- requisito de widgets em Dart;
- diferenças visuais entre plataformas;
- GTK não é padrão em todo Linux;
- acoplamento a main loop;
- distribuição de bibliotecas;
- dificultaria renderer próprio;
- impediria paridade com Windows/macOS.

## 17.2 Integração do GLib main loop

Duas estratégias:

1. GLib como loop mestre e Dart processado por sources;
2. dispatcher Dart integra `GMainContext` por iterações não bloqueantes.

Escolher por protótipo e benchmark. Requisitos:

- GTK na main thread;
- callbacks seguros;
- wakeup;
- timers;
- file descriptors;
- loops modais;
- sem busy loop;
- sem starvation de input.

## 17.3 Binding GObject/GTK

- gerar de headers/GIR;
- wrappers de ownership;
- signals;
- properties;
- boxed types;
- `GError`;
- `GVariant`;
- callbacks;
- UTF-8;
- version probing GTK 4;
- não suportar GTK 3 no núcleo novo salvo necessidade comprovada.

---

# 18. OpenGL

OpenGL será um backend portátil, mas não a única abstração gráfica.

## 18.1 Loader

Resolver funções por:

- `opengl32.dll` + `wglGetProcAddress`;
- `libGL`/EGL;
- framework OpenGL no macOS apenas como legado, não como alvo principal.

Gerar dispatch table por contexto.

## 18.2 Nível inicial

Escolher um subset moderno:

- buffers;
- vertex arrays;
- textures;
- framebuffers;
- shaders;
- blend;
- scissor;
- stencil;
- instancing;
- sync;
- debug output quando disponível.

Evitar fixed-function.

## 18.3 Renderer 2D OpenGL

Pipeline:

- tessellation/path raster CPU inicialmente;
- upload de vértices;
- quads instanciados;
- atlas de glifos;
- atlas de imagens pequenas;
- clipping por scissor/stencil;
- layers em FBO;
- compositing shaders;
- batching por pipeline/texture/blend;
- ring buffers;
- partial redraw quando viável.

## 18.4 Shaders

- fontes GLSL versionadas;
- reflexão gerada;
- validação offline;
- testes de compilação;
- fallback shader;
- cache por driver;
- diagnóstico com source map.

---

# 19. Vulkan

Vulkan deve entrar depois de:

- DisplayList estável;
- renderer CPU estável;
- um backend GPU funcional;
- abstração de recursos comprovada;
- testes de device-loss e resize.

## 19.1 Não criar uma abstração “Vulkan disfarçado”

A API comum deve representar necessidades da UI, não todos os objetos Vulkan. O backend Vulkan gerencia:

- instance;
- extensions;
- validation;
- physical device;
- logical device;
- queues;
- allocator;
- command pools;
- descriptor pools;
- pipelines;
- shader modules;
- swapchain;
- synchronization;
- caches.

## 19.2 Fases

1. bindings e loader;
2. instance e diagnóstico;
3. surface por plataforma;
4. device/queue;
5. swapchain;
6. clear/present;
7. triângulo;
8. quads;
9. textures;
10. glyph atlas;
11. clips;
12. layers;
13. damage/incremental present;
14. device loss;
15. pipeline cache;
16. multi-window.

## 19.3 Gerenciamento de memória

Implementar allocator interno específico para UI:

- heaps;
- memory types;
- blocks;
- suballocation;
- staging;
- upload ring;
- readback;
- budget;
- eviction;
- deferred destruction por fence;
- métricas.

Não portar VMA em C; estudar o algoritmo e implementar o subset necessário em Dart.

## 19.4 Critérios

Revisto em 2026-08-23 contra `lib/src/rendering/gpu/vulkan/`.

- [ ] **validação sem erros — não provado, e a razão é honesta**: os testes
  abrem a sessão pedindo `VK_LAYER_KHRONOS_validation` e exigem que ela não
  reclame, mas **a layer não está instalada nesta máquina** — há o ICD da Intel
  e não há SDK do LunarG, e `vkEnumerateInstanceLayerProperties` devolve nada.
  O que aqueles testes provaram aqui foi que os pipelines desenham os pixels
  certos, **não** que um validador os inspecionou. A distinção é impressa, não
  escondida, e `VulkanInstance.validationEnabled` é legível;
- [ ] nenhum objeto destruído antes da fence — não verificado;
- [ ] resize contínuo — não verificado;
- [x] swapchain out-of-date: recriação com `oldSwapchain` em
  `VK_ERROR_OUT_OF_DATE_KHR` e `VK_SUBOPTIMAL_KHR`, com semáforo de
  render-finished por imagem;
- [ ] múltiplas janelas — não verificado;
- [ ] fallback;
- [ ] benchmark contra OpenGL;
- [ ] ausência de stutter após cache aquecido.

### Estado auditado em 2026-08-23

- **SPIR-V é emitido em Dart**, e é um codificador binário de verdade —
  `vulkan_spirv.dart` tem magic, versão, opcodes nomeados, `SpirvBuilder` com
  `Uint32List assemble()` e `SpirvFunction`. Quatro entry points: vértice,
  fragmento (um módulo por modo, para não precisar de `OpSelectionMerge`), e o
  par vértice/fragmento de sparse. O arquivo declara o limite de escopo: **não
  é um compilador de GLSL e não deve virar um**;
- **swapchain e WSI existem e estão em voo**: `VulkanSurfaceConfiguration`,
  `VulkanPresentPolicy` (`fifo`, `lowLatency` por MAILBOX com queda para FIFO),
  `vkAcquireNextImageKHR`, `vkQueuePresentKHR`, e create-infos escritas à mão
  para Win32, Xlib, XCB e Wayland. `VulkanWindowTarget` está completo, e
  `VulkanOffscreenTarget` é o gêmeo — **não é offscreen-only**;
- **~~o que trava: dois arquivos de teste não compilam~~** — corrigido:
  `vulkan_window_test.dart` e `zz_smoke_test.dart` compilam e passam
  (19 casos em 26/08/2026), incluindo apresentação numa janela Win32 real,
  `resize` e comparação de pixels contra a CPU;
- **no seletor desde 26/08/2026, como experimental**: o Windows registra
  `vulkan` depois de D3D11/GL/D2D/D3D12, com probe próprio que exige
  `VK_KHR_win32_surface` (o probe do backend cria uma instância *sem* WSI e
  responderia "sim" numa máquina onde `vkCreateWin32SurfaceKHR` não existe).
  `experimental: true` porque este alvo **não desenha texto** — sem atlas de
  glifos, o primeiro `drawGlyphRun` é recusado pelo nome —, então ele só é
  alcançado por quem o pede com `allowExperimentalBackends`;
- `vulkan_wsi_platform.dart` passa o handle nativo como `IntPtr` porque
  `test/architecture/layering_test.dart` proíbe `HWND`/`Display*` fora de
  `lib/src/backends` — e diz, por escrito, que o preço disso é **não conseguir
  validar um handle**;
- **abordagem D não tem rota aqui**: este backend não constrói pipeline de
  compute, e o recorder recusa D por nome em vez de oferecer e descartar depois.

---

# 20. Backend macOS — Objective-C Runtime, AppKit e Core Foundation

O macOS é o ponto mais desafiador da exigência sem wrapper porque AppKit é Objective-C e espera delegates, subclasses e execução na main thread.

A estratégia é chamar Objective-C diretamente por FFI e registrar classes dinamicamente.

## 20.1 Submódulos

```text
dart_ui_backend_macos/
├── macos_platform.dart
├── macos_application.dart
├── macos_dispatcher.dart
├── macos_window.dart
├── macos_view.dart
├── macos_class_registry.dart
├── macos_events.dart
├── macos_keyboard.dart
├── macos_text_input.dart
├── macos_clipboard.dart
├── macos_drag_drop.dart
├── macos_screens.dart
├── macos_cursor.dart
├── macos_menu.dart
├── macos_dialogs.dart
├── macos_accessibility.dart
├── macos_autorelease.dart
└── macos_diagnostics.dart
```

## 20.2 Bootstrap

1. verificar execução na main thread;
2. carregar Objective-C Runtime, Foundation, AppKit, QuartzCore e Metal;
3. criar autorelease pool;
4. obter `NSApplication.sharedApplication`;
5. configurar activation policy;
6. registrar classe delegate;
7. registrar classe customizada de view;
8. criar menu mínimo;
9. criar `NSWindow`;
10. criar view;
11. instalar content view;
12. mostrar e ativar;
13. executar loop;
14. liberar recursos.

### Restrição medida no POC-03 (risco R02)

O passo 1 não é formalidade: **um binário gerado por `dart compile exe` reprova
nessa verificação**. Medido no CI macOS (macos-14 arm64, Dart 3.6.0):

```
[AppKit] pthread_main_np() = 0
[AppKit] sharedApp pointer: 5408589776
*** NSInternalInconsistencyException:
    'NSWindow should only be instantiated on the main thread!'  -> Abort trap: 6
```

A VM do Dart não entrega a main thread do processo ao código Dart — "main
isolate" e "main thread do processo" são coisas diferentes. Consequências:

- `objc_getClass`, `sel_registerName`, `objc_msgSend` e até
  `[NSApplication sharedApplication]` funcionam fora da main thread;
- `NSWindow` aborta o processo;
- passar o trabalho para `dispatch_sync_f(dispatch_get_main_queue(), ...)` **não
  resolve e trava para sempre**: nenhum `NSApplicationMain`, `dispatch_main` ou
  `CFRunLoop` está drenando a main queue. E, mesmo que estivesse, um
  `NativeCallable.isolateLocal` aborta ao ser invocado por outra thread que não
  a do isolate que o criou;
- `dispatch_async_f` e `NativeCallable.listener` também não servem: o primeiro só
  remove a espera, o segundo devolve o callback para a thread do Dart.

Nenhum modo de execução muda isso: JIT (`dart run`), `dartaotruntime` e
`dart compile exe` foram medidos e os três dão `pthread_main_np() = 0`.

### Rotas abertas (medidas, não teóricas)

O spike completo está em
[SPIKE_MACOS_MAIN_THREAD.md](SPIKE_MACOS_MAIN_THREAD.md). Duas rotas **100%
Dart** — sem fonte nativa, sem shellcode, sem entitlement — foram confirmadas em
CI:

1. **Sequestro da main thread por sinal.** Um sinal é entregue *na thread alvo*:
   instalando o endereço da própria `CFRunLoopRun` como handler de `SIGUSR2` e
   mandando `pthread_kill` na main thread, ela entra num `CFRunLoop` e passa a
   drenar a main queue. A partir daí a chamada restrita vai empacotada como
   `NSInvocation` por `performSelectorOnMainThread:` — **uma `NSWindow` real já
   foi criada assim**. O runtime continuou ativo, mas `[NSApp run]`, pumps e
   shutdown ainda produzem traps/bloqueios; esta rota é laboratório, não default.
2. **WindowServer direto via SkyLight/CGS.** `SLSMainConnectionID()` responde
   fora da main thread, sem AppKit e sem regra de thread. O CI já confirmou
   janela, pixels e input dirigido ao processo (`[10, 11, 5]`) pela Mach port.
   É tecnicamente completo no spike, mas privado e ainda sem matriz de robustez.

A alternativa conservadora continua válida e é hoje a recomendada por robustez:
um **host nativo mínimo** Objective-C como `main()` real, que inicializa o
AppKit e conversa com um **processo Dart worker**. O componente nativo resolve
ownership e lifecycle; a política de UI continua em Dart. O host está em
`poc/poc_20_macos_three_backends/native/minimal_appkit_host.m`.

O "ou hospeda a VM Dart" saiu dessa frase por medição, não por preferência: o
SDK de release não distribui `libdart` linkável, então um `main()` nativo que
referencia `Dart_Initialize` não linka. Hospedar a VM exige compilar o SDK do
código-fonte. E o custo que isso evitaria é pequeno — a fronteira de processo
mede 22–59 µs, ~0,2% de um frame a 60 Hz, com `IOSurface` levando os frames em
66 µs a 480×320 e 130 µs em 4K. Números e condições para reabrir em
[logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md](logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md).

A arquitetura, seleção e critérios comparáveis das três rotas estão em
[MACOS_TRES_BACKENDS.md](MACOS_TRES_BACKENDS.md). Os três backends passam a
mesma suíte de conformidade no CI — janela, framebuffer de CPU, testemunha
externa de pixels, input pela rota real e teardown sem `_exit`
([medições](logs/CONFORMANCE_TRES_BACKENDS_2026-08-08.md)). A decisão do
default depende agora de compatibilidade multiversão e da matriz de robustez
restante, não mais de input nem do spike embedder-vs-IPC.

## 20.3 Geração de bindings Objective-C

`ffigen` pode gerar bindings de headers Objective-C, mas o projeto precisa de uma camada estável própria:

- tipos Foundation comuns;
- strings;
- arrays;
- dictionaries;
- numbers;
- data;
- URLs;
- errors;
- selectors;
- classes;
- protocolos;
- methods;
- blocks.

Não expor classes geradas diretamente ao core.

## 20.4 Registro dinâmico de classes

Para receber eventos e delegates:

- `objc_allocateClassPair`;
- `class_addIvar` se necessário;
- `class_addMethod`;
- `objc_registerClassPair`;
- criar instância;
- associar token Dart;
- IMP aponta para callback FFI;
- no `dealloc`, remover token e chamar super.

Classes necessárias:

- application delegate;
- window delegate;
- custom `NSView`;
- accessibility element/view;
- text input client;
- drag destination/source;
- display link callback bridge quando aplicável.

## 20.5 `objc_msgSend`

Não criar uma única assinatura dinâmica universal. Criar wrappers tipados por forma de chamada:

- retorna ponteiro;
- retorna void;
- retorna bool/int;
- retorna double;
- retorna `NSRect`;
- recebe ponteiros;
- recebe structs.

Em Apple Silicon e x64, regras de retorno de struct podem diferir. Gerar e testar variantes.

## 20.6 Ownership

Política:

- métodos `alloc`, `new`, `copy`, `mutableCopy`: owned;
- demais retornos: normalmente autoreleased/borrowed;
- `retain/release` explícitos onde necessário;
- autorelease pool por frame/iteração;
- `CFTypeRef` com `CFRetain/CFRelease`;
- não misturar ownership CF/ObjC sem regra;
- debug retain tracking opcional.

## 20.7 NSWindow e NSView

Recursos:

- título;
- style mask;
- resize;
- min/max;
- fullscreen;
- miniaturize;
- zoom;
- focus/key window;
- backing scale;
- occlusion;
- transparent titlebar;
- custom chrome;
- dark/light appearance;
- multiple windows;
- tabs apenas posterior.

A view customizada:

- aceita first responder;
- recebe mouse;
- recebe keyboard;
- suporta tracking areas;
- fornece layer;
- invalida regiões;
- converte coordenadas;
- informa accessibility;
- implementa text input client.

## 20.8 Event loop macOS

AppKit deve governar a main thread. Integrar o scheduler Dart por:

- `CFRunLoopSource`;
- timer;
- wakeup;
- dispatch na main queue quando necessário;
- processamento limitado de tarefas;
- frame scheduling.

Evitar polling agressivo.

Loops aninhados aparecem em:

- file dialogs;
- menus;
- drag-and-drop;
- sheets;
- modal sessions.

Testar reentrância.

## 20.9 Input macOS

### Mouse/trackpad

- down/up/moved/dragged;
- entered/exited;
- scroll com precise deltas;
- momentum;
- phases;
- pressure;
- tablet events;
- modifier changes;
- cursor update;
- coordinate conversion.

### Teclado

- keyDown/keyUp;
- flagsChanged;
- keyCode físico;
- characters;
- charactersIgnoringModifiers;
- repeat;
- system shortcuts;
- Command versus Control;
- dead keys;
- layout.

Não interceptar atalhos reservados do sistema incorretamente.

## 20.10 Texto e IME

Implementar protocolo equivalente a `NSTextInputClient`:

- marked text;
- selected range;
- replacement range;
- attributed substring;
- first rect for character range;
- character index for point;
- insert text;
- unmark text;
- valid attributes.

Esse componente deve mapear diretamente para o `TextInputClient` comum.

Testar:

- dead keys;
- acentos;
- CJK;
- emoji picker;
- dictation quando possível;
- seleção;
- serviços de texto.

## 20.11 Clipboard e drag-and-drop

`NSPasteboard`:

- texto;
- HTML/RTF opcional;
- PNG/TIFF;
- URLs;
- arquivos;
- tipos customizados;
- promises posterior.

Drag:

- register dragged types;
- validate;
- enter/update/exit/perform;
- source operations;
- drag image;
- file promises posterior.

## 20.12 Menus

macOS espera menu de aplicação. Fornecer:

- application menu;
- About;
- Services;
- Hide;
- Quit;
- Edit com Undo/Cut/Copy/Paste/Select All;
- Window;
- Help.

O framework poderá gerar menus nativos a partir de um modelo Dart. Menus desenhados em Dart podem existir para contexto interno, mas o menu global do macOS deve respeitar convenções.

## 20.13 Core Graphics CPU

Backend de bootstrap:

- bitmap context;
- buffer BGRA/RGBA premultiplicado;
- `dart_graphics` desenha;
- criar `CGImage`;
- apresentar na view;
- dirty rect;
- double buffering;
- scale Retina.

Alternativa: view layer-backed com upload de bitmap.

## 20.14 Acessibilidade macOS

Mapear árvore semântica para atributos/ações:

- role;
- subrole;
- title;
- value;
- help;
- enabled;
- focused;
- children;
- parent;
- position;
- size;
- selected;
- actions;
- text ranges.

Emitir notificações:

- focus changed;
- value changed;
- layout changed;
- selected children changed;
- live region quando aplicável.

Validar com VoiceOver e Accessibility Inspector.

## 20.15 Critérios AppKit

- [ ] app bundle;
- [ ] NSApplication;
- [ ] janela;
- [ ] custom NSView;
- [ ] CPU;
- [ ] Retina;
- [ ] mouse/trackpad;
- [ ] teclado;
- [ ] IME;
- [ ] clipboard;
- [ ] drag;
- [ ] menus;
- [ ] file dialogs;
- [ ] acessibilidade;
- [ ] x64;
- [ ] arm64;
- [ ] assinatura/notarização documentadas.

---

# 21. Metal

## 21.1 Estratégia

A view será layer-backed e usará `CAMetalLayer`.

Objetos:

- `MTLDevice`;
- command queue;
- command buffer;
- render command encoder;
- textures;
- buffers;
- samplers;
- pipeline states;
- drawable;
- depth/stencil quando necessário;
- fences/events conforme disponibilidade.

## 21.2 Sequência mínima

1. obter default device;
2. configurar `CAMetalLayer`;
3. pixel format;
4. framebufferOnly;
5. drawable size;
6. command queue;
7. pipeline de clear;
8. next drawable;
9. render pass;
10. encode;
11. present;
12. commit;
13. resize/scale;
14. teardown.

## 21.3 Renderer 2D Metal

- quads instanciados;
- buffers ring;
- textura atlas;
- glyph atlas;
- stencil clips;
- offscreen textures;
- blend premultiplied;
- gradients por shader;
- filters posteriores;
- MSAA opcional;
- resource heaps posteriores.

## 21.4 Shaders Metal

Duas estratégias:

- compilar `.metal` durante build e empacotar `metallib`;
- compilar source em runtime para desenvolvimento.

Produção deve preferir binário pré-compilado por arquitetura/SDK, com fallback diagnosticável.

## 21.5 Agendamento

Usar:

- display link adequado à versão do sistema;
- callback de frame;
- sincronização com main/UI;
- limitar frames em voo;
- não acessar objetos UI AppKit fora da main thread;
- render isolate apenas após protótipo validado.

## 21.6 Critérios Metal

Revisto em 2026-08-23 contra `lib/src/rendering/gpu/metal/` (cinco arquivos).

- [ ] **clear/present — não há apresentação nenhuma**: sem `CAMetalLayer`, sem
  drawable, sem IOSurface no caminho do renderer, sem janela.
  `supportsSurface` só aceita `MemorySurfaceDescriptor`, e a capacidade
  anunciada é `cpuPresentation`, não `gpuPresentation`;
- [ ] resize Retina;
- [~] display list básica — **retângulos sólidos e com alpha**, offscreen, com
  paridade medida contra a CPU em CI Apple Silicon: desvio 0 onde nada mistura,
  1 nível onde mistura;
- [ ] **texto — recusado por nome**: não há atlas de glifos neste caminho;
- [ ] **clips e layers — recusados por nome**: não há atlas de máscara nem
  pilha de layers;
- [ ] múltiplas janelas;
- [ ] perda/indisponibilidade tratada;
- [ ] fallback CPU;
- [~] Intel e Apple Silicon — só arm64 no CI;
- [ ] validação sem erros.

### E a lacuna que o roteiro não tinha como prever

**Não existe MSL para sparse strips.** O layout sparse foi portado para HLSL
(D3D12), SPIR-V (Vulkan) e WGSL/WebGL2, com paridade medida em cada um;
o diretório `metal/` não contém uma linha de sparse — as únicas ocorrências de
"strip" ali são `MtlPrimitiveType.lineStrip` e `.triangleStrip`. É o único
porte de shader que falta, e está registrado como seam explícito no documento
de aceleração vetorial.

---


# 22. Integração de `dart_graphics` e `marlin`

## 22.1 Objetivo

Transformar os componentes gráficos existentes em serviços consumíveis pelo framework sem acoplamento circular.

## 22.2 Contrato gráfico canônico

Criar em `dart_ui_graphics_api`:

```dart
abstract interface class CpuCanvas {
  void save();
  void restore();
  void transform(Matrix4 matrix);
  void clipRect(Rect rect, {ClipOperation operation});
  void clipPath(Path path, {ClipOperation operation});
  void drawColor(Color color, BlendMode mode);
  void drawRect(Rect rect, Paint paint);
  void drawRoundedRect(RoundedRect rect, Paint paint);
  void drawPath(Path path, Paint paint);
  void drawImage(ImageHandle image, Rect src, Rect dst, Paint paint);
  void drawGlyphRun(GlyphRun run, Offset origin, Paint paint);
}
```

## 22.3 Tipos que devem ser compartilhados

- `Color`;
- `PixelFormat`;
- `AlphaType`;
- `ColorSpace`;
- `Point`;
- `Offset`;
- `Size`;
- `Rect`;
- `RoundedRect`;
- `Matrix3/4`;
- `Path`;
- `PathVerb`;
- `FillRule`;
- `StrokeStyle`;
- `Paint`;
- `Gradient`;
- `Image`;
- `GlyphRun`;
- `BlendMode`.

Evitar duplicações entre `dart_ui`, `dart_graphics` e `marlin`.

## 22.4 Processo de estabilização

Para cada tipo existente:

1. localizar todas as versões;
2. comparar semântica;
3. escolher uma representação;
4. escrever testes;
5. criar adapter temporário;
6. migrar consumidores;
7. marcar versão antiga deprecated;
8. remover após convergência.

## 22.5 Rasterizadores plugáveis

```dart
abstract interface class PathRasterizer {
  String get name;
  RasterizerCapabilities get capabilities;

  void rasterize({
    required Path path,
    required Matrix4 transform,
    required FillRule fillRule,
    required ClipRegion clip,
    required CoverageTarget target,
  });
}
```

Implementações:

- Marlin;
- Blend2D-like;
- AGG;
- scanline baseline;
- referência lenta de alta precisão;
- GPU path posterior.

O framework escolhe um padrão, mas benchmark permite comparação.

## 22.6 Regra de corretude

A saída visual deve ser validada antes de escolher por velocidade:

- múltiplos subpaths;
- winding;
- `evenodd`;
- self-intersection;
- curvas degeneradas;
- coordenadas grandes;
- linhas finas;
- clipping;
- transformações;
- alpha;
- comp-ops;
- gradientes;
- strokes;
- joins/caps;
- SVG corpus.

## 22.7 Texto

A tipografia existente deverá ser organizada em:

```text
dart_ui_text/
├── font_data/
├── opentype/
├── shaping/
├── bidi/
├── line_break/
├── segmentation/
├── font_fallback/
├── glyph_cache/
├── raster/
├── layout/
└── editing/
```

Não acoplar o parser de fonte ao renderer CPU. O parser produz outlines/métricas; cada renderer escolhe raster/atlas/path.

---

# 23. Motor de renderização portátil

## 23.1 Pipeline por frame

```text
Mudança de estado/input/timer
  → marca widget/element/render object sujo
  → scheduler agenda frame
  → animações
  → style resolution
  → measure
  → arrange
  → paint
  → DisplayList
  → scene diff
  → damage calculation
  → renderer
  → present
  → semântica/notificações
```

A ordem exata deverá ser documentada e testada. Alterações disparadas durante uma fase serão encaminhadas para fase válida ou próximo frame.

## 23.2 Dirty flags

```dart
enum DirtyFlag {
  style,
  measure,
  arrange,
  paint,
  compositing,
  semantics,
}
```

Propagação:

- mudança de largura preferida → measure;
- mudança apenas de cor → paint;
- mudança de transform → compositing;
- texto → measure, paint, semantics;
- visibility → arrange/paint/semantics;
- opacity → compositing, salvo otimização;
- child add/remove → measure/arrange/paint/semantics.

## 23.3 Damage tracking

Manter:

- bounds anterior;
- bounds atual;
- clip;
- transform;
- opacity;
- layer;
- região suja.

A região final inclui união da área antiga e nova. Usar:

- rect simples no bootstrap;
- lista pequena de rects;
- region merger;
- fallback full redraw se complexidade ultrapassar limiar.

## 23.4 Scene graph

Nós internos:

- transform;
- clip;
- opacity;
- picture/display list;
- texture;
- external surface;
- backdrop/filter posterior;
- platform view posterior.

Cada nó possui:

- ID estável;
- revision;
- bounds;
- children;
- resource references;
- compositing hints.

## 23.5 Retained rendering

Não regenerar tudo sempre. Caches:

- DisplayList por subtree;
- layer por subtree;
- text layout;
- glyph atlas;
- image decode;
- path tessellation;
- gradient LUT;
- stroke expansion;
- shader pipeline;
- platform resources.

Cada cache precisa de:

- chave;
- geração;
- tamanho;
- uso;
- política de eviction;
- métricas;
- invalidação.

## 23.6 Pixel formats

Formato canônico inicial CPU:

- BGRA8888 premultiplied em Windows/macOS quando reduz cópia;
- RGBA8888 ou BGRA conforme surface Linux;
- abstração informa layout;
- conversão só em bordas;
- alpha premultiplicado no pipeline;
- sRGB inicial;
- linear/HDR posterior.

## 23.7 Composição

Blend modes mínimos:

- clear;
- source;
- source-over;
- destination-over;
- source-in/out/atop;
- destination-in/out/atop;
- xor;
- plus;
- multiply;
- screen;
- overlay;
- darken;
- lighten;
- color dodge/burn;
- hard/soft light;
- difference;
- exclusion.

A paridade entre CPU e GPU deverá ser medida.

## 23.8 Clipping

Estratégias:

- scissor para rect alinhado;
- stack de rects;
- stencil para paths;
- alpha mask para clips complexos;
- CPU coverage mask;
- flatten/merge apenas quando seguro.

## 23.9 Layers

Criar layer offscreen quando:

- opacity em subtree;
- complex clip;
- filter;
- saveLayer explícito;
- cache hint;
- backdrop.

Evitar layer desnecessária. Devtools deve mostrar por que cada layer foi criada.

## 23.10 Imagens

Pipeline:

1. bytes;
2. sniff format;
3. decode em isolate;
4. orientação EXIF;
5. color profile;
6. pixel buffer;
7. upload;
8. cache;
9. mip/resize conforme backend;
10. eviction.

Suportar inicialmente PNG, JPEG e WebP com uma política **native-first**:

- Windows: WIC (`windowscodecs.dll`) para PNG/JPEG/WebP disponíveis no SO;
- macOS: ImageIO/CoreGraphics para PNG/JPEG/WebP;
- Linux: TurboJPEG para JPEG quando `libturbojpeg.so` estiver instalada;
- navegador: `createImageBitmap` pela API assíncrona;
- headless, CI, biblioteca ausente ou falha do codec nativo: implementação
  100% Dart (`dart_ui` para PNG e `package:image` para JPEG/WebP).

O resultado de todos os caminhos é `DecodedImage` em RGBA/BGRA
pré-multiplicado, sem expor tipos do SO ou de dependências. A orientação EXIF
é normalizada antes da entrega e limites de bytes, dimensão e pixels são
aplicados antes da alocação da superfície. `preferNative: false` existe para
testes determinísticos e diagnóstico; não é a política normal de produção.

O SVG permanece vetorial: o parser produz `Path`, `fill-rule`, fill/stroke e
transformações consumidos pelo mesmo display list dos demais widgets. Assim,
o backend atual usa máscaras analíticas cacheadas, enquanto tessellation,
stencil-then-cover ou compute raster podem ser adicionados futuramente sem
alterar o widget ou o formato SVG.

## 23.11 Shaders e assets

Estrutura:

```text
shaders/
├── common/
├── hlsl/
├── glsl/
├── spirv/
├── metal/
└── manifests/
```

Manifesto descreve:

- uniforms;
- textures;
- vertex inputs;
- blend;
- variants;
- hash;
- compiler;
- target;
- source provenance.

## 23.12 Device loss

Eventos:

```dart
sealed class RendererEvent {}
final class DeviceLost extends RendererEvent { ... }
final class SurfaceOutOfDate extends RendererEvent { ... }
final class OutOfMemory extends RendererEvent { ... }
```

Recuperação:

1. parar submissions;
2. preservar scene lógica;
3. descartar resources nativos;
4. recriar device/surface;
5. reconstruir recursos a partir de fontes Dart;
6. repintar full;
7. registrar causa e tempo;
8. cair para CPU se falhar repetidamente.

---

## 23.13 Aceleração vetorial — o que mudou de decisão (2026-08-23)

O documento canônico é
[`architecture/ACELERACAO_GPU_VETORIAL.md`](architecture/ACELERACAO_GPU_VETORIAL.md),
e este roteiro **não o duplica**. O que segue é só o que mudou de decisão e que
alguém lendo o roteiro precisa saber para não decidir errado:

1. **A escolha de rasterização deixou de ser por plataforma e passou a ser por
   custo.** `GpuPathStrategySelector.select` decide com um modelo de custo cujo
   principal insumo são **cruzamentos de tile contra área**, com a taxa de
   câmbio medida — `kDefaultSparseCrossingCostInDensePixels = 50`, que já foi
   83. Uma versão anterior decidia por **bytes de upload**, e decidia errado:
   numa GPU de memória compartilhada, upload não é o gargalo;
2. **Os rótulos A–D são de documentação, não de código.** O enum real é
   `GpuPathStrategy`, com seis valores — `analyticPrimitive`, `coverageAtlas`,
   `sparseStrips`, `tessellatedMesh`, `stencilThenCover`, `computeTiles`.
   Quem procurar um `enum Approach { a, b, c, d }` não vai achar;
3. **Sparse strips foram promovidas — no OpenGL, e só ali.**
   `GlSparseStripsPolicy.auto` é o padrão de `GlRenderDevice.adoptContext`, e o
   antigo booleano passou a significar `required`, porque as duas perguntas são
   diferentes: quem *pediu* sparse e não pode tê-lo quer ouvir isso alto; quem
   não pediu nada quer um renderer funcionando. Em **D3D12, WebGPU e WebGL2 a
   flag continua `false`** — lá sparse ainda é opt-in;
4. **A promoção só foi possível depois de trocar o rasterizador.** A primeira
   avaliação reprovou porque as strips re-codificavam a saída do
   `ScanlineFiller` — pagavam a rasterização densa **mais** um passe de
   empacotamento, e não podiam ganhar. `NativeStripRasterizer` (porte de
   `vello_common`, Apache-2.0 OR MIT) rasteriza de fato, e aí a vantagem
   assintótica apareceu. Ele declara três omissões: **sem SIMD** (Dart não
   tem), **sem culling** de geometria fora da tela, e curvas achatadas por
   `Path.flattenTo` em vez da subdivisão por integral de parábola do Vello;
5. **O cache de plano retido existe e é de CPU, de propósito.**
   `VectorPlanCache` guarda o *encode*, com chave por path, transform, clip,
   fill rule e tolerância — e **não retém recurso de GPU**. Ao lado dele,
   `GpuPathRepetitionTracker` fecha um defeito específico: uma rota promovida
   nunca chega ao atlas, então `denseMaskCacheHit` fica falso para sempre e a
   rota "ganha uma comparação contra um custo que ela mesma criou";
6. **O binning de segmentos por tile é de CPU.** `ComputeTileScene` produz
   listas CSR por tile mais um backdrop por tile — dois números, porque nonzero
   e even-odd precisam de backdrops diferentes. O primeiro executor real da
   abordagem D é o do **Direct3D 12**, e o que o compute shader faz lá é
   converter em cobertura uma cena **já binada**, com supersampling em vez de
   área analítica. Não é Vello: não há flattening paralelo, nem prefix scan,
   nem separação coarse/fine;
7. **Nenhum shader é bytecode embarcado.** HLSL é compilado em runtime por
   `d3dcompiler_47.dll`/`D3DCompile` — não por `fxc` na build, e não por DXIL —
   justamente para que o framework continue puro em Dart; SPIR-V é **emitido**
   por `SpirvBuilder`; WGSL e GLSL são texto.

Seams explícitos que continuam abertos, e que o roteiro deve continuar
lembrando: **MSL** (§21.6), **franja analítica no cover** de C, **culling de
geometria**, **gradiente em glifos** na GPU (a CPU pinta glifos com gradiente
nos dois caminhos; o atlas de glifos continua recusando por nome, e o caminho
de contorno da GPU herda essa recusa em vez de divergir dela), e **D no
OpenGL**, que segue como plano e referência de CPU sem executor nativo.

Um seam que **fechou**: texto sob transform rotacionada, inclinada, espelhada
ou de escala não uniforme era recusado por nome nos dois renderizadores e hoje
é desenhado pelos dois, pelo contorno do glifo, com paridade medida de desvio 0
em `test/rendering/gpu/gl_glyph_device_test.dart`. Ver ADR 0007 e a seção 30
acima.

Outro que **fechou, em 26 de agosto de 2026**: B e C não eram alcançáveis de
aplicação nenhuma. `GlRenderDevice.adoptContext` só constrói os dois executores
quando é pedido, e `default_platform_resolver.dart` nunca pedia — rodavam de
teste, da POC e de uso direto do device. Agora o resolver pede, e quem decide é
`RenderPolicy.routes`. O padrão continua sendo **não construir**, e a razão é
medida: numa UI comum, ligar C custa 9% e desenha **zero** draws pelo cover
pass, porque toda camada a partir de 128 px passa a carregar stencil e quatro
amostras; na carga para a qual as rotas existem — path grande, não cacheado,
animando dentro de camada — o mesmo par entrega 1,21× (C) e 1,33× (B e C). As
tabelas estão em `RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md`, seção
“Correção de 26 de agosto de 2026”, que também corrige o nicho que o relatório
atribuía a B e que na prática é tomado pelas strips e pela trava de repetição.

No mesmo movimento, `RenderDiagnosticsMode.counters` deixou de reportar sempre
“0 draws”: `recordDecision` e os contadores de cache do atlas não tinham
chamador nenhum em produção, então `Application.renderDiagnostics` não sabia
dizer qual rota um quadro real havia tomado. Passam a ser alimentados em
`GpuPathPlanningTelemetry.complete` — no executado, não no proposto.

O seam que tinha **aberto por consequência** também fechou: o sink **Direct2D**
tomou a mesma rota, com `FillGeometry` sobre um `ID2D1PathGeometry` por glifo
em vez do `ScanlineFiller`. Como a cobertura embaixo é o rasterizador do
`d2d1.dll`, a paridade dele contra a CPU é uma **tolerância declarada** e não
desvio 0 — 53 níveis por canal no pior caso, sobre no máximo 6,7% da superfície
(`test/backends/win32/d2d/d2d_glyph_transform_test.dart`).

---

# 24. Sistema de widgets

## 24.1 Escolha do modelo

Recomendação: modelo declarativo com três camadas:

- `Widget`: configuração imutável;
- `Element`: identidade, estado e reconciliação;
- `RenderObject`: layout, pintura e hit-test.

Vantagens:

- atualizações eficientes;
- testes;
- composição;
- widgets leves;
- estado preservado;
- separação de layout;
- capacidade de gerar semântica.

Não reproduzir APIs Flutter literalmente. Definir nomenclatura e contratos próprios.

## 24.2 Identidade

Tipos de chave:

- sem chave: identidade por posição/tipo;
- `ValueKey`;
- `ObjectKey`;
- `GlobalKey` somente quando necessário.

Regras:

- global keys são caras;
- detectar duplicatas;
- preservar estado em reordenação;
- ciclo de vida determinístico;
- debug de reconciliação.

## 24.3 Ciclo de vida

`StatefulElement`:

1. create;
2. mount;
3. init state;
4. dependencies changed;
5. build;
6. update;
7. deactivate;
8. reactivate ou unmount;
9. dispose.

Proibir:

- `setState` depois de dispose;
- dependência nativa no build;
- side effects não controlados durante build;
- reentrância de build do mesmo nó.

## 24.4 Build scheduling

- mudanças marcam element dirty;
- dirty list ordenada por profundidade;
- cada element no máximo uma vez por ciclo;
- filhos sujos processados na ordem;
- build pode criar/remover;
- erro isolado produz ErrorWidget em debug;
- limite para loops infinitos;
- stack de diagnóstico.

## 24.5 Estado e reatividade

Oferecer núcleo mínimo:

```dart
final class Signal<T> {
  T get value;
  set value(T value);
  Subscription listen(void Function(T) callback);
}
```

Também:

- `ValueNotifier`;
- `Computed`;
- `Effect` restrito;
- `InheritedValue`/context;
- streams/futures adapters;
- bindings bidirecionais explícitos.

Não tornar todo objeto magicamente observável. Preferir dependências rastreáveis.

## 24.6 Sistema de propriedades

Para controles templated e estilos:

```dart
final class UiProperty<T> {
  final String name;
  final T defaultValue;
  final bool inherits;
  final T Function(Object owner, T value)? coerce;
  final bool Function(T value)? validate;
  final PropertyInvalidation invalidation;
}
```

Precedência:

1. animação;
2. valor local;
3. binding;
4. template;
5. trigger/pseudo-class;
6. style;
7. herdado;
8. default.

Cada mudança informa exatamente quais dirty flags marcar.

## 24.7 Árvores lógica e visual

- árvore lógica representa conteúdo e recursos;
- árvore visual inclui elementos criados por template;
- roteamento de eventos pode usar árvore visual ou lógica conforme evento;
- recursos e DataContext seguem regras explícitas;
- acessibilidade usa semântica, não simplesmente a árvore visual.

## 24.8 Contexto

O contexto fornece:

- tema;
- media query;
- escala;
- locale;
- directionality;
- navigator opcional;
- focus scope;
- shortcuts;
- actions;
- inherited values;
- platform capabilities.

Evitar service locator global.

---

# 25. Layout

## 25.1 Contrato measure/arrange

```dart
abstract class RenderObject {
  Size measure(BoxConstraints constraints);
  void arrange(Rect finalRect);
  void paint(PaintContext context, Offset offset);
  bool hitTest(HitTestResult result, Offset position);
}
```

Separar:

- desired size;
- arranged bounds;
- visual bounds;
- hit-test bounds;
- paint bounds;
- semantic bounds.

## 25.2 Constraints

```dart
final class BoxConstraints {
  final double minWidth;
  final double maxWidth;
  final double minHeight;
  final double maxHeight;
}
```

Regras:

- valores normalizados;
- infinitos permitidos em eixos específicos;
- NaN proibido;
- clamp explícito;
- rounding só na fronteira de pixel;
- layout em logical pixels.

## 25.3 Layouts mínimos

- leaf;
- padding;
- align;
- center;
- constrained box;
- sized box;
- row;
- column;
- flex;
- wrap;
- stack;
- grid;
- scroll viewport;
- sliver/list virtual;
- intrinsic sizing;
- baseline;
- aspect ratio;
- flow/custom layout.

## 25.4 Grid

Suportar:

- fixed;
- auto;
- fraction;
- minmax;
- gaps;
- spans;
- shared size opcional;
- alignment;
- implicit tracks posterior.

Implementar com testes de casos extremos antes de otimizar.

## 25.5 Pixel snapping

Oferecer política:

- none;
- edges;
- text/baseline;
- device-pixel.

O renderer conhece scale. O layout permanece lógico.

## 25.6 Intrinsic measurement

É caro. Regras:

- cache por constraints;
- invalidar corretamente;
- evitar chamadas repetidas;
- devtools alerta layout intrínseco;
- listas virtualizadas não devem depender dele.

## 25.7 Layout cycle detection

Detectar:

- parent/child dependency circular;
- medida infinita inválida;
- mudança de propriedade durante arrange;
- número excessivo de passes.

Emitir árvore reduzida de diagnóstico.

---

# 26. Pintura, hit-test e composição

## 26.1 PaintContext

```dart
final class PaintContext {
  final DisplayListBuilder canvas;
  final DamageRegion damage;
  final double scale;

  void paintChild(RenderObject child, Offset offset);
  void pushClipRect(...);
  void pushTransform(...);
  void pushOpacity(...);
  void pushLayer(...);
}
```

## 26.2 Hit-test

Resultado ordenado do mais profundo para raiz:

```dart
final class HitTestEntry {
  final RenderObject target;
  final Matrix4 transformToLocal;
}
```

Requisitos:

- transformações;
- clips;
- opacity não elimina hit-test automaticamente;
- visibility/hit-test behavior separados;
- pointer-events;
- children em ordem z;
- cache espacial posterior;
- captura de ponteiro.

## 26.3 Bounds

- layout bounds;
- paint bounds;
- transformed bounds;
- clip bounds;
- damage bounds;
- semantic bounds.

Não reutilizar um único `Rect` para todos.

## 26.4 Repaint boundaries

Permitir isolamento:

- subtree repinta independentemente;
- DisplayList cacheada;
- layer opcional;
- métricas de custo;
- não criar automaticamente em todo controle.

---

# 27. Input e eventos

## 27.1 Normalização

Backend produz eventos brutos:

```dart
sealed class RawPlatformInputEvent {}
```

Core converte para:

- pointer;
- wheel;
- key;
- text;
- composition;
- focus;
- drag;
- gesture;
- window.

## 27.2 Roteamento

Fases:

1. preview/capture;
2. target;
3. bubble.

Cada evento:

- timestamp monotônico;
- device;
- modifiers;
- handled;
- original source;
- current target;
- position transformável;
- synthetic flag;
- native sequence/serial opcional.

## 27.3 Pointer

Modelo unificado:

- mouse;
- touch;
- pen;
- eraser;
- unknown.

Dados:

- pointer ID;
- position;
- delta;
- buttons;
- pressure;
- tilt;
- orientation;
- contact size;
- primary;
- synthesized;
- coalesced events.

## 27.4 Captura

- implicit capture opcional;
- explicit capture;
- capture lost;
- validação quando target desmonta;
- captura por ID;
- drag/gesture interage com captura;
- backend nativo informado quando necessário.

## 27.5 Gestures

Arena de reconhecedores:

- tap;
- double tap;
- long press;
- drag;
- pan;
- scale;
- rotate;
- scroll;
- selection.

Reconhecedores competem por sequência e resolvem aceitação. Mouse e touch podem ter políticas diferentes.

## 27.6 Keyboard

Representar:

- `PhysicalKey`;
- `LogicalKey`;
- text;
- modifiers;
- repeat;
- location;
- dead/composing.

Atalhos:

```dart
ShortcutMap → Intent → Action
```

Separar tecla de ação sem codificar Ctrl/Command em todos os widgets.

## 27.7 Focus

- focus node;
- focus scope;
- traversal policy;
- tab order;
- directional navigation;
- focus ring;
- request;
- restore;
- modal trapping;
- accessibility focus distinto;
- janela ativa.

## 27.8 Scroll

- delta em pixels/linhas;
- high precision;
- momentum;
- overscroll;
- nested scrolling;
- scroll chaining;
- scrollbar;
- viewport;
- restoration;
- programmatic animation;
- accessibility actions.

---

# 28. Estilos, temas e templates

## 28.1 Objetivo

Permitir controles reutilizáveis sem codificar aparência no widget.

## 28.2 Seletores

Subset inicial:

- type;
- class;
- id/key opcional;
- ancestor;
- child;
- pseudo-class;
- property state;
- logical combinations limitadas.

Não tentar implementar CSS completo.

## 28.3 Pseudo-classes

- hover;
- pressed;
- focused;
- focus-visible;
- disabled;
- checked;
- selected;
- expanded;
- invalid;
- dragging;
- window-inactive;
- dark/light;
- high-contrast.

## 28.4 Recursos

- resources por aplicação;
- janela;
- subtree;
- tema;
- template;
- busca hierárquica;
- static/dynamic resource;
- cache;
- ciclo detectado;
- fallback.

## 28.5 Templates

Controles expõem propriedades e estados; template cria árvore visual.

Exemplo conceitual:

```dart
ControlTemplate<Button>(
  builder: (context, button) => Border(
    classList: {'button-surface'},
    child: ContentPresenter(content: button.content),
  ),
)
```

## 28.6 Temas

Entregar ao menos:

- base neutral;
- Fluent-like;
- macOS-like opcional;
- high contrast;
- density compact/comfortable;
- dark/light.

O framework não deve depender de copiar assets proprietários.

## 28.7 Animação de estilo

Transições:

- color;
- opacity;
- transform;
- size com cautela;
- border;
- shadow.

Preferir propriedades de composição para animações fluidas.

---

# 29. Controles

## 29.1 Foundation controls

- `ContentControl`;
- `ItemsControl`;
- `TemplatedControl`;
- `Panel`;
- `Decorator`;
- `Presenter`;
- `ScrollViewer`;
- `Popup`;
- `AdornerLayer`;
- `FocusScope`.

## 29.2 Controles básicos

Revisto em 2026-08-23 contra `lib/src/widgets/`. Todos são desenhados pelo
framework — nenhum hospeda controle nativo — e todos estão exportados por
`lib/dart_ui.dart`.

- [x] Text, Icon, Image (mais `Svg`, e os conjuntos `Icons`, `TablerIcons`, `PhosphorIcons`);
- [x] Button, ToggleButton, CheckBox (tri-state), RadioButton, Switch, Slider, Progress (linear e circular, mais `LoadingSpinner`);
- [x] TextField, PasswordField (seleção, caret, undo/redo, clipboard);
- [ ] TextArea — edição multilinha não fechada;
- [x] ComboBox (com overlay flutuante próprio), ListBox virtualizado;
- [x] **TreeView** — virtualizado pelo mesmo `ListVirtualization` do ListBox, com o handshake de carga preguiçosa (`hasChildren` verdadeiro com `children` vazio) e navegação por teclado. **Seleção única apenas**: não há conjunto de seleção nem extensão por Shift/Ctrl;
- [x] **DataGrid** — ~~posterior~~, entregue: virtualização de **linhas**, redimensionamento de coluna por arraste, seleção `none`/`single`/`multiple` com Shift e Ctrl+A. **Sem virtualização de coluna e sem rolagem horizontal** (o excesso é recortado), **sem edição de célula**, e **a ordenação é intenção**: a grade desenha a seta e reporta por `onSortChanged`, e quem ordena os dados é o chamador — ela não sabe se a coluna guarda texto, data ou dinheiro;
- [x] Tabs, Menu, ContextMenu, Toolbar, Tooltip, Dialog, SplitView (o divisor), Expander;
- [x] **Calendar/DatePicker** — ~~posterior~~, entregue. **O DatePicker abre embutido, abaixo do botão, não flutuando**: a máquina de overlay que um dropdown flutuante precisa está no `combo_box.dart` e ainda não foi reaproveitada aqui;
- [x] **NumberBox**;
- [x] **InfoBar / Toast** (`InfoBarSeverity`, `ToastController`, `ToastHost`);
- [x] **Badge, Chip, Avatar, Card**;
- [x] **Docking** — `DockingLayout`, `DockingRow`/`Column`/`Tabs`, tema próprio, e a **faixa de abas recolhidas** (`CollapsedTabStrip`, `CollapsedTab`), que é API pública. **Duas ressalvas**: `Docking.draggable` é declarado e **nunca lido** — não dá para arrastar um painel para redocá-lo, só mover por API —, e a faixa recolhida **empilha caracteres em vez de rotacionar o rótulo**, por uma limitação de renderer que já não existe mais (ver §68);
- [x] Scrollable, ListView, GridView, Scrollbar, Overlay, PopupStack, Navigator/rotas;
- [x] **DropTarget / DragSource** e `DragDropScope`, ligados ao porte de drag-and-drop da §56;
- [ ] **Ribbon — não existe**;
- [ ] **ColorPicker — não existe** como controle geral. O que há é `ColorPaletteBar`, uma faixa de amostras fixa do editor vetorial: sem roda HSV, sem espectro, sem entrada hexadecimal;
- [ ] **MenuBar e StatusBar não existem no framework** — são código de aplicação nos exemplos. `Menu` é menu suspenso, não barra.

Lacunas de comportamento que valem registro, porque cada uma já é bug em algum
toolkit: o caret **não se move corretamente em texto bidirecional** (salta em
texto de direção mista), e um menu mais alto que a tela é **encostado no topo**
sem rolagem, de modo que os itens abaixo da borda ficam inalcançáveis.

## 29.3 Estados de um Button

- normal;
- hover;
- pressed;
- focused;
- focus-visible;
- disabled;
- default;
- cancel;
- pointer capture;
- keyboard activation;
- automation invoke.

## 29.4 Primeiro botão vertical

Critério obrigatório:

- criado por código Dart;
- medido/arranjado;
- desenhado pelo backend CPU;
- texto centralizado;
- hit-test;
- hover;
- press;
- click;
- foco por Tab;
- ativação por Space/Enter;
- acessibilidade role=button;
- sem controle nativo.

## 29.5 Virtualização

Para listas:

- viewport;
- item provider;
- realize/recycle;
- stable keys;
- estimated extent;
- variable extent;
- cache before/after;
- focus preservation;
- selection;
- accessibility de itens não realizados;
- scroll anchor;
- incremental loading.

## 29.6 Popups

Backend comum deve decidir:

- popup dentro da mesma surface;
- janela nativa separada;
- Wayland `xdg_popup`;
- menus;
- tooltip;
- combo dropdown;
- modal overlay.

Contrato precisa considerar:

- placement;
- screen bounds;
- flip/slide;
- DPI;
- owner;
- focus;
- dismissal;
- input grab;
- serial Wayland.

---

# 30. Texto, fontes e edição

## 30.1 Pipeline de texto

```text
String Dart
 → code points
 → grapheme clusters
 → script/language runs
 → bidi
 → font fallback
 → GSUB shaping
 → GPOS positioning
 → glyph runs
 → line breaking
 → justification/alignment
 → decoration
 → raster/atlas/path
```

## 30.2 Parser OpenType

Reusar e completar:

- `head`;
- `maxp`;
- `hhea`;
- `hmtx`;
- `vhea/vmtx` posterior;
- `cmap`;
- `name`;
- `OS/2`;
- `post`;
- `loca`;
- `glyf`;
- `CFF/CFF2`;
- `kern`;
- `GDEF`;
- `GSUB`;
- `GPOS`;
- `BASE`;
- `JSTF` posterior;
- `fvar/gvar/avar`;
- `HVAR/VVAR/MVAR`;
- `COLR/CPAL`;
- `CBDT/CBLC`;
- `sbix`;
- SVG glyphs;
- `STAT`.

## 30.3 Shaping

Fases:

1. Latin básico;
2. ligaturas;
3. kerning;
4. marks;
5. cursive;
6. Arabic;
7. Indic;
8. Southeast Asian;
9. complex scripts;
10. variation features;
11. vertical text posterior.

Usar corpus e comparar com HarfBuzz como oráculo de teste, sem tornar HarfBuzz requisito runtime.

## 30.4 Font discovery

Backends:

- Windows DirectWrite/font registry;
- Linux fontconfig;
- macOS Core Text;
- fontes empacotadas;
- fontes em memória.

A API comum retorna descritores. O shaping continua em Dart.

## 30.5 Fallback

Resolver por:

- family solicitada;
- weight;
- style;
- stretch;
- locale/script;
- coverage;
- emoji preference;
- color glyph;
- user overrides.

Cache por run/script.

## 30.6 Line breaking

Implementar Unicode Line Breaking, considerando:

- graphemes;
- whitespace;
- hyphenation opcional;
- soft hyphen;
- tabs;
- bidi;
- max lines;
- ellipsis;
- word/character wrap;
- justification.

## 30.7 Edição

`TextEditingValue`:

```dart
final class TextEditingValue {
  final String text;
  final TextSelection selection;
  final TextRange composing;
}
```

Motor:

- caret;
- selection;
- word/line movement;
- delete grapheme/word;
- home/end;
- clipboard;
- undo/redo;
- composition;
- scroll caret into view;
- mouse selection;
- double/triple click;
- bidi caret;
- accessibility text ranges.

## 30.8 Segurança

- password não exposto à semântica;
- clipboard policy;
- limite de input;
- evitar quadratic behavior;
- validar fontes;
- parser resistente a offsets inválidos;
- fuzzing de OpenType;
- não confiar em fontes do sistema.

---

# 31. Acessibilidade e semântica

## 31.1 Árvore semântica

```dart
final class SemanticsNode {
  final SemanticsId id;
  final SemanticsRole role;
  final Rect bounds;
  final Matrix4 transform;
  final String? label;
  final String? value;
  final String? hint;
  final Set<SemanticsState> states;
  final Set<SemanticsAction> actions;
  final List<SemanticsNode> children;
}
```

## 31.2 Propriedades

- role;
- name;
- description;
- value;
- range;
- checked;
- selected;
- expanded;
- enabled;
- hidden;
- read-only;
- required;
- invalid;
- multiline;
- password;
- live region;
- heading level;
- relationships;
- position in set;
- set size.

## 31.3 Ações

- focus;
- activate;
- click/invoke;
- increment/decrement;
- set value;
- set selection;
- scroll;
- expand/collapse;
- show context menu;
- dismiss.

## 31.4 Atualização incremental

Gerar diff semântico:

- node added;
- removed;
- reparented;
- property changed;
- focus changed;
- bounds changed;
- text changed.

Adaptadores convertem diff em notificações nativas.

## 31.5 Testes

- snapshot semântico headless;
- navegação;
- foco;
- labels;
- action invocation;
- screen-reader smoke;
- automation tools;
- high contrast;
- reduced motion;
- large text;
- keyboard-only.

Acessibilidade não será uma “fase final”. A árvore semântica entra junto ao primeiro Button.

---

# 32. Animações

## 32.1 Relógio

Usar timestamp monotônico.

Tipos:

- duration;
- curve;
- spring;
- keyframes;
- transition;
- implicit;
- explicit.

## 32.2 Scheduler

Animação pede frame, não cria timer por propriedade.

## 32.3 Compositor

Propriedades elegíveis para animação independente:

- transform;
- opacity;
- clip simples;
- color/filter posterior.

No primeiro release, animações podem ser calculadas no UI isolate. Depois, transferir curvas ao compositor/render isolate.

## 32.4 Acessibilidade

Respeitar reduced motion. Temas podem reduzir/dessativar transições.

---

# 33. Internacionalização

- locales;
- directionality;
- plural;
- number/date formatting por package Dart ou backend;
- font fallback por locale;
- bidi;
- mirrored icons;
- resources;
- runtime locale change;
- IME;
- pseudo-localization;
- strings de sistema;
- atalhos culturalmente adequados.

Não incluir um sistema completo de mensagens no núcleo gráfico; manter integração extensível.

---

# 34. Backend headless

## 34.1 Objetivo

Executar sem janela real:

- build;
- layout;
- paint;
- input sintético;
- semântica;
- animação;
- screenshots;
- golden tests.

## 34.2 Relógio controlado

```dart
final class TestClock {
  Duration now;
  void advance(Duration delta);
}
```

## 34.3 Janela virtual

- size;
- scale;
- visibility;
- focus;
- monitor;
- input queue;
- framebuffer;
- clipboard fake;
- IME fake;
- accessibility recorder.

## 34.4 Importância

O headless deve surgir antes do segundo backend real. Caso contrário, cada bug parecerá bug nativo.

---


# 35. Testes

## 35.1 Pirâmide

### Unitários

- geometria;
- propriedades;
- binding;
- reconciliação;
- layout;
- hit-test;
- eventos;
- styles;
- text;
- parsers;
- máquinas de estado de clipboard;
- protocolo Wayland;
- COM wrappers;
- ownership.

### Headless

- widgets;
- golden;
- semântica;
- animação;
- input replay;
- focus;
- virtualização.

### ABI

- `sizeOf`;
- offsets;
- enums;
- calling conventions;
- callbacks;
- strings;
- structs retornadas;
- vtables;
- Objective-C message signatures.

### Integração por plataforma

- cria/fecha janela;
- múltiplas janelas;
- resize;
- DPI;
- monitor hotplug;
- focus;
- clipboard;
- drag;
- IME;
- renderer;
- accessibility;
- packaging.

### End-to-end

- aplicativo de galeria;
- interações gravadas;
- screenshots;
- automação nativa;
- restart;
- device loss;
- atualização de tema.

## 35.2 Golden tests

Metadados:

```yaml
scene: button_hover
logical_size: 320x120
scale: 1.5
font_set: bundled-test-fonts-v1
color_space: sRGB
renderer: cpu
threshold:
  max_channel_delta: 2
  differing_pixels_percent: 0.05
```

Comparações:

- pixel exact quando possível;
- threshold;
- heatmap;
- perceptual metric;
- bounding box de divergência;
- relatório HTML;
- baseline por renderer apenas quando diferença é justificada.

## 35.3 Fontes de teste

Empacotar fontes abertas e fixas para goldens. Não depender da fonte do sistema.

## 35.4 Testes diferenciais

- CPU versus referência lenta;
- CPU Marlin versus Blend2D-like;
- CPU versus Direct2D;
- CPU versus OpenGL;
- CPU versus Vulkan;
- CPU versus Metal;
- shaping Dart versus HarfBuzz de teste;
- layout versus casos normativos.

## 35.5 Input replay

Formato:

```json
{
  "version": 1,
  "window": {"width": 800, "height": 600, "scale": 1.25},
  "events": [
    {"t": 0, "type": "pointerMove", "x": 50, "y": 20},
    {"t": 12000, "type": "pointerDown", "button": 1},
    {"t": 22000, "type": "pointerUp", "button": 1}
  ]
}
```

Usos:

- reproduzir bugs;
- comparar plataformas;
- benchmark;
- teste de gestos;
- fuzzing dirigido.

## 35.6 Fuzzing

Alvos:

- SVG;
- OpenType;
- image formats;
- Wayland XML generator;
- style parser;
- resource parser;
- input traces;
- DisplayList decoder;
- clipboard MIME;
- D-Bus messages;
- Windows messages sintetizadas.

## 35.7 Leak tests

Contadores em debug:

- HWND;
- HDC;
- HBITMAP;
- COM refs;
- D3D resources;
- XCB windows/pixmaps;
- Wayland proxies/buffers;
- GL objects;
- Vulkan objects;
- ObjC retains;
- CF objects;
- Metal resources;
- callbacks;
- native allocations.

Teste abre/fecha recursos em loop e exige retorno ao baseline.

## 35.8 Stress

- resize rápido;
- mover entre monitores;
- minimizar/restaurar;
- alternar fullscreen;
- abrir/fechar popups;
- clipboard grande;
- drag cancelado;
- IME durante resize;
- dispositivo GPU reiniciado;
- 10 mil widgets;
- lista de 1 milhão de itens virtualizada;
- texto de milhões de caracteres com viewport;
- janelas múltiplas;
- scale change durante animação.

---

# 36. Benchmarks

## 36.1 Metodologia

Seguir disciplina já usada nos roteiros de `marlin`:

- warmup;
- ao menos dez repetições para decisões de regressão;
- mediana;
- mínimo/máximo;
- p95;
- desvio;
- CPU/GPU/modelo registrados;
- build mode;
- SDK;
- frequência/energia quando disponível;
- guardar JSON bruto;
- não escolher por uma execução.

## 36.2 Categorias

### Startup

- processo até primeira janela;
- primeira pintura;
- primeiro frame interativo;
- carregamento de fonte;
- criação de device.

### Layout

- árvore estática;
- atualização de leaf;
- flex;
- grid;
- listas;
- texto;
- intrinsic.

### Build/reconciliation

- rebuild pequeno;
- reorder;
- inserção/remoção;
- global keys;
- style change.

### Rendering

- retângulos;
- paths;
- SVG;
- texto;
- imagens;
- clips;
- layers;
- gradients;
- scrolling;
- dirty rect.

### Input

- eventos/s;
- hit-test;
- routed event;
- gestures;
- keyboard repeat.

### Memória

- widgets;
- DisplayList;
- glyph atlas;
- image cache;
- scene;
- backend resources.

## 36.3 Budgets iniciais

Os números finais devem vir de medição, mas estabelecer gates relativos:

- atualização de cor não deve disparar measure;
- mover transform de layer não deve rerasterizar subtree;
- scroll virtualizado não deve criar todos os itens;
- frame estável não deve alocar proporcionalmente ao número total de widgets;
- janela ociosa não deve usar CPU continuamente;
- backend GPU não deve fazer readback por frame;
- clipboard/drag não deve bloquear o UI isolate em I/O grande.

## 36.4 Regressão

CI falha quando:

- mediana piora acima do limiar;
- memória cresce;
- alocação por frame aumenta;
- golden muda sem aprovação;
- leak count não volta;
- startup ultrapassa budget.

Para benchmarks ruidosos, usar tendência e confirmação local, não bloquear por um único resultado remoto.

---

# 37. Diagnóstico e DevTools

## 37.1 Overlay

- FPS;
- frame time;
- build/layout/paint/render/present;
- dirty rects;
- repaint boundaries;
- layers;
- overdraw;
- glyph atlas;
- texture memory;
- input latency;
- backend/capabilities;
- DPI;
- event queue.

## 37.2 Inspector

- árvore widgets;
- elements;
- render;
- semantics;
- propriedades e precedência;
- constraints;
- bounds;
- styles aplicados;
- listeners;
- focus;
- resource lookup;
- native handle apenas em modo avançado.

## 37.3 Tracing

Formato de eventos compatível com Chrome Trace JSON ou formato próprio conversível:

- begin/end frame;
- build;
- layout;
- paint;
- raster;
- submit;
- present;
- input;
- callbacks;
- allocations;
- device events.

## 37.4 Logs

Categorias:

- platform;
- ffi;
- window;
- input;
- text;
- accessibility;
- renderer;
- scheduler;
- layout;
- style;
- widget;
- resource;
- performance.

Cada evento inclui timestamp monotônico, thread/isolate, window ID e backend.

## 37.5 Crash diagnostics

- últimos eventos;
- backend selecionado;
- bibliotecas/símbolos;
- dispositivos;
- DisplayList opcode atual;
- janela;
- callback;
- resources;
- versão SDK;
- arquitetura.

Não tentar capturar access violation como se fosse exceção Dart recuperável. Prevenir com invariantes e isolamento.

---

# 38. Segurança e robustez

## 38.1 Fronteira FFI

- validar ponteiros nulos;
- validar comprimentos;
- overflow;
- alinhamento;
- lifetime;
- callbacks;
- return codes;
- thread affinity;
- strings sem terminador;
- dados externos.

## 38.2 Conteúdo não confiável

- fontes;
- SVG;
- imagens;
- clipboard;
- drag-and-drop;
- arquivos;
- MIME;
- URIs.

Aplicar:

- limites;
- timeouts;
- parsing bounds-checked;
- profundidade máxima;
- tamanho máximo;
- cancelamento;
- isolates para decode;
- fuzzing.

## 38.3 Plugins

Não permitir plugin nativo arbitrário no núcleo inicial. Para plugins Dart:

- contratos versionados;
- capabilities;
- isolamento;
- lifecycle;
- sem acesso implícito a handles;
- allow-list de APIs sensíveis.

## 38.4 Sandboxing

Documentar limitações:

- macOS sandbox entitlements;
- Flatpak/Snap;
- portais;
- acesso a arquivos;
- clipboard;
- drag;
- notificações;
- rede não é responsabilidade do framework.

---

# 39. Empacotamento

## 39.1 Executável Dart

- AOT por arquitetura;
- assets;
- shaders;
- fontes;
- manifest;
- arquivos de licença;
- runtime config;
- ícones.

## 39.2 Windows

- `.exe`;
- manifest DPI/long path;
- ícone/version resource;
- DLLs apenas se pertencentes a dependências externas opcionais;
- MSIX posterior;
- assinatura;
- installer fora do núcleo;
- crash dump documentado.

## 39.3 Linux

- binário;
- assets;
- `.desktop`;
- icons;
- MIME;
- AppImage/Flatpak/Snap opcionais;
- dependências mínimas;
- detecção de X11/Wayland;
- portal;
- RPATH cuidadosamente evitado/configurado.

## 39.4 macOS

```text
MyApp.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/MyApp
    ├── Resources/
    └── Frameworks/  (somente se necessário)
```

- bundle ID;
- version;
- icon;
- high resolution;
- usage descriptions;
- entitlements;
- codesign;
- hardened runtime;
- notarization;
- universal binary ou bundles separados.

## 39.5 Licenças

Gerar automaticamente `THIRD_PARTY_NOTICES` a partir da lockfile e inventário.

---

# 40. CI

## 40.1 Matriz

- Windows x64;
- Windows arm64 quando runner disponível;
- Ubuntu X11;
- Ubuntu Wayland virtual/compositor de teste;
- macOS x64;
- macOS arm64;
- headless em todos;
- debug/profile/release selecionados.

## 40.2 Jobs

1. format/analyze;
2. unit;
3. bindings regeneration diff;
4. headless;
5. platform smoke;
6. golden CPU;
7. GPU smoke;
8. accessibility smoke;
9. benchmark;
10. package;
11. leak/stress agendado;
12. license scan.

## 40.3 Ambientes gráficos CI

- Xvfb para X11;
- Weston/headless ou compositor apropriado para Wayland;
- sessão real para testes específicos;
- Windows desktop runner;
- macOS GUI session;
- goldens com fontes empacotadas.

## 40.4 Reprodutibilidade

Fixar:

- Dart SDK;
- headers/SDK metadata usados pelos geradores;
- protocolo Wayland;
- compiladores de shader;
- fontes;
- imagens;
- locale;
- scale;
- timezone;
- flags.

---

# 41. Política de compatibilidade

## 41.1 API Dart

- semantic versioning;
- experimental namespace;
- annotations;
- deprecation com migração;
- changelog;
- API diff.

## 41.2 ABI do sistema

Não prometer compatibilidade com símbolos opcionais. Usar probe.

## 41.3 Backends

Cada release publica matriz:

- complete;
- beta;
- experimental;
- disabled;
- unsupported.

## 41.4 Fallback

Aplicação pode exigir capability:

```dart
const DartUiConfig(
  requiredCapabilities: {
    Capability.accessibility,
    Capability.gpuAcceleration,
  },
);
```

Se faltar, falhar com diagnóstico, não degradar silenciosamente quando requisito é explícito.

---

# 42. ADRs obrigatórios

Criar antes/depois dos protótipos:

1. definição de puro Dart;
2. modelo Widget/Element/RenderObject;
3. ownership nativo;
4. dispatcher e main thread;
5. DisplayList;
6. escolha do backend CPU;
7. escolha Win32 renderer inicial;
8. XCB versus Xlib;
9. Wayland codegen;
10. GTK opcional;
11. Objective-C Runtime;
12. Metal layer;
13. render isolate;
14. sistema de propriedades;
15. estilos/templates;
16. texto puro Dart;
17. acessibilidade;
18. licença/proveniência;
19. shader build;
20. política de backend fallback.

**ADRs que existem em `doc/adr/`, em 2026-08-23:**

| | Assunto | Item da lista acima |
|---|---|---|
| 0001 | worker process com IOSurface no macOS | 4, 11 |
| 0002 | `Transform2D` afim em vez de `Matrix4` | — (não previsto) |
| 0003 | sem hinting TrueType | 16 |
| 0004 | implementando hinting TrueType (reverte 0003) | 16 |
| 0005 | Metal sobre IOSurface compartilhada | 12 |
| 0006 | aceleração vetorial por sparse strips | 19 |
| 0007 | contorno transformado para texto não alinhado | 16 |

**Continuam sem ADR**, e cada um já é uma decisão tomada em código: *Wayland
codegen* (item 9 — a decisão real foi **não** gerar e transcrever à mão,
§16.1), *escolha do backend CPU* (6), *XCB versus Xlib* (8), *acessibilidade*
(17) e *política de backend fallback* (20), que hoje vive só na ordem de
`defaultPresentations()`.

Modelo:

```markdown
# ADR-0001: Título

- Status:
- Data:
- Decisores:

## Contexto
## Opções
## Decisão
## Consequências positivas
## Consequências negativas
## Evidências
## Plano de reversão
```

---

# 43. Registro de riscos

| ID | Risco | Probabilidade | Impacto | Mitigação |
|---|---|---:|---:|---|
| R01 | callback nativo chamado após GC/dispose | alta | crítico | registry, token geracional, leak tests |
| R02 | AppKit exige comportamento difícil sem ObjC wrapper | alta | crítico | spike executado — ver [SPIKE_MACOS_MAIN_THREAD.md](SPIKE_MACOS_MAIN_THREAD.md); `NSWindow` criada de Dart puro, falta input |
| R03 | COM vtable incorreta | alta | crítico | gerador, ABI tests, wrappers mínimos |
| R04 | event loop Dart compete com loop nativo | alta | crítico | dispatcher por plataforma e testes de idle/latência |
| R05 | Wayland marshalling incorreto | média | crítico | codegen XML, conformance, sanitização |
| R06 | renderer abstrato vira lowest common denominator | média | alto | capability API e extensões internas |
| R07 | GPU explode escopo | alta | alto | CPU first, D2D first, Vulkan posterior |
| R08 | texto complexo incompleto | alta | alto | corpus, comparação HarfBuzz, fases |
| R09 | acessibilidade tardia exige refatoração | alta | alto | semantics desde Button |
| R10 | APIs copiadas de GPL | baixa/média | crítico | clean-room, provenance, revisão |
| R11 | divergência `dart_graphics`/`marlin` | alta | alto | contratos canônicos e adapters |
| R12 | alocação Dart causa jank | média | alto | arenas, typed buffers, benchmark |
| R13 | FFI crash sem stack útil | alta | alto | invariantes, trace, small bindings |
| R14 | dependências Linux fragmentadas | alta | médio/alto | probes e fallbacks |
| R15 | DPI inconsistente | alta | médio | modelo lógico/físico desde o início |
| R16 | IME quebrado | alta | alto | contrato comum e testes CJK cedo |
| R17 | device loss | média | alto | scene independente e rebuild |
| R18 | shaders não reproduzíveis | média | médio | manifest e toolchain pinada |
| R19 | pacote macOS não notariza | média | alto | pipeline de bundle cedo |
| R20 | projeto cria pacotes demais cedo | alta | médio | bootstrap consolidado |
| R21 | backend GTK vira dependência involuntária | média | médio | package opcional |
| R22 | lista de recursos sem eviction | alta | alto | budgets e telemetry |
| R23 | bindings ficam desatualizados | alta | alto | geração reproduzível e CI diff |
| R24 | arquitetura arm64 não testada | média | alto | runners e ABI golden |
| R25 | ausência de maintainer por backend | alta | alto | ownership e documentação |

## 43.1 Regra de spikes

Riscos críticos precisam de protótipo descartável antes da implementação ampla:

- WndProc Dart;
- COM callback em Dart;
- XCB event loop;
- Wayland listener/marshal;
- Objective-C subclass;
- NSTextInputClient;
- CAMetalLayer;
- UI Automation;
- AT-SPI;
- render isolate.

---

# 44. Definition of Done geral

Uma funcionalidade só está concluída quando:

- API documentada;
- testes unitários;
- teste de integração;
- tratamento de erro;
- ownership documentado;
- dispose testado;
- diagnostics;
- benchmark quando hot path;
- acessibilidade quando visível/interativa;
- keyboard;
- DPI;
- tema;
- goldens;
- plataforma aplicável;
- changelog;
- nenhuma dependência circular;
- analyzer limpo;
- AOT validado.

“Funciona no exemplo” não é conclusão.

---


# 45. Roteiro de execução por fases

As fases abaixo são gates de engenharia, não estimativas de calendário. Uma fase pode ter trabalho paralelo, mas seus critérios de saída não podem ser ignorados.

**Nota de 2026-08-23.** A execução real **não seguiu esta sequência**, e fingir
que seguiu tornaria as fases inúteis como gate. Três desvios, registrados:

1. **Fases foram abertas antes de a anterior fechar.** F10 (D2D/D3D11), F11
   (OpenGL), F12 (Metal), F13 (Wayland) e F14 (Vulkan) estão todas em
   andamento simultâneo, com F13 quase completa em código e **zero execução
   real**, enquanto F8 (X11) seguia com o gate travado no teclado — que foi
   destravado em 26/08/2026 (§68.1), restando IME e acessibilidade. O custo
   apareceu: várias frentes com código escrito e nenhum consumidor — ver a §68,
   item *escrito e não ligado*;
2. **Trabalho fora de qualquer fase entrou no repositório**: PDF, assinatura
   PAdES, CorelDRAW e o motor vetorial (§4.4), mais o porte de APIs de SO
   (§56.1) e o de drag-and-drop, que atravessa três backends. Nenhum deles tem
   fase, e dois deles já custaram arestas de camada;
3. **F16 (acessibilidade) e F15 (GTK/desktop) não começaram**, e a
   acessibilidade é o item que o *Gate 1.0* exige e que menos avançou fora do
   Windows.

Isso não pede reordenar as fases. Pede que os gates voltem a ser respeitados
como condição de saída — em particular o de F13, que hoje depende de uma coisa
só: rodar contra um compositor de verdade.

---

## Fase 0 — Governança, inventário e licenças

### Objetivo

Eliminar ambiguidades antes de portar código ou gerar bindings.

### Dependências

Nenhuma.

### Trabalho

- criar repositório/monorepo;
- escolher licença do projeto;
- executar inventário local;
- catalogar Avalonia, OpenJFX e referências;
- registrar licença por arquivo relevante;
- decidir política clean-room;
- criar ADRs iniciais;
- definir plataformas/arquiteturas mínimas;
- fixar Dart SDK;
- configurar analyzer;
- configurar CI headless;
- definir nomenclatura;
- criar issue templates;
- criar regra de ownership por módulo;
- criar matriz de capacidades;
- criar threat model da fronteira FFI;
- escrever Definition of Done;
- definir política de benchmarks;
- definir formato de golden;
- definir política de versionamento dos bindings.

### Artefatos

- `doc/reference-inventory`;
- `doc/licenses`;
- ADR-0001 a ADR-0005;
- `CONTRIBUTING.md`;
- `SECURITY.md`;
- `CODE_OF_CONDUCT.md`;
- matriz de plataformas;
- relatório de riscos inicial.

### Gate

- nenhum arquivo de referência importante sem licença identificada;
- nenhum plano de cópia de código OpenJFX sem análise específica;
- todos entendem a definição de puro Dart;
- CI executa `dart analyze` e teste vazio em três sistemas.

### Não fazer ainda

- bindings massivos;
- widgets;
- Vulkan;
- Metal;
- port integral.

---

## Fase 1 — Foundation, geometria e contratos

### Objetivo

Criar o vocabulário comum sem dependência de plataforma.

### Trabalho

- `Point`, `Offset`, `Size`, `Rect`, `Insets`, `RoundedRect`;
- matrizes e transforms;
- cores e pixel formats;
- constraints;
- clocks;
- IDs geracionais;
- disposable/lifetime;
- error/diagnostic model;
- capability model;
- event timestamps;
- arena/pools;
- immutable collections necessárias;
- `Path` canônico;
- `Paint`;
- `ImageHandle`;
- `GlyphRun`;
- interfaces de plataforma;
- interfaces de renderer;
- surface descriptors;
- DisplayList format v0;
- serializer/decoder;
- trace hooks;
- API docs.

### Integração com projetos existentes

- mapear tipos equivalentes de `dart_graphics`;
- criar adapters;
- mapear `marlin`;
- escolher um `Path` canônico;
- evitar copiar buffers entre packages;
- criar testes de paridade geométrica.

### Gate

- package comum compila em Windows/Linux/macOS;
- nenhum import FFI no package comum;
- DisplayList grava e reproduz retângulo/path/text mock;
- round-trip serialização determinístico;
- 100% dos tipos fundamentais têm igualdade/hash/NaN policy documentados;
- adapters de `dart_graphics` passam testes.

---

## Fase 2 — Scheduler, dispatcher abstrato e backend headless

### Estado auditado em 2026-08-09

- `HeadlessWindowingBackend` implementa o mesmo contrato dos backends nativos,
  com probe sempre disponível, múltiplas janelas, lifecycle idempotente e
  reinicialização sem FFI;
- `HeadlessWindow` oferece `MemorySurfaceDescriptor`, escala configurável,
  coordenadas client/screen, show/hide, título, cursor, resize com nova
  generation, redraw/damage, fechamento e injeção de input normalizado;
- `pumpEvents()` drena uma fila FIFO sem relógio de parede, inclusive trabalho
  gerado por listeners durante o pump; close e shutdown preservam a ordem dos
  eventos e fecham os streams depois da notificação final;
- testes determinísticos cobrem surface → `CpuRendererBackend` → framebuffer,
  descarte de input stale, eventos, múltiplas janelas e shutdown;
- o gate continua aberto para integrar `ManualDispatcher` ao pulse completo,
  virtual surface screenshot/PNG, golden harness, clipboard/text input falsos,
  input replay e semantic recorder.

### Objetivo

Ter uma aplicação sem janela real capaz de executar build/layout/paint.

### Trabalho

- dispatcher fake;
- clock fake;
- task priorities;
- frame scheduler;
- dirty queues;
- virtual window;
- virtual surface;
- input fake;
- clipboard fake;
- text input fake;
- semantic recorder;
- framebuffer CPU;
- screenshot;
- golden harness;
- input replay;
- tracing;
- deterministic random seed;
- error boundary;
- lifecycle de aplicação.

### Gate

- teste cria raiz, mede, pinta e produz PNG;
- clock avança animação sem dormir;
- eventos sintéticos chegam ao alvo;
- semântica pode ser inspecionada;
- teste de idle não executa loop infinito;
- nenhuma dependência nativa.

---

## Fase 3 — Backend CPU integrado a `dart_graphics`/`marlin`

### Objetivo

Usar o motor gráfico real antes de abrir uma janela.

### Trabalho

- adapter `CpuCanvas`;
- pixel buffer canônico;
- fill/stroke;
- clips;
- transforms;
- gradients;
- images;
- text básico;
- blend modes;
- save/restore;
- damage;
- dirty rect;
- path cache;
- glyph cache;
- benchmark;
- goldens;
- seleção de rasterizador;
- referência lenta.

### Gate

- corpus SVG escolhido renderiza;
- múltiplos contornos corretos;
- `evenodd/nonzero`;
- alpha premultiplied;
- dez execuções de benchmark registradas;
- nenhuma regressão visual conhecida sem issue;
- output reutilizável por GDI/XCB/CG.

---

## Fase 4 — Spike Win32 mínimo

### Objetivo

Provar que Dart controla Win32 sem shim.

### Trabalho

- atualizar/criar binding mínimo;
- DLL loader;
- structs;
- callback WndProc;
- class registry;
- create/show;
- message loop;
- paint;
- resize;
- close;
- Unicode title;
- diagnostic log;
- AOT;
- x64;
- protótipo arm64 quando disponível.

### Testes especiais

- callback exception;
- janela destruída com mensagens pendentes;
- abrir/fechar em loop;
- `WM_NCDESTROY`;
- GC forçada;
- resize agressivo;
- timer/wakeup.

### Gate

- janela sólida colorida;
- sem C/C++;
- AOT;
- zero callback tardio;
- idle sem CPU excessiva;
- relatório de ABI.

### Decisão

Se este spike falhar por limitação real de callback/thread, parar expansão e resolver o runtime/event loop antes de widgets.

---

## Fase 5 — Win32 CPU vertical slice

### Estado auditado em 2026-08-09

- janela Win32, DPI, DIB retido, apresentação GDI com damage/resize e replay de
  `DisplayList` estão integrados e cobertos por testes portáveis;
- mouse core e transições de teclado são normalizados no contrato comum; o
  probe agora anuncia `pointerInput` e `keyboardInput` de forma coerente;
- wheel, foco de widgets, clipboard, semantics, texto real e o Button vertical
  completo ainda mantêm o gate aberto.

### Objetivo

Primeira aplicação interativa completa.

### Trabalho

- DIB section;
- apresentação CPU;
- scale/DPI;
- mouse;
- keyboard;
- foco;
- cursor;
- scheduler;
- dirty rect;
- Button;
- Text;
- layout;
- semantics snapshot;
- clipboard text;
- screenshot;
- app packaging básico.

### Demonstração obrigatória

Uma janela contém contador e botão:

- hover;
- pressed;
- click;
- Tab;
- Enter/Space;
- texto atualiza;
- apenas subárvore necessária repinta;
- resize;
- mudança de DPI;
- fecha sem leak.

### Gate

Esse exemplo é o primeiro marco público interno. Nenhum outro backend deve avançar profundamente sem ele.

---

## Fase 6 — Núcleo de widgets profissional

### Estado auditado em 2026-08-09

- Widget/Element/State, keys, reconciliação, lifecycle, build scheduler e a
  ligação com a árvore de `RenderObject` já possuem testes portáveis;
- widgets declarativos iniciais incluem `ColoredBox`, `Padding`, `Align`,
  `Text` e `GestureDetector`; `Align` preserva Element/RenderObject durante
  updates e encaminha alignment/widthFactor/heightFactor ao layout;
- `PointerRouter` liga eventos normalizados ao hit-test deepest-first, faz
  bubbling e cancelamento de captura; `BuildOwner.dispatchPointerEvent()` e
  `GestureDetector.onTap` completam a primeira interação declarativa real;
- layout, painting e hit-test têm infraestrutura funcional, mas texto continua
  recusando pintura até existir shaping/rasterização reais;
- foco, routed events, styles, templates, semantics e controles profissionais
  mantêm o gate da fase aberto.

### Estado auditado em 2026-08-12

- `InheritedWidget`/`InheritedElement` publicam valores por subárvore com mapa
  copiado uma vez por escopo, registro de dependentes e notificação seletiva
  via `updateShouldNotify`; `BuildContext` expõe
  `dependOnInheritedWidgetOfExactType`, `getInheritedWidgetOfExactType`,
  `findAncestorWidgetOfExactType` e `visitAncestorElements`, sem service
  locator global (seção 24.8);
- o sistema de propriedades da seção 24.6 existe com os oito níveis de
  precedência (animação → local → binding → template → trigger → style →
  herdado → default), `coerce`/`validate`, invalidação declarada por
  propriedade e escrita por nível que nunca sobrescreve um nível mais forte;
- `MultiChildRenderObjectWidget`/`Element` reconciliam listas por prefixo,
  sufixo e chave, e reordenam os filhos do render container por permutação
  (`RenderBoxContainer.reorderChildren`) em vez de destruir e recriar; `Column`,
  `Row`, `Stack` e `SizedBox` passam a existir sobre `RenderFlex`/`RenderStack`;
- foco é uma árvore real: `FocusNode`, `FocusScopeNode`, `FocusManager`,
  restauração por escopo, `:focus-visible` distinto de `:focused`, modal
  trapping, janela ativa/inativa e ordem de tabulação derivada da **árvore de
  render** (ordem visual), não da ordem de build;
- `ShortcutMap → Intent → Action` com mapas encadeados; `BuildOwner`
  despacha teclado na ordem controle focado → atalhos → travessia, e
  `KeyboardEventTarget.handleKeyEvent` passou a devolver se consumiu o evento;
- estilos com seletores de tipo/classe/chave/pseudo-classe/descendente/filho,
  especificidade determinística, regras com e sem estado aplicadas nos níveis
  `style` e `trigger`, e `ResourceDictionary` hierárquico com cache, fallback e
  detecção de ciclo de alias;
- temas entregam base neutra clara/escura, Fluent-like, alto contraste e
  densidade compacta/confortável, com `ControlTemplate`/`TemplateRegistry`;
- scroll possui `ScrollPosition` puro (extents, clamping, chaining pelo delta
  não consumido, linhas vs pixels, página, overscroll, fling determinístico,
  scrollbar, reveal) e `RenderViewport` com clip e hit-test recortados;
- popups têm posicionamento puro estilo `xdg_positioner` (flip → slide →
  resize, nessa ordem), escolha entre superfície própria e janela nativa, e uma
  pilha com dismissal em cascata, light-dismiss, grab e Escape por nível;
- os controles do gate existem sem controle nativo: `Button`, `ToggleButton`,
  `CheckBox` (tri-state), `Radio`, `Switch`, `Slider`, `ProgressBar`,
  `TextField`/`PasswordField` (seleção, caret, undo/redo, Ctrl+A/Z/Y),
  `ScrollViewer`, `ListBox` virtualizado, `Dialog`, `Menu` e `Tooltip`;
- a virtualização segue a seção 29.5: planejador puro (`ListVirtualization`)
  com extents uniformes ou variáveis por soma de prefixos, cache antes/depois,
  âncora de scroll, e realização por chave estável — 10 000 itens realizam
  menos de 20 render objects e a semântica anuncia a contagem **total**;
- a árvore semântica é separada da visual: `SemanticsProvider`,
  `SemanticsOwner` com ids estáveis por identidade de render object, poda,
  atualização incremental (added/updated/removed), merge de descendentes,
  `isBlocking` para modais e ordem de leitura por `sortKey`;
- diagnóstico de erro nomeia o caminho de widgets (`FrameworkError`), com
  `ErrorReporter` que por padrão registra **e** relança, e contenção opcional
  para o shell; o dev overlay reporta média, p99 nearest-rank, frames fora do
  orçamento e um histograma contra a linha de 16,6 ms;
- gate fechado: a galeria monta headless e no Win32 CPU a partir da **mesma
  árvore de widgets**; a suíte de golden compara display lists estáveis por
  tema e uma delas rasteriza para pixels reais; a operação é integralmente por
  teclado (Tab/Shift+Tab com wrap, Space/Enter, setas em slider e lista);
  semântica cobre todos os papéis; 963 testes portáveis passam com
  `dart analyze` limpo;
- o benchmark de 10 000 nós (`benchmark/widget_tree_benchmark.dart`) reporta,
  com asserts desligados: cold build 11,2 ms, rebuild integral 2,5 ms,
  `setState` em uma folha 0,97 ms, layout 0,89 ms, paint 0,93 ms, hit-test
  36 µs, scroll de lista de 10 000 itens 0,32 ms e semântica 1,35 ms —
  o caso que importa (`setState` numa folha) fica bem dentro de um frame;
- `example/gallery_win32.dart --frames 30` abriu janela Win32 real, apresentou
  30 frames por DIB, e reportou `WIN32_GALLERY=PASS`, 20 controles próprios do
  framework e 21 nós semânticos, sem nenhum controle nativo;
- a regra de camadas passou a ser testada (`test/architecture/layering_test.dart`):
  nenhum arquivo do core importa backend e nenhum identificador de plataforma
  (`HWND`, `WndProc`, `xcb_`, `NSWindow`, `objc_msgSend`, `IOSurface`, …)
  aparece fora de `lib/src/backends`. Quatro arestas anteriores à Fase 6
  continuam registradas como exceções nomeadas e justificadas, e o teste falha
  se qualquer uma delas desaparecer ou se surgir uma nova:
  `rendering/render_object.dart → layout` (typedef de compatibilidade),
  `scheduler/frame_scheduler.dart → layout` e `→ graphics` (o coordenador de
  frames dirige o `PipelineOwner`, logo está acima de layout e deveria morar
  numa camada de aplicação) e `platform/native_window.dart → rendering` (as
  seções 9.3/9.7 acoplam janela e superfície);
- pendências reconhecidas: texto continua com a fonte de células fixas de
  `lib/src/text/placeholder_font.dart` até a Fase 7 entregar shaping real, e
  animação de estilo (seção 28.7) ainda não tem transições.

### Objetivo

Estabilizar o framework acima das plataformas.

### Trabalho

- Widget/Element/RenderObject;
- stateless/stateful;
- keys;
- inherited context;
- properties;
- bindings;
- logical/visual trees;
- lifecycle;
- build scheduler;
- measure/arrange;
- hit-test;
- routed events;
- focus;
- shortcuts/actions;
- styles;
- templates;
- resources;
- themes;
- basic controls;
- scroll;
- popup model;
- semantics;
- error diagnostics;
- dev overlay.

### Controles de saída

- Button;
- CheckBox;
- Radio;
- TextField básico;
- Slider;
- ScrollViewer;
- ListBox virtualizado;
- Dialog;
- Menu básico;
- Tooltip.

### Gate

- gallery headless;
- gallery Win32 CPU;
- golden suite;
- keyboard-only;
- semantics;
- 10 mil nodes benchmark;
- lista virtualizada;
- nenhum Win32 type no core.

---

## Fase 7 — Texto, shaping e IME Windows

### Estado auditado em 2026-08-12

- o parser OpenType existe em Dart puro, sem FreeType nem HarfBuzz em runtime:
  `sfnt.dart` valida o diretório de tabelas uma única vez — offset e tamanho de
  cada registro contra o tamanho do arquivo — para que nenhum parser de tabela
  precise reconferir a própria faixa; `font_data.dart` é um cursor big-endian
  com verificação de limites em toda leitura, de modo que fonte malformada
  produz `FontFormatException` nomeada em vez de `RangeError` vindo do fundo de
  um parser (seção 30.8);
- `head`, `maxp`, `hhea`, `hmtx`, `loca`, `cvt `, `fpgm` e `prep` estão
  parseados; `hmtx` trata a cauda comprimida, onde glifos além de
  `numberOfHMetrics` herdam o último avanço — errar isso colapsa toda fonte
  monoespaçada, que rotineiramente declara um único par;
- `cmap` implementa os formatos 0, 4, 6 e 12, com a política de preferência de
  subtabela (Unicode completo → BMP → Mac Roman). O formato 4 é resolvido em um
  mapa plano ordenado no momento do parse, o que remove de vez a aritmética de
  `idRangeOffset` — o campo mais implementado errado do formato — do caminho de
  consulta;
- `glyf` decodifica **sob demanda**, um glifo por vez, direto em `Path`: o
  quadrático do TrueType encontra `PathBuilder.quadraticBezierTo` sem modelo
  intermediário, e a transformação de cada componente de um glifo composto é
  aplicada ponto a ponto na emissão, produzindo um `Path` por glifo em vez de
  um por componente. Compostos têm limite de profundidade, porque uma fonte que
  se auto-referencia é estouro de pilha guiado por entrada não confiável;
- o **interpretador de bytecode TrueType** está implementado em
  `lib/src/text/truetype/`, com estado gráfico, zonas (twilight e glyph),
  phantom points e os grupos de opcodes de pilha, aritmética, controle de
  fluxo, estado gráfico, memória e movimentação de pontos. O ADR 0003 registra
  que omitir hinting foi proposto e recusado, e — importante — que os phantom
  points deixam de ser opcionais por causa disso: o avanço passa a ser a
  distância entre pp1 e pp2 depois do programa rodar, não `hmtx` direto;
- rasterização de glifo reusa o `ScanlineFiller` sem alteração alguma: ele já
  era acumulação analítica de área exata, a mesma família do rasterizador
  smooth do FreeType, então um glifo é preenchido pelo mesmo código que
  preenche qualquer caminho. `rendering/text/glyph_raster.dart` é só a mudança
  de coordenadas (escala e inversão de y) e a alocação da máscara;
- **texto sob transform afim arbitrária está implementado nos dois
  renderizadores** — rotação, skew, espelhamento, escala não uniforme e
  qualquer composição delas. Até então ambos *recusavam por nome* essas
  matrizes (`_deviceFont`, em `cpu_renderer.dart` e em `gpu_raster_sink.dart`),
  o que fazia com que um rótulo girado desenhasse na GPU e lançasse exceção no
  software; a `CollapsedTabStrip` empilhava caracteres exatamente por causa
  disso e hoje gira o rótulo de verdade. O critério é uma única função,
  `glyphMasksFit` em `rendering/text/glyph_raster.dart`, importada pelos dois
  sinks — dois critérios copiados é precisamente como um backend passa a
  aceitar uma cena que o outro recusa:
  - **caminho rápido, e ele continua sendo o caminho comum**: `b == 0`,
    `c == 0`, `a > 0`, `d > 0` e `a == d` — máscara de cobertura em cache,
    blitada em pixel inteiro, com bucket subpixel horizontal. É o que toda
    interface faz, e a comparação `a == d` é exata de propósito: não existe
    epsilon correto a 8px e a 200px ao mesmo tempo, e errar para o lado do
    contorno custa tempo enquanto errar para o lado da máscara custa a imagem;
  - **caminho geral**: o contorno do glifo é preenchido sob a matriz completa
    (`glyphOutlineTransform`), pelo mesmo `ScanlineFiller` e com a mesma regra
    de preenchimento não-zero que qualquer `drawPath`. Na GPU isso é o *atlas
    de máscara*, não o atlas de glifos — e o atlas de máscara roda esse mesmo
    filler na CPU e sobe a cobertura, que é por que a paridade medida entre os
    dois caminhos é **desvio 0** e não uma tolerância;
  - **o que é cacheado**: o contorno, pela própria `Typeface`, com chave só de
    glifo — ele é a forma de design e não depende da matriz, então uma
    animação de rotação decodifica cada glifo uma única vez. O resultado
    rasterizado **não** é cacheado, e isso é decisão e não omissão: ele é
    função da matriz inteira e da fração da caneta, então uma chave sobre isso
    erraria em todo quadro que não fosse repetição exata e ainda cobraria a
    chave. Nada é admitido no cache de glifos nem no atlas de glifos por um run
    girado — a chave deles não tem onde guardar um ângulo, e uma entrada feita
    ali seria entregue depois a um chamador em pé;
  - **hinting é desligado no caminho geral**, e o motivo está no código e no
    ADR 0007: o programa TrueType alinha hastes à grade de *pixels* usando os
    eixos do próprio glifo, e sob rotação esses eixos não são mais os da tela.
    O caminho da máscara pede `Typeface.outlineOf(glifo, ppem)`; o caminho do
    contorno pede `outlineOf(glifo)` sem ppem;
  - **custo medido**: o caso alinhado **não regrediu**. Numa cena de 2160
    glifos (DejaVu 14px, 40 linhas, superfície 480x760, cache quente,
    `dart run`, asserts desligados) a mediana foi 2,32–2,35 ms antes da
    mudança e 2,31–2,37 ms depois, com p05 de 2,09 ms nos dois casos — dentro
    do ruído das amostras. O caminho girado custa cerca de 2,4x o alinhado
    nessa mesma cena (5,5 ms), que é o preço de um preenchimento de caminho
    por glifo onde antes havia uma exceção. Os dois casos ficaram
    versionados em `benchmark/text_benchmark.dart` (`draw a line, upright` e
    `draw a line, rotated`), com orçamentos folgados pela política do arquivo:
    eles existem para pegar uma ordem de grandeza, não alguns por cento;
- shaping Latin em `shaper.dart` com kerning pela tabela `kern` legada, medido
  em DejaVu 48px: "To" fecha 8,16px e "AV" 3,07px, e o teste exige que o
  deslocamento seja o valor da tabela escalado, não apenas que tenha encolhido.
  `GlyphRun` carrega índices de cluster desde a primeira versão, porque cursor,
  seleção e a reordenação que árabe e índico exigem dependem deles e adicioná-
  los depois significaria mexer em todas as camadas acima;
- a display list ganhou tabela de fontes (`addFont`/`fontAt`). O tamanho vive
  no `fontId`, que interna um par (face, tamanho): um shaper molda *num*
  tamanho, então id, offsets e tamanho são uma decisão indivisível, e um
  formato capaz de expressá-los separadamente é capaz de expressá-los em
  desacordo;
- o backend CPU compõe máscaras de cobertura tingidas pela paint através do
  mesmo `_fillSpan` que o preenchimento antialiasado usa, o que torna a
  paridade com `fillRect` estrutural em vez de coincidente. O cache de glifos
  tem chave (face, glifo, tamanho em 1/64px, bucket subpixel em quartos),
  evicção LRU sob orçamento em bytes, e métricas de acerto/erro/evicção;
- descoberta de fontes do sistema em Dart puro, sem DirectWrite, fontconfig ou
  Core Text — varredura de diretório mais leitura do arquivo. Verificado nesta
  máquina: 483 arquivos encontrados, `segoeui.ttf` selecionada;
- três fontes de teste versionadas com licença permissiva (Roboto Apache-2.0,
  DejaVu, Ahem público), escolhidas para exercitar `loca` curto **e** longo,
  presença e ausência de `kern`, e métricas exatas. Nada de `C:\Windows\Fonts`,
  que é proprietário. `NOTICE` na raiz registra o que é derivado e o que foi
  apenas lido como referência;
- pendente para fechar o gate: bidi (UAX #9), quebra de linha (UAX #14),
  GSUB/GPOS além de kerning, fallback de fonte, CFF/CFF2, IME por IMM32,
  edição multilinha e o corpus comparado com HarfBuzz como oráculo de teste.

### Estado auditado em 2026-08-23

- **IME por IMM32 está feito** e fecha o item mais pesado que a auditoria de
  12/08 deixava pendente: composição, cláusulas com estilo (`GCS_COMPATTR`),
  posicionamento da janela de candidatos (`ImmSetCandidateWindow`) e
  cancelamento, com o bridge lendo tudo **dentro** do `WM_IME_COMPOSITION` —
  `ImmGetCompositionStringW` só vale ali — e empurrando um valor imutável para
  cima, sem acessor preguiçoso e sem `await`. **Fica de fora**: texto ao redor
  (`IMR_DOCUMENTFEED` não é respondida) e **TSF**;
- o contrato `lib/src/platform/text_input.dart` generalizou o que era só
  Windows: `TextInputClient`, `TextInputConnection`, `TextInputBackend`, com as
  assimetrias entre plataformas **modeladas em vez de suavizadas** — o v3 do
  Wayland não tem estilo por cláusula, o Win32 não tem texto ao redor;
- **teclas mortas em Dart puro**: `platform/compose_sequences.dart` lê as
  tabelas Compose do próprio X11 (`$XCOMPOSEFILE`, `~/.XCompose`,
  `/usr/share/X11/locale/<locale>/Compose`, com `include` e `%L`/`%H`/`%S`) e
  resolve teclas mortas e a tecla Compose. Ligada **no Wayland**, e só quando o
  compositor não oferece IME;
- **continua pendente do gate original**: bidi (UAX #9) no *movimento do
  caret* — o caret salta em texto de direção mista —, GSUB/GPOS além de
  kerning, fallback de fonte, CFF/CFF2 com hinting aplicado, edição multilinha,
  e o corpus comparado com HarfBuzz como oráculo;
- **novidade que muda uma decisão anterior**: o rasterizador de CPU **passou a
  aceitar texto sob transformação rotacionada**, caindo na rota de contorno
  (`_drawGlyphRunAsOutlines`), com hinting desligado sob rotação. A decisão está
  no **ADR 0007**, escrito em 23/08/2026 (§68.4). O **Direct2D** acompanhou em
  24/08/2026, pela mesma dupla de funções compartilhadas.

### Objetivo

Tornar edição de texto uma capacidade central, não um adendo.

### Trabalho

- consolidar parser OpenType;
- shaping Latin;
- GSUB/GPOS;
- bidi;
- line breaking;
- fallback;
- text layout cache;
- caret;
- selection;
- editing commands;
- undo/redo;
- clipboard;
- IMM32;
- candidate rect;
- composition;
- password;
- TextArea;
- tests CJK;
- fuzzing de fonte.

### Gate

- editor multiline;
- português;
- árabe;
- hebraico;
- chinês/japonês/coreano;
- emoji;
- seleção bidi;
- screen reader lê texto básico;
- comparação de shaping em corpus;
- não usar FreeType/HarfBuzz no runtime padrão.

---

## Fase 8 — Backend X11/XCB CPU

### Estado auditado em 2026-08-09

- `X11WindowingBackend.probe()` abre uma conexão XCB temporária real, inspeciona
  tela, `RESOURCE_MANAGER` e extensões, resolve a escala e fecha a conexão;
- `initialize()` e `shutdown()` possuem uma conexão separada, com teardown
  idempotente, e `wake()` já usa o self-pipe da conexão;
- `createWindow()` está ligado a uma janela XCB real com criação checked,
  `WM_PROTOCOLS`/`WM_DELETE_WINDOW`, título UTF-8 + fallback, hints
  ICCCM/EWMH, map/unmap, bounds, redraw e teardown idempotente;
- o pump possui mapa XID → janela, orçamento contra starvation e coalesce de
  Configure/Expose/Focus/ClientMessage/Destroy; erros X são diagnosticados;
- a conexão valida `image_byte_order`, formato de pixmap e visual root antes de
  aceitar BGRA: a primeira versão segura restringe-se a TrueColor depth 24,
  bpp/pad 32, LSB-first e máscaras RGB canônicas, sem tratar depth 30 como se
  fosse BGRA8888;
- cada janela compatível possui framebuffer BGRA retido, GC criado por request
  checked e apresentação `PutImage`; requests grandes são divididos por um
  planner puro em bandas verticais ou tiles horizontais, com um único flush;
- resize invalida a generation, substitui a surface antes de emitir o evento e
  teardown libera buffer/GC antes do XID; o probe anuncia `cpuPresentation`
  somente quando o formato real do servidor é compatível;
- `X11CpuPresenter` rasteriza `DisplayList` diretamente no buffer nativo,
  reenvia pixels em Expose e repete a lista retida na surface de um resize,
  sempre revalidando identidade e generation antes de apresentar;
- mouse core normaliza Motion, botões 1/2/3/8/9 e Enter/Leave para os eventos
  comuns, preservando timestamp, coordenadas lógicas, window id e generation;
  wheel 4/5/6/7 produz scroll vertical/horizontal em linhas, enquanto teclado
  continua reservado ao XKB;
- setenta e oito testes X11 portáveis cobrem conexão, layouts ABI, limites
  core/BIG-REQUESTS, fragmentação sem gaps, surface, damage, resize/lifecycle,
  presenter, decoder, tradução, coalescimento, roteamento, generation e
  descarte;
- o smoke AOT rasterizou uma `DisplayList`, apresentou frame completo e damage,
  redimensionou/recriou a surface e fechou a janela real sob Xvfb no
  [GitHub Actions #31348127502](https://github.com/insinfo/dart_ui/actions/runs/31348127502),
  com `cpu=true`, `X11_PUT_IMAGE=PASS`, depth 24/BGRA8888 e generation 1;
  Analyze/Test/AOT também ficaram verdes em Linux, Windows e macOS, e o gate
  integral do framework passou nas três plataformas no
  [GitHub Actions #31348127462](https://github.com/insinfo/dart_ui/actions/runs/31348127462);
- as referências locais confirmaram os padrões sem cópia de código: Cairo
  1.18.4 (LGPL-2.1/MPL-1.1) para create checked e PutImage em bandas,
  Avalonia `064b84a` (MIT) para lifecycle/roteamento por XID, e Skia
  `2eed75b` (BSD-3) para drenagem limitada/coalescida;
- Wayland/Weston segue como POC: o
  [GitHub Actions #31343964231](https://github.com/insinfo/dart_ui/actions/runs/31343964231)
  comprovou conexão, registry, `wl_compositor`, `wl_shm`, surface, commit e
  teardown, mas ainda não `xdg-shell` nem o lifecycle de `wl_buffer.release`.

### Estado auditado em 2026-08-23

Desde 09/08 este backend ganhou **XDND nos dois sentidos** — `X11DragDropManager`
recebe e `X11XdndSource` inicia — e nada mais que mude o quadro. O que **não**
mudou é o que importa:

- **continua sem teclado.** `x11_events.dart` consome `xcbKeyPress`/
  `xcbKeyRelease` e os descarta; o backend não constrói um único `KeyEvent` nem
  `TextInputEvent` e **não reivindica** `Capability.keyboardInput`. Sem keysym,
  sem `GetKeyboardMapping`, sem `xcb_xkb_*`, sem `libxkbcommon`;
- **continua sem clipboard**: não existe `x11_clipboard.dart` e o backend não
  implementa `ClipboardProvider`;
- **continua sem IME**, que é consequência do primeiro item e não uma decisão
  separada (§15.2.1);
- o caminho GL de janela existe no seletor e **nunca foi executado**.

Ligar XKB é o próximo passo desta fase, e destranca teclado, atalhos, teclas
mortas e IME de uma vez — o motor de teclas mortas já está escrito e testado.

### Objetivo

Provar portabilidade do núcleo sem GPU.

### Trabalho

- XCB bindings;
- event loop;
- atoms;
- ICCCM/EWMH;
- window;
- SHM;
- XKB;
- input;
- scale;
- clipboard;
- XDND;
- popups;
- cursor;
- system theme;
- AT-SPI inicial;
- packaging Linux;
- CI Xvfb.

### Gate

A mesma gallery usada no Windows roda sem condicionais nos widgets.

Requisitos:

- clipboard grande/INCR;
- multi-monitor;
- keyboard layout;
- input repeat;
- XWayland;
- leak loop;
- CPU idle.

---

## Fase 9 — Backend AppKit CPU

### Estado auditado em 2026-08-09

- o spike arm64 das três estratégias permanece verde no
  [GitHub Actions #31341132992](https://github.com/insinfo/dart_ui/actions/runs/31341132992):
  SkyLight e `appkitSignal` passaram janela, pixels, input e teardown sem sinal
  fatal;
- o LLDB confirmou que `CFRunLoopStop` + `CFRunLoopWakeUp` devolve a thread
  sequestrada de `CFRunLoopRun` para `Dart_RunLoop`, mas isso não torna a
  entrada por signal async-signal-safe;
- em `lib`, `appkitNativeHost` está ligado a `MacosWindow.open` e inclui host
  Objective-C protocolo v4 + script de build; compilação, criação/attach da
  janela e IOSurfaces e teardown passaram no runner `macos-14` arm64 no
  [GitHub Actions #31343965371](https://github.com/insinfo/dart_ui/actions/runs/31343965371);
- o supervisor possui testes determinísticos de crash/restart, replay de
  estado, preservação/reattach do mesmo pool e esgotamento de tentativas;
- SkyLight e `appkitSignal` continuam indisponíveis para seleção de produção
  até que suas implementações saiam dos POCs;
- a seleção exige opt-in privado + ABI validada para SkyLight, e pedido
  explícito + opt-in inseguro para `appkitSignal`; nenhum dos dois entra como
  fallback silencioso;
- o gate desta fase ainda está aberto: faltam gallery, Intel, IME, clipboard,
  drag, menus, diálogos, tema, acessibilidade e packaging.

### Estado auditado em 2026-08-23

O quadro de 09/08 continua valendo, e vale acrescentar o que o backend macOS
**não** tem, medido contra os portes que as outras plataformas ganharam desde
então: **sem drag-and-drop** (não implementa `DragDropProvider`), **sem
clipboard** (não implementa `ClipboardProvider`), **sem IME** (não implementa
`TextInputProvider`). As APIs de SO da §56.1 existem no macOS por
`osascript`/`open`/movimento para `~/.Trash`, **sem vincular AppKit ou
Foundation** — `NSSearchPathForDirectoriesInDomains`, `NSOpenPanel` e
`trashItemAtURL` não estão vinculados, e os arquivos dizem isso por escrito.

### Objetivo

Provar o caminho Objective-C puro.

### Spikes prévios

- `objc_msgSend`;
- register class;
- delegate;
- NSView events;
- NSTextInputClient;
- autorelease;
- app bundle.

### Trabalho

- application;
- window;
- view;
- loop;
- Core Graphics/bitmap;
- Retina;
- mouse/trackpad;
- keyboard;
- IME;
- clipboard;
- drag;
- menus;
- dialogs;
- theme;
- accessibility;
- packaging.

### Gate

A mesma gallery roda em macOS Intel/Apple Silicon, com VoiceOver básico e composição de texto.

Se subclasses ObjC por callback FFI forem instáveis, registrar limitação objetiva e reavaliar a restrição sem esconder o problema.

---

## Fase 10 — Direct2D/D3D11/DXGI

### Estado auditado em 2026-08-23 — gate fechado, com ressalvas nomeadas

- **D3D11 com COM em Dart puro, swapchain DXGI e paridade com a CPU** está
  entregue e é o **primeiro caminho tentado no Windows** pelo seletor;
- **Direct2D** está entregue e é escolhível (§13.12). O caminho de texto foi
  medido e reescrito em 2026-08-24 — atlas de glifos único mais
  `ID2D1SpriteBatch`, 4–5× mais rápido, paridade alinhada ainda em desvio 0 —
  e a conclusão sobre DirectWrite está fechada:
  **o lote fecha a diferença de desempenho sem ela**, então ela existe apenas
  como **opção explícita de aparência nativa**
  (`GlyphRasterization.platformNative`), desligada por padrão e em nível 1 (só
  rasterização; métricas e layout continuam em Dart). Ver
  `doc/architecture/TEXTO_DIRECT2D.md`. Correção ao plano original:
  **DirectWrite não é o caminho padrão**. Os glifos vêm do
  `GlyphCache` compartilhado e são compostos com `FillOpacityMask`, o que
  atende à *Regra de texto* desta fase de forma mais forte do que consumir
  glyph runs pela DirectWrite;
- **D3D12** também existe, com fence, barreiras e paridade zero, e hospeda o
  **primeiro executor de compute tiles** do projeto (§23.13). **Não está no
  seletor**;
- **device loss** deixou de ser lacuna: `gpu_recovery.dart` é o orquestrador,
  chamado por GL e D3D11;
- **fallback GDI** existe e é o último da fila no Windows;
- **DirectComposition não existe** e não foi começada;
- ressalvas abertas do gate: `sem COM leak` e `scroll fluido` não foram
  medidos; `render sem readback` vale para GL e D3D11 com janela, e **não** vale
  para Metal, que só faz readback.
### Objetivo

Primeiro renderer GPU de produção.

### Trabalho

- COM generator;
- D3D11 device;
- DXGI;
- swapchain;
- D2D device/context;
- DirectWrite opcional, e **entregue** exatamente assim: opção pública
  `GlyphRasterization.platformNative`, nível 1, desligada por padrão
  (`doc/architecture/TEXTO_DIRECT2D.md`);
- mappings de DisplayList;
- caches;
- clips;
- layers;
- text;
- images;
- gradients;
- resize;
- present;
- device loss;
- diagnostics;
- GPU validation;
- benchmark.

### Regra de texto

Mesmo que DirectWrite desenhe glyphs, o layout/shaping canônico permanece em Dart. DirectWrite pode consumir glyph runs.

### Gate

- gallery;
- SVG corpus;
- text editor;
- parity visual;
- device loss;
- fallback GDI;
- sem COM leak;
- scroll fluido;
- render sem readback.

---

## Fase 11 — OpenGL/EGL

### Estado auditado em 2026-08-23

- o backend GL é hoje o **mais completo** do projeto: janela por
  `GlWindowTarget` (swap de buffers, sem readback por frame), atlas de máscara,
  **atlas de glifos ligado**, pilha de layers, pool de framebuffers, gradientes
  e recuperação de device;
- é também o **único** backend com as abordagens B (tesselação retida) e C
  (stencil-then-cover), e o único onde **sparse strips estão promovidas** — a
  política `auto` é o padrão;
- os attachments e o sample count do render pass entraram no descriptor, e por
  causa disso a escolha entre A, sparse, B e C passou a ser **automática no
  replay**: o seletor lê o que o framebuffer daquele pass realmente carrega, em
  vez de uma hipótese global;
- **EGL no X11 nunca foi executado.** A entrada existe no seletor e o teste
  correspondente diz por escrito "has never been executed - this suite runs on
  Windows". No Wayland não há EGL nenhum (§16.12);
- o gate desta fase perguntava se a abstração exigiria hacks por comando em
  todos os backends antes de Metal/Vulkan. A resposta medida foi **não** — GL,
  D3D11, D3D12, WebGL2 e WebGPU compartilham `GpuRasterSink`, batches, atlas e
  layers — mas o preço apareceu em outro lugar: o **seletor de estratégia
  vetorial** precisa de capacidades por backend, e é lá que a divergência entre
  eles fica visível (§23.13).
### Objetivo

Segundo renderer GPU, validando abstração.

### Trabalho

- GL loader;
- contexts;
- EGL X11;
- shader compiler;
- pipeline 2D;
- atlas;
- batching;
- clipping;
- offscreen;
- present;
- context loss;
- capability fallback;
- debug labels;
- benchmark.

### Gate

Se a abstração exigir hacks específicos em todos os comandos, revisar `RendererBackend` antes de Metal/Vulkan.

---

## Fase 12 — Metal

### Estado auditado em 2026-08-23 — gate aberto

Existe um backend Metal real, validado em CI Apple Silicon: runtime
Objective-C próprio, `MTLCreateSystemDefaultDevice`, MSL compilada de verdade
por `newLibraryWithSource:options:error:`, um `MTLRenderPipelineState` por modo
de blend, passe offscreen, leitura de volta e paridade medida contra a CPU.

E, apesar disso, **o gate está aberto por um item só, que vale por todos**:
**não há apresentação**. Sem `CAMetalLayer`, sem drawable, sem janela; e sem
atlas de máscara, sem atlas de glifos e sem pilha de layers, então path, rrect,
texto e layer são **recusados por nome**. O probe diz a verdade sobre isso — ele
anuncia `cpuPresentation`, não `gpuPresentation`. Ver §21.6, inclusive para a
ausência de MSL no porte sparse.
### Objetivo

Renderer nativo macOS de produção.

### Trabalho

- bindings;
- CAMetalLayer;
- device/queue;
- drawable;
- shaders;
- pipelines;
- buffers;
- textures;
- atlas;
- clipping;
- layers;
- synchronization;
- frame scheduling;
- resource cache;
- device errors;
- fallback CPU.

### Gate

- Retina;
- multiple windows;
- text;
- clips;
- resize;
- minimized/occluded;
- no retain leak;
- parity;
- notarized sample.

---

## Fase 13 — Wayland CPU

### Estado auditado em 2026-08-23 — quase tudo feito, e nada executado

O trabalho desta fase está, em sua maior parte, **feito**, e por um caminho que
o roteiro não previa: **sem `libwayland`, sem `xkbcommon` e sem gerador de
XML**. O §16.0 lista o que existe e o §16.14 marca item a item.

O gate, porém, **não pode ser fechado**, e não por falta de código:

- **Weston, GNOME, KDE e wlroots**: nenhum. Este backend **nunca falou com um
  compositor real**. Toda a suíte roda contra um compositor falso em memória, e
  a camada FFI (`sendmsg`/`recvmsg`/`SCM_RIGHTS`/`memfd`) **não tem cobertura
  automatizada nenhuma**;
- **IME**: feito (`text-input-v3`, com a ordem de aplicação do protocolo);
- **clipboard**: feito, texto apenas;
- **popup correto**: feito, com `xdg_positioner` completo;
- **sem reuso precoce de buffer**: feito, e a exaustão do swapchain é
  **contada** em vez de silenciosa;
- **sem deadlock**: provado contra o falso, incluindo o curto-circuito de
  clipboard;
- **gallery CPU**: não verificado.

Itens do *Trabalho* que **não** foram feitos: touch, escala fracionária,
portais, AT-SPI, e decoração — a negociação existe, o desenho não.
### Objetivo

Janela Wayland correta antes de GPU.

### Trabalho

- XML codegen;
- core;
- registry;
- xdg-shell;
- configure;
- shm pool/buffers;
- frame callbacks;
- seat;
- xkb;
- pointer/touch;
- clipboard;
- DnD;
- text-input-v3;
- scale;
- popups;
- decorations;
- portals;
- AT-SPI.

### Gate

- Weston;
- GNOME;
- KDE;
- wlroots;
- no deadlock;
- no buffer reuse early;
- popup correto;
- IME;
- clipboard;
- gallery CPU.

---

## Fase 14 — Vulkan

### Estado auditado em 2026-08-23 — em voo, e a árvore não compila

- **bindings, loader, instance, device, queues, memória, pipelines, descriptors
  e command buffers** existem, e os **shader assets são emitidos em Dart**:
  `SpirvBuilder` é um codificador binário de SPIR-V, não um blob;
- **as três surfaces** do gate estão escritas — Win32, XCB/Xlib e Wayland —,
  mas a de Wayland **não tem como ser usada** por este projeto: ela exige um
  `wl_display*` que um backend sem `libwayland` não possui (§16.12);
- **swapchain** com `oldSwapchain`, out-of-date e suboptimal: feito;
- **validação: não provada aqui**, porque a layer não está instalada nesta
  máquina — ver §19.4, que é o lugar onde essa distinção está registrada;
- **o que trava hoje**: dois arquivos de teste desta frente **não compilam**;
- **fallback e benchmark contra D2D/OpenGL**: não feitos. E a última linha do
  gate — "não promover a default se não houver ganho/estabilidade" — está
  cumprida por omissão: Vulkan **não está no seletor**.
### Objetivo

Renderer moderno comum a Windows/Linux e potencialmente macOS apenas via camada externa opcional, não obrigatória.

### Trabalho

- bindings;
- loader;
- instance;
- surfaces Win32/XCB/Wayland;
- device;
- queues;
- memory;
- swapchain;
- pipelines;
- descriptors;
- shader assets;
- command buffers;
- sync;
- atlas;
- clips;
- layers;
- incremental present;
- device loss;
- cache;
- validation.

### Gate

- três surfaces;
- resize;
- multi-window;
- zero validation errors;
- fallback;
- benchmark real contra D2D/OpenGL;
- não promover a default se não houver ganho/estabilidade.

---

## Fase 15 — GTK e integração de desktop

### Objetivo

Completar integrações que variam por ambiente sem substituir widgets Dart.

### Trabalho

- GObject core;
- GLib main context;
- GTK 4 probe;
- dialogs;
- theme;
- icon theme;
- portal fallback;
- notifications;
- system tray conforme ambiente;
- hosting opcional de native view;
- comparison harness.

### Gate

GTK permanece opcional. Remover `libgtk` não impede X11/Wayland básico.

---

## Fase 16 — Acessibilidade profissional

### Objetivo

Elevar adaptadores básicos a conformidade prática.

### Trabalho comum

- semantics diff;
- relationships;
- text ranges;
- virtualized children;
- live regions;
- headings;
- tables/grids;
- selection;
- range;
- focus;
- automation actions.

### Windows

- UIA patterns;
- notifications;
- text provider;
- fragment navigation;
- offscreen.

### Linux

- AT-SPI interfaces;
- D-Bus;
- events;
- text;
- table;
- collection.

### macOS

- attributes;
- actions;
- notifications;
- text;
- rotor/relationships quando aplicável.

### Gate

- Narrator;
- NVDA opcional;
- Orca;
- VoiceOver;
- keyboard;
- automated semantics suite;
- accessibility gallery.

---

## Fase 17 — Hardening, performance e release

### Objetivo

Transformar protótipos em framework consumível.

### Trabalho

- API review;
- documentation;
- migration;
- deprecations;
- fuzzing contínuo;
- leak suites;
- stress;
- performance;
- startup;
- memory;
- package sizes;
- crash diagnostics;
- security review;
- license audit;
- sample apps;
- installers/bundles;
- release channels;
- support policy;
- issue triage;
- contributor docs.

### Gate 1.0

Estado em 2026-08-23, medido contra os critérios de promoção da §50.

- [~] **backend CPU estável nas três plataformas** — Windows sim; X11 validado
  sob Xvfb; macOS validado em CI; Wayland **nunca executado de verdade**;
- [~] **ao menos D2D e Metal estáveis** — D2D está em *alpha/beta* (existe,
  escolhível, com recusas nomeadas); **Metal não apresenta**, então não passa
  nem de *experimental* por este critério;
- [ ] **Linux GPU estável por OpenGL ou Vulkan** — o caminho EGL no X11 nunca
  rodou e o Wayland não tem GPU;
- [~] **X11 estável** — teclado e clipboard entraram em 26/08/2026, mas
  **nenhum dos dois rodou contra um X server real** e o backend segue sem IME e
  sem acessibilidade; não passa de *beta* pela evidência (§68.1);
- [~] **Wayland ao menos beta com CPU** — o código está em nível de beta e a
  evidência não: a §50 exige *gallery, clipboard, IME, resize/DPI, packaging,
  leak suite* e nada disso foi exercido contra um compositor;
- [~] **widgets e texto estáveis** — os controles estão amplos (§29.2); o texto
  tem lacunas nomeadas (bidi no caret, fallback, CFF hinting, multilinha);
- [ ] **acessibilidade básica funcional** — só a ponte UIA no Windows, e
  parcial; nada em X11, Wayland ou web;
- [ ] sem leaks conhecidos críticos — não medido;
- [x] CI multi-plataforma;
- [x] **documentação de limitações** — §68 e
  [`architecture/overview.md`](architecture/overview.md#estado-executivo--23-de-agosto-de-2026);
- [x] **nenhuma dependência de wrapper nativo próprio** — mantido, e o backend
  Wayland é a prova mais forte disso até aqui. A exceção conhecida continua
  sendo o host Objective-C do macOS, que tem ADR (0001).

---

# 46. Ordem crítica de implementação

```text
F0 inventário/licença
  ↓
F1 foundation/contratos
  ↓
F2 headless/scheduler
  ↓
F3 renderer CPU
  ↓
F4 Win32 spike
  ↓
F5 Win32 vertical slice
  ↓
F6 widgets
  ↓
F7 texto/IME
  ├───────────────┬─────────────────┐
  ↓               ↓                 ↓
F8 X11 CPU       F9 AppKit CPU     F10 D2D
  ↓               ↓                 ↓
F11 OpenGL       F12 Metal          performance baseline
  ↓
F13 Wayland CPU
  ↓
F14 Vulkan
  ↓
F15 GTK integration
  ↓
F16 accessibility completeness
  ↓
F17 release
```

## 46.0 A ordem que realmente aconteceu (registro de 2026-08-23)

O diagrama acima é a ordem pretendida. A executada foi outra, e registrá-la é o
que permite avaliar se o desvio valeu a pena:

```text
F0..F7 na ordem prevista, com F7 fechando o IME do Windows
  │
  ├─ F10 D2D/D3D11/D3D12 ─── entregues; D3D12 fora do seletor
  ├─ F11 OpenGL ──────────── o backend mais completo; EGL no X11 nunca rodou
  ├─ F12 Metal ───────────── offscreen apenas, sem apresentação
  ├─ F13 Wayland ─────────── quase completo em código, zero execução real
  ├─ F14 Vulkan ──────────── SPIR-V em Dart; WSI em voo, testes não compilam
  ├─ web ─────────────────── WebGL2 + WebGPU, fora de qualquer fase
  ├─ APIs de SO + DnD ────── fora de qualquer fase (§56.1)
  └─ PDF/CDR/vetorial ────── fora de qualquer fase (§4.4)
  │
  F8 X11 ─── teclado e clipboard entraram em 26/08/2026; restam IME e a11y
```

Duas conclusões que o desvio sustenta, e uma que ele não sustenta:

- **sustenta** que a abstração de renderer aguentou seis APIs sem virar um
  "Vulkan disfarçado" (§19.1) — GL, D3D11, D3D12, Metal, Vulkan, WebGL2 e
  WebGPU compartilham sink, batches e atlas;
- **sustenta** que abrir uma frente nova é mais barato do que terminar uma —
  e é exatamente por isso que existem hoje quatro subsistemas completos sem
  consumidor (§68);
- **não sustenta** que paralelizar backends cedo tenha sido seguro. A §46.1
  dizia que não era, e o preço não veio em arquitetura duplicada — veio em
  evidência: o backend mais bem escrito do projeto nunca falou com o sistema
  que ele implementa.

## 46.1 Trabalho paralelo seguro

Pode ocorrer em paralelo:

- bindings e testes ABI;
- parser OpenType;
- headless widgets;
- inventory/licensing;
- shader tooling;
- goldens;
- documentation;
- accessibility semantics.

Não é seguro paralelizar cedo:

- três modelos diferentes de widget;
- três DisplayLists;
- backends GPU antes do contrato;
- três sistemas de texto;
- cópias independentes de geometria;
- Xlib e XCB completos simultaneamente.

---

# 47. Primeiros marcos executáveis

## Marco A — “Janela vazia”

- Win32;
- fundo sólido;
- resize;
- close;
- AOT.

## Marco B — “Pixel Dart”

- DIB;
- buffer desenhado por Dart;
- dirty rect.

## Marco C — “Botão Dart”

- layout;
- hit-test;
- hover/press;
- click;
- texto;
- foco.

## Marco D — “Uma aplicação”

- estado;
- vários controles;
- scroll;
- tema;
- clipboard;
- text field.

## Marco E — “Mesmo código, X11”

- nenhuma mudança na aplicação;
- apenas backend diferente.

## Marco F — “Mesmo código, macOS”

- AppKit puro por FFI;
- Retina;
- IME.

## Marco G — “GPU”

- Direct2D;
- scene/display list invariantes.

## Marco H — “Linux moderno”

- Wayland;
- OpenGL/Vulkan.

---

# 48. Plano dos primeiros commits

## Commit 1 — Estrutura

- license;
- readme;
- roadmap;
- analysis options;
- CI;
- packages mínimos.

## Commit 2 — Foundation

- geometry;
- IDs;
- lifetime;
- diagnostics;
- tests.

## Commit 3 — Graphics API

- color;
- path;
- paint;
- display list;
- serializer;
- tests.

## Commit 4 — Headless

- fake dispatcher;
- window;
- framebuffer;
- golden.

## Commit 5 — CPU adapter

- `dart_graphics` adapter;
- rectangle;
- path;
- image.

## Commit 6 — Win32 raw

- loader;
- constants;
- structs;
- functions;
- ABI tests.

## Commit 7 — Win32 window

- WndProc;
- registry;
- loop;
- close.

## Commit 8 — GDI surface

- DIB;
- present;
- resize.

## Commit 9 — Input

- mouse;
- keyboard;
- focus.

## Commit 10 — Button vertical slice

- widgets;
- layout;
- paint;
- click;
- semantics.

Cada commit deve compilar e testar. Não acumular um “mega port”.

---

# 49. Backlog técnico por domínio

## 49.1 Foundation

- [ ] monotonic clock;
- [ ] arena;
- [ ] pooled list;
- [ ] generational IDs;
- [ ] diagnostics;
- [ ] trace;
- [ ] cancellation;
- [ ] lifecycle;
- [ ] capability registry;
- [ ] immutable value types.

## 49.2 Platform

- [ ] selection;
- [ ] initialization;
- [ ] event loop;
- [ ] windows;
- [ ] monitors;
- [ ] theme;
- [ ] clipboard;
- [ ] drag;
- [ ] IME;
- [ ] cursor;
- [ ] dialogs;
- [ ] accessibility;
- [ ] shutdown.

## 49.3 Rendering

- [ ] DisplayList;
- [ ] resources;
- [ ] CPU;
- [ ] damage;
- [ ] layers;
- [ ] images;
- [ ] text;
- [ ] D2D;
- [ ] GL;
- [ ] Metal;
- [ ] Vulkan;
- [ ] device recovery.

## 49.4 Widgets

- [ ] lifecycle;
- [ ] reconciliation;
- [ ] properties;
- [ ] binding;
- [ ] layout;
- [ ] painting;
- [ ] hit-test;
- [ ] events;
- [ ] focus;
- [ ] styles;
- [ ] templates;
- [ ] controls;
- [ ] virtualization;
- [ ] semantics.

## 49.5 Text

- [ ] parser;
- [ ] shaping;
- [ ] bidi;
- [ ] fallback;
- [ ] line break;
- [ ] glyph raster;
- [ ] atlas;
- [ ] editing;
- [ ] IME;
- [ ] accessibility ranges.

---

# 50. Critérios para promover backends

## Experimental

- cria janela;
- exemplo básico;
- crashes podem existir;
- API interna instável.

## Alpha

- input básico;
- CPU/GPU básico;
- testes smoke;
- limitações documentadas.

## Beta

- gallery;
- clipboard;
- IME;
- resize/DPI;
- packaging;
- leak suite;
- acessibilidade básica.

## Estável

- conformance suite;
- stress;
- recuperação;
- suporte de arquiteturas;
- documentação;
- compatibilidade;
- sem problemas críticos conhecidos.

---

# 51. Política de não regressão

Antes de reverter ou trocar algoritmo:

1. reproduzir em build controlado;
2. executar pelo menos dez vezes;
3. comparar mediana/faixa;
4. comparar saída visual;
5. registrar hardware;
6. verificar alocações;
7. verificar outros backends;
8. abrir ADR/issue;
9. manter benchmark;
10. só então decidir.

Essa política preserva o aprendizado acumulado em `marlin`.

---


# 52. Mapeamento de arquivos do bootstrap

## 52.1 `dart_ui_foundation`

```text
lib/
├── dart_ui_foundation.dart
└── src/
    ├── diagnostics/
    │   ├── diagnostic.dart
    │   ├── diagnostic_node.dart
    │   ├── error_reporter.dart
    │   └── trace_event.dart
    ├── lifecycle/
    │   ├── disposable.dart
    │   ├── lifetime.dart
    │   ├── native_resource.dart
    │   └── resource_tracker.dart
    ├── scheduling/
    │   ├── clock.dart
    │   ├── priority.dart
    │   └── cancellation.dart
    ├── collections/
    │   ├── pooled_list.dart
    │   ├── small_vector.dart
    │   └── generational_table.dart
    └── ids/
        ├── generational_id.dart
        └── id_allocator.dart
```

## 52.2 `dart_ui_geometry`

```text
lib/src/
├── point.dart
├── offset.dart
├── size.dart
├── rect.dart
├── insets.dart
├── rounded_rect.dart
├── constraints.dart
├── matrix.dart
├── region.dart
├── path.dart
├── path_builder.dart
└── path_metrics.dart
```

## 52.3 `dart_ui_graphics_api`

```text
lib/src/
├── color.dart
├── color_space.dart
├── pixel_format.dart
├── blend_mode.dart
├── paint.dart
├── stroke.dart
├── gradient.dart
├── image.dart
├── glyph_run.dart
├── display_list/
│   ├── opcodes.dart
│   ├── builder.dart
│   ├── reader.dart
│   ├── resources.dart
│   ├── validator.dart
│   └── debug_dump.dart
└── renderer/
    ├── backend.dart
    ├── capabilities.dart
    ├── device.dart
    ├── target.dart
    ├── frame.dart
    └── surface.dart
```

## 52.4 `dart_ui_platform`

```text
lib/src/
├── platform_backend.dart
├── platform_selector.dart
├── capabilities.dart
├── dispatcher.dart
├── windowing.dart
├── window.dart
├── window_options.dart
├── window_event.dart
├── native_handle.dart
├── surface_descriptor.dart
├── input_backend.dart
├── text_input_backend.dart
├── clipboard_backend.dart
├── drag_drop_backend.dart
├── accessibility_backend.dart
├── theme_backend.dart
├── screen.dart
└── diagnostics.dart
```

## 52.5 `dart_ui`

```text
lib/src/
├── application.dart
├── binding/
├── widgets/
│   ├── widget.dart
│   ├── element.dart
│   ├── state.dart
│   ├── key.dart
│   ├── build_owner.dart
│   └── context.dart
├── rendering/
│   ├── render_object.dart
│   ├── render_box.dart
│   ├── pipeline_owner.dart
│   ├── paint_context.dart
│   └── hit_test.dart
├── layout/
├── input/
├── focus/
├── styles/
├── templates/
├── controls/
├── semantics/
├── animation/
└── text/
```

## 52.6 `dart_ui_backend_win32`

```text
lib/src/
├── raw/
│   └── reexports.dart
├── platform/
│   ├── platform.dart
│   ├── dispatcher.dart
│   └── capabilities.dart
├── window/
│   ├── window.dart
│   ├── window_class.dart
│   ├── registry.dart
│   ├── wnd_proc.dart
│   ├── chrome.dart
│   └── dpi.dart
├── input/
├── services/
├── surfaces/
│   ├── gdi_surface.dart
│   ├── hwnd_surface.dart
│   └── dxgi_surface.dart
└── diagnostics/
```

## 52.7 Testes espelhados

A estrutura de `test/` deve espelhar `lib/src/`. Arquivo nativo sem teste de ABI não é aceito.

---

# 53. API pública proposta

## 53.1 Hello world

```dart
import 'package:dart_ui/dart_ui.dart';

Future<void> main() async {
  await DartUi.run(
    config: const DartUiConfig(),
    builder: () => const ApplicationRoot(
      child: Center(
        child: Text('Olá, Dart UI!'),
      ),
    ),
  );
}
```

## 53.2 Estado

```dart
final class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

final class _CounterPageState extends State<CounterPage> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      spacing: 12,
      children: [
        Text('Cliques: $count'),
        Button(
          onPressed: () => setState(() => count++),
          child: const Text('Adicionar'),
        ),
      ],
    );
  }
}
```

Essa API é ilustrativa. O ADR de widgets decidirá nomes finais.

## 53.3 Configuração de backend

```dart
const DartUiConfig(
  platform: PlatformPreference.auto,
  rendererPreferences: {
    OperatingSystem.windows: [
      RendererKind.direct2d,
      RendererKind.cpu,
    ],
    OperatingSystem.linux: [
      RendererKind.vulkan,
      RendererKind.opengl,
      RendererKind.cpu,
    ],
    OperatingSystem.macos: [
      RendererKind.metal,
      RendererKind.cpu,
    ],
  },
  diagnostics: DiagnosticsConfig(
    logBackendSelection: true,
    trackNativeResources: true,
  ),
);
```

## 53.4 Janela

```dart
Window(
  title: 'Editor',
  initialSize: const Size(1280, 800),
  minSize: const Size(640, 480),
  themeMode: ThemeMode.system,
  child: const EditorPage(),
)
```

## 53.5 Canvas

```dart
final class CustomPainter extends RenderBox {
  @override
  void paint(PaintContext context, Offset offset) {
    context.canvas.drawRoundedRect(
      RoundedRect.fromRectAndRadius(
        offset & size,
        const Radius.circular(8),
      ),
      Paint.fill(const Color(0xff356ae6)),
    );
  }
}
```

---

# 54. Cenários de conformidade obrigatórios

## 54.1 Janela

- criação e destruição;
- múltiplas;
- owner;
- modal;
- resize;
- min/max;
- fullscreen;
- minimize/restore;
- DPI;
- monitor disconnect;
- focus;
- close cancelado;
- title Unicode.

## 54.2 Input

- mouse;
- touch;
- pen;
- wheel;
- smooth scroll;
- capture;
- focus;
- key repeat;
- layout internacional;
- AltGr;
- Command;
- dead key;
- IME;
- drag.

## 54.3 Layout

- constraints infinitas;
- zero;
- negative invalid;
- nested flex;
- grid spans;
- baseline;
- text wrap;
- scroll;
- virtualization;
- transform;
- scale.

## 54.4 Render

- alpha;
- clips;
- paths;
- gradients;
- images;
- text;
- blend;
- layers;
- partial damage;
- scale;
- device loss;
- color formats.

## 54.5 Texto

- Latin;
- combining marks;
- ligatures;
- Arabic;
- Hebrew;
- Indic;
- CJK;
- emoji;
- bidi;
- multiline;
- selection;
- clipboard;
- composition.

## 54.6 Acessibilidade

- button;
- checkbox;
- text field;
- list;
- tree;
- table;
- dialog;
- focus;
- disabled;
- live region;
- value;
- text range;
- virtualized item.

---

# 55. Matriz de capacidades por backend

Legenda: **M** obrigatório, **P** posterior, **N/A** não aplicável.

| Capacidade | Win32 | X11 | Wayland | GTK opcional | AppKit |
|---|---:|---:|---:|---:|---:|
| janela | M | M | M | P | M |
| DPI/scale | M | M | M | P | M |
| mouse | M | M | M | P | M |
| touch | P/M | P/M | M | P | P/M |
| pen | P | P | P | P | P |
| teclado | M | M | M | P | M |
| IME | M | M | M | P | M |
| clipboard | M | M | M | P | M |
| drag-and-drop | M | M | M | P | M |
| popups | M | M | M | P | M |
| tray | P | P | P/portal | P | P |
| file dialogs | M | portal/P | portal/M | P | M |
| accessibility | M | AT-SPI | AT-SPI | AT-SPI | M |
| CPU | GDI | SHM | wl_shm | N/A | Core Graphics |
| OpenGL | P | M/P | M/P | P | legado |
| Vulkan | P | P | P | N/A | N/A |
| Direct2D | M | N/A | N/A | N/A | N/A |
| Metal | N/A | N/A | N/A | N/A | M |

## 55.1 Matriz de capacidades **medida** em 2026-08-23

A tabela acima diz o que é obrigatório. Esta diz o que existe, lida direto dos
conjuntos `Capability` que cada probe devolve e do código por trás deles.
Legenda: **sim**, **parcial** (com o limite nomeado), **não**, **—** não se
aplica, **?** não verificado.

| Capacidade | Win32 | X11 | Wayland | AppKit | Web | Headless |
|---|---|---|---|---|---|---|
| `window` | sim | sim | sim | sim | sim | sim |
| `multipleWindows` | sim | sim | sim | ? | sim (várias canvas) | sim |
| `cpuPresentation` | sim (DIB) | sim (`PutImage`, se o formato do servidor bate) | sim (`wl_shm`) | sim | — | sim |
| `gpuPresentation` | sim (D3D11, GL, D2D) | não (entrada EGL nunca executada) | **não** | não (Metal só offscreen) | sim (WebGL2/WebGPU) | — |
| `partialPresent` | sim | ? | sim | ? | ? | ? |
| `vsync` | **não reivindicada** — o `BitBlt` não é paced, ainda que o DWM componha no vblank | ? | ? | ? | ? | — |
| `pointerInput` | sim | sim | sim | sim | ? | sim |
| `scrollInput` | ? (roda normalizada) | sim | sim | sim | ? | sim |
| **`keyboardInput`** | sim | sim desde 26/08/2026 (core protocol: dois grupos, sem `DetectableAutoRepeat`) | sim (subconjunto xkb) | sim | ? | sim |
| **`textComposition`** | sim, se `imm32` carrega | **não** (XIM não implementado; teclas mortas funcionam e não são IME) | sim, se o compositor anuncia v3 | não | não | não |
| `clipboardText` | sim | sim desde 26/08/2026 (selections; **sem dono INCR**, sem `PRIMARY`) | sim | não | não | sim (falso) |
| `clipboardImage` | **não em plataforma nenhuma** — o contrato `Clipboard` é só texto | não | não | não | não | não |
| `dragAndDrop` | sim (OLE, dois sentidos; **imagem de arraste ignorada**) | sim (XDND, dois sentidos; **imagem ignorada**) | sim (dois sentidos; **imagem ignorada**, **sem `link`**) | não | não | não |
| `perMonitorDpi` | sim | parcial (escala do probe) | parcial (inteira, a maior dos outputs) | ? | sim | sim |
| `orderlyShutdown` | sim | sim | sim | sim (provado no spike) | ? | sim |
| `accessibility` | **não reivindicada** — ponte UIA parcial | não | não | **não** — `hasAccessibility: false` nos três kinds, "not wired yet" | não | não |
| touch | não | não | **não** (`wl_touch` nunca vinculado) | não | ? | — |
| pen / tablet | não | não | não | não | não | — |
| popups | sim | sim | sim (`xdg_positioner`) | ? | — | sim |
| tray / notificações | não | não | não | não | não | — |
| decoração quando o compositor recusa SSD | — | — | **não desenha CSD** | — | — | — |

A **árvore semântica** do framework existe, é testada e não aparece na tabela
de propósito: ela é da camada comum, não uma capacidade de backend. O que a
linha `accessibility` mede é se alguém a **expõe ao sistema operacional**, e
hoje **nenhum backend reivindica essa capacidade** — nem o macOS, cujos três
kinds trazem `hasAccessibility: false` com o comentário "not wired yet".

Cinco leituras que essa tabela deixa claras, e que a normativa esconde:

1. ~~**X11 é o único backend de desktop sem teclado**, e sem clipboard.~~
   Deixou de ser em 26/08/2026: os dois entraram pelo core protocol (§68.1). O
   que resta faltando só no X11 entre os backends de desktop é o **IME**;
2. **drag-and-drop chegou nos três backends de desktop antes de clipboard e IME
   chegarem em dois deles** — foi a única capacidade portada em bloco;
3. **`clipboardImage` não existe em lugar nenhum**: o contrato é texto, por
   decisão registrada, e a matriz normativa que pede "clipboard de imagens
   básicas" na §4.1 está descrevendo trabalho não começado;
4. **`vsync` não é reivindicada por ninguém**, o que é honesto e vale manter:
   o `BitBlt` não é paced, e o `PresentMode` só tem `fifo`/`immediate` reais no
   WGL e no GDI;
5. **acessibilidade é a linha mais vazia da tabela**, e é requisito de Gate 1.0.

---

# 56. Matriz de APIs nativas e ownership

| API | Tipo de recurso | Liberação |
|---|---|---|
| Win32 HWND | handle | `DestroyWindow` |
| HDC obtido por `GetDC` | borrowed/acquired | `ReleaseDC` |
| HDC criado | owned | `DeleteDC` |
| GDI object | owned | `DeleteObject` |
| COM interface | ref-counted | `Release` |
| XCB reply | allocated | `free` |
| XCB connection | owned | `xcb_disconnect` |
| Wayland proxy | protocol object | destroy request ou `wl_proxy_destroy` conforme contrato |
| `wl_buffer` | protocol object | após release/destroy |
| GL object | context-owned | `glDelete*` |
| Vulkan object | device/instance-owned | `vkDestroy*` |
| GObject | ref-counted | `g_object_unref` |
| ObjC object | ref-counted/autorelease | `release`/pool |
| CFType | ref-counted | `CFRelease` |
| Metal object | ObjC ref-counted | `release` |
| native allocation | heap | allocator correspondente |

Cada wrapper precisa declarar a linha correspondente em documentação.

**Linhas acrescentadas em 2026-08-23**, todas em uso:

| API | Tipo de recurso | Liberação |
|---|---|---|
| `wl_shm_pool` / `wl_buffer` sobre `memfd` | fd + mapeamento | `munmap`, `close`, e destruição **adiada** até `wl_buffer.release` |
| fd recebido por `SCM_RIGHTS` | fd | `close` — o keymap é mapeado `MAP_PRIVATE`, copiado e fechado |
| socket `AF_UNIX` e self-pipe (`pipe2`) | fds | `close` |
| `ID2D1Factory`/`RenderTarget`/`Layer`/`Brush`/`Geometry` | COM ref-counted | `Release`, com pools por profundidade de layer e caches com limite |
| `IDataObject`/`IDropSource`/`IDropTarget` | COM ref-counted | `Release`; `RevokeDragDrop` e `OleUninitialize` no teardown |
| `HIMC` de `ImmGetContext` | borrowed | `ImmReleaseContext` |
| `PIDLIST`/string de `SHGetKnownFolderPath` | alocada pelo shell | `CoTaskMemFree` |
| `VkInstance`/`VkDevice`/`VkSwapchainKHR`/`VkSemaphore` | device/instance-owned | `vkDestroy*`, com `oldSwapchain` na recriação |
| blob compilado por `D3DCompile` | COM ref-counted | `Release` |

## 56.1 APIs de sistema operacional — porte de 2026-08-23

Sete portes que **nenhuma fase da §45 previa**, todos em `lib/src/platform/`
com o mesmo formato: contrato portátil, implementação por `_platform_io.dart`,
`_platform_web.dart` quando faz sentido, e `_platform_stub.dart` que **lança
uma exceção nomeada** em vez de devolver um no-op. Nenhum usa
`UnimplementedError`: toda recusa é uma exceção tipada carregando plataforma e
motivo.

| Porte | Windows | Linux | macOS | Web |
|---|---|---|---|---|
| `StandardPaths` | `SHGetKnownFolderPath` (shell32) | XDG + `~/.config/user-dirs.dirs` | **só convenção**: `NSSearchPathForDirectoriesInDomains` **não** vinculada | lança |
| `Shell` (abrir URL/arquivo, revelar) | `ShellExecuteW`; revelar por `explorer /select,` | `xdg-open`→`gio`→`kde-open5`; revelar por D-Bus `FileManager1` | `/usr/bin/open`, `open -R` | só `openUrl` |
| `Trash` | `SHFileOperationW` + `FOF_ALLOWUNDO` (**`IFileOperation` foi avaliado e recusado**) | spec freedesktop, **só a lixeira do home** — sem `.Trash-$uid` por volume | move para `~/.Trash`; **`trashItemAtURL` não vinculada**, então "Put Back" se perde | lança |
| `SystemInfo` + tema escuro | `RegGetValueW` em `AppsUseLightTheme` | `gsettings … color-scheme` | `defaults read -g AppleInterfaceStyle` | `matchMedia` |
| `NativeMessageBox` | `MessageBoxW` (**nativa**) | **subprocesso** `zenity`/`kdialog` | `osascript display dialog` | lança — um `alert()` seria mentira |
| `FileWatcher` | `dart:io` → `ReadDirectoryChangesW` | `dart:io` → inotify | `dart:io` → FSEvents | `isSupported == false` |
| `FilePicker` (**só abrir**) | `GetOpenFileNameW` (**não** `IFileDialog`) | **`zenity`/`kdialog`/`yad`** — **sem portal XDG** | `osascript choose file` | `<input type=file>` |

Três avisos que valem mais do que a tabela:

1. **Não existe diálogo de salvar, nem seletor de diretório, nem seleção
   múltipla.** A API de `FilePicker` é `openFile` e mais nada;
2. **Linux não usa portais em lugar nenhum.** A §16.13 pede
   `xdg-desktop-portal` para diálogos e integração, e o que existe é
   subprocesso de helper — o que falha em sandbox, que é justamente o caso que
   o portal resolve;
3. **`system_fonts.dart` importa `dart:io` sem import condicional** e é
   exportado por `lib/dart_ui.dart`; e o próprio arquivo diz que **só os
   caminhos do Windows foram executados**.

### Drag-and-drop, o porte que atravessa três backends

Contrato em `lib/src/platform/drag_drop.dart` (`DropTargetHandler`,
`DragDropBackend`, `DragDropProvider`, `DragData` com variante preguiçosa),
widgets em `lib/src/widgets/drag_drop.dart` (`DropTarget`, `DragSource`,
`DragDropScope`, `DragRouter`), e três implementações — **Win32 por OLE
(`IDropTarget` implementado em Dart mais `DoDragDrop`), X11 por XDND, Wayland
por `wl_data_device`** — todas nos **dois sentidos**. Sem provider, o
`application.dart` devolve `UnavailableDragDrop` nomeando o backend, em vez de
um no-op.

**A imagem de arraste (`DragRequest.feedback`) é ignorada nos três** — no
Wayland por um `TODO` que explica o porquê (o ícone é um `wl_surface` com
buffer shm, e as seams de compositor/shm não estão expostas ao cliente de
drag), em Win32 e X11 por decisão registrada no código. Em todos os casos a
degradação é documentada, não silenciosa. macOS e web não têm o porte.

---

# 57. Estratégia de geração de bindings

## 57.1 Manifests

```yaml
name: win32_user32
source:
  kind: windows_sdk
  version: pinned
libraries:
  - user32.dll
headers:
  - windows.h
symbols:
  include:
    - CreateWindowExW
    - DefWindowProcW
    - DispatchMessageW
overrides:
  - file: overrides/user32.yaml
output:
  raw: lib/src/raw/generated/user32.g.dart
```

## 57.2 Pipeline

1. obter headers/metadata;
2. validar hash;
3. gerar;
4. formatar;
5. aplicar overrides declarativos;
6. produzir relatório;
7. compilar analyzer;
8. executar ABI tests;
9. comparar diff;
10. exigir revisão humana.

## 57.3 Overrides

Usar para:

- macros;
- aliases;
- callback signatures;
- unions;
- bitfields;
- nomes conflitantes;
- métodos COM;
- Objective-C ownership;
- funções variádicas rejeitadas.

Não editar manualmente arquivo gerado.

## 57.4 Wayland

Manifesto inclui XMLs e versões. Gerador produz:

- request methods;
- event listener;
- enums;
- interface descriptors;
- tests de opcode/signature.

## 57.5 Objective-C

Gerar wrappers brutos, mas manter uma camada manual pequena para:

- message variants;
- class registration;
- ownership;
- blocks;
- association com Dart.

---

# 58. Regras de performance Dart

## 58.1 Hot path

Evitar:

- closures por pixel/evento;
- `List<dynamic>`;
- maps por draw;
- string formatting;
- exceptions;
- lookup de symbol;
- alocação de Matrix/Rect;
- polymorphism excessivo no loop interno;
- boxing.

Preferir:

- typed data;
- arrays SoA;
- pools;
- sealed classes fora do hot path;
- dispatch por opcode;
- métodos estáticos/inlinable;
- buffers reutilizados;
- branch specialization;
- cache.

## 58.2 FFI

- agrupar chamadas quando possível;
- não cruzar FFI por pixel;
- não chamar API nativa para cada glyph se puder enviar run;
- usar command buffers;
- manter função ponteiro cacheada;
- medir custo de callback;
- evitar conversão repetida de string;
- usar arena por chamada.

## 58.3 Isolates

Isolate não é thread compartilhando heap. Usar para:

- decode;
- parsing;
- shaping em lote posterior;
- compilation de assets;
- raster offscreen quando dados transferíveis.

Não usar um isolate por widget ou evento.

---

# 59. Erros a evitar

1. começar por Vulkan;
2. criar bindings para toda API antes de usar;
3. usar GTK widgets como núcleo;
4. copiar JavaFX;
5. manter três tipos `Rect`;
6. misturar handles nativos em widgets;
7. usar timer periódico para repaint;
8. repaint total sempre;
9. criar uma thread nativa sem ownership;
10. fechar `NativeCallable` cedo;
11. depender de finalizer;
12. ignorar DPI;
13. tratar keydown como texto;
14. deixar IME para o fim;
15. deixar semântica para o fim;
16. usar fontes do sistema em goldens;
17. otimizar sem benchmark repetido;
18. esconder fallback;
19. engolir `HRESULT`;
20. compartilhar GPU entre isolates sem protocolo;
21. usar FFI variádica Wayland;
22. depender de Xlib e XCB com dois loops;
23. presumir que macOS callbacks são simples;
24. esquecer autorelease pool;
25. criar API pública por conveniência do backend.

---

# 60. Questões técnicas que precisam de spike

## 60.1 Dart/main thread macOS

- o executável AOT inicia Dart na thread principal?
- como integrar `NSApplication` sem bloquear processamento Dart?
- qual mecanismo de wakeup tem menor latência?
- callbacks AppKit entram no isolate correto?
- como loops modais afetam scheduler?

## 60.2 COM callbacks

- como garantir vtable estável?
- quais callbacks podem vir de outras threads?
- como retornar valores sincronamente?
- como preservar objeto Dart?
- como tratar apartment?

## 60.3 Wayland listeners

- `NativeCallable.isolateLocal` é suficiente se tudo ocorrer na UI thread?
- callbacks de certas bibliotecas podem vir de outras threads?
- como gerar listener structs estáveis?
- como fechar proxies e callbacks na ordem correta?

## 60.4 Render isolate

- custo de transferir DisplayList;
- latência;
- backpressure;
- resource upload;
- frames em voo;
- shutdown.

## 60.5 Objective-C blocks

- assinatura;
- copy/dispose helpers;
- ownership;
- callback thread;
- block layout;
- alternativas por target/action/delegate.

Cada spike produz documento, código mínimo e decisão. Código descartável não entra automaticamente no core.

---

# 61. Checklist para cada backend nativo

## Inicialização

- [ ] biblioteca carregada;
- [ ] símbolos validados;
- [ ] versão;
- [ ] thread correta;
- [ ] logs;
- [ ] fallback.

## Recursos

- [ ] ownership;
- [ ] dispose;
- [ ] idempotência;
- [ ] leak counter;
- [ ] callback lifetime;
- [ ] error path.

## Janela

- [ ] create;
- [ ] show;
- [ ] resize;
- [ ] scale;
- [ ] focus;
- [ ] close;
- [ ] multiple;
- [ ] popup.

## Input

- [ ] pointer;
- [ ] wheel;
- [ ] key;
- [ ] text;
- [ ] IME;
- [ ] capture;
- [ ] drag.

## Render

- [ ] surface;
- [ ] resize;
- [ ] present;
- [ ] damage;
- [ ] lost;
- [ ] fallback.

## Serviços

- [ ] clipboard;
- [ ] dialogs;
- [ ] theme;
- [ ] monitor;
- [ ] accessibility.

## Qualidade

- [ ] AOT;
- [ ] architecture;
- [ ] stress;
- [ ] idle;
- [ ] benchmark;
- [ ] docs.

---

## 61.1 O mesmo checklist, preenchido por backend (2026-08-23)

`sim` / `parcial` / `não` / `?` não verificado.

| | Win32 | X11 | Wayland | AppKit | Web |
|---|---|---|---|---|---|
| biblioteca carregada, símbolos validados, versão | sim | sim | sim (libc + registry) | sim | sim |
| thread correta | sim | sim | sim | sim (host ObjC) | — |
| logs / diagnóstico de probe | sim | sim | sim | sim | sim |
| fallback | sim | sim | sim | sim | — |
| ownership / dispose / idempotência | sim | sim | sim | sim | ? |
| leak counter | ? | ? | ? | ? | ? |
| create / show / resize / scale / focus / close | sim | sim | sim | sim | parcial |
| múltiplas janelas | sim | sim | sim | ? | sim |
| popup | sim | sim | sim | ? | — |
| pointer / wheel | sim | sim | sim | sim | ? |
| **key** | sim | **não** | sim | sim | ? |
| **text / IME** | sim | **não** | sim | **não** | não |
| capture | sim | ? | ? | ? | ? |
| **drag** | sim | sim | sim | **não** | não |
| surface / resize / present / damage | sim | sim | sim | sim | sim |
| device lost / fallback de render | sim | ? | — (sem GPU) | ? | sim |
| **clipboard** | sim | **não** | sim | **não** | não |
| **dialogs** | sim (`MessageBoxW`, `GetOpenFileNameW`) | parcial (helpers externos) | parcial (helpers externos) | parcial (`osascript`) | parcial |
| theme | sim | ? | ? | ? | sim |
| monitor | parcial | parcial | parcial | ? | sim |
| **accessibility** | parcial (UIA) | **não** | **não** | **não** | **não** |
| AOT | sim | sim | ? | sim | — |
| architecture test | sim (com as exceções nomeadas da Fase 6 + 4 arestas novas em vermelho) | idem | idem | idem | sim (proíbe `dart:ffi`) |
| stress / idle / benchmark | parcial | ? | ? | ? | ? |
| docs | sim | sim | sim | sim | parcial |

Duas colunas dizem a mesma coisa por caminhos diferentes: **X11 e AppKit são os
dois backends que faltam serviços inteiros** — o X11 fechou teclado e clipboard
em 26/08/2026 e segue **sem IME**; o AppKit segue sem drag, IME e clipboard.

---

# 62. Checklist do primeiro release interno

Revisto em 2026-08-23.

- [–] **monorepo** — decisão consciente de continuar em **um package**, que a §7.1 autoriza; a divisão por camadas já está em `lib/src`;
- [x] inventário;
- [x] licenças (`NOTICE`, `THIRD_PARTY_NOTICES.md`);
- [x] foundation;
- [x] display list;
- [x] headless;
- [x] CPU renderer;
- [x] Win32 window;
- [x] GDI;
- [x] input;
- [x] Button;
- [x] Text;
- [x] layout (Grid e Wrap inclusive; **faltam medição intrínseca, baselines e damage tracking** — `flushPaint` ainda repercorre a árvore inteira);
- [x] focus;
- [x] semantics;
- [x] golden;
- [x] benchmark (com orçamentos como portão de CI);
- [ ] leak test;
- [x] AOT;
- [x] sample (galeria, docking, editor vetorial, leitor e assinador de PDF);
- [x] documentação — este roteiro, `architecture/overview.md`, os ADRs e os relatórios de POC.

**O que impede chamar isto de release interno hoje** não é nenhum item acima:
é que `dart test` tem falhas abertas, incluindo três arquivos que **não
compilam** (§68).

---

# 63. Comandos locais sugeridos

## 63.1 Criar diretório de documentação

```powershell
New-Item -ItemType Directory -Force `
  -Path 'C:\MyDartProjects\dart_ui\doc'
```

## 63.2 Verificar SDK

```powershell
dart --version
dart doctor
```

## 63.3 Inventariar referências

```powershell
$roots = @(
  'C:\MyDartProjects\dart_ui\referencias',
  'C:\MyDartProjects',
  'C:\MyDartProjects\marlin\referencias',
  'C:\MyDartProjects\dart_graphics\referencias'
)

$roots |
  ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Recurse -File -ErrorAction SilentlyContinue
  } |
  Select-Object FullName, Length, LastWriteTime, Extension |
  Export-Csv `
    -NoTypeInformation `
    -Encoding UTF8 `
    'C:\MyDartProjects\dart_ui\doc\inventario_referencias.csv'
```

Esse comando é apenas um inventário inicial; o gerador Dart deverá acrescentar hashes, licença e classificação.

## 63.4 Criar workspace mínimo

```powershell
Set-Location 'C:\MyDartProjects\dart_ui'
dart create -t package packages\dart_ui_foundation
dart create -t package packages\dart_ui_geometry
dart create -t package packages\dart_ui_graphics_api
dart create -t package packages\dart_ui_platform
dart create -t package packages\dart_ui_headless
dart create -t package packages\dart_ui_renderer_cpu
dart create -t package packages\dart_ui_backend_win32
```

Adaptar quando a estrutura já existir. Não executar cegamente sobre arquivos existentes.

## 63.5 Verificações

```powershell
dart format .
dart analyze
dart test
```

---

# 64. Referências técnicas primárias

## Dart

- C interop: <https://dart.dev/interop/c-interop>
- Objective-C interop: <https://dart.dev/interop/objective-c-interop>
- `NativeCallable`: <https://api.dart.dev/dart-ffi/NativeCallable-class.html>
- `dart:ffi`: <https://api.dart.dev/dart-ffi/>

## Avalonia

- repositório: <https://github.com/AvaloniaUI/Avalonia>
- Win32 backend: `src/Windows/Avalonia.Win32`
- X11 backend: `src/Avalonia.X11`
- platform interfaces: `src/Avalonia.Controls/Platform`
- composition: `src/Avalonia.Base/Rendering/Composition`
- macOS native notes: `docs/macos-native.md`

## OpenJFX

- repositório: <https://github.com/openjdk/jfx>
- toolkit/quantum: `modules/javafx.graphics/src/main/java/com/sun/javafx/tk`
- Prism: `modules/javafx.graphics/src/main/java/com/sun/prism`
- Glass: `modules/javafx.graphics/src/main/native-glass`
- licença: `LICENSE` e `ADDITIONAL_LICENSE_INFO`

## Windows

- Win32 desktop APIs;
- Direct2D;
- Direct3D 11;
- DXGI;
- DirectComposition;
- DirectWrite;
- Windows UI Automation.

## Linux

- XCB;
- ICCCM;
- EWMH;
- XInput2;
- XKB Common;
- Wayland client API;
- Wayland protocol XML;
- xdg-shell;
- xdg-desktop-portal;
- GTK 4/GObject/GLib;
- AT-SPI.

## macOS

- Objective-C Runtime;
- AppKit;
- Foundation;
- Core Foundation;
- Core Graphics;
- QuartzCore;
- CAMetalLayer;
- Metal;
- NSAccessibility.

## Repositórios do projeto

- `insinfo/dart_graphics`;
- `insinfo/marlin`;
- `insinfo/win32`;
- `insinfo/dart_tkui`;
- `insinfo/freetype_dart`.

---

# 65. Decisão final recomendada

A implementação deve começar pela arquitetura abaixo:

```text
Dart widgets
  ↓
RenderObject + DisplayList
  ↓
dart_graphics/marlin CPU renderer
  ↓
CpuFramebufferSurface
  ↓
Win32 CreateDIBSection
```

Somente depois:

```text
DisplayList
  ├─ Direct2D/D3D11
  ├─ OpenGL
  ├─ Metal
  └─ Vulkan
```

E as plataformas:

```text
PlatformBackend
  ├─ Win32
  ├─ XCB
  ├─ Wayland
  ├─ GTK integration
  └─ AppKit
```

Essa ordem maximiza a chance de sucesso porque:

- valida FFI com uma API conhecida;
- reutiliza o trabalho gráfico já feito;
- cria testes headless;
- impede que GPU defina widgets;
- prova portabilidade antes de otimização;
- enfrenta o risco AppKit cedo o bastante;
- mantém Wayland correto por codegen;
- preserva fallback CPU;
- permite evolução incremental.

---

# 66. Resultado esperado da arquitetura

Ao final, uma aplicação deverá ser capaz de:

```dart
Future<void> main() => DartUi.run(
  config: const DartUiConfig(
    rendererPreferences: {
      OperatingSystem.windows: [
        RendererKind.direct2d,
        RendererKind.cpu,
      ],
      OperatingSystem.linux: [
        RendererKind.vulkan,
        RendererKind.opengl,
        RendererKind.cpu,
      ],
      OperatingSystem.macos: [
        RendererKind.metal,
        RendererKind.cpu,
      ],
    },
  ),
  builder: () => const MyDesktopApplication(),
);
```

Sem:

- Flutter Engine;
- JVM;
- .NET;
- Node.js;
- Chromium;
- wrapper C/C++;
- wrapper Objective-C;
- widgets nativos obrigatórios.

Com:

- janelas reais;
- input real;
- IME;
- acessibilidade;
- renderização CPU/GPU;
- widgets Dart;
- testes headless;
- fallback;
- diagnóstico;
- empacotamento nativo.

---

# 67. Próxima ação concreta

A ação original desta seção — copiar o roteiro, inventariar as referências,
criar os pacotes mínimos, o headless, o spike de `WndProc` e só então o
primeiro Button — **foi executada e está fechada**. Fica registrada porque a
ordem dela é a razão de o projeto ter framework e backend em vez de uma coleção
de bindings.

**A próxima ação concreta em 2026-08-23** é outra, e sai direto da §68:

1. **fazer a árvore compilar**: três arquivos de teste não compilam (os dois de
   janela do Vulkan e o de interação do editor vetorial). Uma árvore que não
   compila esconde toda regressão posterior;
2. **decidir as quatro arestas de camada** que o motor vetorial trouxe — ou a
   regra da §8.2 muda com justificativa registrada, ou o código sobe de camada.
   O teste que as acusa existe exatamente para impedir que isso passe em
   silêncio;
3. **atualizar os dois testes que ficaram velhos** (`gl_device_test`,
   `text_rendering_test`) para afirmarem o comportamento novo, junto com a
   paridade que ele passou a permitir;
4. ~~**ligar XKB no X11.**~~ Feito em 26/08/2026 **pelo core protocol**, não
   pelo XKB: `GetKeyboardMapping` + `GetModifierMapping` destravaram teclado,
   atalhos, teclas mortas e clipboard. `libxcb-xkb` continua sendo a resposta
   para três ou mais grupos e para `DetectableAutoRepeat`; IME (XIM) segue
   fora. Ver §68.1;
5. **ligar o que está escrito e solto** (§68.2). Fechados em 26/08/2026:
   Vulkan e D3D12 no seletor (Vulkan como experimental, porque não desenha
   texto), `RenderPolicy.restrict` no planejador e `ContentHintAwareSink` no
   `GpuRasterSink`. Abertos: `GlVideoDevice`, `FilePicker` no editor vetorial e
   `FrameLoopController` — este último com a política duplicada já removida e a
   decisão registrada em §68.2;
6. **rodar o Wayland contra um compositor de verdade** — é a única coisa que
   valida a camada FFI e o único item que separa a Fase 13 do gate.

O detalhamento por frente está em §68.

---

# 68. Limitações conhecidas — auditoria de 2026-08-23

Esta seção existe porque é a que torna o documento útil. Um roteiro que só
lista o que funciona é propaganda; o que decide bem é saber onde o chão não
está firme. Cada item abaixo foi **conferido no código** nesta data e nomeia o
arquivo. Onde não deu para confirmar, está escrito **não verificado** — e isso
também é informação.

## 68.1 Buracos funcionais

### ~~X11 não tem teclado~~ — **fechado em 26/08/2026**, pelo core protocol

Esta era a linha mais cara da seção e ela mudou de lado. O que existe agora:

- `x11_keyboard.dart` decodifica `GetKeyboardMapping` e `GetModifierMapping`
  **do core protocol**, aplica as regras de seleção de keysym do próprio
  protocolo (Shift, CapsLock que *maiúsculiza o símbolo*, ShiftLock que
  seleciona o nível 2, NumLock testado **antes** de CapsLock, grupo 2 por
  `Mode_switch`/`ISO_Level3_Shift`) e resolve **por keysym** em que `Mod1`-`Mod5`
  o teclado do usuário pôs Alt, Meta, Super, NumLock e AltGr — em vez de assumir
  `Mod1 == Alt`, que é o motivo de Alt+Tab quebrar em setups incomuns;
- `X11EventTranslator.translateKey` constrói `KeyDownEvent`/`KeyUpEvent` e o
  `TextInputEvent` que o keysym produz, nessa ordem (hardware antes de texto,
  como Win32 entrega `WM_KEYDOWN` antes de `WM_CHAR`);
- `x11_backend.dart` lê o mapa no `initialize`, **relê em `MappingNotify`** (que
  é o que troca de layout), e **reivindica `Capability.keyboardInput`** quando o
  servidor respondeu — e não reivindica quando ele recusou, caso em que
  `KeyEvent` continua saindo com o keycode físico e texto nenhum é inventado;
- `X11KeyRepeatFilter` reconhece o auto-repeat pela assinatura de fio
  (`KeyRelease` + `KeyPress` no **mesmo timestamp do servidor**), porque
  `DetectableAutoRepeat` é um flag por cliente do XKB;
- **teclas mortas funcionam**: `ComposeEngine` é instalado por janela a partir
  do `~/.XCompose` ou da tabela de locale da própria máquina, exatamente como no
  Wayland.

**Por que o core protocol e não XKB nem libxkbcommon** está escrito no topo de
`x11_keyboard.dart`, com o que a rota **não** cobre: só **dois grupos** (três ou
quatro layouts configurados alcançam os dois primeiros), **sem grupo por
evento**, e **sem `DetectableAutoRepeat`**. `libxcb-xkb` continua sendo a
resposta para isso.

**Continua sem IME**: XIM precisa de Xlib e de um input context, e CJK segue
indisponível neste backend. Teclas mortas e AltGr **não são IME** e funcionam.

### O clipboard do X11 existe — com um limite nomeado

`x11_clipboard.dart` implementa `Clipboard` sobre seleções e `x11_backend.dart`
implementa `ClipboardProvider`. Ler pede `UTF8_STRING`, cai para
`text/plain;charset=utf-8` e depois para `STRING` (que é Latin-1 **por
definição**, e é decodificado como tal), e **monta transferências `INCR`** —
que o destino XDND, ao lado, recusa. Escrever toma `CLIPBOARD`, verifica a posse
com um round trip (`SetSelectionOwner` não dá erro quando é ignorado) e serve
`TARGETS`, `TIMESTAMP`, `UTF8_STRING`, `STRING` e `TEXT`.

**O que não tem**: servir como **dono INCR**. Um payload maior que 200 KiB é
recusado **em voz alta** em vez de truncado. E `PRIMARY` — a seleção do botão do
meio — está deliberadamente fora: é outra funcionalidade, com outra semântica.

### O que disso está provado por teste executável, e o que não está

A distinção importa e esta máquina é Windows, então nada de X11 rodou aqui:

- **provado por teste**: `test/backends/x11/x11_keyboard_test.dart` (38 testes)
  constrói respostas de `GetKeyboardMapping`/`GetModifierMapping` **byte a
  byte** e afirma o keysym que sai; `x11_events_test.dart` monta os 32 bytes de
  um `xcb_key_press_event_t` de verdade, passa por `decodeFrom` e afirma o
  `KeyEvent`/`TextInputEvent`; `x11_clipboard_test.dart` (41 testes) roda a
  máquina de estados contra um cliente de seleção falso; `x11_backend_test.dart`
  prova o roteamento pelo pump, a releitura em `MappingNotify` e o colapso do
  par de auto-repeat;
- **não provado**: que o libxcb entrega esses bytes intactos, que um servidor
  real responde assim, e que um GTK/Qt do outro lado negocia a seleção como o
  falso negocia. **Nada disto foi executado contra um X server real.**
  `tool/x11_backend_smoke.dart` ganhou as linhas `X11_KEYBOARD=` e
  `X11_CLIPBOARD=` para que seja executável numa sessão Linux — mas **ainda não
  foi executado**.

### O backend Wayland nunca falou com um compositor

As 14 suítes (6.709 linhas) rodam contra um compositor **falso em memória** —
que é um bom teste, porque decodifica o que o cliente envia com o wire de
verdade e sintetiza eventos de volta, e **não é a mesma coisa** que um
compositor. A camada FFI — `sendmsg`, `recvmsg`, `SCM_RIGHTS`, `memfd_create`,
`mmap` — **não tem cobertura automatizada nenhuma** e só roda numa sessão
Wayland real. Não existe `tool/wayland_backend_smoke.dart`, que X11 e macOS
têm.

### ~~Acessibilidade quase não existe~~ — **fechada no Windows em 26/08/2026**

Esta linha dizia que só havia a ponte UIA e que `Capability.accessibility`
não era reivindicada por backend nenhum. A ponte estava certa; o diagnóstico
estava incompleto, e a parte incompleta era a que importava. Os 4.009 linhas de
`backends/win32/uia/` **funcionavam** e eram **inalcançáveis**, por três
chamadas que nunca aconteciam:

- ninguém em `lib/` chamava `Win32UiaBridge.attach`;
- ninguém bombeava um `SemanticsUpdate` para a ponte — `BuildOwner.updateSemantics`
  só era chamado por teste, e `application.dart` construía a árvore semântica
  apenas para **contar nós** num diagnóstico;
- `UiaProviderTree.actionDispatcher` nunca era atribuído, então **todo** padrão
  de controle respondia `UIA_E_NOTSUPPORTED`. O botão se anunciava
  corretamente e não podia ser pressionado.

O que existe agora:

- **`lib/src/platform/accessibility.dart`** — `AccessibilityHost`,
  `WindowAccessibility` e `AccessibilityTreeSource`. A camada neutra; é o único
  arquivo de `platform/` que importa `widgets/`, e o cabeçalho diz por quê e
  qual seria a correção honesta (tirar `SemanticsOwner` de `widgets/`);
- **`backends/win32/uia/uia_session.dart`** — `WindowsAccessibility` liga a
  árvore viva à ponte, e `WindowsUiaAccessibilityHost` é a implementação da
  interface neutra. **Ativação preguiçosa**: registrar custa uma entrada de
  mapa, e o provider só é construído quando um cliente manda o primeiro
  `WM_GETOBJECT` — que é o sinal honesto de que alguém quer a árvore. Uma
  máquina sem leitor de tela roda o código que rodava antes;
- **`win32_backend.dart`** instala o host no `initialize` e **reivindica
  `Capability.accessibility`**, condicionada a `uiautomationcore.dll` ter
  carregado — a mesma regra de ole32 e imm32;
- **`application.dart`** registra a janela na criação, bombeia a árvore depois
  de cada frame (`_pumpAccessibility`, uma busca em mapa quando ninguém está
  lendo) e desregistra no teardown;
- **`widgets/semantics.dart`** ganhou `SemanticsActionTarget` e
  `SemanticsOwner.performAction`, que é o caminho de volta: um id que veio do
  leitor de tela vira o render object que o publicou. `ControlBehavior` implementa
  `activate` e `focus` para **todo** controle; `RenderSlider` implementa
  increment/decrement/setValue e `RenderTextField` implementa setValue pelo
  caminho do *paste* (uma entrada de undo).

**O que está provado por teste executável, e o que não está.** A distinção é a
mesma que a seção faz para X11, e aqui ela cai do lado bom:

- **provado, e por um cliente em outro processo**:
  `test/backends/win32/uia/uia_app_test.dart` sobe uma aplicação `dart_ui` de
  verdade (`uia_app_host.dart`, que não faz nada específico de acessibilidade —
  quem faz é `lib/`), e aponta `uia_app_client.dart` para o HWND dela **de um
  processo separado**. Esse cliente é `CLSID_CUIAutomation`, o mesmo objeto que
  a biblioteca do Narrator cria. Ele encontra os quatro controles na **control
  view** — Button (50000) "Save", CheckBox (50002) "Remember me", Slider (50015)
  sem rótulo, Edit (50004) "Name" — chama `IUIAutomationInvokePattern::Invoke`,
  `ITogglePattern::Toggle` e `IValuePattern::SetValue`, e os *callbacks da
  aplicação hospedeira rodam*: `presses=1`, `checked=true`, `slider=0.75`,
  `text=after`. Os valores novos voltam pela árvore num frame posterior, o que
  é a metade que prova que `application.dart` bombeia. **Fora de processo é a
  medição que importa**: um cliente in-process compartilha o apartamento com o
  provider e nunca exercita o marshalling que `uia_bridge.dart` depende;
- **também provado, in-process**: `uia_session_test.dart` (11 casos) e o
  `uia_widget_probe.dart` que ele roda — render objects reais, ativação
  preguiçosa medida (`liveBeforeClient=0`, `liveAfterClient=1`), e as mesmas
  três operações; `test/widgets/semantics_actions_test.dart` (12 casos) cobre
  as recusas — controle desabilitado, ação não declarada, campo read-only,
  `setValue` com texto que não é número, incremento no fim da faixa;
- **não provado**: que o **Narrator** anuncia o que o cliente lê. Ninguém rodou
  o Narrator nesta máquina — ele fala em voz alta e toma a máquina, e esta é a
  máquina do usuário. O que foi provado é a API que o Narrator usa, do jeito que
  ele a usa, de fora do processo. **Também não provado**: NVDA, JAWS, e o
  comportamento sob *high contrast* ou *text scaling* do sistema.

**O que continua ausente no Windows**, por nome e com motivo, em
`Win32UiaBridge.absentFeatures`: `IAccessible` (MSAA), `ITextProvider`,
`IScrollProvider`, `IRangeValueProvider`, `IRawElementProviderAdviseEvents`. E
uma consequência do desenho a mais: um render object que **declara** uma ação
em `SemanticsConfiguration` mas não implementa `SemanticsActionTarget` continua
respondendo `UIA_E_NOTSUPPORTED`. Os controles ligados hoje são os que passam
por `ControlBehavior` (botão, toggle/checkbox, radio, switch), o slider e o
campo de texto; `list_box`, `tree_view`, `data_grid`, `combo_box`, `menu`,
`tabs` e `expander` **descrevem-se e não se operam**.

**Fora do Windows continua não existindo nada.** X11, Wayland, macOS e web não
têm host de acessibilidade; AT-SPI e NSAccessibility não foram começados, e
nenhum deles pode ser verificado nesta máquina — escrever um às cegas produziria
confiança falsa, que é exatamente o que esta seção existe para evitar. É
requisito de *Gate 1.0* (§45, Fase 17), e o Gate continua aberto pelos outros
três.

## 68.2 Escrito e não ligado

Esta seção listava quatro subsistemas completos e sem consumidor. **Três foram
ligados em 26/08/2026**; o que sobra está abaixo com o motivo, porque um item
fechado sem dizer como foi fechado é a mesma opacidade que a lista existe para
evitar.

### Fechado

- **D3D12 e Vulkan no seletor** (`default_platform_resolver.dart`). Os dois
  entram depois de `direct3d11`, `opengl` e `direct2d` e antes do `win32-dib`,
  pela mesma razão que o Direct2D entrou depois dos dois primeiros: a figura
  padrão de uma máquina comum não muda, e uma máquina cujos probes de D3D11,
  GL e D2D falham passa a alcançar um caminho acelerado em vez de cair na CPU.
  `--presentation=direct3d12` e `--presentation=vulkan` os fixam pelo nome.

  **Vulkan é `experimental: true`, e a bandeira não é cautela:**
  `VulkanWindowTarget` monta seu `GpuRasterSink` sem atlas de glifos e sem
  `GpuFontResolver`, então o primeiro `drawGlyphRun` levanta
  `UnsupportedCapabilityError` pelo nome — verificado em janela real. Um
  caminho que não desenha texto não pode ser alcançado por *fallback* num
  framework de UI; ele está registrado para poder ser pedido, não para ser
  escolhido. O D3D12 tem atlas de glifos e resolver, e por isso entra sem a
  bandeira.

  Também corrigido no caminho: `D3d12WindowTarget` declarava só `RenderTarget`
  e não `DisplayListRenderTarget`, embora já tivesse `renderDisplayList`. O
  `RenderTargetPresenter` que não enxerga a interface mais estreita desvia para
  `beginFrame`/`rasterizeDisplayList`, que ali rasteriza no `Framebuffer` de
  1x1 que o alvo usa como espaço reservado — janela em branco, sem erro.

  **Prova em janela real**, Intel UHD, `RenderingPolicy.gpuOnly` e `onError`
  instalado: `direct3d12` desenhou 105 frames em 16 s com texto, preenchimentos
  e um retângulo arredondado antialiasado, `errors=0`, *feature level* 12_1;
  `vulkan` (sem texto) apresentou pelo swapchain `VK_KHR_win32_surface` com
  `errors=0`.

- **Política de renderização.** `RenderPolicy.restrict(...)` é chamado — uma
  vez, em `GpuPathPlanningTelemetry.plan`, que é o único ponto onde o que o
  *dispositivo* sabe executar encontra o que o *seletor* pode escolher. Os três
  backends de GPU deste repositório (`gl_vector_replay.dart`,
  `d3d12_offscreen_target.dart`, `vulkan_backend.dart`) constroem essa
  telemetria, então os *kill switches* e a troca de qualidade valem para todos
  de uma vez, e um backend novo os herda sem saber que existem. O seletor
  também passa a vir de `RenderPolicy.buildSelector()`, que é como
  `RenderQualityPreference.speed`/`exact` chega ao limiar do *cover pass* —
  metade que não estaria ligada se só as capacidades fossem restritas.
  `test/rendering/gpu/gpu_path_policy_test.dart`.

- **Hints de conteúdo.** `GpuRasterSink` implementa `ContentHintAwareSink`
  (`gpu_raster_sink.dart:136`); o hint chega tanto à admissão no atlas denso
  (`_admitToAtlas`) quanto ao planejador (`hint: _contentHint`). Coberto por
  `test/rendering/gpu/gpu_path_hint_test.dart` e
  `test/widgets/content_hint_test.dart`.

### Aberto

1. **Laço de tempo real.** `lib/src/app/frame_loop.dart` — `FrameLoopMode`,
   `FrameLoopOptions.continuous`, `FrameLoopController`, `FixedStepAccumulator`
   e telemetria de pacing. Continua **sem consumidor em `lib/`**, e a decisão
   de 26/08/2026 foi *manter o desenho e remover a política duplicada*:
   - o que fazia dele pior que ausência era `FrameLoopController.pumpTimeout`,
     que respondia "quanto o laço pode bloquear" com um `idleTimeout` **plano**
     no modo `onDemand` — exatamente a política que a espera ociosa adaptativa
     de `Application.run` substituiu, e por um motivo medido (a espera síncrona
     no pump é a latência de *todo* trabalho Dart pendente, e um teto plano de
     250 ms transforma um `Timer.periodic` de 16 ms em 4 Hz). Duas respostas
     para uma pergunta, em dois arquivos, com só uma rodando: a morta se lê
     como a política e não é. **Removida.** O arquivo fica com o *prazo*
     (`timeUntilNextFrame`) e o laço fica com a política de espera;
   - o resto — modo contínuo, passo fixo, pacing — é a resposta a um requisito
     nomeado do §1 (editores de animação e vídeo, jogos 2D/2.5D), não depende
     de nada e não custa nada carregado. Apagá-lo enquanto quatro frentes rodam
     em paralelo seria uma frente decidindo por outra;
   - o arquivo agora **diz de si mesmo** que não está ligado e nomeia a costura
     de uma linha que o ligaria, e `test/app/frame_loop_test.dart` (21 casos)
     fixa a política — inclusive a garantia de coexistência: em `onDemand`
     nenhum frame vence nunca, então ligá-lo não move nada numa aplicação
     dirigida por invalidação.
2. **Vídeo.** `GlVideoDevice` é o único allocator e não é referenciado por
   ninguém; o próprio arquivo diz que ligá-lo ao sink de batching "é uma decisão
   separada e posterior".

Some-se a isso o **`FilePicker` que existe e que o editor vetorial não usa**.

## 68.3 Contratos sem implementação

- **Textura externa.** `GpuForeignTextureImporter` e `ForeignTextureDescriptor`
  descrevem handle DXGI, `EGLImage` e `IOSurface`, e
  `RendererCapabilities.supportsExternalTextures` é **falso em todos os
  backends** deste repositório;
- **Decodificação de vídeo.** `lib/src/graphics/video/` diz na primeira linha
  que **nada ali decodifica nada**: um frame chega como planos de bytes
  (NV12, I420, YUY2) que outra pessoa produziu;
- **`PresentMode`.** `fifo` e `immediate` são reais no WGL (`wglSwapIntervalEXT`)
  e no GDI (`DwmFlush`); `mailbox` é **recusado por nome** nos dois; o D3D12
  tem só o contrato;
- **Portais XDG.** A §16.13 os pede para diálogos e integração em ambientes
  sandboxed, e o que existe é subprocesso de helper (`zenity`, `kdialog`,
  `yad`) — que falha exatamente no caso que o portal resolve.

## 68.4 Limitações do renderer e do texto

### Texto rotacionado: nenhum dos três recusa mais

Esta linha mudou de lado duas vezes e vale dizer com precisão, porque a versão
antiga ainda circula por aí:

- **CPU: aceita.** `cpu_renderer.dart` testa `glyphMasksFit(transform)` e, se a
  matriz não couber em máscara, desvia para `_drawGlyphRunAsOutlines`, que
  aplica a transformação **durante** o achatamento do contorno, sem alocar
  cópia. O `UnsupportedCapabilityError` de `_deviceFont` está atrás dessa
  guarda e é inalcançável por rotação;
- **GPU (`GpuRasterSink`): aceita**, pelo mesmo par de helpers, o que permite
  paridade com desvio 0 em vez de tolerância — os dois caminhos rodam o mesmo
  `ScanlineFiller`. O custo honesto está escrito: **uma rasterização por glifo
  por frame**, porque o atlas é chaveado só por tamanho;
- **Direct2D: aceita**, desde 24/08/2026, pelo mesmo `glyphMasksFit` e pelo
  mesmo `glyphOutlineTransform`. O caso alinhado continua sendo o blit de
  máscara com `FillOpacityMask`; o caso geral é `FillGeometry` sobre um
  `ID2D1PathGeometry` por glifo. A diferença que sobra é **de rasterizador, não
  de rota**: a cobertura vem do `d2d1.dll` e não do `ScanlineFiller`, então a
  paridade medida contra a CPU é uma **tolerância declarada** — 53 níveis por
  canal no pior caso (giro de 45°), sobre no máximo 6,7% da superfície
  (espelhamento), e desvio 0 no caso alinhado, onde ele blita as máscaras que a
  própria CPU rasterizou. Está em
  `test/backends/win32/d2d/d2d_glyph_transform_test.dart`.

**As duas consequências que ficavam registradas aqui foram fechadas:** o
comentário do `d2d_raster_sink.dart` não afirma mais paridade de recusa com a
CPU, e `widgets/docking/collapsed_tab_strip.dart` gira o rótulo de verdade —
um único run moldado, com kerning — em vez de empilhar caracteres.

O **ADR 0007** — citado por `cpu_renderer.dart`, `gpu_raster_sink.dart` e
`text/glyph_raster.dart` — **passou a existir em 23/08/2026**, enquanto esta
auditoria rodava. Ele registra a decisão: quando a máscara em cache não serve,
o glifo é preenchido **a partir do contorno, sob a matriz completa**, pelo mesmo
`ScanlineFiller` que preenche qualquer caminho — em vez de reamostrar um bitmap
já antialiasado, que produz o texto mole que dá má fama a cache de bitmap de
fonte. O critério é uma função só, `glyphMasksFit`, importada pelos dois sinks,
com a comparação `a == d` **exata** porque não existe epsilon correto a 8px e a
200px ao mesmo tempo. Na GPU o caminho geral não é o atlas de glifos e sim o
`GpuMaskAtlas`, que roda o mesmo `ScanlineFiller` na CPU — é por isso que a
paridade medida para texto girado é **desvio 0** e não tolerância. Hinting fica
desligado sob rotação porque grid-fitting alinha a haste a uma linha por onde os
pixels não correm.

### Sparse strips: promovida no OpenGL, opt-in no resto

`GlSparseStripsPolicy.auto` é o padrão de `GlRenderDevice.adoptContext`; em
**D3D12, WebGPU e WebGL2** o parâmetro continua `enableExperimentalSparseStrips
= false`. Por que o resto ainda é opt-in, em uma frase cada: no D3D12 o seletor
ainda decide sparse pela **regra antiga de bytes de upload** (a de cruzamentos
de tile é a nova); no WebGPU **não há alvo de readback**, então não existe
paridade medida contra a CPU; no WebGL2 o executor é o do desktop adaptado, e o
custo não foi medido no navegador.

O rasterizador nativo declara três omissões: **sem SIMD** (Dart não tem — em
Rust os 4 pixels de um tile são uma instrução), **sem culling** de geometria
fora da tela, e curvas achatadas por `Path.flattenTo`.

### Divergências CPU↔GPU e outras lacunas de renderização

- gradiente **em glifos e em imagens** é recusado por nome nos dois renderers,
  CPU inclusive;
- retângulos antialiasados divergem em 1 nível: `raster/coverage.dart` quantiza
  em 1/255 enquanto o shader mantém float;
- `src` sobre forma baseada em máscara diverge até 255, por semântica do lado
  da GPU;
- do texto continuam faltando: COLR/CPAL, CBDT e sbix (emoji colorido), fontes
  variáveis, shaping índico/USE, escrita vertical CJK, `BASE`, fallback de
  fonte, edição multilinha, e **hinting de CFF** — os parâmetros são parseados
  e nunca aplicados;
- **bidi**: o *movimento do caret* em texto de direção mista salta;
- do layout continuam faltando **medição intrínseca, baselines e damage
  tracking**; `RenderRepaintBoundary` existe como marcador, e `isRepaintBoundary`
  é, nas palavras do próprio arquivo, "consultado por nada" — `flushPaint`
  repercorre a árvore inteira.

## 68.5 Limitações por plataforma, em uma linha cada

- **Windows**: sem DirectComposition; sem TSF (só IMM32); IME não lê texto ao
  redor; `FilePicker` usa o `GetOpenFileNameW` legado, não `IFileDialog`;
  `vsync` não é reivindicada porque o `BitBlt` não é paced;
- **X11**: teclado e clipboard existem desde 26/08/2026 (§68.1), mas **sem
  IME** (XIM não implementado), **sem XKB** — logo só dois grupos de layout e
  sem `DetectableAutoRepeat` —, sem dono `INCR` no clipboard, sem `PRIMARY`, sem
  XInput2, sem RandR, sem `MIT-SHM` (a apresentação é `PutImage` do core), e o
  caminho EGL **nunca executado**;
- **Wayland**: sem GPU de qualquer espécie, sem touch, sem escala fracionária
  (só inteira, e a **maior** dos outputs, não por superfície), sem seleção
  primária, sem CSD quando o compositor recusa SSD, sem movimento/resize
  interativo, sem `set_maximized`/`set_fullscreen`/`set_minimized`, sem posição
  de janela; xkb reduzido a **primeiro grupo e dois níveis** com bits de
  modificador **assumidos**; apenas ABIs **LP64**;
- **macOS**: sem drag-and-drop, sem clipboard, sem IME; Metal **não apresenta**;
  as APIs de SO não vinculam AppKit nem Foundation;
- **Web**: sem clipboard, sem drag-and-drop, sem IME; WebGPU sem alvo de
  readback, logo **sem paridade medida**; `system_fonts.dart` sequer compila
  para web.

## 68.6 Limitações de evidência — o que a suíte **não** prova

Isto é tão importante quanto a lista anterior, e é mais fácil de esquecer:

- **as validation layers do Vulkan não estão instaladas nesta máquina.** Os
  testes pedem `VK_LAYER_KHRONOS_validation` e exigem que ela não reclame; aqui
  há só o ICD da Intel, sem SDK do LunarG, e
  `vkEnumerateInstanceLayerProperties` devolve nada. O que aqueles testes
  provaram **aqui** foi pixel correto, **não** validação — e a distinção é
  impressa, não escondida;
- **Metal só roda em CI Apple Silicon**, e nunca em Intel;
- **X11 só rodou sob Xvfb**, nunca num Xorg ou XWayland de verdade — e o
  teclado e o clipboard que entraram em 26/08/2026 **não rodaram nem sob Xvfb**:
  são provados por testes sobre bytes numa máquina Windows, e a metade FFI
  (`xcb_get_keyboard_mapping`, `SetSelectionOwner`) **nunca foi executada**;
- **Wayland nunca rodou** (§68.1);
- **a camada FFI do Wayland não tem teste algum**;
- **os dois arquivos de janela do Vulkan voltaram a compilar** em 24/08/2026:
  pediam `Win32Window.setClientSize` e `Win32Window.physicalSize`, que nunca
  existiram em backend nenhum — a API é `setBounds` (lógica) e `pixelSize`
  (física), com o mesmo nome no Win32, no X11 e no Wayland —, e um
  `blendModeSrcOver` que existe e só faltava importar. Os testes é que estavam
  errados;
- **os dois testes velhos foram corrigidos**: `gl_device_test` afirma agora a
  política real (`GlSparseStripsPolicy.auto`, sparse em todo driver que a
  suporta) e `text_rendering_test` deixou de exigir que a CPU recuse rotação;
- **o teste de camadas voltou a passar**: as arestas `geometry → graphics` e
  `graphics → pdf` eram inversões reais e foram corrigidas **no código**
  (`bezier.dart`, `contour.dart` e `shaping.dart` desceram para
  `graphics/vector/`, e `vector_pdf_exporter.dart` subiu para `pdf/export/`),
  a camada `audio` passou a ser declarada, e a menção a `kernel32` no núcleo
  virou um campo nomeado pela função (§4.4);
- `dart test` deu **números diferentes em duas execuções da mesma tarde**,
  porque a árvore estava sendo editada. **Trate a lista nomeada desta seção
  como a medição; o número não é.**

## 68.7 Divergências documentação ↔ código encontradas nesta auditoria

Registradas para quem mexer no código a seguir; **em todas, o código venceu**:

| Onde | O que diz | O que é |
|---|---|---|
| `d2d_raster_sink.dart` | a recusa de texto rotacionado é "a mesma da CPU" | **resolvido em 24/08/2026**: o D2D passou a preencher o contorno e o comentário foi corrigido |
| `widgets/docking/collapsed_tab_strip.dart` | o rasterizador de CPU recusa glifo sob rotação | **resolvido**: gira o rótulo de verdade |
| `x11_backend.dart` (probe) | "XDND drop targets are available; dragging out is not implemented" | o caminho de `initialize` liga `X11XdndSource` e diz "in both directions" |
| `wayland_backend.dart` (probe) | teclado "no dead keys/compose" | `ComposeEngine` é instalado por janela quando não há `text-input-v3` |
| `wayland_xcursor.dart` | "only the first frame is used today" | `wayland_cursor.dart` anima todos os quadros |
| `platform/drag_drop.dart` | cita `DragDropController` em `widgets/drag_drop.dart` | a classe não existe; são `WidgetTreeDropTarget` + `DragRouter` |
| `platform/text_input.dart` | citava `x11_compose.dart` | **resolvido em 26/08/2026**: o arquivo nunca existiu; a referência passou a ser `backends/x11/x11_keyboard.dart`, e a frase "o teclado da plataforma ainda produz `TextInputEvent`" deixou de ser aspiracional no X11 |
| `vector/compute_tile_scene.dart` | "nenhum binding de API consome estes buffers ainda" | o executor de compute do D3D12 consome |
| `doc/vector_editor.md` | o exemplo está em `examples/sk1_editor_demo/` | está em `examples/vector_editor_demo/` |
| `doc/vector_editor.md` | booleanas 2D em polígonos **e caminhos** | `shaping.dart` achata para polilinhas e usa Sutherland-Hodgman (convexo, perde curvas) |
| `examples/vector_editor_demo/main_window.dart` | "não há seletor de arquivo neste framework" | `platform/file_picker.dart` existe e está exportado |
| três arquivos de renderização | citavam `ADR 0007` sem ele existir | **resolvido em 23/08/2026**, durante esta auditoria: o ADR foi escrito |

# 69. Não penalizar uma plataforma por causa de outra — PoC de 2026-08-25

O framework compila para cinco alvos com capacidades numéricas diferentes, e
até esta data o código escrito para ser alcançável pela web era escrito no
menor denominador comum: 32 bits. Isso cobra um preço da VM e do WebAssembly
por um limite que é só do dart2js.

O caso que expôs isso foi `DisplayList.addPaint`. A função de hash foi
escrita em 64 bits, o `dart compile js` **recusou os literais**, e ela foi
refeita em 32 bits com multiplicações partidas em metades de 16 bits — ~3,5 ns
por chamada mais lenta, em todos os alvos, inclusive nos dois que não têm o
problema.

## 69.1 O que a PoC mediu

Uma PoC executou o mesmo programa nos três alvos (Dart 3.6.2, Node v24) e
verificou tanto o mecanismo de seleção quanto a capacidade real do `int`:

| | Dart VM | dart2js | dart2wasm |
|---|---|---|---|
| `export … if (dart.library.js) …` seleciona | int64 | **int32** | **int64** |
| `export … if (dart.library.html) …` seleciona | int64 | int32 | int64 |
| `bool.fromEnvironment('dart.tool.dart2wasm')` | false | false | **true** |
| `bool.fromEnvironment('dart.tool.dart2js')` | false | **true** | false |
| `bool.fromEnvironment('dart.library.js')` | false | true | **false** |
| `bool.fromEnvironment('dart.library.js_interop')` | false | true | **true** |
| `identical(0, 0.0)` (constante) | false | **true** | false |
| `2^53+1` sobrevive | sim | **não** | sim |
| `(1<<60) >> 60 == 1` | sim | **não** | sim |
| `3037000499²` exato | sim | **não** | sim |

Três conclusões:

1. **`dart.library.js_interop` não serve** para este corte: é `true` no dart2js
   *e* no dart2wasm. Ele significa "este alvo tem interop com JavaScript", não
   "este alvo é JavaScript".
2. **`dart.library.js` serve**, e é o corte exato: `true` só nos backends
   JavaScript, `false` na VM e no Wasm.
3. **O Wasm tem `int` de 64 bits de verdade** — não é "mais preciso que o JS",
   é outra categoria. Escrever 32 bits para ele desperdiça a vantagem de
   compilar para WebAssembly.

O dart2js recusa literais de 64 bits **em tempo de compilação**
(`The integer literal 9007199254740993 can't be represented exactly in
JavaScript`), então o imposto não é sutil: ele aparece como erro de build e
força a reescrita.

## 69.2 O padrão a adotar

Um arquivo seletor, e duas implementações com a mesma API:

```dart
// int_ops.dart — a única linha que conhece a diferença
export 'int_ops_int64.dart' if (dart.library.js) 'int_ops_js32.dart';
```

Isolar o teste **num arquivo só** é deliberado: `dart.library.js` está atado à
biblioteca legada `dart:js`, que está em depreciação. Quando o SDK oferecer um
discriminador melhor — há discussão sobre algo como `dart.mode.jsNumbers` — a
migração é uma linha, não uma varredura.

Para diferenças pequenas demais para justificar dois arquivos, a constante
resolve, e o compilador elimina o ramo morto:

```dart
const bool kIsJavaScript = identical(0, 0.0);
```

## 69.3 Quando dividir, e quando não

A divisão **não** é gratuita: são duas implementações que precisam concordar,
duas superfícies de teste, e risco de divergência silenciosa. O critério é
medir, não presumir.

- **Divida** quando o alvo web muda o que o código *pode fazer*: aritmética
  acima de 53 bits, bitwise acima de 32 bits, checksums, hashes, codecs. Aqui
  não é otimização, é viabilidade — e é a mesma razão pela qual `crypto`,
  `inflate.dart` e os pares `_io`/`_stub` já existem.
- **Não divida** quando o custo é de nanossegundos num caminho que não é
  quente. O próprio `addPaint`, que motivou esta seção, é o exemplo: 3,5 ns por
  chamada, ~600 chamadas por quadro, dá **2,1 µs** — 0,013% de um quadro de
  60 Hz. Medir primeiro teria evitado a discussão.

A regra prática: se o ganho não aparecer numa medição reprodutível de quadro
inteiro, não vale duas implementações.

## 69.4 A varredura, medida — 2026-08-26

O trabalho que 69.1–69.3 deixaram em aberto foi feito. O resultado é o que a
própria seção previa como plausível: **nenhum candidato passa do limiar, e nada
foi dividido.** O que segue é a tabela do que foi medido, para que a varredura
não precise ser refeita.

### O método

Duas etapas, nesta ordem, porque a primeira é de graça e elimina a maioria.

1. **Alcance.** Um candidato que a web nunca compila não paga imposto nenhum.
   O que a web compila é `test/backends/web/web_compilation_fixture.dart`, e o
   fecho transitivo dos seus `import`/`export` — resolvendo cada
   `if (dart.library.…)` pelo ramo do dart2js — dá **448 arquivos de `lib/`**.
   A conferência não ficou na leitura: injetar um literal de 64 bits num
   arquivo e rodar `dart compile js` sobre o fixture faz o próprio compilador
   responder. Feito em `crypto/dart/pure_dart_sha.dart`, que respondeu
   `The integer literal 0x428a2f98d728ae22 can't be represented exactly in
   JavaScript` — logo aquele arquivo está, de fato, dentro do conjunto.

2. **Medição.** Só para os que sobraram: AOT (`dartaotruntime`), semi space
   fixado (`--new_gen_semi_initial_size=2 --new_gen_semi_max_size=2
   --verbose_gc`), N e 2N iterações por processo tomando `t(2N) − t(N)` para o
   startup cancelar, N = 5×10⁷, e o **mínimo** de 7 a 9 repetições — o ruído
   desta máquina é sempre aditivo, então o mínimo é o estimador certo, e as
   repetições isoladas variaram até 2× entre si. Nenhum candidato aloca: a
   contagem de scavenges deu zero dos dois lados em todos eles, e o custo que
   resta é de tempo, não de lixo.

As chamadas por quadro **não** foram estimadas: `_hashPaint`, `encodeHeader` e
`_packKey` foram instrumentados com um contador e a galeria rodou 120 quadros
no backend headless. O quadro de 60 Hz vale **16,667 ms**.

### O que a web sequer alcança

| Subsistema | Alcançável de `dart_ui.dart`? | Por quê |
|---|---|---|
| `src/audio/codecs/**` — FLAC, MP3, OGG, WAV, PCM, demuxer, CRC-8/16/32 | **não** | `src/audio/audio.dart` exporta só `audio_codec`, `audio_device` e `audio_format`. Os codecs saem apenas por `lib/audio.dart`, e nove deles importam `dart:io` ou `dart:ffi` direto — não é questão de alcance, é de viabilidade. |
| `src/backends/{win32,x11,wayland}/**` | **não** | `dart:ffi`. |
| `src/audio/{native,windows,playback,dsp}/**` | **não** | `dart:ffi`, `dart:io`. |
| `src/crypto/dart/**` — MD5, SHA-1/256/384/512, AES, RC4 | **sim** | `dart_ui.dart` exporta `src/crypto/crypto.dart`. |
| `src/graphics/image/**` — 117 arquivos: PNG, JPEG, WebP, EXIF, inflate | **sim** | |
| `src/pdf/**` (5 arquivos), `src/cdr/**` (8) | **sim, parcial** | só o recorte que `dart_ui.dart` exporta. |
| `src/graphics/display_list*`, `src/rendering/**`, `src/text/**` | **sim** | o núcleo. |

O candidato mais citado de antemão — os codecs de áudio, com suas tabelas de
CRC e seus escritores de bits — sai da lista inteiro, e nem foi preciso medir:
`dart:io` já o tinha excluído.

### O que sobrou, e quanto custa

Ganho por chamada é `atual − 64 bits`; positivo significa que a forma de 64
bits é mais rápida. Chamadas por quadro são medidas, na galeria headless.

| Candidato | O que a forma atual faz | ns/chamada, atual → 64 bits | Chamadas/quadro | Fração do quadro | Veredito |
|---|---|---|---|---|---|
| `_hashPaint`/`_mul32` (`graphics/display_list.dart`) | multiplica em metades de 16 bits | 2,20→1,55 e 3,59→1,51 nas duas séries; ganho 0,65 a 2,08 ns | **55,8** | 0,12 µs = **0,0007 %** | **não divide** |
| `encodeHeader` (`graphics/display_list_opcodes.dart`) | `.toUnsigned(32)` no cabeçalho | 0,49→0,82 e 1,02→1,10; a forma atual **nunca** foi a mais lenta | **121,4** | **0 %** | **não divide** — o imposto não existe |
| `_packKey` (`rendering/text/glyph_cache.dart` e `rendering/gpu/gpu_glyph_atlas.dart`) | multiplica em vez de deslocar, para caber em 53 bits | 0,42→1,55 e 0,65→1,20: a forma de 64 bits é **2× mais lenta** na VM | **171,4** | −0,0012 % | **não divide** — o imposto é negativo |
| SHA-512 em pares `(hi, lo)` (`crypto/dart/pure_dart_sha.dart`) | 80 rodadas sobre `Uint32List` | 31 MiB/s → 247 MiB/s, **7,9×** | **0** | **0 %** | **não divide** — ver abaixo |
| `shiftR`/`shiftL` no IDCT do JPEG (`image/codecs/formats/jpeg/`) | já dividido, mas em `dart.library.io` | a VM já pegava o ramo rápido; o **dart2wasm não** | 0 | 0 % na VM | eixo trocado — ver 69.5 |

Dispensados por inspeção, sem medir, e a razão de cada um:

- **MD5, SHA-1, SHA-256, AES, RC4, CRC-32 do PNG, Adler-32 do zlib.** São
  algoritmos de 32 bits *por definição*. Um `int` de 64 bits não compra nada:
  não há palavra partida, só aritmética modular de 32 bits que é o que a
  especificação manda.
- **`text/normalize.dart`.** A chave de composição empacota dois code points de
  21 bits em 42. Já está acima de 32 e dentro de 53 — a web não custou nada
  aqui, e 64 bits não acrescentariam nada.
- **`gradient.dart`, `text/cff.dart`, `crypto/windows/…_types.dart`,
  `audio/audio_device.dart`.** `toUnsigned(32)`/`toSigned(32)` em construção ou
  em formatação de mensagem, uma vez, fora de laço.
- **`webp/vp8l_transform.colorTransformDelta`.** Contorna o bug 16497 do
  dart2js passando por vistas de `TypedData`. É por decodificação de WebP, não
  por quadro.

### As duas coisas que a varredura achou e vale registrar

**SHA-512 é o único imposto grande — e não é de quadro.** Sobre 8 MiB, mínimo
de cinco execuções: 257 ms na forma atual contra 32,4 ms numa implementação de
64 bits nativos, conferida contra os vetores do FIPS 180-4 e contra a própria
forma atual em 600 comprimentos diferentes de entrada. São 7,9×, e é
exatamente a categoria que 69.3 chama de viabilidade — bitwise acima de 32
bits. Mesmo assim não divide, por duas razões que se somam: SHA-512 não roda
dentro de um quadro (ele roda quando um documento é assinado), então a
conversão para fração de quadro dá zero por não haver denominador; e duas
implementações de um primitivo criptográfico são o caso mais caro possível do
risco de divergência silenciosa que 69.3 levanta. Se um dia a assinatura de
documentos grandes virar reclamação medida, o número está aqui e a
implementação de 64 bits já foi escrita e conferida uma vez.

De passagem, no mesmo arquivo: `sha512` escreve o comprimento da mensagem com
`setUint32(padded.length - 4, lengthInBits & 0xFFFFFFFF)`. Os 64 bits que a
FIPS 180-4 reserva para o comprimento existem no buffer, mas só os 32 baixos
são escritos, então uma entrada acima de 512 MiB produz digest errado. É a
mesma mentalidade de 32 bits, mas é um defeito de correção, não de desempenho,
e não foi tocado nesta varredura.

**O seletor do JPEG está condicionado no eixo errado.** `jpeg_data.dart` faz

```dart
import '_jpeg_quantize_html.dart' if (dart.library.io) '_jpeg_quantize_io.dart';
```

O eixo é `dart.library.io`, que responde "este alvo tem sistema de arquivos",
não "este alvo é JavaScript". A VM tem `dart:io` e pega a versão rápida; o
**dart2wasm não tem**, e fica com a versão que passa cada deslocamento por
`shiftR`/`shiftL` (`(v >> n).toSigned(32)`) para contornar um bug que é só do
dart2js. É o caso que dá título a esta seção — uma plataforma penalizada por
causa de outra — só que a penalizada é o Wasm, e por isso o método de medição
desta seção, que roda na VM, não o enxerga.

Trocar a condição por `if (dart.library.js)` é uma linha, mas não era seguro
naquele dia: os dois arquivos **não** eram equivalentes. O `_io` tinha um
`if (index < 0) break` no clamp final que o `_html` não tinha, e os dois
copiavam o perfil ICC em pontos diferentes. Trocar mudaria o resultado do Wasm,
e a exigência de 69.3 — teste provando resultados idênticos onde ambos são
válidos — teria de ser cumprida antes. **Foi cumprida; ver 69.5.**

### O que continua valendo do item 4

Nada foi dividido nesta varredura, então o quarto caminho de código não foi
criado por ela e `test/backends/web/web_compilation_test.dart` segue rodando
`dart compile js` *e* `dart compile wasm`. A exigência continua de pé para toda
divisão: o ramo do dart2js precisa continuar sendo compilado pelo portão, e
precisa de um teste que o execute. **A primeira divisão a cumprir as duas é a
do JPEG, em 69.5.**

## 69.5 O eixo do JPEG, corrigido — 2026-08-26

A pendência que 69.4 deixou registrada foi fechada. O seletor de
`jpeg_data.dart` passou de

```dart
import '_jpeg_quantize_html.dart' if (dart.library.io) '_jpeg_quantize_io.dart';
```

para

```dart
import '_jpeg_quantize_io.dart' if (dart.library.js) '_jpeg_quantize_html.dart';
```

O que muda: o dart2wasm, que não tem `dart:io` e por isso caía no ramo do
contorno, passou a compartilhar com a VM o ramo sem contorno. O dart2js
continua com o `_html`, e nada mais mudou de alvo.

### As diferenças reais entre os dois arquivos

A leitura linha a linha achou **uma** divergência de comportamento, e não as
duas que 69.4 supunha:

| Diferença | Veredito |
|---|---|
| `shiftR`/`shiftL` em 45 deslocamentos do IDCT e da conversão de cor, e em 2 `<<` | o contorno; é a razão de existir da divisão |
| clamp final: `if (index < 0) break` no `_io`, indexação sem guarda no `_html` | **divergência real**, e um defeito nos dois — ver abaixo |
| perfil ICC copiado na construção (`_html`) ou no fim (`_io`) | **nenhuma**: `Image.iccProfile` nasce nulo, e a atribuição incondicional de `null` é a mesma coisa que não atribuir. Provado por teste, não por leitura |
| `_dctClip` como `final` de topo (`_io`) ou `Uint8List?` com verificação por chamada (`_html`) | nenhuma; um `final` de topo já é preguiçoso em todos os alvos |
| `lines[y]!` no `_io` contra `line![x]` no `_html` | nenhuma; o mesmo erro no mesmo lugar |
| `h`/`w` contra `height`/`width`, e `final cy` reatribuído | **dentro de um bloco `/* */`**: o `case 2` do PDF está comentado nos dois. Código morto, não divergência |

O clamp final era o único ponto de verdade, e o problema é maior do que "os
dois discordam". O índice vale `384 + ((p[i] + 8) >> 4)` numa tabela de 768
entradas que satura por construção. O `_io` guardava **só** o lado negativo, e
guardava com `break`, o que abandonava o resto do bloco de 64 amostras com o
lixo do bloco anterior; o lado positivo não era guardado em **nenhum** dos
dois, e estourava `RangeError`. Os dois lados são alcançáveis a partir de um
fluxo corrompido ou hostil: `p[i]` é o produto de um coeficiente da entropia
pela tabela de quantização, e as duas coisas vêm do arquivo.

O comportamento escolhido é **saturar**, que é o que a tabela de clip já faz no
miolo: um índice abaixo dela vira 0, um acima vira 255. Para todo índice dentro
da tabela — isto é, para todo JPEG válido — é bit a bit o que os dois já
faziam. Fora dela, troca um `break` que corrompia o bloco e um `RangeError` que
derrubava a decodificação por uma amostra saturada.

### A prova de equivalência

`test/graphics/image/jpeg_quantize_equivalence_test.dart` importa **os dois
arquivos com prefixo** — o que nenhum teste normal consegue, já que a
importação condicional só deixa um deles compilado — e exige bytes idênticos:

- `quantizeAndInverse` sobre 2.000 blocos aleatórios na faixa de um JPEG
  válido, 500 blocos com coeficientes extremos e 7 valores de DC escolhidos nas
  bordas exatas da tabela de clip, com `dataOut` pré-preenchido com um
  sentinela para que o `break` apareça se voltar;
- `getImageFromJpeg` sobre o mesmo JPEG nos dois ramos, comparando
  `toUint8List()`, o perfil ICC e a orientação, em 4:4:4, em 4:2:0 (inclusive
  1×1 e dimensões ímpares, que exercitam os deslocamentos de subamostragem),
  com e sem perfil ICC, e nas oito orientações EXIF.

Rodado **antes** da correção, ele falhava nos três testes de
`quantizeAndInverse` — `RangeError` em −10393 no `_html` e em 389785 no `_io` —
e passava nos cinco de imagem, que é o que estabeleceu que a diferença do ICC
não existia. Depois, passa nos oito.

O caminho CMYK de 4 componentes não tem fixture: o codificador deste pacote não
escreve 4 componentes. Ele é coberto pela geração mecânica descrita abaixo e
por inspeção — todos os valores ali são amostras de 0..255, muito longe de 32
bits.

Para que a equivalência não volte a se perder, `_jpeg_quantize_html.dart` foi
**gerado** a partir de `_jpeg_quantize_io.dart` por substituição mecânica dos
deslocamentos, e o cabeçalho dele diz isso. Fora do contorno, os dois arquivos
são a mesma sequência de caracteres.

### O ramo do dart2js, executado

A exigência do item 4 é cumprida por
`test/graphics/image/jpeg_quantize_dart2js_test.dart`, que compila uma sonda
com `dart compile js`, roda no Node e compara com a resposta da VM. Ele leva
2 s. São dois testes:

1. o ramo que o dart2js escolhe decodifica no dart2js os mesmos bytes que na
   VM;
2. o ramo **sem** contorno decodifica *diferente* no dart2js — uma armadilha
   deliberada: se um dia ela falhar, o dart2js parou de precisar do contorno e
   a divisão inteira pode ser apagada.

O segundo é o que justifica a divisão, e não é sutil. Num bloco perfeitamente
comum — quantização até 96, coeficientes até ±256 — o ramo sem contorno
devolve, no dart2js, `[255, 255, 255, …]` onde a VM e o ramo com contorno
devolvem `[0, 0, 255, 255, 255, 255, 0, 255, …]`. Não é imprecisão de último
bit: é a imagem errada. Isto é viabilidade, o critério que 69.3 chama de
"divida", e não otimização.

### O ganho, medido

`quantizeAndInverse` sobre 4.096 blocos com forma de bloco real, os dois ramos
no mesmo processo, mínimo de 9 séries alternadas após aquecimento longo:

| Alvo | sem contorno | com contorno | razão |
|---|---|---|---|
| dart2wasm (Node v24) | **757,5 ns/bloco** | 835,3 ns/bloco | **1,10×** |
| VM (AOT) | 757,3 ns/bloco | 948,9 ns/bloco | 1,25× |

O dart2wasm ganhou os ~78 ns por bloco de 8×8 que vinha pagando. Num JPEG
4:2:0 são 1,5 blocos por 64 pixels, ou ~23.400 blocos por megapixel: **~1,8 ms
por megapixel**, ~22 ms numa foto de 12 MP. Decodificação de JPEG não é
trabalho de quadro, então a regra de fração de quadro de 69.3 não se aplica —
mas aqui não é o ganho que decide a divisão, e sim o `[255, 255, 255, …]` da
seção anterior.

Duas observações sobre o método, porque custaram tempo: sob o V8 a diferença
`t(2N) − t(N)` que 69.4 usa **não** serve, porque o tiering faz a série longa
sair mais rápida por iteração que a curta e a diferença chega a dar negativa;
o que serve é aquecer bastante e tomar o mínimo de séries diretas alternadas.
E o número absoluto do Wasm oscila (757 a 1.215 ns entre execuções desta
máquina) enquanto a razão fica presa entre 1,08× e 1,18× — a razão é o que
vale, e o mínimo é o estimador certo, pelo mesmo motivo que 69.4 dá.

### Onde o portão continua

`test/backends/web/web_compilation_test.dart` passa nos três casos depois da
troca: `dart compile js`, `dart compile wasm` e `dart compile exe`. O
`_jpeg_quantize_io.dart` não importa `dart:io` — nunca importou; o nome é
herança do pacote de origem — e por isso o dart2wasm o aceita. Os nomes dos
dois arquivos foram mantidos de propósito, para não gerar ruído de diff em
cima de outras frentes; o cabeçalho de cada um diz qual alvo o recebe.

---

**Fim do roteiro.**
