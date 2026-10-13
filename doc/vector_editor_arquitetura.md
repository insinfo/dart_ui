# Editor vetorial: arquitetura "tudo é um comando"

> Criado em 13/10/2026. Inspirado na organização pública do VectorCraft
> (storytold/vectorcraft, Apache-2.0: `AGENTS.md`, `docs/architecture.md`,
> `docs/control-protocol.md`). Só a **organização** foi tomada como referência;
> nenhum código foi copiado.

## Por que reestruturar

O editor nasceu como uma janela com callbacks espalhados: o menu chamava o
modelo, o painel chamava o modelo, a caixa de ferramentas trocava um campo, e
um atalho só existia se alguém lembrasse de ligá-lo. Isso tem três custos:

1. **Nada é automatizável.** Um agente (ou um teste) só consegue usar o editor
   simulando cliques em coordenadas.
2. **Paridade não é mensurável.** Não dá para responder "quantos itens do menu
   do CorelDRAW já funcionam?" sem ler o código.
3. **Cada superfície decide sozinha** se um comando está habilitado, que nome
   tem e qual atalho mostra, e elas divergem.

A resposta do VectorCraft, que adotamos: **todo comportamento visível é um
comando registrado**, com id, rótulo, atalho, parâmetros documentados,
`enabled` e `run`. Menus, menus de contexto, barras, atalhos, paleta de
comandos, testes e o canal de automação usam todos o mesmo registro.

## Camadas: portas e adaptadores

O motor é o núcleo; a janela e a linha de comando são **adaptadores** sobre
ele (arquitetura hexagonal). O núcleo não importa framework de interface, e um
único ponto de composição liga cada adaptador ao núcleo. Por isso o motor roda
num script ou servidor, e a interface pode trocar de framework sem tocar no
desenho nem nos comandos.

| Camada | Onde | O que contém | Pode importar |
|---|---|---|---|
| Framework: comandos | `lib/src/commands/` → `package:dart_ui/commands.dart` | `CommandSpec`, `CommandRegistry`, parâmetros, `MenuSpec` como dados, `flattenMenus` | só `platform` (`KeyGesture`, teclas) |
| Framework: edição vetorial | `lib/src/vector_editing/` + modelo em `graphics/vector` → `package:dart_ui/vector.dart` | documento, histórico, SVG/PDF/CDR, seleção, encaixe, ferramentas, métrica de texto | geometria, gráficos, renderização de texto |
| Framework: menus de widget | `lib/src/widgets/command_menus.dart` | `MenuBuilder`: `MenuSpec` → `PlatformMenu`, com `iconOf` | comandos, widgets |
| Framework: automação | `lib/src/automation/` → `package:dart_ui/automation.dart` | `ControlServer`, `WindowAutomation` | app, comandos |
| Editor: motor | `examples/vector_editor_demo/lib/src/engine/` | modelo, E/S de arquivos, inspeção, **comandos por módulo** em `commands/` | **só** `dart:*`, `vector.dart`, `commands.dart` |
| Editor: CLI | `lib/src/cli/` + `bin/vector_cli.dart` | adaptador de linha de comando | o motor |
| Editor: interface | `lib/src/ui/` + `bin/vector_editor_demo.dart` | janela, painéis, menus, ícones, comandos de janela | o motor e `dart_ui.dart` |

Testes que seguram as camadas:
- `test/architecture/headless_libraries_test.dart`: `commands.dart` e
  `vector.dart` não alcançam widgets, layout, app nem backends.
- `test/layers_test.dart` (editor): o motor e o CLI só importam as bibliotecas
  sem interface.

## Comandos

- **Um módulo por área**, não um arquivo para todos. Cada área
  (`file_commands.dart`, `edit_commands.dart`, `object_commands.dart`,
  `arrange_commands.dart`, `layer_commands.dart`...) é uma função
  `List<CommandSpec> xCommands(EditorContext context)`. O agregador
  (`editor_commands.dart`) só lista os módulos. Uma área nova é um arquivo
  novo e uma linha. É a organização do VectorCraft: cerca de 700 comandos em
  cerca de 150 arquivos de `cmd/`, cada um com seus `specs()`.
- **Dependências injetadas.** O `EditorContext` (modelo e host) chega a cada
  módulo pelo construtor, sem globais. Um teste ou o CLI injeta outro host.
- **Uma condição, um motivo.** `when` responde de uma vez "pode rodar?" e "por
  que não?" (`null` = pode), como o `enabled` do VectorCraft, que devolve o
  erro. Condições comuns (`needsDocument`, `needsSelection`,
  `needsSelected(n)`) ficam no contexto e são escritas uma vez.
- **Apresentação fora do motor.** O ícone de um comando é decisão da
  interface (`ui/command_icons.dart`); o atalho é um `KeyGesture` resolvido
  por plataforma. Assim como no VS Code, a posição nos menus é registrada à
  parte da definição do comando (`MenuSpec`).
- **Teclas compartilhadas** seguem as cláusulas `when` do VS Code: ganha o
  comando que pode rodar; entre dois que podem, ganha o que vale só num
  contexto (B alinha embaixo com seleção e escolhe a Caneta sem).
- Id com ponto, por área: `file.save`, `edit.undo`, `object.toCurves`,
  `view.zoomIn`, `tool.rectangle`, `layer.new`, `panel.objects`, `shape.rectangle`.
- Parâmetros declarados (`CommandParam`: nome, tipo, obrigatório, descrição).
  Um parâmetro desconhecido é erro **antes** de rodar, com sugestão do mais
  próximo (`widht` → "você quis dizer `width`?").
