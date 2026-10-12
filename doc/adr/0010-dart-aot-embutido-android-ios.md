# ADR 0010 — Android e iOS: Dart AOT embutido no app, runtime compilado do Dart SDK

**Status:** proposto (em implementação desde 12 de outubro de 2026)
**Data:** 12 de outubro de 2026
**Relacionado:** [ADR 0009](0009-android-host-java-e-processo-dart.md),
[ADR 0001](0001-worker-process-com-iosurface-no-macos.md),
[`ANDROID_IOS.md`](../ANDROID_IOS.md)

## Contexto

O ADR 0009 põe o dart_ui no Android sem código nativo, mas não serve para o
iOS e tem limites para as lojas:

- o **iOS** proíbe criar processos e JIT. Todo código que executa precisa estar
  no Mach-O assinado do app: o Dart vai compilado em AOT e **ligado** ao
  executável, com o runtime junto;
- no **Android**, desenhar com GPU exige a `ANativeWindow` da superfície no
  processo que desenha, e o AOT exige um `gen_snapshot` que gere código Android.

Nenhum dos dois existe pronto: o Dart SDK oficial não traz `gen_snapshot`
cruzado para android-arm64 ou ios-arm64, nem o runtime AOT como biblioteca. O
roteiro (seção 2.3, e as condições de reabertura do log
`DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md`) já previa reabrir a decisão "se o
projeto precisar compilar o SDK do Dart por outra razão". Mobile é essa razão.

## Decisão proposta

1. **Compilar o Dart SDK do código-fonte** (`dart-lang/sdk`, tag igual à do SDK
   que compila o kernel; hoje 3.13.5) para `android-arm64`, `android-x64` e
   `ios-arm64` (aparelho e simulador). Produtos: `gen_snapshot` do host para cada
   alvo, e o runtime AOT (`dart_precompiled_runtime`) como biblioteca estática.
   Um job de CI publica esses artefatos; nenhum desenvolvedor precisa compilar.
2. **Camada nativa mínima**, a única exceção à seção 2.2 que este ADR pede:
   - iOS: um `main` que inicia a VM, carrega o snapshot ligado ao binário e roda
     o isolate principal; `UIApplicationMain`, janelas, `CAMetalLayer` e toque
     ficam em Dart, pelo runtime ObjC via FFI, como o AppKit no macOS;
   - Android: `ANativeActivity_onCreate` (ou `GameActivity`), que inicia a VM no
     processo do app e entrega a `ANativeWindow`. O resto, inclusive chamadas a
     APIs Java, em Dart via FFI sobre a `JNIEnv`.

   Essa camada é um arquivo C/Objective-C por plataforma, sem lógica de UI, e
   continua passando pelas regras de revisão de código nativo.
3. **O Android mantém o host Java do ADR 0009** como caminho de desenvolvimento
   e de máquinas sem os artefatos; o embutido vira o padrão para publicar.

## Por que não o motor do Flutter

O Flutter carrega uma VM Dart dentro do `libflutter.so`/`Flutter.framework`.
Usá-lo só para "carregar o Dart" seria depender do Flutter no app do usuário, o
que o projeto não aceita em nenhuma forma. As fontes do engine em
`referencias/` servem de estudo, não de dependência.

## Riscos

- **Tamanho e tempo de build do SDK:** checkout de vários GB e compilação de
  dezenas de minutos; por isso os artefatos vêm do CI.
- **Embedding API do Dart (`dart_api.h`):** é a API pública de embedders, mas
  muda entre versões. O kernel, o `gen_snapshot` e o runtime têm de vir da
  mesma tag.
- **App Store:** só APIs públicas no iOS (nada de SkyLight ou equivalente).
  Publicar exige o Apple Developer Program.
