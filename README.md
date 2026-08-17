# dart_ui

Aplicações usam somente a fachada pública:

```dart
import 'package:dart_ui/dart_ui.dart';

void main() => runApp(const MyApp());
```

## Compilar uma aplicação desktop

O CLI público compila no sistema operacional atual e produz o artefato de
lançamento gráfico adequado:

```shell
dart run dart_ui build example/hello_world.dart -o build/hello_world
```

- Windows: gera `.exe` e muda o subsistema PE para GUI, eliminando a janela de
  console. Use `--console` para manter o terminal durante depuração.
- Linux: gera o binário e um launcher `.desktop` com `Terminal=false`.
- macOS: gera um bundle `.app` com `Contents/Info.plist`, `Contents/MacOS/` e
  `Contents/Resources/`.

`dart compile exe` não faz cross-compilation: cada artefato deve ser produzido
no próprio sistema operacional. Distribuição pública no Windows/macOS também
deve assinar o artefato depois do build; alterar um executável já assinado
invalida sua assinatura.

O cabeçalho de um `.exe` também pode ser inspecionado diretamente:

```shell
dart run dart_ui pe example/hello_world.exe --info
dart run dart_ui pe example/hello_world.exe --gui
```

## Imagens e SVG

JPEG, PNG e WebP usam os codecs otimizados da plataforma primeiro: WIC no
Windows, ImageIO/CoreGraphics no macOS, TurboJPEG no Linux e
`createImageBitmap` no navegador. Se o codec não existir ou falhar, o mesmo
contrato cai para o decodificador Dart; headless e CI não dependem de uma
biblioteca nativa instalada.

```dart
final DecodedImage photo = await decodeImageAsync(bytes);
final Widget icon = Svg.string(svgSource);
```

O decode aplica limites contra imagens hostis, orientação EXIF e converte uma
única vez para pixels pré-multiplicados. SVG suporta paths completos
(`M/L/H/V/C/S/Q/T/A/Z`), formas básicas, transformações, fill, stroke,
`currentColor` e regras non-zero/even-odd. Gradientes, filtros, texto SVG,
`<use>` e folhas CSS externas continuam fora deste primeiro recorte.

## APIs de widgets, cores e temas

A superfície pública segue os contratos do Flutter sempre que o motor já
consegue honrá-los. Cores são valores `Color`, não inteiros soltos; o inteiro
ARGB existe somente na fronteira interna da display list.

```dart
const color = Color(0xFF2563EB);
final translucent = color.withOpacity(0.4);

Theme(
  data: ThemeData.materialDark,
  child: const Icon(PhosphorIcons.magnifyingGlass),
);
```

`ThemeData`, `ColorScheme`, `TextTheme`, `TextStyle`, `IconThemeData`,
`ProgressIndicatorThemeData`, `ScrollbarThemeData`, `Brightness`,
`FontWeight`, `Icon`, `IconButton`, `TextField.focusNode` e os indicadores de
progresso usam nomes e tipos compatíveis com o subconjunto implementado do
Flutter. `ThemeData.materialLight` e `ThemeData.materialDark` fornecem os
modos claro e escuro modernos.

`FrameworkFonts.install()` registra Inter Regular/Medium/SemiBold, Material
Icons, Tabler Icons e os 1.512 ícones regulares do Phosphor Icons 2.1.2 a
partir de `assets/fonts`. A API é direta — por exemplo,
`Icon(PhosphorIcons.floppyDisk)` — e todos os glifos são vetoriais e escaláveis.
Licenças e atribuições estão em `THIRD_PARTY_NOTICES.md` e ao lado dos próprios
arquivos.

## Processamento em segundo plano

`compute` possui o contrato familiar do Flutter e executa a função em outro
isolate nas plataformas nativas. Na web, usa o fallback assíncrono compatível.

```dart
final document = await compute<Uint8List, PdfDocument>(
  PdfDocument.fromBytes,
  bytes,
  debugLabel: 'pdf.parse',
);
```

O relógio de animação acorda o loop nativo a cada frame necessário. Assim,
`CircularProgressIndicator()` e `LoadingSpinner()` continuam animados enquanto
um isolate lê ou interpreta um arquivo.

## Leitor PDF

O exemplo completo abre arquivos pelo seletor multiplataforma, interpreta o
PDF em isolate, navega, busca, ajusta página/largura, aplica zoom, alterna tema,
seleciona texto continuamente entre páginas e copia pelo menu de contexto:

```shell
dart run examples/pdf_reader_demo/main.dart
```

O rodapé de diagnóstico do leitor informa o modo do Dart e a cadeia gráfica
realmente selecionada, por exemplo `AOT • GPU/direct3d11 • win32`. Para comparar
o mesmo documento no Windows sem depender da seleção automática:

```shell
dart run examples/pdf_reader_demo/main.dart --presentation direct3d11
dart run examples/pdf_reader_demo/main.dart --presentation opengl
dart run examples/pdf_reader_demo/main.dart --presentation win32-dib
```

`--gpu` e `--cpu` também restringem a categoria de apresentação. Uma aplicação
pode consultar os mesmos dados publicamente com
`ApplicationInfo.of(context)`; código fora da árvore de widgets pode usar
`Application.instance.runtimeInfo`. O resultado inclui JIT/AOT, backend de
janela, apresentação CPU/GPU, renderer ativo e escalas lógica/física.

`PdfViewController` expõe navegação, busca e seleção; `PdfTextSelection`
registra página e deslocamento tanto da âncora quanto da extensão. A seleção é
mantida quando cruza páginas e o texto copiado preserva as quebras entre elas.

## Docking desktop

`DockingLayout` organiza `DockingItem`, `DockingTabs`, `DockingRow` e
`DockingColumn`. O widget `Docking` renderiza abas, divisores redimensionáveis,
fechamento, seleção, maximização de painel/grupo e restauração. Alterações de
layout também podem ser dirigidas programaticamente por `addItem`, `moveItem`
e `removeItem`.

```dart
final layout = DockingLayout(
  root: DockingRow(<DockingArea>[
    DockingItem(name: 'Arquivos', widget: const FilesPanel()),
    DockingTabs(<DockingItem>[
      DockingItem(name: 'Documento', widget: const Editor()),
    ]),
  ]),
);

Docking(layout: layout);
```

Uma aplicação executável está em `examples/docking_demo/main.dart`. O modelo
foi adaptado de `docking_flutter` sob licença MIT; o aviso integral está em
`THIRD_PARTY_NOTICES.md`.
