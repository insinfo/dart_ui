# Seleção pelo alvo do menu contextual (2026-10-19)

O Explorador escolhia o menu pela seleção anterior, sem resolver o arquivo sob
o botão direito nos modos de ícones, lista, blocos e conteúdo. Clicar no vazio
podia abrir ações do arquivo anteriormente selecionado. Em Detalhes, o grid
já atualizava a seleção, mas a montagem antecipada dos itens do menu podia
conservar o conteúdo anterior até o próximo rebuild.

FolderView agora resolve cada pressão pela linha/item realmente atingido.
Uma pressão secundária no vazio limpa a seleção; em item fora da seleção,
seleciona somente esse item; em item já selecionado, preserva o grupo.
Pressão primária no vazio também limpa a seleção, sem abrir menu. O DataGrid
conserva sua própria lógica de seleção primária, incluindo cabeçalhos.
Os eventos do editor de nomes continuam isolados dos alvos de linha.

ContextMenuArea usa o novo MenuAnchor.menuChildrenBuilder, avaliado quando o
popup é construído, depois de onOpen e da atualização da seleção. O menu
nasce com as opções atuais e com sua medida correta. A lista estática
menuChildren continua compatível; o builder opcional tem prioridade.

A regressão do Explorador percorre os oito layouts com eventos do roteador:
seleção por botão direito, preservação de grupo, troca para outro arquivo,
limpeza no vazio e conteúdo correto de cada menu, além de clique esquerdo no
vazio sem menu. A regressão da biblioteca muda o alvo dentro de onOpen sem
reconstruir o proprietário e verifica que só as opções novas são exibidas.

Validação local: análise estática limpa; 2.020 testes de widgets/aplicação/
arquitetura e 65 testes do Explorador aprovados.

Com a montagem antiga restaurada temporariamente, a regressão da biblioteca
falhou: ainda exibia a ação do arquivo em vez da pasta. O código corrigido foi
restaurado após a comparação.

Windows: 1.852 testes dirigidos da biblioteca aprovados, com dois skips, e
65 testes do Explorador aprovados. Linux: análise limpa, testes dirigidos de
menus/popups/ponteiro/arquitetura e 65 testes do Explorador aprovados. Builds
AOT atualizados nos três sistemas.
