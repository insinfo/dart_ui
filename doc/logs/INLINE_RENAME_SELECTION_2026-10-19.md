# Seleção de texto na renomeação inline (2026-10-19)

A regressão foi reproduzida pela árvore real: após o clique pausado abrir o
campo, pressionar e arrastar sobre seu texto fazia `tab.renaming` virar `null`
no modo Detalhes. O evento chegava primeiro ao TextField, mas continuava até o
DataGrid, que retomava o foco. O listener de perda de foco confirmava o nome e
removia o editor no meio da seleção.

O editor agora interrompe a propagação dos eventos de pressão, movimento,
soltura e cancelamento depois que o TextField os processa. A roda continua
podendo chegar à lista. Perder foco por si só não confirma mais a renomeação.
Um clique fora confirma; Esc cancela; Enter mantém a confirmação já existente.
O estado de inicialização do campo é limpo antes de confirmar, permitindo
renomear novamente o mesmo item com um nome inicial e seleção corretos.

A dart_ui ganhou `PointerListener.onPointerDownCapture`: observação da pressão
antes dos filhos, independente das barreiras de propagação, sem disputar ou
capturar gestos. O Explorador compara a posição com a região atual do editor.
Isso também permite encerrar a edição ao clicar fora sobre uma barra de
rolagem ou sobre uma área vazia que não recebe foco.

## Regressões

O teste percorre os oito modos de exibição e executa eventos reais no roteador:
selecionar, abrir pelo clique pausado, arrastar a seleção de texto, duplo clique
no campo sem abrir a pasta, mudança programática de foco sem confirmar, Esc
sem gravar o rascunho, F2 para uma edição nova e clique externo para confirmar.
O teste anterior à correção falha com o mesmo fechamento indevido reportado.

O teste de PointerListener verifica a ordem de captura antes do filho e a
observação através de uma barreira, preservando o bloqueio da fase de bubbling.

Validação local: análise estática limpa, 2.018 testes de widgets/aplicação/
arquitetura e 62 testes do Explorador aprovados. Build AOT recompilado.

No Linux, os testes dirigidos de ponteiro, popups e arquitetura e os 62 testes
do Explorador passaram, com análise limpa e AOT atualizado. No Windows,
1.850 testes dirigidos da biblioteca passaram com dois skips; os 62 testes
do Explorador e seu build AOT também passaram.
