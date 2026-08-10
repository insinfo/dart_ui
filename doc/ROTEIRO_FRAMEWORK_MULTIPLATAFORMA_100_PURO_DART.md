# Roteiro de Engenharia — Framework de Interface Gráfica Multiplataforma em 100% Dart

> **Projeto-alvo:** `C:\MyDartProjects\dart_ui`  
> **Destino solicitado:** `C:\MyDartProjects\dart_ui\doc\ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md`  
> **Plataformas iniciais:** Windows, Linux e macOS  
> **Linguagem do framework:** Dart nativo  
> **Integração nativa:** `dart:ffi`, sem biblioteca intermediária escrita pelo projeto em C, C++, Objective-C ou Swift  
> **Modelo de widgets:** widgets, layout, estilos, eventos, composição e acessibilidade implementados em Dart  
> **Backends planejados:** Win32, GDI, Direct2D, Direct3D 11, DirectComposition, X11/XCB, Wayland, GTK opcional, OpenGL, Vulkan, AppKit, Core Graphics e Metal  
> **Referências arquiteturais principais:** Avalonia, OpenJFX/JavaFX, `dart_graphics`, `marlin`, `win32` e demais referências locais

---

# Sumário

- [Roteiro de Engenharia — Framework de Interface Gráfica Multiplataforma em 100% Dart](#roteiro-de-engenharia-framework-de-interface-grafica-multiplataforma-em-100-dart)
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
- vídeo;
- WebGPU;
- iOS/Android;
- navegador;
- renderização remota;
- controles nativos embutidos;
- editor visual;
- hot reload avançado;
- acessibilidade completa de todos os padrões;
- internacionalização avançada;
- suporte a HDR amplo;
- múltiplas GPUs;
- interop de textura com engines externas.

## 4.3 Fora de escopo

- portar integralmente Avalonia;
- portar integralmente JavaFX;
- reproduzir todas as APIs do Flutter;
- criar um sistema operacional gráfico;
- implementar drivers de GPU;
- substituir o compositor do desktop;
- criar uma ABI binária estável para plugins nativos no primeiro release;
- oferecer pixel idêntico entre plataformas quando as fontes instaladas diferem.

---

# 5. Matriz inicial de plataformas

| Plataforma | Janela primária | Janela alternativa | CPU | GPU primária | GPU alternativa |
|---|---|---|---|---|---|
| Windows 10/11 x64/arm64 | Win32 | — | GDI/DIB + `dart_graphics` | Direct2D sobre D3D11/DXGI | OpenGL/Vulkan |
| Linux X11 x64/arm64 | XCB | GTK shell opcional | XCB SHM | OpenGL/EGL ou Vulkan | upload de CPU |
| Linux Wayland x64/arm64 | Wayland + xdg-shell | GTK shell opcional | `wl_shm` | Vulkan ou EGL/OpenGL | upload de CPU |
| macOS x64/arm64 | AppKit por Objective-C Runtime | — | Core Graphics | Metal + `CAMetalLayer` | upload CPU para Metal |

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

1. suporte `WM_IME_*` com IMM32;
2. composição, candidato e caret;
3. integração com `TextInputClient`;
4. evolução opcional para TSF.

Contrato comum:

```dart
abstract interface class TextInputClient {
  TextEditingValue get value;
  Rect get caretRect;
  TextRange get composingRange;

  void updateEditingValue(TextEditingValue value);
  void commitText(String text);
  void setComposingRegion(TextRange range);
  void deleteSurroundingText(int before, int after);
}
```

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

- [ ] janela e múltiplas janelas;
- [ ] DPI por monitor;
- [ ] CPU/GDI;
- [ ] mouse, teclado, pointer;
- [ ] IME;
- [ ] clipboard;
- [ ] drag-and-drop;
- [ ] cursor;
- [ ] monitores;
- [ ] temas;
- [ ] Direct2D;
- [ ] D3D11/DXGI;
- [ ] DirectComposition opcional;
- [ ] acessibilidade básica;
- [ ] device-loss;
- [ ] leak-check;
- [ ] AOT x64;
- [ ] AOT arm64;
- [ ] testes em Windows 10 e 11.

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
├── x11_ime.dart
├── x11_accessibility.dart
└── x11_diagnostics.dart
```

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

Usar `xkbcommon`:

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

- [ ] XCB sem Xlib obrigatória;
- [ ] janela;
- [ ] resize/move/focus;
- [ ] CPU SHM;
- [ ] XKB;
- [ ] mouse/wheel;
- [ ] XInput2;
- [ ] clipboard INCR;
- [ ] XDND;
- [ ] RandR;
- [ ] OpenGL/EGL;
- [ ] Vulkan opcional;
- [ ] AT-SPI básico;
- [ ] GNOME/KDE/Xfce;
- [ ] Xorg e XWayland;
- [ ] x64 e arm64.

---

# 16. Backend Wayland

Wayland deverá ser tratado como protocolo, não como uma coleção de funções equivalentes ao Win32.

## 16.1 Gerador de protocolo em Dart

As funções inline geradas em C não fazem parte da ABI de `libwayland-client`. Portanto, o projeto deverá gerar seus próprios stubs Dart a partir dos XMLs.

```text
tools/wayland_codegen/
├── bin/wayland_codegen.dart
├── lib/src/xml_parser.dart
├── lib/src/model.dart
├── lib/src/dart_emitter.dart
└── test/
```

Gerar:

- interface;
- opcode de requests;
- eventos;
- assinatura;
- versão;
- enums;
- bitfields;
- listeners;
- wrappers de `wl_proxy`;
- marshalling via APIs não variádicas;
- validação de versão;
- documentação de ownership.

Evitar FFI variádica. Usar arrays de argumentos e funções estáveis da biblioteca.

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

Fluxo correto:

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

Criar testes de máquina de estados para não bloquear nem perder eventos.

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

- keymap recebido por FD;
- mapear e alimentar `xkbcommon`;
- modifiers;
- repeat info;
- repeat timer;
- pointer enter/leave/motion/button/axis;
- axis source/discrete/value120;
- touch frames;
- serials registrados;
- high-resolution scroll;
- cursor surface;
- tablet protocol posterior.

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

- [ ] gerador XML;
- [ ] xdg-shell;
- [ ] `wl_shm`;
- [ ] frame callback;
- [ ] teclado xkbcommon;
- [ ] pointer/touch;
- [ ] clipboard;
- [ ] drag-and-drop;
- [ ] text-input-v3;
- [ ] scaling inteiro/fracionário;
- [ ] EGL ou Vulkan;
- [ ] portais;
- [ ] GNOME/KDE/wlroots;
- [ ] protocolo sem deadlock;
- [ ] buffers sem use-after-release.

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

- validação sem erros;
- nenhum objeto destruído antes da fence;
- resize contínuo;
- swapchain out-of-date;
- múltiplas janelas;
- fallback;
- benchmark contra OpenGL;
- ausência de stutter após cache aquecido.

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

- [ ] clear/present;
- [ ] resize Retina;
- [ ] display list básica;
- [ ] texto;
- [ ] clips;
- [ ] layers;
- [ ] múltiplas janelas;
- [ ] perda/indisponibilidade tratada;
- [ ] fallback CPU;
- [ ] Intel e Apple Silicon;
- [ ] validação sem erros.

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

Suportar inicialmente PNG, JPEG, WebP quando biblioteca Dart existente for suficiente. Decodificadores nativos podem ser plugins opcionais.

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

- Text;
- Icon;
- Image;
- Button;
- ToggleButton;
- CheckBox;
- RadioButton;
- TextField;
- TextArea;
- PasswordField;
- Slider;
- Progress;
- Switch;
- ComboBox;
- ListBox;
- TreeView;
- Table/DataGrid posterior;
- Tabs;
- Menu;
- ContextMenu;
- Toolbar;
- Tooltip;
- Dialog;
- SplitView;
- Expander;
- Calendar/DatePicker posterior.

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
- o probe anuncia somente `window`, `multipleWindows` e `orderlyShutdown`;
  apresentação CPU, input, cursor nativo e DPI por monitor continuam fora;
- trinta e oito testes X11 portáveis cobrem conexão, ABI/lifecycle da janela,
  decoder, tradução, coalescimento, roteamento, generation e descarte;
- o smoke AOT do backend criou, expôs, redimensionou e fechou uma janela real
  sob Xvfb no
  [GitHub Actions #31346512333](https://github.com/insinfo/dart_ui/actions/runs/31346512333),
  com probe/window/smoke verdes; os POCs X11 e o MVP-02 também permanecem
  verdes no
  [GitHub Actions #31343963060](https://github.com/insinfo/dart_ui/actions/runs/31343963060);
- as referências locais confirmaram os padrões sem cópia de código: Cairo
  1.18.4 (LGPL-2.1/MPL-1.1) para create checked e futuro PutImage em bandas,
  Avalonia `064b84a` (MIT) para lifecycle/roteamento por XID, e Skia
  `2eed75b` (BSD-3) para drenagem limitada/coalescida;
- Wayland/Weston segue como POC: o
  [GitHub Actions #31343964231](https://github.com/insinfo/dart_ui/actions/runs/31343964231)
  comprovou conexão, registry, `wl_compositor`, `wl_shm`, surface, commit e
  teardown, mas ainda não `xdg-shell` nem o lifecycle de `wl_buffer.release`.

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

### Objetivo

Primeiro renderer GPU de produção.

### Trabalho

- COM generator;
- D3D11 device;
- DXGI;
- swapchain;
- D2D device/context;
- DirectWrite opcional apenas como renderer de comparação/fallback;
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

- backend CPU estável nas três plataformas;
- ao menos D2D e Metal estáveis;
- Linux GPU estável por OpenGL ou Vulkan;
- X11 estável;
- Wayland ao menos beta com CPU;
- widgets e texto estáveis;
- acessibilidade básica funcional;
- sem leaks conhecidos críticos;
- CI multi-plataforma;
- documentação de limitações;
- nenhuma dependência de wrapper nativo próprio.

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

# 62. Checklist do primeiro release interno

- [ ] monorepo;
- [ ] inventário;
- [ ] licenças;
- [ ] foundation;
- [ ] display list;
- [ ] headless;
- [ ] CPU renderer;
- [ ] Win32 window;
- [ ] GDI;
- [ ] input;
- [ ] Button;
- [ ] Text;
- [ ] layout;
- [ ] focus;
- [ ] semantics;
- [ ] golden;
- [ ] benchmark;
- [ ] leak test;
- [ ] AOT;
- [ ] sample;
- [ ] documentação.

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

A primeira ação no repositório deverá ser:

1. copiar este arquivo para `C:\MyDartProjects\dart_ui\doc`;
2. executar o inventário local;
3. preencher a matriz de referências;
4. confirmar a licença do novo projeto;
5. criar os pacotes mínimos;
6. implementar o backend headless;
7. implementar o spike de WndProc;
8. só então iniciar o primeiro Button.

Esse fluxo evita que o projeto se transforme em uma coleção de bindings sem framework ou em um framework sem backend executável.

---

**Fim do roteiro.**
