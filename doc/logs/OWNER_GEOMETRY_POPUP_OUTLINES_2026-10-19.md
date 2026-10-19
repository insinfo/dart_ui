# Geometria do proprietário e bordas de popups (2026-10-19)

## Propriedades não restaura a janela principal

Fechar uma janela filha devolve o foco ao proprietário por `focusWindow`.
`Win32Window.activate` usava SW_SHOWNORMAL, que restaura o retângulo normal
de uma janela maximizada ou encaixada. O resultado parecia uma movimentação
inexplicável, apesar de SetWindowPos usar NOMOVE/NOSIZE depois dela.

A ativação agora usa SW_SHOW, preservando o estado e a geometria existentes.
Somente uma janela minimizada usa SW_RESTORE. A exibição também usa SW_SHOW,
sem desfazer uma maximização já solicitada. A distinção é documentada em
[ShowWindow, Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow).
Isso corrige o retorno de foco de Propriedades e das outras janelas filhas.

## Acabamento dos menus e dropdowns

O host tratava transparentPopups como sinônimo de borda nativa. Isso funcionava
para os painéis AppKit, mas, ao habilitar alpha no Windows e Linux, fez os
widgets omitirem a borda mesmo sem o compositor desenhá-la. Superfícies brancas
ficavam soltas sobre outras superfícies claras, sem contorno definido.

A capacidade popupWindowOutline agora é independente da transparência. Os
backends AppKit existentes a anunciam; Windows, Wayland e X11 deixam os widgets
pintarem sua borda. Menus, dropdowns e tooltips que consultam PopupWindowFrame
recebem a informação correta. Os cantos continuam transparentes.

Menus adaptados a Windows/Linux usam raio de 8 px no painel, raio de 4 px no
destaque e separadores recuados 8 px. macOS mantém suas métricas; temas sem
adaptação de plataforma conservam o raio configurado.

Popups ARGB do Windows também deixaram de usar CS_DROPSHADOW: a sombra clássica
seguia o HWND retangular e produzia a quina dura mostrada na captura. Eles usam
a classe sem essa sombra, com contorno arredondado pintado pelo widget.
Este ajuste não adiciona Acrylic, blur de fundo ou uma nova sombra por software.

Capturas do diagnóstico nativo após a correção:

- [Windows / janela principal Direct3D11](MENU_OUTLINE_WIN32_2026-10-19.png).
- [GNOME Wayland / OpenGL](MENU_OUTLINE_WAYLAND_2026-10-19.png).

## Validação

- macOS: análise limpa, 2.024 testes de widgets/aplicação/arquitetura e seleção
  de backend aprovados; revalidação dirigida final com 43 aprovados.
- Windows: 1.851 testes dirigidos da biblioteca aprovados, dois skips; 22 testes
  nativos de estado, telas e popups aprovados em sessão gráfica, serialmente.
  Eles verificam posição/tamanho ao ativar, preservação da maximização e
  ausência de CS_DROPSHADOW nos popups ARGB.
- Linux: testes dirigidos de popups, ponteiro, métricas de tema e arquitetura
  aprovados, com análise estática final limpa.
- Explorador: 62 testes aprovados por sistema e builds AOT recompilados.
- properties_window_smoke.dart abre Propriedades sobre o proprietário maximizado
  e compara tamanho, posição disponível e estado antes/depois de fechar.
  Passou nativamente em Windows/Direct3D11, macOS e GNOME Wayland/OpenGL.
  O diagnóstico espera a maximização terminar antes de medir; uma espera fixa
  de 300 ms capturava um estado intermediário da animação AppKit.
- menu_surface_smoke.dart apresentou menus reais com alpha e contorno do widget
  em Windows e Wayland, com screenshots inspecionados.
