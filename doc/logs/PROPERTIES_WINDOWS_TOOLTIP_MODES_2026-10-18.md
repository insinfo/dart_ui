# Propriedades não modais e apresentação de tooltips (2026-10-18)

Propriedades agora abre uma janela filha nativa não modal de 480 × 520 pixels
lógicos, com decoração do sistema. A janela principal permanece utilizável e
sem escurecimento. Cada janela guarda sua própria lista de itens; é possível
abrir propriedades de seleções diferentes simultaneamente. Fechar a janela de
propriedades mantém o Explorador aberto; fechar o proprietário fecha suas
janelas filhas pelo ciclo de vida existente da Application.

OK/Enter aplica a renomeação e fecha; Aplicar mantém a janela; Cancelar/Escape
fecha sem aplicar a edição pendente. A contagem assíncrona de pastas continua
sendo cancelada na desmontagem. Conteúdo rolável preserva os botões ao redimensionar.

A janela filha agora recebe seu próprio WindowPopupHost, com suas coordenadas
e seu parentesco nativo. Ela não reutiliza o host da janela principal.

## Tooltips

A API oferece `TooltipMode.auto`, `window` e `overlay`, tanto por tooltip
(`Tooltip(mode: ...)`) como por árvore (`TooltipPresentation(mode: ..., child: ...)`).
`auto` conserva o comportamento anterior; `window` exige um host de janelas
nativas; `overlay` desenha na camada da janela e fica limitado à sua área.

PopupScope mantém uma camada composta disponível junto do host nativo.
Assim, escolher overlay para tooltips não transfere os menus para overlays.
O conteúdo composto também não herda a borda de uma janela de popup nativa.
Mudanças de host fecham a dica existente, sem deixar uma superfície órfã.

No Explorador, Opções de Pasta → Exibir → “Mostrar dicas como sobreposição”
controla essa escolha e é salvo nas preferências. Desmarcado usa a escolha
automática, com janela nativa nos desktops e fallback onde não há suporte.

## Verificação

- macOS: análise limpa; 2.017 testes de widgets, aplicação e arquitetura;
  62 testes do Explorador; build AOT atualizado.
- Linux: 783 testes dirigidos de aplicação, Wayland, X11 e arquitetura;
  62 testes do Explorador; build AOT atualizado.
- Windows: 1.849 testes dirigidos de widgets, popups, ABI e presenter CPU,
  com dois skips; 62 testes do Explorador; build AOT atualizado.
- Testes de Propriedades verificam janela independente, ausência de modalDepth,
  input do proprietário, seleção estável por janela, renomeação por OK e
  Cancelar sem alteração no disco.
- Teste integrado de tooltips usa WindowPopupHost real sobre backend headless:
  `window`/`auto` criam uma janela; `overlay` desenha RenderTooltip no proprietário
  e não cria janela nativa.
- `examples/file_explorer/tool/properties_window_smoke.dart` exercita a API
  real de janelas filhas e seu fechamento nos desktops. Validação nativa de
  apresentação e ciclo de vida passou em macOS, Windows/Direct3D11 e GNOME
  Wayland/OpenGL.

[Janela independente no Windows, sem escurecimento do Explorador](PROPERTIES_WINDOW_WIN32_2026-10-18.png).
