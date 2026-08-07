# Pacote de documentação — propostas de evolução do Dart SDK

Duas limitações distintas do Dart standalone impedem um framework de UI 100%
Dart sobre `dart:ffi`. Elas são ortogonais e têm propostas separadas.

## Eixo 1 — process main thread (só macOS)

O AppKit exige a primeira thread do processo, e a VM do Dart não a entrega.
Windows e Linux **não** têm esse problema: os POCs 01 e 02 já criam janelas na
própria thread do isolate.

1. `01_proposta_dart_sdk_main_thread_ptbr.md`
   Proposta técnica completa em português, com API, semântica, implementação
   sugerida, alternativas e critérios de aceitação.

2. `02_proposal_dart_sdk_process_main_thread_github_en.md`
   Corpo em inglês pronto para ser adaptado e publicado no issue tracker do
   Dart SDK.

3. `03_investigacao_main_thread_macos_dart_puro.md`
   Investigação técnica detalhada dos probes A–K, análise do runtime,
   limitações do probe K e plano dos próximos experimentos.

Destino recomendado: comentário de design em `dart-lang/sdk#38315` ou nova
issue ligada a `#38315`, `#46943` e `#56841`.

## Eixo 2 — integração de event loop (as três plataformas)

O loop bloqueante do toolkit nativo e o event loop do isolate disputam a mesma
thread, e não há primitiva suportada para reconciliá-los. Afeta Windows, Linux
e macOS por igual — inclusive **depois** de o eixo 1 ser resolvido.

4. `04_proposta_dart_sdk_event_loop_nativo_ptbr.md`
   Proposta de implementação das APIs já declaradas `Isolate.onEvent` e
   `Isolate.handleEvent`, com POC de métricas e quatro lacunas secundárias e
   separáveis: callback síncrono de thread estrangeira, lifetime seguro de
   `NativeCallable`, cooperação do GC com frames e diagnóstico de falha em FFI.

Destino recomendado: issue própria pedindo a implementação de
`Isolate.onEvent`/`handleEvent`, após confirmar em `dart-lang/sdk#56841` se isso
já pertence ao trabalho experimental escondido por flags.

5. `05_proposal_dart_sdk_external_event_loop_github_en.md`
   Versão inglesa curta e pronta para issue, limitada à implementação das APIs
   já declaradas, com evidência da POC-19 e critérios de aceitação.