- `run` devolve um resultado serializável em JSON (ou nada). Exceções viram
  `CommandError`; o registro nunca deixa uma exceção escapar.
- `batch` roda vários como **um** passo de desfazer (`DocumentHistory.group`).
- A interface é fina: um painel age por `registry.execute(id, params)`.

## Desempenho

- **Reconstruir só o que mudou.** O que muda a cada movimento do mouse (a
  posição do ponteiro) é um `ValueNotifier` próprio, e só as réguas e as
  coordenadas da barra de status escutam (`ValueListenableBuilder`, que o
  framework não tinha e passou a ter). Antes, cada movimento reconstruía a
  janela inteira, com todos os painéis. Um teste conta os builds da janela e
  falha se um movimento do ponteiro a reconstruir.
- **Comandos registrados uma vez**, na abertura. Ler `enabled` e `checked` de
  um menu custa uma chamada de função por linha, só quando o menu é montado.
- **A fazer:** o histórico captura o documento inteiro a cada passo
  (`DocumentState.capture`, O(objetos)). Com documentos grandes, o caminho é
  compartilhamento estrutural (só copiar o que mudou), como faz o VectorCraft.
  Também falta medir: um `tool/perf.dart` com documento sintético de milhares
  de objetos e metas por operação.

## Canal de controle (agentes)

`cd examples/vector_editor_demo && dart run bin/vector_editor_demo.dart --control 7979` abre
`127.0.0.1:7979`. Uma requisição JSON por linha:

```json
{"id":1,"method":"engine.execute","params":{"command":"shape.rectangle","params":{"x":10,"y":10,"width":100,"height":50}}}
```

Métodos: `engine.commands`, `engine.execute`, `engine.batch`, `ui.menu.list`,
`ui.contextMenu.list`, `ui.inspect`, `document.inspect`, `ui.pointer`,
`ui.key`, `ui.text`, `ui.screenshot`. Só loopback; linha que não for objeto
JSON com `method` fecha a conexão; linhas acima de 4 MiB são recusadas.

## Paridade medida

Dentro de `examples/vector_editor_demo`, `dart run tool/parity.dart` cruza as
175 funcionalidades do catálogo do CorelDRAW
(`doc/vector_editor_catalogo_coreldraw.md`, só documentação pública) com o
registro de comandos do editor e escreve `doc/paridade.md`: feitas, parciais e
faltando, por prioridade e por área. Um teste exige que o relatório esteja
atual e que a tabela só cite comandos registrados e testes que existem.

## Sala limpa

- Comportamento vem só da documentação pública do CorelDRAW (manuais em PDF,
  ajuda online), citada por página. Nunca automatizar, medir ou capturar o
  CorelDRAW, nem copiar ícones, textos ou arquivos dele.
- `referencias/` (sK1, Inkscape, docking_flutter, coreldraw_cdr.ksy) serve para
  **entender comportamento**. sK1 e Inkscape são GPL: nenhum trecho deles entra
  neste repositório MIT, nem traduzido de Python ou C++ para Dart.
- **Pendência de auditoria:** o modelo vetorial (`lib/src/graphics/vector/`) e
  o editor citam o sK1 em comentários e usam nomes do sK1 (`trafo`,
  `cachePaths`, `TextStylePlugin`). É preciso conferir se houve tradução de
  código, e reescrever o que tiver sido, antes de afirmar que o projeto é sala
  limpa.

## Etapas

| # | Entrega | Estado |
|---|---|---|
| 1 | `lib/src/commands/`: registro, parâmetros, `MenuSpec`, atalhos, testes | feito |
| 2 | `lib/src/automation/` (`package:dart_ui/automation.dart`): servidor de controle e host padrão de janela | feito |
| 3 | Editor: todos os comandos no registro; menus, contexto, barras e atalhos a partir dele | feito (painéis de propriedades ainda chamam o modelo) |
| 4 | Editor: pastas `engine/` e `ui/`, teste de camadas | feito |
| 5 | `--control` no editor; sonda que desenha e captura só pelo canal (`tool/control_probe.dart`) | feito |
| 6 | Ferramenta de paridade (`tool/parity.dart`) e `examples/vector_editor_demo/doc/paridade.md` | feito: 23% no total, 52% das P0 |
| 7 | Paleta de comandos (Ctrl/⌘+Shift+P) | — |
| 8 | Auditoria de sala limpa do código derivado do sK1 | — |
| 9 | Comandos em módulos por área; motor só com `vector.dart` e `commands.dart`; CLI | feito |
| 10 | Ponteiro sem reconstruir a janela (`ValueListenableBuilder`) | feito |
| 11 | Histórico com compartilhamento estrutural e metas de desempenho | — |

## Fontes

- VectorCraft (Apache-2.0), organização pública: `AGENTS.md`,
  `docs/architecture.md`, `crates/engine/src/cmd/mod.rs`
  ([github.com/storytold/vectorcraft](https://github.com/storytold/vectorcraft)).
- VS Code: registro de comandos, registro de menus com `when`, camadas que só
  dependem das de baixo
  ([contribution model](https://www.mintlify.com/microsoft/vscode/concepts/contribution-model),
  [commands and keybindings](https://dev.to/ryankolter/vscode-4-commands-and-keybindings-system-4nhm)).
- Arquitetura hexagonal: núcleo sem framework; CLI e interface como
  adaptadores; ponto de composição
  ([arc42](https://quality.arc42.org/approaches/hexagonal-architecture),
  [archman](https://archman.dev/docs/architectural-styles/hexagonal-ports-and-adapters)).

