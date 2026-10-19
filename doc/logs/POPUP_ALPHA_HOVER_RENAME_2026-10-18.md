# Popups transparentes, isolamento de hover e renomeação (2026-10-18)

## Comportamento corrigido

Menus nativos bloqueiam movimentos e rolagem enviados à janela proprietária
pelas tracking areas do sistema. O hover anterior é limpo antes da criação do
popup, cancelando também tooltips pendentes sem violar a ordem de destruição dos
popups Wayland. Menus pais continuam recebendo movimentos para alternar submenus;
a área explícita de passagem de uma barra de menus continua funcionando.
Tooltips não bloqueiam o mouse. O clique externo conserva a política existente
de fechamento e despacho.

Um clique sem modificadores no nome do único item já selecionado inicia a
renomeação no próprio lugar após 500 ms, nos oito modos de exibição. O primeiro
clique apenas seleciona. Duplo clique, arrastar, perder seleção/foco, desmontar
o item ou abrir um menu impedem a renomeação pendente. A preferência de abrir
com clique único tem prioridade. O campo usa o mesmo comando e validação de F2.

## Alpha até o compositor

- **Wayland:** o backend anuncia a transparência que seus buffers ARGB já
  preservam, tanto em wl_shm como em GBM/EGL/DMA-BUF. A apresentação OpenGL foi
  validada com virgl na VM GNOME Wayland.
- **X11:** popups usam visual TrueColor de 32 bits e colormap próprio quando
  existe compositor e formato BGRA compatível. O visual correto chega ao EGL;
  PutImage envia a profundidade correta. O colormap é liberado com a janela.
  Sem compositor/visual compatível, permanece o fallback opaco. CPU e OpenGL
  foram verificados em Xwayland sob GNOME.
- **Windows:** menus/tooltips são WS_EX_LAYERED e apresentam BGRA premultiplicado
  com UpdateLayeredWindow. Os caminhos padrão adaptam apenas essas janelas para
  um DIB retido renderizado por CPU; a janela principal mantém sua apresentação
  selecionada, inclusive Direct3D11. Isso não implementa DirectComposition nem
  afirma que os popups Windows sejam renderizados pela GPU.
- **macOS:** conserva o suporte nativo existente a transparência.

O diagnóstico reproduzível está em `tool/popup_alpha_smoke.dart`. Ele verifica
alpha zero no canto e 255 no centro do conteúdo e exige frames efetivamente
apresentados. No Windows também lê o desktop composto por GetPixel: o canto
precisa mostrar exatamente a cor azul da janela de trás e o centro branco.
Essa verificação passou para menu e tooltip com janela principal CPU e
Direct3D11. A leitura do desktop existe somente na ferramenta de diagnóstico.

Capturas do compositor, além dos testes do buffer:

- [Wayland / OpenGL](POPUP_ALPHA_WAYLAND_2026-10-18.png).
- [X11 / OpenGL](POPUP_ALPHA_X11_GPU_2026-10-18.png).

## Validação e limites

- macOS: análise estática limpa; 2.930 testes de widgets/aplicação/backends e
  arquitetura passaram, com 281 skips de plataforma. Após o último ajuste,
  os 66 testes de popups, startup e arquitetura passaram novamente.
- Linux ARM64: suíte completa com 7.827 aprovados e 907 skips. Revalidação
  dirigida de popups, Wayland, X11 e arquitetura: 782 aprovados.
- Windows ARM64: validação dirigida de widgets, popups, ABI, presenter CPU e
  arquitetura com 1.848 aprovados e dois skips. Revalidação final dos 30 testes
  de popups e análise estática limpa.
- Explorador: 61 testes aprovados em cada sistema, incluindo o clique de
  renomeação pela árvore real nos oito layouts. Builds AOT recompilados nos
  três sistemas.
- A regressão de hover falha com o isolamento removido e passa com a correção.

Uma execução ampliada Windows encontrou quatro falhas de tolerância de pixels
em `d2d_glyph_transform_test.dart` (texto rotacionado, espelhado e com escala
não uniforme). Persistiram numa execução serial na sessão gráfica e também ao
restaurar temporariamente a tolerância antiga de achatamento de curvas (0,25),
sem as alterações recentes desse parâmetro. Os outros testes nativos reexecutados
nessa sessão passaram (61 aprovados, quatro falhas). Os limites não foram
relaxados; essa suíte D2D não está sendo declarada aprovada. A composição real
CPU/Direct3D11 dos popups passou independentemente dessas comparações de texto.
