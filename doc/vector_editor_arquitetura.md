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

## Camadas

| Camada | Onde | O que contém | Pode depender de |
|---|---|---|---|
| Framework: comandos | `lib/src/commands/` | `CommandSpec`, `CommandRegistry`, `MenuSpec`, validação de parâmetros | nada de widgets além de `KeyGesture` |
| Framework: automação | `lib/src/automation/` | `ControlServer` (JSON por linha, loopback), `AutomationHost` | comandos, plataforma |
| Editor: motor | `examples/vector_editor_demo/engine/` | sessão, histórico, seleção, **todos os comandos** do editor | framework (sem widgets do editor) |
| Editor: interface | `examples/vector_editor_demo/ui/` | janela, painéis, canvas, barras | motor |
| Editor: app | `examples/vector_editor_demo/main.dart`, `tool/` | ponto de entrada, `--control`, ferramentas | tudo |

Um teste de camadas (`test/examples/vector_editor_layers_test.dart`) lê os
`import` e falha se o motor importar a interface.

## Comandos

- Id com ponto, por área: `file.save`, `edit.undo`, `object.toCurves`,
  `view.zoomIn`, `tool.rectangle`, `layer.new`, `panel.objects`, `shape.rectangle`.
- Parâmetros declarados (`CommandParam`: nome, tipo, obrigatório, descrição).
  Um parâmetro desconhecido é erro **antes** de rodar, com sugestão do mais
  próximo (`widht` → "você quis dizer `width`?").
- `run` devolve um resultado serializável em JSON (ou nada). Exceções viram
  `CommandError`; o registro nunca deixa uma exceção escapar.
- `command.batch` roda vários como **um** passo de desfazer.
- A interface é fina: um painel age por `registry.execute(id, params)`.

## Canal de controle (agentes)

`cd examples/vector_editor_demo && dart run --control 7979` abre
`127.0.0.1:7979`. Uma requisição JSON por linha:

```json
{"id":1,"method":"engine.execute","params":{"command":"shape.rectangle","params":{"x":10,"y":10,"width":100,"height":50}}}
```

Métodos: `engine.commands`, `engine.execute`, `engine.batch`, `ui.menu.list`,
`ui.contextMenu.list`, `ui.inspect`, `document.inspect`, `ui.pointer`,
`ui.key`, `ui.text`, `ui.screenshot`. Só loopback; linha que não for objeto
JSON com `method` fecha a conexão; linhas acima de 4 MiB são recusadas.

## Paridade medida

`dart run tool/vector_editor_parity.dart` cruza o catálogo dos menus do
CorelDRAW (`doc/vector_editor_catalogo_coreldraw.md`, só documentação pública)
com o registro e imprime "N de M funcionam", por menu. O número e a lista do
que falta vão para `doc/vector_editor_paridade.md` a cada entrega.

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
| 6 | Ferramenta de paridade e `doc/vector_editor_paridade.md` | — |
| 7 | Paleta de comandos (Ctrl/⌘+Shift+P) | — |
| 8 | Auditoria de sala limpa do código derivado do sK1 | — |
