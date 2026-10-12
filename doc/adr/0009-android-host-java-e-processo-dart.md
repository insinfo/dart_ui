# ADR 0009 — Android: activity Java como host e a VM do Dart como processo filho

**Status:** aceito
**Data:** 12 de outubro de 2026
**Relacionado:** [ADR 0001](0001-worker-process-com-iosurface-no-macos.md) (o mesmo
desenho no macOS), [ADR 0010](0010-dart-aot-embutido-android-ios.md) (o caminho
embutido, para as lojas e para o iOS), [`ANDROID_IOS.md`](../ANDROID_IOS.md)

## Contexto

O Android dá a janela a uma `Activity`, que vive na thread de UI de um processo
iniciado pelo zygote. O roteiro (seção 2.2) proíbe ponte JNI e biblioteca nativa
própria em C/C++. Não existe Dart SDK oficial para Android: o Google publica o
SDK para Linux arm64, não para Android.

O que existe, medido em 12/10/2026: o pacote `dart` do Termux (3.13.5) é o SDK
compilado para Android, e os binários dependem **só** de bibliotecas do sistema
(`libc.so`, `libdl.so`, `libm.so`, `liblog.so`, sem `RUNPATH`). A VM (`dartvm`)
roda num emulador Android 15 arm64 um kernel compilado no macOS pelo Dart
3.13.5 oficial: `Platform.operatingSystem == 'android'`, e a libc tem
`memfd_create`, `mmap64` e `ftruncate64`.

## Decisão

**O app é uma activity em Java que inicia a VM do Dart como processo filho.**

- O APK leva `lib/<abi>/libdartvm.so` (a VM) e `lib/<abi>/libdartui_app.so` (o
  kernel da aplicação). Com o nome `lib*.so` e `extractNativeLibs="true"`, o
  gerenciador de pacotes os extrai para o diretório de bibliotecas nativas,
  único lugar de onde um app (targetSdk ≥ 29) pode executar arquivos.
- A activity (`lib/src/backends/android/host/`) abre um `LocalServerSocket` no
  namespace abstrato, inicia a VM com o nome em `DART_UI_ANDROID_SOCKET` e fala
  o protocolo binário de `android_host_protocol.dart`.
- Os quadros vão por `memfd` compartilhado (dois buffers RGBA), cujos
  descritores viajam como `SCM_RIGHTS` no socket. O host mapeia, copia num
  `Bitmap` e desenha no `SurfaceView`.
- O socket do lado Dart é o transporte libc do backend Wayland. O `dart:io` só
  anexa descritores de arquivos que ele mesmo abriu, e o SELinux não deixa um
  app reabrir o próprio `memfd` por `/proc/self/fd`.

## Justificativa

- Cumpre a seção 2.2 sem exceção: o host é Java (bytecode Dart nenhum, código
  nativo nenhum) e a VM é um executável, não uma biblioteca carregada por JNI.
- Repete o desenho já aceito no macOS (ADR 0001): a plataforma fica com a
  thread de UI, o Dart do outro lado de um socket, pixels por memória
  compartilhada.
- Funcionou no primeiro dia: `example/hello_world.dart` desenha com Roboto,
  responde a toque e conta cliques no emulador.

## Consequências e limites

- **Cópia por quadro:** o host copia o buffer para um `Bitmap` e o `Bitmap` para
  a superfície. Não há GPU direta; para isso o processo precisaria da janela
  (`ANativeWindow`), que só o modelo embutido do ADR 0010 dá.
- **JIT ou AOT:** sem `--aot` o app vai como kernel, que abre mais devagar e
  fica legível no APK. Com `--aot` (12/10/2026) vai como snapshot ELF com o
  `dartaotruntime`, ambos do Dart SDK compilado do código-fonte (ADR 0010), e o
  Termux sai do APK.
- **Runtime de terceiros:** o repositório do Termux guarda só a versão mais
  nova de cada pacote. O build fixa 3.13.5 e guarda o `.deb` em cache; a troca
  por um runtime compilado do código-fonte do Dart SDK é parte do ADR 0010.
- **Lojas:** para o Google Play faltam AAB, targetSdk 35 com edge-to-edge
  (insets no framework) e binários alinhados a 16 KB. Este ADR não as cobre.
- **iOS:** este desenho não se aplica. O iOS proíbe criar processos e JIT.

## Proibido

Depender do motor do Flutter, em qualquer forma, para carregar a VM.
