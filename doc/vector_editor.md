#  Vector Editor  Vector Graphics Framework em 100% Puro Dart (`dart_ui`)

Implementação completa e de nível de produção da arquitetura do editor vetorial inspirado em **sK1-wx** e **UniConvertor** em **100% Puro Dart** sobre o framework gráfico multiplataforma `dart_ui`.

---

## 🎯 Resumo Executivo & Decisões Confirmadas

- **Formato Nativo**: **CorelDRAW (.cdr)** — Suporte completo a RIFF binário (CDR v3 a v13) e ZIP estruturado (CDR X4 a 2024), com tradução direta bidirecional via `CdrTranslator`.
- **Formatos de Importação e Exportação**:
  - **CorelDRAW (.cdr)**: Leitura e escrita nativa completa.
  - **SVG 1.1**: Importação e exportação de nós, primitivas geométricas e estilos via `VectorSvgCodec`.
  - **PDF (ISO 32000)**: Exportação de alta fidelidade vetorial via `VectorPdfExporter`.
- **Renderização e DisplayList**: Renderizador nativo `VectorRenderer` que compila árvores de documentos vetoriais diretamente em comandos do `DisplayList` do `dart_ui` com aceleração de hardware sem dependência de bibliotecas nativas C/C++ ou Cairo.
- **Aplicação Completa**: Implementada em `examples/vector_editor_demo/` com MenuBar, Tool Palette, Context Ribbon, Viewport com Pan/Zoom, Réguas graduadas em tempo real, Paleta de Cores e StatusBar.

---

## 🏗️ Arquitetura dos Módulos Implementados

### 1. Modelo de Documento Vetorial DOM (`lib/src/graphics/vector/`)
- [constants.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/constants.dart): Enumerações (`DocUnit`, `DocOrigin`, `FillType`, `LineCap`, `LineJoin`, `ArcType`, `NodeType`, `PathClosure`, `PageOrientation`) e formatos de página (`PageFormats.a4`, `letter`, etc.).
- [document_object.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/document_object.dart): Classe base abstrata `DocumentObject` com hierarquia de nós, clonagem profunda (`copy()`, `createEmpty()`, `copyFields()`), invalidação e cálculo de *bounding box* em cache (`cacheBbox`).
- [document.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/document.dart): Raiz `VectorDocument` e container `VectorPages`, gerenciador de páginas e camadas (`desktopLayers`, `pages`, `masterLayers`).
- [structural_objects.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/structural_objects.dart): `VectorPage`, `VectorLayer`, `GuideLayer`, `GridLayer`, `MasterLayers`, `DesktopLayers`, `VectorGuide`.
- [selectable_objects.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/selectable_objects.dart): `SelectableObject`, `VectorGroup`, `TPGroup` (texto no caminho), `VectorContainer` (máscara de recorte) e utilitários de transformação afim 2D de 6 elementos (`multiplyTrafo`, `applyTrafoToPoint`, `applyTrafoToPoints`, `trafoRotate`, `pointsDistance`, `getPointAngle`).
- [primitives.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/primitives.dart): Primitivas geométricas com cálculo analítico de nós e Béziers: `VectorRectangle`, `VectorCircle`, `VectorPolygon`, `VectorCurve`, `VectorText` e `VectorPath`.
- [pixmap.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/pixmap.dart): Contêiner de imagens bitmap embutidas.
- [style.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/style.dart): `FillDescriptor`, `StrokeDescriptor`, `TextStyleDescriptor`, `VectorStyle` e `GradientColorStop`.
- [doc_methods.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/doc_methods.dart): `DocumentMethods` fornecendo operações CRUD de alto nível, z-ordering (`raiseObject`, `lowerObject`, `toFront`, `toBottom`), agrupamento/desagrupamento e criação de primitivas.

