# Exemplos

Cada pasta aqui é um **projeto Dart completo**: `pubspec.yaml` próprio (que
depende do `dart_ui` por `path: ../..`), `analysis_options.yaml`, `test/` e
`tool/` próprios. A suíte do framework em `test/` não importa nenhum exemplo;
os testes de cada exemplo rodam dentro dele, e o workflow
`.github/workflows/examples.yml` faz isso para todos.

```sh
cd examples/vector_editor_demo
dart pub get
dart run main.dart
dart test
```

Os exemplos existem para encontrar o que falta no `dart_ui`: quando um
exemplo precisa de algo que o framework não tem, a correção vai para `lib/`,
não para um contorno no exemplo.
