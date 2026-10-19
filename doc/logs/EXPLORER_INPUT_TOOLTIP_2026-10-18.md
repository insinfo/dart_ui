# Captura de tela, foco e tooltips (2026-10-18)

## Banner ao usar o atalho de captura no macOS

O teste de troca de visualização reproduziu, com a implementação antiga do
foco, a mesma exceção do screenshot:

```text
Bad state: _DataGridState.widget was read after dispose().
_DataGridState._handleKey
RenderDataGridBody.handleKeyEvent
KeyboardRouter.route
BuildOwner.dispatchKeyEvent
```

Ao remover o render object, `ControlBehavior.detach` limpa `FocusNode.target`.
O setter retargetava o teclado, mas, se o alvo novo era nulo, o roteador
continuava com o antigo. Na desmontagem seguinte, o nó já não conhecia o alvo
que precisava liberar. A próxima tecla chegava ao State descartado.

Agora o setter libera o alvo anterior por identidade antes de retargetar.
Isso também preserva o foco que já foi transferido a outro controle.
A regressão executa a troca real de Details para Small icons, descarta o grid
e envia outra tecla; o código anterior falha com a exceção acima e o corrigido
passa. Há ainda um teste direto da remoção do alvo focado.

Os modos de exibição usavam o modificador portátil `command`, que no Mac
produzia Command+Shift+3/4/5 e colidia com os atalhos de captura. Agora usam
Control+Shift+1…8 nos três sistemas. Os testes verificam que Command+Shift+4 e
Control+Command+Shift+4 não mudam a visualização, enquanto Control+Shift+4 muda.

## Caractere estranho no tooltip

O texto do Explorador contém uma quebra de linha entre nome, tipo e tamanho.
O `RenderTooltip` o tratava como uma única label e enviava o controle de nova
linha ao shaper; isso aparecia como glifo ausente. O tooltip agora mede e pinta
cada linha separadamente, mantendo o texto integral na semântica. LF, CRLF e CR
são aceitos. O teste verifica altura de duas linhas, origens verticais distintas
e ausência do glifo `.notdef` na lista efetivamente desenhada.

[Renderização do tooltip corrigido](TOOLTIP_MULTILINE_2026-10-18.png).

## Transparência de popups

Atualização posterior: a integração foi concluída em Windows, Wayland e X11;
consulte [o relatório de alpha, hover e renomeação](POPUP_ALPHA_HOVER_RENAME_2026-10-18.md)
para os caminhos utilizados e a validação. O texto abaixo registra o estado
anterior a essa correção.

Apenas os backends macOS anunciam `Capability.transparentPopups` nesta revisão.
Nos demais, `Application.openPopup` conserva o fundo opaco e o fallback dos
widgets preenche os cantos para não deixá-los pretos. Isso é uma limitação de
integração da dart_ui, não do Dart nem uma impossibilidade dos sistemas.
A transparência por pixel de Windows/Wayland/X11 não foi implementada por este
patch; exige preservar o alpha até o compositor e validar cada apresentação.

## Validação

- macOS: análise limpa, 1.992 testes de widgets/aplicação e 59 do exemplo passaram;
  `.app` AOT recompilado e reaberto.
- Linux ARM64: análise limpa, 1.990 testes de widgets/aplicação passaram com dois
  skips; 59 testes do exemplo passaram e AOT Wayland foi recompilado.
- Windows ARM64: análise estática limpa. A suíte ampliada de aplicação encerrou
  o processo na chamada nativa WGL/GDI de `Win32GlSurface._create`, acionada pelo
  probe de OpenGL em `default_startup_test.dart`; não houve uma falha de
  asserção Dart nessa saída. Esse código não foi alterado por este patch.
  A validação dirigida passou 1.818 testes de widgets/popups com dois skips,
  mais 59 testes do exemplo; o executável AOT GUI foi recompilado para uso
  com `--cpu`. Isso não certifica o backend OpenGL dessa VM.
