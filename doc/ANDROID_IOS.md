# Android e iOS

Estado em 12/10/2026. As decisões estão nos ADRs
[0009](adr/0009-android-host-java-e-processo-dart.md) (Android com host Java,
funcionando) e [0010](adr/0010-dart-aot-embutido-android-ios.md) (Dart AOT
embutido, para as lojas e para o iOS, em implementação). O dart_ui não depende
do Flutter em nenhum desses caminhos.

## Android (host Java + processo Dart)

### Como gerar e rodar

```
export ANDROID_HOME=/caminho/android-sdk        # platforms;android-35 e build-tools
export JAVA_HOME=/caminho/jdk-17
export DART_UI_ANDROID_DART=/caminho/dart-3.13.5/bin/dart
dart run tool/android/build_apk.dart example/hello_world.dart \
    --out build/android/hello.apk --package dev.dartui.hello --run
```

O kernel precisa vir de um Dart **3.13.5**, a versão da VM empacotada
(`runtimeVersion` em `tool/android/build_apk.dart`). Na primeira vez o script
baixa o pacote `dart` do Termux para `build/android/runtime/`. `--abi x86_64`
gera para emulador x86_64.

### O que funciona (emulador Android 15 arm64)

- janela em tela cheia, com tamanho e densidade da tela (`renderScale`);
- desenho pelo caminho CPU `android-cpu`: dois `memfd` RGBA, sem conversão de cor;
- texto com as fontes do sistema (Roboto, `/system/fonts`);
- toque com vários dedos, caneta e mouse; roda do mouse; teclado físico;
- teclado virtual que abre quando um campo de texto ganha foco (texto confirmado
  pela palavra, sem pré-edição ainda);
- Voltar vira pedido de fechar janela; foco e visibilidade da activity;
- menus e popups dentro da janela (a activity é uma janela só).

### O que falta

- AOT (hoje é JIT), GPU direta, áreas das barras do sistema (insets), AAB,
  targetSdk 35 e alinhamento de 16 KB para o Google Play — ver ADR 0010.

### Peças

| Arquivo | Papel |
|---|---|
| `lib/src/backends/android/host/` | activity Java e manifesto |
| `lib/src/backends/android/android_host_protocol.dart` | protocolo binário |
| `lib/src/backends/android/android_backend.dart` | `WindowingBackend` |
| `lib/src/backends/android/android_window.dart` | janela e buffers |
| `lib/src/backends/android/android_shared_memory.dart` | `memfd` e `mmap` |
| `lib/src/backends/android/android_text_input.dart` | teclado virtual |
| `tool/android/build_apk.dart` | APK sem Gradle |

## iOS

Precisa do caminho embutido do ADR 0010: o iOS proíbe processos filhos e JIT.
Ferramentas prontas no Mac de desenvolvimento: Xcode 27.0 em
`/Volumes/ssd_dock/Xcode.app` (usar `DEVELOPER_DIR`), SDKs iOS 27.0 e runtime
do simulador iOS 27.0.
