# Compatibilidade com o Flutter: instruções para agentes

O objetivo é que um app ou pacote Flutter migre para o `dart_ui` mudando o
mínimo de código: **mesmos nomes, mesmos parâmetros, mesma semântica**. Sem
depender do engine do Flutter, nem para carregar a VM. As regras do
repositório (`../AGENTS.md`) valem antes destas.

## Comece toda sessão aqui

1. Leia o fim de [`DIARIO_FLUTTER.md`](DIARIO_FLUTTER.md): onde a última
   sessão parou e o que ficou pela metade.
2. Leia [`paridade_flutter.md`](paridade_flutter.md) (gerado) e escolha
   trabalho entre as linhas ❌ e 🟡 do **P0**, depois P1, salvo pedido do
   usuário. Agrupe por afinidade (um widget e seus irmãos, uma família de
   APIs), não pela ordem alfabética.
3. O guia para quem migra é [`MIGRACAO_DO_FLUTTER.md`](MIGRACAO_DO_FLUTTER.md):
   toda diferença que sobrar vai para lá.

## Regras que não se negociam

- **O nome do Flutter, a assinatura do Flutter.** Construtor com os mesmos
  parâmetros nomeados, os mesmos padrões, os mesmos callbacks e tipos. Onde o
  `dart_ui` já tem um nome próprio para a mesma coisa (`axis:` em vez de
  `scrollDirection:`, `ScrollPosition` no papel de `ScrollController`), aceite
  **também** o nome do Flutter, sem quebrar quem usa o nosso.
- **Semântica antes de existência.** Um nome só vira ✅ quando se comporta
  como o do Flutter nos casos que um app usa. O que falta entra em
  `tool/flutter_parity/catalog.dart` (`kPartial`, com o que difere) e conta
  metade. Na dúvida, marque para baixo.
- **Toda diferença é escrita.** No doc comment da classe e em
  `MIGRACAO_DO_FLUTTER.md`. Diferença por arquitetura (sem platform views,
  `Transform2D` em vez de `Matrix4` no display list) diz o porquê.
- **Desktop primeiro, sem perder o resto.** Teclado, foco, hover, menus de
  contexto e acessibilidade (papéis semânticos) fazem parte do widget, não
  são extras.
- **Camadas.** `platform` não importa `graphics`; `graphics` não importa
  `vector_editing`; `test/architecture` falha se a regra quebrar.
- **Nunca derrubar o app.** Entrada inválida vira `ArgumentError`/`StateError`
  com mensagem clara, como o `assert` do Flutter diria, mas também em release.
- **Licença.** O Flutter é BSD-3: dá para ler o código em
  `../referencias/flutter-master` para entender o comportamento e até adaptar
  trechos, mantendo o aviso de copyright do Flutter no arquivo que recebeu o
  trecho. sK1 e Inkscape (GPL) continuam proibidos.

## Como implementar

1. Leia a classe no Flutter (`referencias/flutter-master/packages/flutter/lib/src/...`)
   e os testes dela, para saber o que ela promete.
2. Procure o que o `dart_ui` já tem para a mesma coisa (`lib/src/widgets`,
   `lib/src/layout`, `lib/src/gestures`...) e estenda em vez de duplicar.
3. Escreva os testes primeiro a partir do comportamento do Flutter, no estilo
   de `test/widgets/hero_test.dart` (BuildOwner, PipelineOwner, display list).
4. Para todo widget visual, **olhe o resultado**: captura sem janela
   (`HeadlessScreenshot`/`CpuRendererBackend`, ou um `tool/*_shot.dart`) no
   tema claro e no escuro, e corrija o que estiver feio.
5. Exporte em `lib/dart_ui.dart` (ordem alfabética) e atualize a tabela.

## Portões antes de cada commit

```sh
dart format <arquivos do commit>
dart analyze lib test tool
dart test                          # a suíte da raiz inteira
dart run tool/flutter_parity.dart  # regenera doc/paridade_flutter.md; o teste exige que esteja atual
```

Depois do push, confira o CI com `gh run list`. Commits só na `main`.

## A tabela

- `tool/flutter_parity/flutter_api.tsv` é o snapshot da API pública do
  Flutter, lido de `referencias/flutter-master` (fora do git) por
  `dart run tool/flutter_parity.dart --refresh`. Atualize ao trocar de versão
  do Flutter de referência.
- `tool/flutter_parity/catalog.dart`: prioridades (`kP0`), divergências
  (`kPartial`) e o que não se aplica, com o motivo.
- `test/tooling/flutter_parity_test.dart` falha se a tabela estiver velha, se
  o catálogo citar um nome que o Flutter não tem, ou se um 🟡 não existir aqui.