### 2. Motor de Geometria Vetorial (`lib/src/geometry/`)
- [bezier.dart](file:///C:/MyDartProjects/dart_ui/lib/src/geometry/bezier.dart): Avaliação analítica de curvas de Bézier cúbicas e quadráticas, derivadas, subdivisão de De Casteljau (`splitCubic`, `splitQuadratic`), localização exata de extremos por raízes da derivada (`cubicExtremaRoots`), *bounding box* estrita analítica (`cubicTightBounds`), achatamento recursivo (`flattenCubic`) e conversão bidirecional entre `VectorPath` e `Path`.
- [contour.dart](file:///C:/MyDartProjects/dart_ui/lib/src/geometry/contour.dart): Gerador de contorno de traço (`strokeToOutline`) com suporte a pontas de linha (`butt`, `round`, `square`) e extrusão de normais.
- [shaping.dart](file:///C:/MyDartProjects/dart_ui/lib/src/geometry/shaping.dart): Operações booleanas 2D em polígonos e caminhos (`union`, `intersection`, `difference`, `exclusion`).

### 3. Engine CorelDRAW Nativo (`lib/src/cdr/`)
- [cdr_color_parser.dart](file:///C:/MyDartProjects/dart_ui/lib/src/cdr/styles/cdr_color_parser.dart): Parser e conversor de modelos de cor binários do CorelDRAW (CMYK, RGB, Grayscale, Pantone/Spot).
- [riff_writer.dart](file:///C:/MyDartProjects/dart_ui/lib/src/cdr/container/riff_writer.dart): Escritor de envelopes binários RIFF alinhados a palavras de 16/32 bits e subchunks.
- [cdr_translator.dart](file:///C:/MyDartProjects/dart_ui/lib/src/cdr/document/cdr_translator.dart): Tradutor completo bidirecional `VectorDocument` ↔ `CdrDocument`, serializando documentos para CDR6 binário (`vrsn`, `DISP`, `LIST page`, `crve`, `fild`, `outl`).
- [cdr_document.dart](file:///C:/MyDartProjects/dart_ui/lib/src/cdr/document/cdr_document.dart): Adicionados métodos `toVectorDocument()` e construtor de fábrica `CdrDocument.fromVectorDocument()`.

### 4. Serialização e Interoperabilidade (`lib/src/graphics/vector/serialization/`)
- [vector_pdf_exporter.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/serialization/vector_pdf_exporter.dart): Exportador vetorial de alta definição para PDF padrão (ISO 32000).
- [vector_svg_codec.dart](file:///C:/MyDartProjects/dart_ui/lib/src/graphics/vector/serialization/vector_svg_codec.dart): Codec SVG bidirecional para importação e exportação de documentos vetoriais SVG 1.1 / SVG Tiny.

### 5. Widgets Especializados do Editor Vetorial (`lib/src/widgets/vector_editor/`)
- [vector_canvas.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/vector_canvas.dart): Viewport interativo com pan, zoom contínuo, integração com réguas e eventos de ponteiro.
- [vector_renderer.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/vector_renderer.dart): Compilador DisplayList que renderiza fundo, sombra de página, folha, objetos gráficos, grade, guias e alças de seleção.
- [selection.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/selection.dart): Gerenciador de seleção única/múltipla, *bounding box* unificada e 8 alças de transformação (*handles*).
- [snap_manager.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/snap_manager.dart): Motor de atração magnética (*snapping*) para grade e linhas guia.
- [ruler.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/ruler.dart): Régua horizontal e vertical interativa com graduações adaptativas em escala e indicador de posição do cursor.
- [tool_controller.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/tool_controller.dart): Controladores de ferramentas interativas (`SelectToolController`, `RectangleToolController`, `CircleToolController`, `CurveToolController`).
- [color_controls.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/color_controls.dart): Barra inferior de paleta de cores (swatches CorelDRAW) com clique para preenchimento e clique com modificador para traço.
- [fill_controls.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/fill_controls.dart): Controles de tipo de preenchimento (nenhum, sólido, gradiente linear/radial).
- [stroke_controls.dart](file:///C:/MyDartProjects/dart_ui/lib/src/widgets/vector_editor/stroke_controls.dart): Controles de espessura de linha, terminais de linha (*caps*) e junções (*joins*).

### 6. Aplicação Desktop Demo (`examples/sk1_editor_demo/`)
- [main.dart](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/main.dart): Ponto de entrada CLI/GUI suportando abertura de arquivos `.cdr` e `.svg`.
- [app.dart](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/app.dart): Wrapper do aplicativo `SK1EditorApp`.
- [main_window.dart](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/main_window.dart): Layout de janela profissional integrando todos os painéis, menus e ferramentas.
- [menu_bar.dart](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/menu_bar.dart): Menus suspensos com atalhos de arquivo, edição, seleção e agrupamento.
- [toolbar.dart](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/toolbar.dart): Barra de ferramentas vertical com ferramentas de criação e manipulação.
- [context_panel.dart](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/context_panel.dart): Faixa de propriedades contextuais dinâmicas.
- [status_bar.dart](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/status_bar.dart): Barra de status com coordenadas, contagem de seleção e metadados.
- [document_api.dart](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/document_api.dart): Gerenciador transacional de comandos com pilha de Undo / Redo.
- [README.md](file:///C:/MyDartProjects/dart_ui/examples/sk1_editor_demo/README.md): Guia de arquitetura e instruções de execução.

---

## 🧪 Verificação e Cobertura de Testes Automatizados

Todos os testes passaram com 100% de sucesso e 0 erros do analisador Dart:
1. `test/graphics/vector/vector_document_test.dart` (5 testes unitários do modelo DOM, transformações, clonagem profunda e z-ordering).
2. `test/geometry/bezier_ops_test.dart` (5 testes unitários de curvas de Bézier, divisão de De Casteljau, raízes e achatamento).
3. `test/cdr/cdr_vector_integration_test.dart` (2 testes de integração serializando `VectorDocument` para CDR binário e lendo de volta).
4. `test/graphics/vector/serialization_test.dart` (3 testes de exportação SVG, importação SVG e exportação PDF).
