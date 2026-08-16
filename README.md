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
