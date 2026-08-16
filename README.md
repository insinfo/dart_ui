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
