# Editor vetorial: instruções para agentes

Editor vetorial no estilo do CorelDRAW, em Dart puro, sobre o `dart_ui`. Ele
existe para **achar o que falta no framework**: quando o editor precisa de algo
que o `dart_ui` não tem, a correção vai para `lib/` da raiz, não para um
contorno aqui. As regras do repositório (`../../AGENTS.md`) valem antes destas.

## Comece toda sessão aqui

1. Leia o fim de [`DIARIO.md`](DIARIO.md): onde a última sessão parou e o que
   ficou pela metade.
2. Leia [`doc/paridade.md`](doc/paridade.md) (gerado) e escolha trabalho entre
   as linhas ❌ e 🟡 de prioridade P0, depois P1, salvo pedido do usuário.
3. A arquitetura está em `../../doc/vector_editor_arquitetura.md`; o catálogo
   do CorelDRAW, em `../../doc/vector_editor_catalogo_coreldraw.md`.

## Regras que não se negociam

- **Tudo é um comando.** Comportamento visível é um `CommandSpec`: comandos de
  documento em `lib/src/engine/editor_commands.dart`, comandos de janela em
  `lib/src/ui/editor_ui.dart`. Cada um tem id com ponto (`object.toCurves`),
  rótulo, parâmetros declarados, `enabled`/`disabledReason` e testes. Menus,
  barras, atalhos, menus de contexto, testes e o canal de controle chegam a
  eles pelo mesmo `CommandRegistry`.
- **A interface é fina.** Um widget age por `registry.execute(id, params)`;
  não chama o modelo para mudar o documento.
- **Camadas.** `lib/src/engine/` não importa nada de `lib/src/ui/`
  (`test/layers_test.dart` falha se importar). O motor roda sem janela.
- **Nunca derrubar o app.** Um comando recusa com `CommandError` e um motivo;
  o registro transforma qualquer exceção em falha relatada. Entrada de arquivo
  e do canal de controle é sempre não confiável.
- **Sala limpa.**
  - O comportamento vem só da documentação pública do CorelDRAW (manuais e
    ajuda online), citada por página.
  - Nunca execute, automatize, meça ou capture o CorelDRAW, nem copie ícones,
    textos ou arquivos dele.
  - `../../referencias/` serve para entender comportamento. sK1 e Inkscape são
    GPL: nenhum trecho deles entra aqui, nem traduzido para Dart.
  - Há auditoria pendente do código antigo que cita o sK1 (ver a arquitetura).
- **Paridade honesta.** Avalie pelo comportamento, não pela existência de um
  item de menu, e erre para baixo. `tool/parity_catalog.dart` só pode citar
  comandos registrados e testes que existem (`test/parity_test.dart`).

## Portões antes de cada commit

```sh
dart format .
dart analyze
dart test
dart run tool/parity.dart   # regenera doc/paridade.md; o teste exige que esteja atual
```

Para mudanças que tocam a janela real, rode também
`dart run tool/control_probe.dart`. Ele sobe o editor com `--control` e o
dirige só pelo canal de controle.

## Rodando e olhando o app

- `dart run` abre o editor; `dart run bin/vector_editor_demo.dart --control 7979` abre também o canal
  de controle (JSON por linha em `127.0.0.1:7979`). Métodos: `engine.commands`,
  `engine.execute`, `engine.batch`, `ui.menu.list`, `ui.contextMenu.list`,
  `ui.inspect`, `document.inspect`, `ui.pointer`, `ui.key`, `ui.text`,
  `ui.screenshot`.
- **Para mudança de interface, olhe o resultado.** Use `ui.screenshot` ou
  `dart run tool/headless_shot.dart saida.png 1400 880 menu:4`.
- No macOS sem permissão de acessibilidade, as sondas `tool/macos_*_probe.dart`
  injetam eventos pelo próprio host.

## Ao terminar a sessão

Acrescente ao `DIARIO.md` uma entrada curta: data, o que mudou (commits), o que
ficou pela metade e o próximo passo. Se a sessão cair no meio, a próxima
começa por ali.
