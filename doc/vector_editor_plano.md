# Editor vetorial — plano de reforma

Iniciado em 12/10/2026, a partir de uma auditoria do código e do catálogo de
funcionalidades do CorelDRAW ([vector_editor_catalogo_coreldraw.md](vector_editor_catalogo_coreldraw.md)).
Referências: sK1 (`referencias/sk1-wx-main`), Inkscape (`referencias/inkscape-master`),
Graphite, SVG-Edit e VectorCraft.

## Fase 1 — correção (feita)

| Problema | Correção |
|---|---|
| Criar objeto não entrava no desfazer; grupo, ordem e operações por painel desfaziam errado; N objetos = N passos | `DocumentHistory`: cada passo é o estado antes/depois, com a identidade dos objetos preservada; seleção podada após desfazer |
| Elipse com o dobro do tamanho e deslocada; polígono fora do centro; `<circle>` do SVG deslocado | geometria do círculo/polígono unitários corrigida em ferramentas, `DocumentMethods` e SVG |
| Ctrl/Shift não restringiam retângulo e elipse | `ToolController.dragBox`: Ctrl = quadrado/círculo, Shift = a partir do centro |
| Curva: polilinha que nunca terminava e criava objetos órfãos | caneta Bézier: clique = canto, arrastar = nó suave, clique no 1º nó fecha, Enter/duplo clique termina, Esc cancela, segmento elástico |
| Duplicar movia; Copiar não copiava; Recortar só apagava; Colar não existia | área de transferência, Duplicar (Ctrl+D) com deslocamento, Colar em cascata, Recortar+Colar no lugar |
| Mover para cima/baixo sem desfazer e errado com vários objetos | reordenação por pai, preservando blocos, num passo |
| Cantos, arco, nº de cantos, página e texto pela barra sem desfazer | `EditorModel.edit` e `coalesce` (digitar = um passo) |
| SVG inválido com `&`/`<`; camadas ocultas perdidas; tipos perdidos | codec SVG reescrito (ver `doc/vector_editor.md`) |
| Salvar regravava o `.cdr` original com um CDR mínimo | Salvar só sobrescreve SVG; `.cdr` é salvo como SVG |
| Salvar Como gravava a aba errada se outra virasse a atual | grava a sessão que pediu |
| Fechar e Sair não perguntavam; Sair não saía | confirmação nativa; `WindowScope.of(context).close()` |
| Abas novas não eram enquadradas | enquadramento por aba na primeira exibição |
| Gradiente gravado mas desenhado sólido; texto não girava | gradiente no espaço do documento; texto desenhado sob a transformação |
| Painel Fill/Outline e paleta mostravam o estilo "atual" | mostram o estilo da seleção |
| Delete não funcionava no Mac | Backspace e Delete |

## Fase 2 — visual (próxima)

Tema escuro no estilo Graphite (tokens `#111/#222/#333/#444`, destaque
`#00a8ff`), papel sempre branco, layout com barra de propriedades de 32 px,
caixa de ferramentas de 32 px com flyouts, réguas de 16 px com números
legíveis na vertical, painel de Objetos/Camadas (miniatura, olho, cadeado),
barra de status com dicas por ferramenta, cursor por ferramenta, alças de 6 px.

## Fase 3 — ferramentas e comandos do catálogo

Edição de nós (F10), mão livre (F5), converter em curvas (Ctrl+Q), alinhar com
`L R T B C E P`, nudge com setas, tabela de zoom, booleanas exatas
(Weld/Trim/Intersect), Combinar/Separar, contorno com cap/join/tracejado,
exportar PNG, guias arrastadas da régua, conta-gotas, várias páginas.
