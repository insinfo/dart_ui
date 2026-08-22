Backends e renderizadores novos

Wayland (Linux) — protocolo wire 100% Dart sobre socket (sem libwayland), wl_shm com memfd/mmap, ciclo configure do xdg-shell, input com parser de keymap xkb, registrado antes do X11 com fallback por probe real. 121 testes com mini-compositor fake em memória.
Direct2D (Windows) — bindings COM puros no padrão D3D12 do projeto, replay completo da display list (paths com curvas nativas, saveLayer real, glifos via cache compartilhado com o CPU, sem DirectWrite), device-lost tratado, selecionável por --presentation=direct2d. 23 testes de pixel contra a d2d1.dll real.
WebGPU (web) — shaders WGSL equivalentes aos GLSL, interop dart:js_interop tipado, plugado no mesmo sink/batcher do WebGL2, fallback automático para WebGL2 quando o adapter recusa. Builds dart compile js/wasm validados.
APIs de sistema operacional — StandardPaths (Known Folders/XDG/macOS), Shell (openUrl/openPath/reveal), Lixeira real nas 3 plataformas, SystemInfo com dark mode, MessageBox nativo, FileWatcher. 51 testes, incluindo reciclagem real de arquivo no Windows.

Widgets modernos — TreeView (virtualizado, lazy loading, teclado ARIA), DataGrid (colunas redimensionáveis, ordenação, seleção multi, 100k linhas virtualizadas), Calendar/DatePicker (locale pt/en), NumberBox, InfoBar/Toast, Badge/Chip/Avatar/Card — todos com tema, foco, semântica, página nova na galeria. Slider e Tooltip já existiam.

Validação e commits
dart analyze: No issues found no repositório inteiro (incluindo os 48 lints antigos que zerei no início).
Suíte completa: 4473 testes passando, 0 falhas (~280 a mais que a baseline de 4192).
A maior parte do trabalho já tinha sido commitada em ff0c60a (pelo fluxo do seu outro agente); commitei o restante em f1ca720 (InfoBar sem icon-font + 4 arquivos de teste). Os arquivos do agente WSLg (poc_02, diagnósticos) seguem intocados na árvore, como você pediu.
Próximos passos naturais do roteiro, se quiser continuar: swapchain de buffers no Wayland (wl_buffer.release), clipboard/DnD Wayland, gradientes no formato de paint da display list (o D2D já os suporta), DirectComposition, e IME/dead keys no teclado Wayland.

c#1-1
sim continue implementando e expandindo e melhorando e ja comece a pensar nos outros modos de aceleração por GPU semelhante ao impeller / vello C:\MyDartProjects\dart_ui\referencias\vello-main  C:\MyDartProjects\dart_ui\referencias\engine-main
Vou verificar as referências do Vello e do Flutter Engine (Impeller) e então despachar a próxima rodada de agentes: evolução do Wayland, gradientes de ponta a ponta no pipeline, e o estudo+protótipo de aceleração GPU estilo Impeller/Vello.

Bash Check vello and engine reference trees
IN
ls "c:\MyDartProjects\dart_ui\referencias\vello-main" 2>&1 | head -20; echo ---; ls "c:\MyDartProjects\dart_ui\referencias\engine-main" 2>&1 | head -20; echo ---; ls "c:\MyDartProjects\dart_ui\referencias\engine-main\impeller" 2>&1 | head -25

OUT
AUTHORS
CHANGELOG.md
Cargo.lock
Cargo.toml
LICENSE-APACHE
LICENSE-MIT
README.md
doc
examples
glifo
rustfmt.toml
sparse_strips
vello
vello_encoding
vello_shaders
vello_tests
xtask
---
AUTHORS
BUILD.gn
CODEOWNERS
CONTRIBUTING.md
DEPS
Doxyfile
LICENSE
README.md
analysis_options.yaml
assets
benchmarking
bin
build
build_overrides
ci
common
display_list
docs
engine.code-workspace
examples
---
BUILD.gn
README.md
base
compiler
core
display_list
docs
entity
fixtures
geometry
golden_tests
playground
renderer
runtime_stage
shader_archive
shader_bundle
tessellator
toolkit
tools
typographer
SendMessage
IN
{
  "to": "a5c27c1ae3e4c42f6",
  "summary": "Wayland rodada 2: swapchain, pacing, clipboard, repeat",
  "message": "Nova tarefa (rodada 2) no seu território, c:\\MyDartProjects\\dart_ui\\lib\\src\\backends\\wayland\\ — evoluir o backend que você criou, atacando as limitações que você mesmo documentou, nesta ordem de prioridade (qualidade > quantidade, pare onde a cota chegar):\n1. **Swapchain de buffers shm**: múltiplos wl_buffer por superfície com reuso guiado por wl_buffer.release (elimine o tearing transitório do buffer único por geração). Cubra redimensionamento durante voo (buffers antigos liberados quando o compositor soltar).\n2. **Frame pacing**: use wl_callback de wl_surface.frame para ritmar apresentação (não apresentar mais rápido que o compositor consome), integrado ao dispatcher/scheduler existente do jeito que o backend win32/x11 faz throttling (verifique como eles fazem).\n3. **Clipboard Wayland**: wl_data_device_manager/wl_data_source/wl_data_offer para texto (text/plain;charset=utf-8) — copiar e colar, com transferência via pipe fds (você já tem pipe2 e SCM_RIGHTS). Implemente o contrato ClipboardBackend que o framework usa (veja lib\\src\\platform\\clipboard.dart e como win32_clipboard implementa).\n4. **Keyboard repeat**: wl_keyboard.repeat_info + timer no dispatcher para repetição de tecla.\nPara cada item: testes headless no seu mini-compositor fake em test\\backends\\wayland (release/reuso de buffers, ordem frame callback, negociação de mime e transferência por pipe fake, cadência de repeat com clock injetado). Rode só seus testes + dart analyze. REGRAS de sempre: main, sem branches, sem git commit, edições mínimas em arquivos compartilhados, NÃO toque em poc\\poc_02_x11_window nem nos docs de diagnóstico WSLg. Ao final retorne resumo: o que entrou, arquivos, testes, limitações restantes.",
  "type": "message",
  "recipient": "a5c27c1ae3e4c42f6",
  "content": "Nova tarefa (rodada 2) no seu território, c:\\MyDa…"
}
OUT
{"success":true,"message":"Resuming agent a5c27c1","resumedAgentId":"a5c27c1ae3e4c42f6","pin":{"id":"a5c27c1ae3e4c42f6","name":"a5c27c1ae3e4c42f6","ref":"e7e3a7"}}

SendMessage
IN
{
  "to": "a5a1206a765eeffd8",
  "summary": "Gradientes de ponta a ponta na display list",
  "message": "Nova tarefa (rodada 2): você deixou os brushes de gradiente do D2D prontos e observou que o formato de wire da display list só carrega cor sólida. Agora implemente **gradientes lineares e radiais de ponta a ponta** no pipeline:\n1. **Formato**: estenda o paint no wire da display list (lib\\src\\graphics\\display_list*.dart) para gradiente linear (p0, p1, stops[]) e radial (centro, raio, stops[], foco opcional), com deduplicação na tabela de recursos como os paints atuais, spread modes (pad/repeat/reflect — implemente ao menos pad, deixe o enum pronto), e modo debug legível. Mantenha o caminho de cor sólida sem custo extra (hot path).\n2. **API pública**: como o usuário do framework expressa o gradiente (veja como Paint/estilos chegam dos widgets — Grep por Paint em lib\\src\\graphics e widgets/style.dart) — adicione a superfície mínima e natural seguindo o estilo existente.\n3. **Rasterizador CPU**: implemente o preenchimento com gradiente no renderer CPU (lib\\src\\rendering — veja raster/ e cpu_canvas.dart; pode haver suporte herdado de dart_graphics/marlin — INVENTARIE antes, não duplique). Interpolação em sRGB simples e consistente entre backends, documentada.\n4. **Replayers**: CPU replay (lib\\src\\rendering\\replay), D2D (seus brushes já prontos — ligue-os), e GPU (lib\\src\\rendering\\gpu: os shaders GL/WebGL/WGSL têm entry points de gradiente? INVENTARIE gl_shaders.dart e wgsl_shaders.dart; se houver, ligue; se não houver, implemente no GL e WGSL seguindo o padrão dos fragment shaders atuais — os demais backends podem cair no fallback documentado se necessário, com recusa nomeada, nunca silenciosa).\n5. **Testes**: golden de pixel no CPU (rampa medida), teste D2D real comparando rampa com o CPU (você já tem o offscreen com readback), testes de wire round-trip, e testes GL/WebGPU nos harnesses que existirem. Rode só os testes das áreas tocadas + dart analyze — NÃO rode a suíte completa.\nREGRAS: main, sem branches, sem git commit, edições mínimas/aditivas em arquivos compartilhados (outro agente está em lib\\src\\backends\\wayland e outro em lib\\src\\rendering\\gpu\\d3d12 + doc/ — coordene não tocando nos territórios deles; o sink/shaders comuns são seus nesta rodada), NÃO toque em poc\\poc_02_x11_window nem nos docs WSLg. Ao final retorne: formato adotado, cobertura por backend, arquivos, resultado dos testes.",
  "type": "message",
  "recipient": "a5a1206a765eeffd8",
  "content": "Nova tarefa (rodada 2): você deixou os brushes de…"
}
OUT
{"success":true,"message":"Resuming agent a5a1206","resumedAgentId":"a5a1206a765eeffd8","pin":{"id":"a5a1206a765eeffd8","name":"a5a1206a765eeffd8","ref":"cf30b6"}}

Read C:\MyDartProjects\dart_ui\lib\src\platform\clipboard.dart
Bash List win32 backend and find throttling code
IN
ls C:/MyDartProjects/dart_ui/lib/src/backends/win32/ && grep -rln "throttl\|frame.*pacing\|vsync\|FramePacer\|presentNow" C:/MyDartProjects/dart_ui/lib/src/backends/win32 C:/MyDartProjects/dart_ui/lib/src/app C:/MyDartProjects/dart_ui/lib/src/scheduler 2>/dev/null | head

OUT
d2d
d3d11
d3d12
uia
win32.dart
win32_abi.dart
win32_api.dart
win32_backend.dart
win32_clipboard.dart
win32_constants.dart
win32_coordinates.dart
win32_cpu_presenter.dart
win32_diagnostics.dart
win32_dib_surface.dart
win32_dispatcher.dart
win32_gl_surface.dart
win32_structs.dart
win32_window.dart
win32_window_class.dart
C:/MyDartProjects/dart_ui/lib/src/backends/win32/d3d11/win32_d3d11_surface.dart
C:/MyDartProjects/dart_ui/lib/src/backends/win32/d3d12/d3d12_backend.dart
C:/MyDartProjects/dart_ui/lib/src/backends/win32/win32_backend.dart
C:/MyDartProjects/dart_ui/lib/src/backends/win32/win32_gl_surface.dart
C:/MyDartProjects/dart_ui/lib/src/app/application.dart
C:/MyDartProjects/dart_ui/lib/src/app/window_host.dart
C:/MyDartProjects/dart_ui/lib/src/scheduler/frame_scheduler.dart
Agent:Aceleração GPU estilo Vello/Impeller
IN
Você trabalha no repositório c:\MyDartProjects\dart_ui — framework de UI desktop/web 100% Dart (dart:ffi direto, sem shims C) com display list própria e renderizadores CPU e GPU (D3D11, D3D12, OpenGL, WebGL2, WebGPU, Metal parcial). O objetivo desta tarefa é INICIAR a próxima geração de aceleração vetorial por GPU, no espírito do Impeller (Flutter) e do Vello.

ESTUDE PRIMEIRO (leitura seletiva, não exaustiva):
- c:\MyDartProjects\dart_ui\referencias\vello-main — README, doc/, vello_encoding (encoding de cenas), vello_shaders (estágios compute WGSL) e especialmente sparse_strips/ (a arquitetura nova híbrida CPU/GPU: vello_cpu/vello_hybrid — strips esparsas com rasterização de cobertura na CPU e composição na GPU)
- c:\MyDartProjects\dart_ui\referencias\engine-main\impeller — README, docs/, entity/, renderer/, tessellator/, geometry/ (abordagem: tessellation + stencil-then-cover, atlas de glifos, arquitetura de Entity/Contents, HAL sobre Metal/Vulkan/GLES)
- No projeto: lib\src\graphics\display_list*.dart, lib\src\rendering\gpu\ (gpu_raster_sink.dart, gpu_batcher.dart, gpu_pipeline.dart, atlases, e os backends d3d12/, gl/, webgl/, webgpu/), lib\src\rendering\raster e replay (o rasterizador CPU atual e o contrato RasterSink), test\backends\win32\d2d e test\rendering (como testes de pixel/golden são feitos), doc\adr\ (formato dos ADRs, em português).

ENTREGÁVEIS:
1. **doc\architecture\ACELERACAO_GPU_VETORIAL.md** — análise comparativa profunda em português: como Vello clássico (compute puro), Vello sparse_strips (híbrido CPU/GPU) e Impeller (tessellation/stencil-cover) resolvem paths, curvas, AA, clipping, blending, texto; requisitos de cada abordagem por API gráfica (compute shaders? storage buffers? indirect dispatch?) versus o que os backends do projeto oferecem (D3D12 sim compute; GL 3.3/WebGL2 não; WebGPU sim; D3D11 CS5.0); e a RECOMENDAÇÃO concreta e faseada para este projeto, considerando que já existe: display list binária, batcher GPU com atlas de máscaras rasterizadas na CPU, e renderer CPU maduro tipo AGG/marlin. A hipótese a avaliar a fundo: sparse strips híbrido é o caminho de menor risco e maior alcance (funciona até em WebGL2), com compute puro como otimização futura em D3D12/WebGPU — confirme ou refute com argumentos técnicos.
2. **doc\adr\0006-*.md** — ADR da decisão recomendada, no formato dos ADRs existentes.
3. **SPIKE executável**: um protótipo mínimo mas real da fase 1 da sua recomendação, em lib\src\rendering\gpu\vector\ (novo diretório) — por exemplo (se confirmar sparse strips): o estágio CPU que converte um path da display list em strips esparsas de cobertura + o estágio GPU que compõe as strips (pode usar o harness D3D12 offscreen existente com readback, que roda NESTA máquina Windows), com testes de pixel comparando contra o rasterizador CPU atual (mesma cena, desvio tolerado documentado) em test\rendering\gpu\vector\. Se no estudo você concluir que outro spike é melhor (ex.: stencil-then-cover), justifique no doc e faça esse. O spike deve rodar e passar testes aqui (D3D12 disponível); NÃO precisa integrar na seleção de produção ainda.
ATENÇÃO a licenças: Vello é Apache-2.0/MIT, Flutter engine é BSD-3 — você pode portar conceitos e algoritmos com atribuição; registre no doc quais algoritmos foram portados de onde (o repo tem THIRD_PARTY_NOTICES.md — adicione entradas se portar código/algoritmos substanciais).
REGRAS: main, sem branches, sem git commit, territórios de outros agentes em andamento: lib\src\backends\wayland, formato de paint/gradientes na display list e shaders GL/WGSL comuns (outro agente mexendo — se precisar de shader novo, crie arquivos novos no seu diretório vector\), NÃO toque em poc\poc_02_x11_window nem nos docs de diagnóstico WSLg. Rode só seus testes + dart analyze. Ao final retorne: recomendação em 5 linhas, sumário do doc, o que o spike prova, resultado dos testes.
Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\win32_clipboard.dart
Bash Find throttling references
IN
cd C:/MyDartProjects/dart_ui && grep -n "throttl\|vsync\|pacing\|presentNow" lib/src/scheduler/frame_scheduler.dart lib/src/app/window_host.dart lib/src/app/application.dart | head -30

OUT
lib/src/scheduler/frame_scheduler.dart:34:/// [frameInterval] of virtual time, which is both what a real vsync does and
lib/src/app/window_host.dart:102:/// [presentNow] is nullable rather than absent, and the null is a real answer:
lib/src/app/window_host.dart:108:  SynchronousDisplayListPresentCallback? presentNow,
lib/src/app/window_host.dart:198:  /// Whether [presentNow] will actually do anything.
lib/src/app/window_host.dart:206:  PresentResult presentNow(
lib/src/app/window_host.dart:437:  /// Whether [presentNow] can do anything but reject.
lib/src/app/window_host.dart:468:  PresentResult presentNow(
lib/src/app/window_host.dart:507:    final result = presenter.presentNow(
lib/src/app/window_host.dart:965:    SynchronousDisplayListPresentCallback? presentNow,
lib/src/app/window_host.dart:972:        _presentNow = presentNow,
lib/src/app/window_host.dart:982:        _presentNow = presenter.presentNow,
lib/src/app/window_host.dart:990:  final SynchronousDisplayListPresentCallback? _presentNow;
lib/src/app/window_host.dart:1015:  bool get canPresentNow => _presentNow != null && !isDisposed;
lib/src/app/window_host.dart:1018:  PresentResult presentNow(
lib/src/app/window_host.dart:1025:    final present = _presentNow;
lib/src/app/application.dart:1244:  ///   * **it respects the generation.** [WindowHost.presentNow] rejects a
lib/src/app/application.dart:1305:      final result = host.presentNow(
Read C:\MyDartProjects\dart_ui\lib\src\scheduler\frame_scheduler.dart
Nova rodada — primeiro, inventário completo antes de desenhar o formato.

Bash Inventory gradient mentions across pipeline
IN
grep -rn -l -i "gradient" lib/src/graphics lib/src/rendering lib/src/widgets 2>/dev/null | head -30

OUT
lib/src/rendering/cpu_canvas.dart
lib/src/rendering/gpu/d3d12/d3d12_shaders.dart
lib/src/rendering/text/glyph_raster.dart
lib/src/widgets/phosphor_icons.dart
lib/src/widgets/proxy.dart
Grep "_paintColors|paintColor\(|addPaint" (in C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart)
2 lines of output
Read C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart
Bash Inventory CPU canvas gradients and GPU shader dirs
IN
grep -n -i "gradient" lib/src/rendering/cpu_canvas.dart | head -20; echo ---; ls lib/src/rendering/raster lib/src/rendering/gpu/gl lib/src/rendering/gpu/webgl 2>/dev/null; echo ---; grep -rn -i "gradient" lib/src/rendering/gpu/gl lib/src/rendering/gpu/webgl lib/src/rendering/gpu/vulkan lib/src/rendering/gpu/metal 2>/dev/null | head

OUT
253:  /// Paints a linear gradient directly into the retained pixel target.
256:  /// opcode until gradient resource serialization is finalized. Colors use
258:  void fillLinearGradient(
---
lib/src/rendering/gpu/gl:
gl_backend.dart
gl_bindings.dart
gl_context.dart
gl_framebuffer_pool.dart
gl_shaders.dart
gl_surface_descriptor.dart
gl_window_target.dart

lib/src/rendering/gpu/webgl:
webgl_backend.dart
webgl_canvas_target.dart
webgl_framebuffer_pool.dart
webgl_surface_descriptor.dart

lib/src/rendering/raster:
blend.dart
clip_stack.dart
coverage.dart
rasterizer.dart
---
Read C:\MyDartProjects\dart_ui\lib\src\rendering\cpu_canvas.dart (lines 231-350)
Bash Find WGSL shaders and public Paint API
IN
ls lib/src/rendering/gpu/webgpu 2>/dev/null; find lib/src -name "*wgsl*" -o -name "*webgpu*" | head; echo ---; grep -rn "class Paint\b\|final class Paint\b" lib/src --include="*.dart" | head; echo ---; grep -n "Paint" lib/src/widgets/style.dart 2>/dev/null | head -20

OUT
webgpu_backend.dart
webgpu_canvas_target.dart
webgpu_interop.dart
webgpu_surface_descriptor.dart
wgsl_shaders.dart
lib/src/rendering/gpu/webgpu
lib/src/rendering/gpu/webgpu/webgpu_backend.dart
lib/src/rendering/gpu/webgpu/webgpu_canvas_target.dart
lib/src/rendering/gpu/webgpu/webgpu_interop.dart
lib/src/rendering/gpu/webgpu/webgpu_surface_descriptor.dart
lib/src/rendering/gpu/webgpu/wgsl_shaders.dart
---
---
Vou começar explorando a estrutura do projeto e das referências em paralelo.

Bash List key project directories
IN
ls C:/MyDartProjects/dart_ui/lib/src/rendering/gpu/ C:/MyDartProjects/dart_ui/lib/src/rendering/ C:/MyDartProjects/dart_ui/lib/src/graphics/ C:/MyDartProjects/dart_ui/doc/adr/ 2>&1

OUT
C:/MyDartProjects/dart_ui/doc/adr/:
0001-worker-process-com-iosurface-no-macos.md
0002-transform-2d-afim-em-vez-de-matrix4.md
0003-sem-hinting-truetype.md
0004-implementando-hinting-truetype.md
0005-metal-sobre-iosurface-compartilhada.md

C:/MyDartProjects/dart_ui/lib/src/graphics/:
color.dart
display_list.dart
display_list_debug.dart
display_list_geometry.dart
display_list_opcodes.dart
display_list_reader.dart
image
svg

C:/MyDartProjects/dart_ui/lib/src/rendering/:
cpu_canvas.dart
cpu_renderer.dart
framebuffer.dart
gpu
path
raster
render_object.dart
renderer.dart
replay
text

C:/MyDartProjects/dart_ui/lib/src/rendering/gpu/:
d3d11
d3d12
gl
gpu_batcher.dart
gpu_device_state.dart
gpu_glyph_atlas.dart
gpu_layer_stack.dart
gpu_mask_atlas.dart
gpu_pipeline.dart
gpu_raster_sink.dart
gpu_recovery.dart
gpu_texture.dart
gpu_vertex_buffer.dart
metal
vulkan
webgl
webgpu
Bash List vello and impeller reference directories
IN
ls C:/MyDartProjects/dart_ui/referencias/vello-main C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips 2>&1; ls C:/MyDartProjects/dart_ui/referencias/engine-main/impeller 2>&1 | head -40

OUT
C:/MyDartProjects/dart_ui/referencias/vello-main:
AUTHORS
CHANGELOG.md
Cargo.lock
Cargo.toml
LICENSE-APACHE
LICENSE-MIT
README.md
doc
examples
glifo
rustfmt.toml
sparse_strips
vello
vello_encoding
vello_shaders
vello_tests
xtask

C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips:
README.md
vello_bench
vello_common
vello_cpu
vello_dev_macros
vello_example_scenes
vello_hybrid
vello_sparse_shaders
vello_sparse_tests
vello_toy
web
BUILD.gn
README.md
base
compiler
core
display_list
docs
entity
fixtures
geometry
golden_tests
playground
renderer
runtime_stage
shader_archive
shader_bundle
tessellator
toolkit
tools
typographer
Rodada 2 despachada — três frentes em paralelo:

Wayland (evolução) — o mesmo agente que construiu o backend agora ataca as limitações que ele documentou: swapchain de buffers shm guiado por wl_buffer.release (elimina o tearing do buffer único), frame pacing via wl_surface.frame, clipboard Wayland completo (wl_data_device com transferência por pipe) implementando o contrato ClipboardBackend do framework, e keyboard repeat.

Gradientes de ponta a ponta — o agente do Direct2D (que deixou os brushes prontos) estende o formato de paint da display list para gradientes lineares/radiais com stops e dedupe, expõe a API pública, implementa no rasterizador CPU, liga o D2D e cobre os shaders GL/WGSL — com goldens de pixel comparando a rampa entre CPU e D2D real.

Aceleração vetorial estilo Impeller/Vello (agente novo) — estuda as duas referências que você apontou (vello-main, incluindo o novo sparse_strips híbrido CPU/GPU, e engine-main/impeller com tessellation/stencil-then-cover), produz doc/architecture/ACELERACAO_GPU_VETORIAL.md com análise comparativa e recomendação faseada mapeada nos backends existentes (D3D12/WebGPU têm compute; GL3.3/WebGL2 não), um ADR formal, e um spike executável com testes de pixel no harness D3D12 offscreen desta máquina, comparando contra o rasterizador CPU atual. Licenças tratadas com atribuição no THIRD_PARTY_NOTICES.

Todos avisados sobre os territórios uns dos outros e sobre não tocar nos arquivos do seu agente WSLg. Quando terminarem, valido integrado (analyze + suíte completa) e commito por área, como antes.

Vou delegar duas pesquisas de referência em paralelo enquanto leio o código do projeto diretamente.

Bash Find how widgets produce paints
IN
grep -n -i "gradient" lib/src/widgets/proxy.dart | head; echo ---; ls lib/src/widgets/ | head -40; echo ---; grep -rn "addPaint" lib/src/widgets lib/src/layout 2>/dev/null | head -10

OUT
210:/// Shadows and gradients are declared absent by name on [BoxDecoration].
---
actions.dart
animation_scope.dart
badge.dart
basic.dart
calendar.dart
cdr
combo_box.dart
context_menu.dart
control.dart
controls.dart
dart_ui_app.dart
data_grid.dart
directionality.dart
docking
docking.dart
element.dart
errors.dart
expander.dart
focus.dart
focus_scope.dart
gesture_detector.dart
icon.dart
icon_button.dart
image.dart
info_bar.dart
keyboard_router.dart
list_box.dart
localizations.dart
media_query.dart
menu.dart
navigator.dart
number_box.dart
overlay.dart
pdf
phosphor_icons.dart
pointer_router.dart
popup.dart
progress_indicator.dart
properties.dart
proxy.dart
---
lib/src/widgets/badge.dart:351:    final int paint = list.addPaint(
lib/src/widgets/basic.dart:741:    final int paint = list.addPaint(colorArgb: _color.value, antiAlias: true);
lib/src/widgets/combo_box.dart:1159:    final int paint = list.addPaint(
lib/src/widgets/context_menu.dart:1286:    final int paint = list.addPaint(colorArgb: _color.value, antiAlias: false);
lib/src/widgets/control.dart:270:    final int paint = list.addPaint(colorArgb: color.value, antiAlias: false);
lib/src/widgets/control.dart:292:      list.addPaint(colorArgb: color.value, antiAlias: true),
lib/src/widgets/control.dart:315:      list.addPaint(
lib/src/widgets/control.dart:331:    final int paint = list.addPaint(colorArgb: color.value, antiAlias: false);
lib/src/widgets/control.dart:418:    final int paint = list.addPaint(colorArgb: color.value, antiAlias: true);
lib/src/widgets/data_grid.dart:682:        list.addPaint(colorArgb: theme.foreground.value, antiAlias: false),
Agent:Estudar Vello sparse_strips
IN
Estude a fundo o diretório C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips (Rust). Quero um relatório técnico DETALHADO (em português, pode ser longo) sobre a arquitetura híbrida CPU/GPU de "sparse strips" do Vello, suficiente para eu reimplementar o algoritmo em Dart sem ler o código Rust. Cubra:

1. Pipeline completo do vello_common/vello_cpu: flatten de curvas (tolerância? como cúbicas/quadráticas são achatadas — leia vello_common/src/flatten.rs ou similar), geração de "tiles" e "strips" (leia vello_common/src/tile.rs, strip.rs, coarse.rs ou equivalentes): qual o tamanho do tile/strip (4x4? 4xN?), como a cobertura (winding/coverage) é acumulada por coluna, como o antialiasing analítico é calculado, como fill rules (nonzero/evenodd) são aplicadas, e o formato exato de dados de saída de uma strip (campos da struct Strip: x, y, width, col/alpha offsets, winding para regiões interiores "sparse fill").
2. Como o vello_cpu compõe (fine rasterization) — wide tiles, comandos por wide tile (Cmd::Fill, Cmd::AlphaFill etc.).
3. Como o vello_hybrid usa a GPU: o que sobe pra GPU (buffer de alphas? textura?), quais shaders (leia vello_sparse_shaders / vello_hybrid/src/*.rs e shaders wgsl/glsl), como as strips viram quads/instâncias, como funciona em WebGL2 (existe backend GL? como contorna falta de storage buffer — textura de alphas?), como clipping/blending/gradientes são tratados no híbrido.
4. Estruturas-chave com campos e tamanhos exatos (Strip, Tile, Footprint, etc.) e constantes (TILE_WIDTH, TILE_HEIGHT, STRIP_HEIGHT).
5. Estado de maturidade/limitações anotadas nos READMEs e docs.

Inclua trechos de código Rust curtos e essenciais (structs, constantes, laços centrais de acumulação de cobertura) literalmente no relatório, com caminhos de arquivo absolutos. Seja muito específico sobre o algoritmo de strip generation (ordenação de tiles, merge de footprints, acumulação de winding entre tiles adjacentes).
I'll explore the Vello sparse strips codebase thoroughly. Let me start by mapping the directory structure.

Bash List all source files in sparse_strips
IN
find "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips" -type f \( -name "*.rs" -o -name "*.wgsl" -o -name "*.glsl" -o -name "*.md" -o -name "*.toml" \) | head -300

OUT
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/benches/main.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/allocator.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/data.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/fine/blend.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/fine/fill.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/fine/gradient.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/fine/image.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/fine/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/fine/pack.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/fine/rounded_blurred_rect.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/fine/strip.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/flatten.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/glyph.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/integration.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/sort.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/strip.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_bench/src/tile.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/assets/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/CHANGELOG.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/blurred_rounded_rect.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/clip.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/encode.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/filter/drop_shadow.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/filter/flood.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/filter/gaussian_blur.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/filter/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/filter/offset.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/filter_effects.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/flatten.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/flatten_simd.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/geometry.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/image_cache.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/mask.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/math.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/multi_atlas.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/paint.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/pico_svg.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/pixmap.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/probe.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/record.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/rect.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/render_state.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/simd.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/strip.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/strip_generator.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/tile.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/transforms.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/util.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_common/src/viewport.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/CHANGELOG.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/basic.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/clipping.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/masking.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/paints.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/wasm_cpu/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/wasm_cpu/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/wasm_cpu/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/wasm_cpu/src/main.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/winit/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/winit/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/examples/winit/src/main.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/coarse/bucketer.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/coarse/cmd.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/coarse/depth.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/coarse/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/dispatch/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/dispatch/multi_threaded/cost.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/dispatch/multi_threaded/worker.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/dispatch/multi_threaded.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/dispatch/single_threaded.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/filter/context.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/filter/drop_shadow.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/filter/flood.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/filter/gaussian_blur.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/filter/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/filter/offset.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/filter/shift.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/common/gradient/linear.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/common/gradient/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/common/gradient/radial.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/common/gradient/sweep.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/common/image.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/common/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/common/rounded_blurred_rect.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/highp/blend.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/highp/compose.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/highp/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/lowp/blend.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/lowp/compose.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/lowp/gradient.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/lowp/image.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/lowp/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/fine/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/record.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/region.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/render.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/text.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/text_debug.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_cpu/src/util.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_dev_macros/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_dev_macros/src/bench.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_dev_macros/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_dev_macros/src/test.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/blend.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/blurred_rounded_rect.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/clip.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/emoji_grid.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/filter.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/filter_blur_circle.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/filter_elements.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/gradient.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/image.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/multi_image.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/path.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/random_text.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/simple.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/spritesheet.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/svg.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_example_scenes/src/text.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/CHANGELOG.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/native_webgl/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/native_webgl/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/native_webgl/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/native_webgl/src/main.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/native_webgl/tests/webgl.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/render_to_file.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/wgpu_webgl/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/wgpu_webgl/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/wgpu_webgl/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/wgpu_webgl/src/main.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/wgpu_webgl/tests/webgl.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/winit/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/winit/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/winit/src/main.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/examples/winit/src/render_context.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/blend.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/copy.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/draw.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/filter.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/gradient_cache.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/paint.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/rect.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/render/common.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/render/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/render/webgl/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/render/webgl/probe.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/render/webgl/resource.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/render/wgpu/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/resources.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/sampling.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/scene.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/schedule/allocate.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/schedule/cursor.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/schedule/execute.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/schedule/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/schedule/round.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/schedule/schedule_tests.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/schedule/test_support.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/target.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/text.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/util.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/build.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/src/compile.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/src/lib.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/src/lint/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/src/lint/no_structs_in_fragment.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/src/main.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/src/types.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_shaders/wesl.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/src/regenerate_probe_reference.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/basic.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/blurred_rounded_rect.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/clip.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/compose.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/external_texture.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/filter.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/glyph.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/gradient.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/hybrid_schedule.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/image.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/image_atlas.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/issues.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/layer.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/mask.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/mix.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/mod.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/opacity.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/renderer.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/scenes.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/util.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/wasm_binary_invariants.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_sparse_tests/tests/wide_tile.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_toy/Cargo.toml
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_toy/README.md
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_toy/src/debug.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_toy/src/svg.rs
C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/web/README.md
Bash List top-level dirs
IN
ls -la "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips"

OUT
total 44
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 .
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 ..
-rw-r--r-- 1 isaque.santana 197121 2760 Aug  9 19:56 README.md
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_bench
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_common
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_cpu
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_dev_macros
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_example_scenes
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_hybrid
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_sparse_shaders
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_sparse_tests
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 vello_toy
drwxr-xr-x 1 isaque.santana 197121    0 Aug  9 19:56 web
Let me read the core files in parallel.

Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\tile.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\strip.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\README.md
Agent:Estudar Impeller e Vello clássico
IN
Estude dois codebases de referência e produza um relatório técnico em português (detalhado, mas sem despejar arquivos inteiros):

A) C:\MyDartProjects\dart_ui\referencias\engine-main\impeller — leia README.md, docs/ (especialmente qualquer doc sobre arquitetura, aiks, entity, renderer), e por cima entity/, renderer/, tessellator/, geometry/, typographer/. Explique: como Impeller renderiza paths preenchidos (tessellation com libtess2? stencil-then-cover? — verifique o estado atual no código: procure StencilThenCover / "convex" / tessellator), como faz antialiasing (MSAA? procure docs sobre AA), como faz strokes (geração de geometria de stroke na CPU?), clipping (stencil), blending (framebuffer fetch / blend modes avançados), texto (atlas de glifos rasterizados — typographer), e a arquitetura Entity/Contents/HAL (quais APIs: Metal/Vulkan/GLES2+?). Requisitos mínimos de API gráfica que a abordagem exige.

B) C:\MyDartProjects\dart_ui\referencias\vello-main (o Vello clássico, NÃO o diretório sparse_strips) — leia README.md, doc/, vello_encoding/src (visão geral do encoding de cena), vello_shaders (liste os estágios compute WGSL do pipeline: pathtag_reduce, flatten, binning, coarse, fine etc. e o que cada um faz em 2-3 frases). Explique os requisitos de GPU: compute shaders, storage buffers read-write, indirect dispatch?, limitações conhecidas (memória intermediária, robustez), e o que o README/doc dizem sobre roadmap e sobre a relação com sparse_strips.

Para cada afirmação técnica importante, cite o caminho absoluto do arquivo-fonte. Termine com uma tabela comparativa curta Impeller vs Vello clássico: pré-requisitos de API, onde roda o trabalho pesado, qualidade de AA, custo de memória, complexidade de implementação.
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_raster_sink.dart
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\flatten.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\strip_generator.rs
I'll explore both codebases in parallel, starting with a structural overview.

Bash List Impeller root and docs
IN
ls C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/ && echo "---DOCS---" && ls C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/docs/

OUT
BUILD.gn
README.md
base
compiler
core
display_list
docs
entity
fixtures
geometry
golden_tests
playground
renderer
runtime_stage
shader_archive
shader_bundle
tessellator
toolkit
tools
typographer
---DOCS---
android.md
android_cpu_profile.md
android_validation_layers.md
assets
babys_first_triangle.md
benchmarks.md
blending.md
coordinate_system.md
faq.md
glossary.md
ios_cpu_profile.md
metal_validation.md
opengles_development_setup.md
read_frame_captures.md
renderdoc_frame_capture.md
shader_optimization.md
specialization_constants.md
standalone_gles.md
ubo_gles2.md
vulkan_threading.md
xcode_frame_capture.md
Bash List Vello root and doc
IN
ls C:/MyDartProjects/dart_ui/referencias/vello-main/ && echo "---DOC---" && ls C:/MyDartProjects/dart_ui/referencias/vello-main/doc/ 2>/dev/null

OUT
AUTHORS
CHANGELOG.md
Cargo.lock
Cargo.toml
LICENSE-APACHE
LICENSE-MIT
README.md
doc
examples
glifo
rustfmt.toml
sparse_strips
vello
vello_encoding
vello_shaders
vello_tests
xtask
---DOC---
ARCHITECTURE.md
blogs.md
images
pathseg.md
roadmap_2023.md
vision.md
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\flatten_simd.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\coarse\cmd.rs
I'll read core docs from both in parallel.

Read README.md
Bash List gpu d3d12, raster, replay, path and test dirs
IN
ls C:/MyDartProjects/dart_ui/lib/src/rendering/gpu/d3d12 C:/MyDartProjects/dart_ui/lib/src/rendering/raster C:/MyDartProjects/dart_ui/lib/src/rendering/replay C:/MyDartProjects/dart_ui/lib/src/rendering/path 2>&1; ls C:/MyDartProjects/dart_ui/test/rendering C:/MyDartProjects/dart_ui/test/backends/win32/d2d 2>&1 | head -60

OUT
C:/MyDartProjects/dart_ui/lib/src/rendering/gpu/d3d12:
d3d12_shaders.dart
d3d12_surface_descriptor.dart

C:/MyDartProjects/dart_ui/lib/src/rendering/path:
coverage_span_sink.dart
fill_rule.dart
scanline_filler.dart
stroker.dart

C:/MyDartProjects/dart_ui/lib/src/rendering/raster:
blend.dart
clip_stack.dart
coverage.dart
rasterizer.dart

C:/MyDartProjects/dart_ui/lib/src/rendering/replay:
display_list_player.dart
recording_sink.dart
replay_state.dart
C:/MyDartProjects/dart_ui/test/backends/win32/d2d:
d2d_backend_test.dart
d2d_replay_golden_test.dart
d2d_session.dart

C:/MyDartProjects/dart_ui/test/rendering:
blend_modes_test.dart
cpu_canvas_test.dart
cpu_layers_test.dart
cpu_renderer_test.dart
framebuffer_test.dart
gpu
path
raster
replay
text
Read C:\MyDartProjects\dart_ui\doc\adr\0005-metal-sobre-iosurface-compartilhada.md
Read blending.md
Read README.md
Read ARCHITECTURE.md
Bash Find tile constants
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips" && grep -rn "WIDE_TILE_WIDTH\|STRIP_HEIGHT\|TILE_HEIGHT\|TILE_WIDTH\|const WIDTH\|const HEIGHT" --include=*.rs --include=*.wgsl --include=*.wesl | grep -v "^vello_sparse_tests" | head -60

OUT
vello_bench/src/glyph.rs:17:    const WIDTH: u16 = 256;
vello_bench/src/glyph.rs:18:    const HEIGHT: u16 = 256;
vello_common/src/tile.rs:263:    pub const WIDTH: u16 = 4;
vello_common/src/tile.rs:266:    pub const HEIGHT: u16 = 4;
vello_common/src/tile.rs:2247:        const WIDTH: u16 = Tile::WIDTH * 35;
vello_common/src/tile.rs:2248:        const HEIGHT: u16 = Tile::HEIGHT * 7;
vello_cpu/src/coarse/depth.rs:44:const DEPTH_BUCKET_TILE_WIDTH: u16 = DEPTH_BUCKET_WIDTH / Tile::WIDTH;
vello_cpu/src/coarse/depth.rs:88:    let aligned_x = x.next_multiple_of(DEPTH_BUCKET_TILE_WIDTH);
vello_cpu/src/coarse/depth.rs:89:    let aligned_end = (end / DEPTH_BUCKET_TILE_WIDTH) * DEPTH_BUCKET_TILE_WIDTH;
vello_cpu/src/coarse/depth.rs:103:            aligned_x / DEPTH_BUCKET_TILE_WIDTH,
vello_cpu/src/coarse/depth.rs:104:            aligned_end / DEPTH_BUCKET_TILE_WIDTH,
vello_cpu/src/fine/lowp/mod.rs:19:use crate::fine::{COLOR_COMPONENTS, FineKernel, Painter, Splat4thExt, TILE_HEIGHT_COMPONENTS};
vello_cpu/src/fine/lowp/mod.rs:341:            &scratch[block_width * TILE_HEIGHT_COMPONENTS..],
vello_cpu/src/fine/lowp/mod.rs:351:    const CHUNK_LENGTH: usize = Tile::WIDTH as usize * TILE_HEIGHT_COMPONENTS;
vello_cpu/src/fine/lowp/mod.rs:360:    for col in scratch[..width * TILE_HEIGHT_COMPONENTS].chunks_exact(CHUNK_LENGTH) {
vello_cpu/src/fine/lowp/mod.rs:413:            &mut scratch[block_width * TILE_HEIGHT_COMPONENTS..],
vello_cpu/src/fine/lowp/mod.rs:420:    let scratch: &mut [f32] = cast_slice_mut(&mut scratch[..width * TILE_HEIGHT_COMPONENTS]);
vello_cpu/src/fine/lowp/mod.rs:720:        let scratch_len = usize::from(width) * TILE_HEIGHT_COMPONENTS;
vello_cpu/src/fine/mod.rs:61:pub(crate) const TILE_HEIGHT_COMPONENTS: usize = Tile::HEIGHT as usize * COLOR_COMPONENTS;
vello_cpu/src/fine/mod.rs:524:        let scratch_len = usize::from(buffer_width) * TILE_HEIGHT_COMPONENTS;
vello_cpu/src/fine/mod.rs:546:        let start = usize::from(span.pixel_x()) * TILE_HEIGHT_COMPONENTS;
vello_cpu/src/fine/mod.rs:547:        let len = usize::from(span.pixel_width()) * TILE_HEIGHT_COMPONENTS;
vello_cpu/src/fine/mod.rs:605:            &mut scratch[scratch_x * TILE_HEIGHT_COMPONENTS..],
vello_cpu/src/fine/mod.rs:861:        let len = usize::from(width) * TILE_HEIGHT_COMPONENTS;
vello_cpu/src/fine/mod.rs:873:        let start = usize::from(x) * TILE_HEIGHT_COMPONENTS;
Now let me dig into the specifics of both.

Bash Find shader files
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips" && find . -name "*.wgsl" -o -name "*.wesl" -o -name "*.glsl" -o -name "*.frag" -o -name "*.vert" | head -50

OUT
./vello_sparse_shaders/shaders/blend.wesl
./vello_sparse_shaders/shaders/clear.wesl
./vello_sparse_shaders/shaders/copy.wesl
./vello_sparse_shaders/shaders/filter.wesl
./vello_sparse_shaders/shaders/render.wesl
Bash List tessellator and geometry dirs
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && ls tessellator/ geometry/ | head -80

OUT
geometry/:
BUILD.gn
README.md
color.cc
color.h
constants.cc
constants.h
geometry_asserts.h
geometry_benchmarks.cc
geometry_unittests.cc
gradient.cc
gradient.h
half.h
matrix.cc
matrix.h
matrix_decomposition.cc
matrix_decomposition.h
matrix_unittests.cc
path.cc
path.h
path_builder.cc
path_builder.h
path_component.cc
path_component.h
path_unittests.cc
point.cc
point.h
quaternion.cc
quaternion.h
rect.cc
rect.h
rect_unittests.cc
round_rect.cc
round_rect.h
round_rect_unittests.cc
saturated_math.h
saturated_math_unittests.cc
scalar.h
separated_vector.cc
separated_vector.h
shear.cc
shear.h
sigma.cc
sigma.h
size.cc
size.h
size_unittests.cc
trig.cc
trig.h
trig_unittests.cc
type_traits.cc
type_traits.h
vector.cc
vector.h
wangs_formula.cc
wangs_formula.h

tessellator/:
BUILD.gn
c
dart
tessellator.cc
tessellator.h
tessellator_libtess.cc
tessellator_libtess.h
tessellator_unittests.cc
Grep "StencilThenCover|stencil_then_cover|kStencilThenCover" (in C:/MyDartProjects/dart_ui/referencias/engine-main/impeller)
2 lines of output
Bash List vello shaders
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main/vello_shaders && ls shader/ shader/shared/ src/

OUT
shader/:
UNLICENSE
backdrop.wgsl
backdrop_dyn.wgsl
bbox_clear.wgsl
binning.wgsl
clip_leaf.wgsl
clip_reduce.wgsl
coarse.wgsl
draw_leaf.wgsl
draw_reduce.wgsl
fine.wgsl
flatten.wgsl
path_count.wgsl
path_count_setup.wgsl
path_tiling.wgsl
path_tiling_setup.wgsl
pathtag_reduce.wgsl
pathtag_reduce2.wgsl
pathtag_scan.wgsl
pathtag_scan1.wgsl
permutations
shared
tile_alloc.wgsl

shader/shared/:
bbox.wgsl
blend.wgsl
bump.wgsl
clip.wgsl
config.wgsl
cubic.wgsl
drawtag.wgsl
pathtag.wgsl
ptcl.wgsl
segment.wgsl
tile.wgsl
transform.wgsl
util.wgsl

src/:
compile
cpu
cpu.rs
lib.rs
types.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\coarse\mod.rs
Bash List gpu tests and backends
IN
ls -R C:/MyDartProjects/dart_ui/test/rendering/gpu 2>&1 | head -60; ls C:/MyDartProjects/dart_ui/lib/src/backends 2>&1

OUT
C:/MyDartProjects/dart_ui/test/rendering/gpu:
d3d11
d3d12
gl_device_test.dart
gl_framebuffer_pool_test.dart
gl_glyph_device_test.dart
gl_layer_device_test.dart
gl_recovery_device_test.dart
gl_window_target_test.dart
gpu_batcher_test.dart
gpu_device_state_test.dart
gpu_glyph_atlas_test.dart
gpu_layer_stack_test.dart
gpu_mask_atlas_test.dart
gpu_pipeline_test.dart
gpu_raster_sink_layer_test.dart
gpu_raster_sink_test.dart
gpu_recovery_test.dart
gpu_shelf_atlas_test.dart
gpu_texture_test.dart
gpu_vertex_buffer_test.dart
metal
vulkan
webgl
webgpu

C:/MyDartProjects/dart_ui/test/rendering/gpu/d3d11:
d3d11_cpu_parity_test.dart
d3d11_device_test.dart
d3d11_recovery_test.dart

C:/MyDartProjects/dart_ui/test/rendering/gpu/d3d12:
d3d12_cpu_parity_test.dart
d3d12_shaders_test.dart

C:/MyDartProjects/dart_ui/test/rendering/gpu/metal:
metal_backend_test.dart
metal_bindings_test.dart
metal_cpu_parity_test.dart
metal_device_test.dart
metal_offscreen_test.dart
metal_shaders_test.dart

C:/MyDartProjects/dart_ui/test/rendering/gpu/vulkan:
vulkan_cpu_parity_test.dart
vulkan_device_test.dart
vulkan_fence_test.dart
vulkan_layout_test.dart
vulkan_memory_test.dart
vulkan_pipeline_test.dart
vulkan_session.dart
vulkan_spirv_test.dart
vulkan_symbol_test.dart

C:/MyDartProjects/dart_ui/test/rendering/gpu/webgl:
webgl_cpu_parity_test.dart
webgl_device_test.dart
webgl_session.dart

C:/MyDartProjects/dart_ui/test/rendering/gpu/webgpu:
default_platform_resolver.dart
default_platform_resolver_stub.dart
headless
macos
wayland
web
win32
x11
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_batcher.dart
Bash List entity subdirs
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/entity && ls . geometry/ contents/ | head -140

OUT
.:
BUILD.gn
clip_stack_unittests.cc
contents
draw_order_resolver.cc
draw_order_resolver.h
draw_order_resolver_unittests.cc
entity.cc
entity.h
entity_pass_clip_stack.cc
entity_pass_clip_stack.h
entity_pass_target.cc
entity_pass_target.h
entity_pass_target_unittests.cc
entity_playground.cc
entity_playground.h
entity_unittests.cc
geometry
inline_pass_context.cc
inline_pass_context.h
render_target_cache.cc
render_target_cache.h
render_target_cache_unittests.cc
save_layer_utils.cc
save_layer_utils.h
save_layer_utils_unittests.cc
shaders

contents/:
anonymous_contents.cc
anonymous_contents.h
atlas_contents.cc
atlas_contents.h
clip_contents.cc
clip_contents.h
color_source_contents.cc
color_source_contents.h
conical_gradient_contents.cc
conical_gradient_contents.h
content_context.cc
content_context.h
contents.cc
contents.h
filters
framebuffer_blend_contents.cc
framebuffer_blend_contents.h
gradient_generator.cc
gradient_generator.h
host_buffer_unittests.cc
linear_gradient_contents.cc
linear_gradient_contents.h
radial_gradient_contents.cc
radial_gradient_contents.h
runtime_effect_contents.cc
runtime_effect_contents.h
solid_color_contents.cc
solid_color_contents.h
solid_rrect_blur_contents.cc
solid_rrect_blur_contents.h
sweep_gradient_contents.cc
sweep_gradient_contents.h
test
text_contents.cc
text_contents.h
texture_contents.cc
texture_contents.h
tiled_texture_contents.cc
tiled_texture_contents.h
tiled_texture_contents_unittests.cc
vertices_contents.cc
vertices_contents.h

geometry/:
circle_geometry.cc
circle_geometry.h
cover_geometry.cc
cover_geometry.h
ellipse_geometry.cc
ellipse_geometry.h
fill_path_geometry.cc
fill_path_geometry.h
geometry.cc
geometry.h
geometry_unittests.cc
line_geometry.cc
line_geometry.h
point_field_geometry.cc
point_field_geometry.h
rect_geometry.cc
rect_geometry.h
round_rect_geometry.cc
round_rect_geometry.h
round_superellipse_geometry.cc
round_superellipse_geometry.h
stroke_path_geometry.cc
stroke_path_geometry.h
superellipse_geometry.cc
superellipse_geometry.h
vertices_geometry.cc
vertices_geometry.h
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\coarse\bucketer.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\coarse\depth.rs
Bash Read color_source_contents.h head
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/entity && head -80 contents/color_source_contents.h

OUT
// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_IMPELLER_ENTITY_CONTENTS_COLOR_SOURCE_CONTENTS_H_
#define FLUTTER_IMPELLER_ENTITY_CONTENTS_COLOR_SOURCE_CONTENTS_H_

#include "fml/logging.h"
#include "impeller/entity/contents/clip_contents.h"
#include "impeller/entity/contents/content_context.h"
#include "impeller/entity/contents/contents.h"
#include "impeller/entity/geometry/geometry.h"
#include "impeller/entity/geometry/rect_geometry.h"
#include "impeller/geometry/matrix.h"
#include "impeller/renderer/render_pass.h"

namespace impeller {

//------------------------------------------------------------------------------
/// Color sources are geometry-ignostic `Contents` capable of shading any area
/// defined by an `impeller::Geometry`. Conceptually,
/// `impeller::ColorSourceContents` implement a particular color shading
/// behavior.
///
/// This separation of concerns between geometry and color source output allows
/// Impeller to handle most possible draw combinations in a consistent way.
/// For example: There are color sources for handling solid colors, gradients,
/// textures, custom runtime effects, and even 3D scenes.
///
/// There are some special rendering exceptions that deviate from this pattern
/// and cross geometry and color source concerns, such as text atlas and image
/// atlas rendering. Special `Contents` exist for rendering these behaviors
/// which don't implement `ColorSourceContents`.
///
/// @see  `impeller::Geometry`
///
class ColorSourceContents : public Contents {
 public:
  ColorSourceContents();

  ~ColorSourceContents() override;

  //----------------------------------------------------------------------------
  /// @brief  Set the geometry that this contents will use to render.
  ///
  void SetGeometry(const Geometry* geometry);

  //----------------------------------------------------------------------------
  /// @brief  Get the geometry that this contents will use to render.
  ///
  const Geometry* GetGeometry() const;

  //----------------------------------------------------------------------------
  /// @brief  Set the effect transform for this color source.
  ///
  ///         The effect transform is a transform matrix that is applied to
  ///         the shaded color output and does not impact geometry in any way.
  ///
  ///         For example: With repeat tiling, any gradient or
  ///         `TiledTextureContents` could be used with an effect transform to
  ///         inexpensively draw an infinite scrolling background pattern.
  ///
  void SetEffectTransform(Matrix matrix);

  //----------------------------------------------------------------------------
  /// @brief   Set the inverted effect transform for this color source.
  ///
  ///          When the effect transform is set via `SetEffectTransform`, the
  ///          value is inverted upon storage. The reason for this is that most
  ///          color sources internally use the inverted transform.
  ///
  /// @return  The inverse of the transform set by `SetEffectTransform`.
  ///
  /// @see     `SetEffectTransform`
  ///
  const Matrix& GetInverseEffectTransform() const;

  //----------------------------------------------------------------------------
  /// @brief  Set the opacity factor for this color source.
  ///
Read geometry.h
Read fill_path_geometry.cc
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\util.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\fine\mod.rs
Grep "class D3D12|d3d12" (in C:\MyDartProjects\dart_ui\lib\src)
23 lines of output
Read C:\MyDartProjects\dart_ui\test\rendering\gpu\d3d12\d3d12_cpu_parity_test.dart
Grep "kNonZero|kEvenOdd|kPreventOverdraw|StencilThenCover|stencil" (in C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/entity/contents/color_source_contents.h)
121 lines of output
Bash Read tessellator.h
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && cat tessellator/tessellator.h | head -200

OUT
// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_IMPELLER_TESSELLATOR_TESSELLATOR_H_
#define FLUTTER_IMPELLER_TESSELLATOR_TESSELLATOR_H_

#include <functional>
#include <memory>
#include <vector>

#include "impeller/core/formats.h"
#include "impeller/core/host_buffer.h"
#include "impeller/core/vertex_buffer.h"
#include "impeller/geometry/path.h"
#include "impeller/geometry/point.h"
#include "impeller/geometry/trig.h"

namespace impeller {

/// The size of the point arena buffer stored on the tessellator.
static constexpr size_t kPointArenaSize = 4096u;

//------------------------------------------------------------------------------
/// @brief      A utility that generates triangles of the specified fill type
///             given a polyline. This happens on the CPU.
///
///             Also contains functionality for optimized generation of circles
///             and ellipses.
///
///             This object is not thread safe, and its methods must not be
///             called from multiple threads.
///
class Tessellator {
 private:
  /// Essentially just a vector of Trig objects, but supports storing a
  /// reference to either a cached vector or a locally generated vector.
  /// The constructor will fill the vector with quarter circular samples
  /// for the indicated number of equal divisions if the vector is new.
  class Trigs {
   public:
    explicit Trigs(std::vector<Trig>& trigs, size_t divisions) : trigs_(trigs) {
      init(divisions);
      FML_DCHECK(trigs_.size() == divisions + 1);
    }

    explicit Trigs(size_t divisions)
        : local_storage_(std::make_unique<std::vector<Trig>>()),
          trigs_(*local_storage_) {
      init(divisions);
      FML_DCHECK(trigs_.size() == divisions + 1);
    }

    // Utility forwards of the indicated vector methods.
    auto inline size() const { return trigs_.size(); }
    auto inline begin() const { return trigs_.begin(); }
    auto inline end() const { return trigs_.end(); }

   private:
    // nullptr if a cached vector is used, otherwise the actual storage
    std::unique_ptr<std::vector<Trig>> local_storage_;

    // Whether or not a cached vector or the local storage is used, this
    // this reference will always be valid
    std::vector<Trig>& trigs_;

    // Fill the vector with the indicated number of equal divisions of
    // trigonometric values if it is empty.
    void init(size_t divisions);
  };

 public:
  enum class Result {
    kSuccess,
    kInputError,
    kTessellationError,
  };

  /// @brief  A callback function for a |VertexGenerator| to deliver
  ///         the vertices it computes as |Point| objects.
  using TessellatedVertexProc = std::function<void(const Point& p)>;

  /// @brief  An object which produces a list of vertices as |Point|s that
  ///         tessellate a previously provided shape and delivers the vertices
  ///         through a |TessellatedVertexProc| callback.
  ///
  ///         The object can also provide advance information on how many
  ///         vertices it will generate.
  ///
  /// @see |Tessellator::FilledCircle|
  /// @see |Tessellator::StrokedCircle|
  /// @see |Tessellator::RoundCapLine|
  /// @see |Tessellator::FilledEllipse|
  class VertexGenerator {
   public:
    /// @brief  Returns the |PrimitiveType| that describes the relationship
    ///         among the list of vertices produced by the |GenerateVertices|
    ///         method.
    ///
    ///         Most generators will deliver |kTriangleStrip| triangles
    virtual PrimitiveType GetTriangleType() const = 0;

    /// @brief  Returns the number of vertices that the generator plans to
    ///         produce, if known.
    ///
    ///         This value is advisory only and can be used to reserve space
    ///         where the vertices will be placed, but the count may be an
    ///         estimate.
    ///
    ///         Implementations are encouraged to avoid overestimating
    ///         the count by too large a number and to provide a best
    ///         guess so as to minimize potential buffer reallocations
    ///         as the vertices are delivered.
    virtual size_t GetVertexCount() const = 0;

    /// @brief  Generate the vertices and deliver them in the necessary
    ///         order (as required by the PrimitiveType) to the given
    ///         callback function.
    virtual void GenerateVertices(const TessellatedVertexProc& proc) const = 0;
  };

  /// @brief  The |VertexGenerator| implementation common to all shapes
  ///         that are based on a polygonal representation of an ellipse.
  class EllipticalVertexGenerator : public virtual VertexGenerator {
   public:
    /// |VertexGenerator|
    PrimitiveType GetTriangleType() const override {
      return PrimitiveType::kTriangleStrip;
    }

    /// |VertexGenerator|
    size_t GetVertexCount() const override {
      return trigs_.size() * vertices_per_trig_;
    }

    /// |VertexGenerator|
    void GenerateVertices(const TessellatedVertexProc& proc) const override {
      impl_(trigs_, data_, proc);
    }

   private:
    friend class Tessellator;

    struct Data {
      // Circles and Ellipses only use one of these points.
      // RoundCapLines use both as the endpoints of the unexpanded line.
      // A round rect can specify its interior rectangle by using the
      // 2 points as opposing corners.
      const Point reference_centers[2];
      // Circular shapes have the same value in radii.width and radii.height
      const Size radii;
      // half_width is only used in cases where the generator will be
      // generating 2 different outlines, such as StrokedCircle
      const Scalar half_width;
    };

    typedef void GeneratorProc(const Trigs& trigs,
                               const Data& data,
                               const TessellatedVertexProc& proc);

    GeneratorProc& impl_;
    const Trigs trigs_;
    const Data data_;
    const size_t vertices_per_trig_;

    EllipticalVertexGenerator(GeneratorProc& generator,
                              Trigs&& trigs,
                              PrimitiveType triangle_type,
                              size_t vertices_per_trig,
                              Data&& data);
  };

  Tessellator();

  virtual ~Tessellator();

  //----------------------------------------------------------------------------
  /// @brief      Given a convex path, create a triangle fan structure.
  ///
  /// @param[in]  path  The path to tessellate.
  /// @param[in]  host_buffer  The host buffer for allocation of vertices/index
  ///                          data.
  /// @param[in]  tolerance  The tolerance value for conversion of the path to
  ///                        a polyline. This value is often derived from the
  ///                        Matrix::GetMaxBasisLengthXY of the CTM applied to
  ///                        the path for rendering.
  ///
  /// @return A vertex buffer containing all data from the provided curve.
  VertexBuffer TessellateConvex(const Path& path,
                                HostBuffer& host_buffer,
                                Scalar tolerance,
                                bool supports_primitive_restart = false,
                                bool supports_triangle_fan = false);

  //----------------------------------------------------------------------------
  /// @brief      Given a path, create a line strip primitive structure.
  ///
  ///             A line strip is a series of vertices that draws a line
  ///             rendered at a specified width (in our case, always 1.0
  ///             physical pixel) that is tessellated by the rasterizer. See
Grep "RenderCmd::(PaintFill|PushBuf|PopBuf|LayerFill)|fn run|fn strip|fn fill\(|alphas\[|alpha_idx" (in C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\fine\mod.rs)
9 lines of output
Grep "fn .*strip|fn .*fill|Tile::HEIGHT|alphas" (in C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\fine\lowp\mod.rs)
21 lines of output
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\fine\mod.rs (lines 481-740)
Grep "TessellatorLibtess|tessellator_libtess" (in C:/MyDartProjects/dart_ui/referencias/engine-main)
10 lines of output
Grep "enum class StencilMode|kStencilNonZeroFill|kCoverCompare|kLegacyClipIncrement|kOverdrawPreventionIncrement" (in C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/entity/contents/content_context.h)
69 lines of output
Grep "SampleCount|kCount4|msaa|MSAA" (in C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/entity/contents/content_context.cc)
9 lines of output
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\README.md
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\render\common.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_sparse_shaders\shaders\render.wesl
Bash Inspect stroke geometry
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/entity/geometry && grep -n "Join::\|Cap::\|CreateSolidStrokeVertices\|kPreventOverdraw\|Wangs\|ComputeStrokeAlphaCoverage\|kMinStrokeSize\|round_\|miter" stroke_path_geometry.cc | head -60

OUT
62:                                    Scalar miter_limit,
69:                  const Scalar p_scaled_miter_limit,
75:        scaled_miter_limit(p_scaled_miter_limit),
169:                  offset.GetVector(), contour_first_offset, scaled_miter_limit,
229:                  scaled_miter_limit, scale);
305:                    scaled_miter_limit, scale);
313:  const Scalar scaled_miter_limit;
414:                     Scalar miter_limit,
428:  Point miter_point = (((start_offset + end_offset) / 2) / alignment);
429:  if (miter_point.GetDistanceSquared({0, 0}) > miter_limit * miter_limit) {
430:    return;  // Convert to bevel when we exceed the miter limit.
433:  // Outer miter point.
434:  vtx_builder.AppendVertex(position + miter_point * direction);
441:                     Scalar miter_limit,
483:                     Scalar miter_limit,
488:void CreateSolidStrokeVertices(PositionWriter& vtx_builder,
491:                               Scalar scaled_miter_limit,
495:  StrokeGenerator stroke_generator(polyline, stroke_width, scaled_miter_limit,
504:    case Join::kBevel:
506:    case Join::kMiter:
508:    case Join::kRound:
515:    case Cap::kButt:
517:    case Cap::kRound:
519:    case Cap::kSquare:
528:    Scalar miter_limit,
532:  auto scaled_miter_limit = stroke_width * miter_limit * 0.5f;
535:  StrokeGenerator stroke_generator(polyline, stroke_width, scaled_miter_limit,
545:                                       Scalar miter_limit,
550:      miter_limit_(miter_limit),
561:  return miter_limit_;
573:  return Geometry::ComputeStrokeAlphaCoverage(transform, stroke_width_);
588:  Scalar min_size = kMinStrokeSize / max_basis;
599:  CreateSolidStrokeVertices(position_writer, polyline, stroke_width,
600:                            miter_limit_ * stroke_width_ * 0.5f,
618:                          .mode = GeometryResult::Mode::kPreventOverdraw};
647:                        .mode = GeometryResult::Mode::kPreventOverdraw};
651:  return GeometryResult::Mode::kPreventOverdraw;
662:  if (stroke_cap_ == Cap::kSquare) {
665:  if (stroke_join_ == Join::kMiter) {
666:    max_radius = std::max(max_radius, miter_limit_ * 0.5f);
673:  Scalar min_size = kMinStrokeSize / max_basis;
O harness D3D12 offscreen com readback existe e é exatamente o que o spike vai usar. Agora vou estudar o rasterizador CPU, o Path e o alvo offscreen D3D12.

Read C:\MyDartProjects\dart_ui\lib\src\rendering\path\scanline_filler.dart
Bash Inspect clip contents
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/entity && grep -n "StencilMode\|kClipDepth\|depth\|ClipOperation\|Restore" contents/clip_contents.cc | head -60

OUT
19:static Scalar GetShaderClipDepth(uint32_t clip_depth) {
20:  // Draw the clip at the max of the clip entity's depth slice, so that other
21:  // draw calls with this same depth value will be culled even if they have a
23:  return std::nextafterf(Entity::GetShaderClipDepth(clip_depth + 1), 0.0f);
40:void ClipContents::SetClipOperation(Entity::ClipOperation clip_op) {
50:    case Entity::ClipOperation::kDifference:
57:    case Entity::ClipOperation::kIntersect:
71:                          uint32_t clip_depth) const {
79:  info.depth = GetShaderClipDepth(clip_depth);
88:  options.depth_write_enabled = false;
95:          ContentContextOptions::StencilMode::kStencilNonZeroFill;
100:          ContentContextOptions::StencilMode::kStencilEvenOddFill;
106:          ContentContextOptions::StencilMode::kOverdrawPreventionIncrement;
118:  /// Write depth.
120:  options.depth_write_enabled = true;
124:    case Entity::ClipOperation::kIntersect:
127:          ContentContextOptions::StencilMode::kCoverCompareInverted;
130:    case Entity::ClipOperation::kDifference:
132:      options.stencil_mode = ContentContextOptions::StencilMode::kCoverCompare;
149: ******* ClipRestoreContents
152:bool RenderClipRestore(const ContentContext& renderer,
154:                       uint32_t clip_depth,
158:  pass.SetCommandLabel("Restore Clip");
162:      ContentContextOptions::StencilMode::kOverdrawPreventionRestore;
183:  info.depth = GetShaderClipDepth(clip_depth);
Grep "SupportsFramebufferFetch|framebuffer_fetch" (in C:/MyDartProjects/dart_ui/referencias/engine-main/impeller)
31 lines of output
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\draw.rs
Bash Inventory ReplayResources implementers and CPU raster API
IN
grep -rn "implements ReplayResources" lib test | head; echo ---; grep -n "void fillRect\|void fillSpan\|blendCoverageMask\|class CpuRasterizer\|void fill\b\|fillPath\|span(" lib/src/rendering/raster/rasterizer.dart | head -30; echo ---; grep -n "fillDeviceRect\|fillDeviceRRect\|drawDevicePath" lib/src/rendering/cpu_renderer.dart | head

OUT
lib/src/rendering/replay/display_list_player.dart:180:final class DisplayListResources implements ReplayResources {
test/rendering/replay/display_list_player_test.dart:597:final class _PaintStyleOverride implements ReplayResources {
---
51:final class CpuRasterizer {
102:  void fillRect(
239:  void fillRectAntiAliased(
441:  void blendCoverageMask(
---
475:  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) {
481:  void fillDeviceRRect(
506:  /// Stroking *is* implemented here - see [drawDevicePath] - but only where
523:          'scale it by. Send the shape through drawDevicePath, which strokes',
766:  void drawDevicePath(
Bash Line counts of key files
IN
wc -l C:/MyDartProjects/dart_ui/lib/src/geometry/path.dart C:/MyDartProjects/dart_ui/lib/src/backends/win32/d3d12/d3d12_offscreen_target.dart C:/MyDartProjects/dart_ui/test/backends/win32/d3d12/d3d12_session.dart C:/MyDartProjects/dart_ui/lib/src/rendering/gpu/gpu_mask_atlas.dart C:/MyDartProjects/dart_ui/lib/src/backends/win32/d3d12/d3d12_device.dart C:/MyDartProjects/dart_ui/lib/src/rendering/path/coverage_span_sink.dart C:/MyDartProjects/dart_ui/lib/src/rendering/gpu/gpu_pipeline.dart 2>&1

OUT
  1148 C:/MyDartProjects/dart_ui/lib/src/geometry/path.dart
   484 C:/MyDartProjects/dart_ui/lib/src/backends/win32/d3d12/d3d12_offscreen_target.dart
   103 C:/MyDartProjects/dart_ui/test/backends/win32/d3d12/d3d12_session.dart
   963 C:/MyDartProjects/dart_ui/lib/src/rendering/gpu/gpu_mask_atlas.dart
  1929 C:/MyDartProjects/dart_ui/lib/src/backends/win32/d3d12/d3d12_device.dart
    51 C:/MyDartProjects/dart_ui/lib/src/rendering/path/coverage_span_sink.dart
   138 C:/MyDartProjects/dart_ui/lib/src/rendering/gpu/gpu_pipeline.dart
  4816 total
Read capabilities.h
Bash List backends and typographer
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && ls renderer/backend/ typographer/ typographer/backends/ 2>/dev/null

OUT
renderer/backend/:
BUILD.gn
gles
metal
vulkan

typographer/:
BUILD.gn
backends
font.cc
font.h
font_glyph_pair.cc
font_glyph_pair.h
glyph.cc
glyph.h
glyph_atlas.cc
glyph_atlas.h
lazy_glyph_atlas.cc
lazy_glyph_atlas.h
rectangle_packer.cc
rectangle_packer.h
text_frame.cc
text_frame.h
text_run.cc
text_run.h
typeface.cc
typeface.h
typographer_context.cc
typographer_context.h
typographer_unittests.cc

typographer/backends/:
skia
Let me check how the win32 backend wires ClipboardProvider and how the app consumes it.

Read C:\MyDartProjects\dart_ui\lib\src\rendering\raster\rasterizer.dart
Read C:\MyDartProjects\dart_ui\lib\src\rendering\path\coverage_span_sink.dart
Grep "alphas_tex|ALPHA|alpha_texture|alphas_texture|texture_width|Rgba32Uint|R32Uint" (in C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src)
81 lines of output
Read C:\MyDartProjects\dart_ui\test\backends\win32\d3d12\d3d12_session.dart
Bash Find clipboard provider wiring
IN
cd C:/MyDartProjects/dart_ui && grep -n "ClipboardProvider\|clipboard" lib/src/backends/win32/win32_backend.dart | head -10 && grep -rn "ClipboardProvider" lib/src/app/*.dart | head -10 && grep -n "class Win32WindowingBackend" lib/src/backends/win32/win32_backend.dart

OUT
25:import '../../platform/clipboard.dart';
29:import 'win32_clipboard.dart';
38:    implements WindowingBackend, ClipboardProvider {
44:  /// The Windows clipboard, over the same `Win32Api` the windows use.
48:  /// the backend answering. See [ClipboardProvider].
54:  ///  * a Windows build without the user32/kernel32 clipboard symbols has no
55:  ///    clipboard at all, and `Capability.clipboardText` is correspondingly
58:  Clipboard get clipboard {
62:        'the win32 backend has not been initialized, so no clipboard has been '
66:    if (!api.clipboardSupported) {
lib/src/app/application.dart:690:  /// selected backend supplies one when it is a [ClipboardProvider] - the Win32
lib/src/app/application.dart:1707:  ///     that backend is a [ClipboardProvider] - which the Win32 backend and
lib/src/app/application.dart:1724:    // A pattern rather than `is`: [ClipboardProvider] is not a subtype of
lib/src/app/application.dart:1727:    if (backend case final ClipboardProvider provider) {
lib/src/app/application.dart:2179:      // A pattern rather than `is`, for the same reason as ClipboardProvider:
37:final class Win32WindowingBackend
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\render\wgpu\mod.rs (lines 2261-2380)
Bash Read glyph atlas headers
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/typographer && sed -n '1,80p' glyph_atlas.h && echo "=== CONTEXT ===" && grep -n "class\|Type::\|kAlphaBitmap\|kColorBitmap\|CreateGlyphAtlas" typographer_context.h | head -30

OUT
// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_IMPELLER_TYPOGRAPHER_GLYPH_ATLAS_H_
#define FLUTTER_IMPELLER_TYPOGRAPHER_GLYPH_ATLAS_H_

#include <functional>
#include <memory>
#include <optional>

#include "flutter/fml/build_config.h"

#if defined(OS_FUCHSIA)
// TODO(gaaclarke): Migrate to use absl. I couldn't get it working since absl
// has special logic in its GN files for Fuchsia that I couldn't sort out.
#define IMPELLER_TYPOGRAPHER_USE_STD_HASH
#else
#include "flutter/third_party/abseil-cpp/absl/container/flat_hash_map.h"
#endif

#include "impeller/core/texture.h"
#include "impeller/geometry/rect.h"
#include "impeller/typographer/font_glyph_pair.h"
#include "impeller/typographer/rectangle_packer.h"

namespace impeller {

class FontGlyphAtlas;

/// Helper for AbslHashAdapter. Tallies a hash value with fml::HashCombine.
template <typename T>
struct AbslHashAdapterCombiner {
  std::size_t value = 0;

  template <typename... Args>
  static AbslHashAdapterCombiner combine(AbslHashAdapterCombiner combiner,
                                         const Args&... args) {
    combiner.value = fml::HashCombine(combiner.value, args...);
    return combiner;
  }
};

/// Adapts AbslHashValue functions to be used with std::unordered_map and the
/// fml hash functions.
template <typename T>
struct AbslHashAdapter {
  constexpr std::size_t operator()(const T& element) const {
    AbslHashAdapterCombiner<T> combiner;
    combiner = AbslHashValue(std::move(combiner), element);
    return combiner.value;
  }
};

struct FrameBounds {
  /// The bounds of the glyph within the glyph atlas.
  Rect atlas_bounds;
  /// The local glyph bounds.
  Rect glyph_bounds;
  /// Whether [atlas_bounds] are still a placeholder and have
  /// not yet been computed.
  bool is_placeholder = true;
};

//------------------------------------------------------------------------------
/// @brief      A texture containing the bitmap representation of glyphs in
///             different fonts along with the ability to query the location of
///             specific font glyphs within the texture.
///
class GlyphAtlas {
 public:
  //----------------------------------------------------------------------------
  /// @brief      Describes how the glyphs are represented in the texture.
  enum class Type {
    //--------------------------------------------------------------------------
    /// The glyphs are reprsented at their requested size using only an 8-bit
    /// color channel.
    ///
    /// This might be backed by a grey or red single channel texture, depending
    /// on the backend capabilities.
=== CONTEXT ===
23:class TypographerContext {
29:  virtual std::shared_ptr<GlyphAtlasContext> CreateGlyphAtlasContext(
32:  virtual std::shared_ptr<GlyphAtlas> CreateGlyphAtlas(
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\render\wgpu\mod.rs (lines 2526-2585)
Bash GLES capabilities version checks
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller/renderer/backend/gles && grep -n "GLES3\|gles3\|kGLES\|version\|Version\|OpenGL ES 2\|es_2\|IsES" capabilities_gles.cc | head -50

OUT
44:  if (desc->IsES()) {
68:  if (desc->IsES()) {
86:  if (desc->IsES()) {
104:  if (desc->IsES()) {
110:  if (desc->IsES()) {
116:  if (desc->GetGlVersion().major_version >= 3) {
137:  is_es_ = desc->IsES();
141:bool CapabilitiesGLES::IsES() const {
Read android.md
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\schedule\mod.rs
Now I'll implement round 2. First, protocol constants for the data-device family.

Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\lib.rs
Read C:\MyDartProjects\dart_ui\lib\src\backends\win32\d3d12\d3d12_offscreen_target.dart
Bash MSAA config in canvas and render target
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && grep -n "msaa\|MSAA\|SampleCount\|kCount4" display_list/canvas.cc | head -30; echo "=== RT ==="; grep -n "kDefaultColorAttachmentConfigMSAA\|CreateOffscreenMSAA\|SampleCount::kCount4\|StorageMode::kDeviceTransient" renderer/render_target.cc | head -30

OUT
126:  if (context->GetCapabilities()->SupportsOffscreenMSAA()) {
127:    target = renderer.GetRenderTargetCache()->CreateOffscreenMSAA(
133:        RenderTarget::AttachmentConfigMSAA{
158:      renderer.GetDeviceCapabilities().SupportsImplicitResolvingMSAA());
869:        renderer_.GetContext()->GetCapabilities()->SupportsOffscreenMSAA(),
893:        renderer_.GetDeviceCapabilities().SupportsImplicitResolvingMSAA()  //
1594:    // When MSAA is being used, we end up overriding the entire backdrop by
1605:        renderer_.GetDeviceCapabilities().SupportsImplicitResolvingMSAA()  //
1627:  // memory than storing/loading large MSAA textures. Also, it's not possible
1628:  // to blit the non-MSAA resolve texture of the previous pass to MSAA
1631:  auto msaa_backdrop_contents = TextureContents::MakeRect(size_rect);
1632:  msaa_backdrop_contents->SetStencilEnabled(false);
1633:  msaa_backdrop_contents->SetLabel("MSAA backdrop");
1634:  msaa_backdrop_contents->SetSourceRect(size_rect);
1635:  msaa_backdrop_contents->SetTexture(input_texture);
1637:  Entity msaa_backdrop_entity;
1638:  msaa_backdrop_entity.SetContents(std::move(msaa_backdrop_contents));
1639:  msaa_backdrop_entity.SetBlendMode(BlendMode::kSource);
1640:  msaa_backdrop_entity.SetClipDepth(std::numeric_limits<uint32_t>::max());
1641:  if (!msaa_backdrop_entity.Render(renderer_, current_render_pass)) {
1642:    VALIDATION_LOG << "Failed to render MSAA backdrop entity.";
=== RT ===
376:RenderTarget RenderTargetAllocator::CreateOffscreenMSAA(
401:    color0_tex_desc.sample_count = SampleCount::kCount4;
492:      depth_stencil_texture_desc.sample_count = SampleCount::kCount4;
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_sparse_shaders\README.md
Bash List vello source dirs
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && ls vello_encoding/src vello/src vello_shaders/src/compile 2>/dev/null && echo "=== perm ===" && ls vello_shaders/shader/permutations && cat vello_shaders/shader/permutations

OUT
vello/src:
debug
debug.rs
lib.rs
recording.rs
render.rs
scene.rs
shaders.rs
util.rs
wgpu_engine.rs

vello_encoding/src:
binning.rs
clip.rs
config.rs
draw.rs
encoding.rs
estimate.rs
glyph.rs
glyph_cache.rs
image_cache.rs
lib.rs
mask.rs
math.rs
monoid.rs
path.rs
ramp_cache.rs
resolve.rs

vello_shaders/src/compile:
mod.rs
msl.rs
permutations.rs
preprocess.rs
=== perm ===
vello_shaders/shader/permutations
pathtag_scan
+ pathtag_scan_large
+ pathtag_scan_small: small
fine
+ fine_area
+ fine_msaa8: msaa msaa8
+ fine_msaa16: msaa msaa16
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\clip.rs
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_protocol.dart
Added 44 lines
Now let me examine the Vello pipeline in detail.

Read shaders.rs
Grep "pub fn intersect|fn intersect_impl" (in C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\clip.rs)
2 lines of output
Bash Read headers of all Vello WGSL stages
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main/vello_shaders/shader && for f in pathtag_reduce.wgsl pathtag_scan.wgsl flatten.wgsl draw_reduce.wgsl draw_leaf.wgsl clip_reduce.wgsl clip_leaf.wgsl binning.wgsl tile_alloc.wgsl path_count.wgsl path_tiling.wgsl coarse.wgsl fine.wgsl backdrop_dyn.wgsl bbox_clear.wgsl path_count_setup.wgsl; do echo "===== $f ====="; sed -n '1,22p' $f; done

OUT
===== pathtag_reduce.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

#import config
#import pathtag

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage, read_write> reduced: array<TagMonoid>;

const LG_WG_SIZE = 8u;
const WG_SIZE = 256u;

var<workgroup> sh_scratch: array<TagMonoid, WG_SIZE>;

@compute @workgroup_size(256)
fn main(
===== pathtag_scan.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

#import config
#import pathtag

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> reduced: array<TagMonoid>;

@group(0) @binding(3)
var<storage, read_write> tag_monoids: array<TagMonoid>;

const LG_WG_SIZE = 8u;
const WG_SIZE = 256u;

#ifdef small
===== flatten.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Flatten curves to lines

#import config
#import drawtag
#import pathtag
#import segment
#import cubic
#import bump

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> tag_monoids: array<TagMonoid>;

struct AtomicPathBbox {
===== draw_reduce.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

#import config
#import drawtag

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage, read_write> reduced: array<DrawMonoid>;

const WG_SIZE = 256u;

var<workgroup> sh_scratch: array<DrawMonoid, WG_SIZE>;

#import util

@compute @workgroup_size(256)
===== draw_leaf.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Finish prefix sum of drawtags, decode draw objects.

#import config
#import clip
#import drawtag
#import bbox
#import transform

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> reduced: array<DrawMonoid>;

@group(0) @binding(3)
var<storage> path_bbox: array<PathBbox>;
===== clip_reduce.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

#import bbox
#import clip

@group(0) @binding(0)
var<storage> clip_inp: array<ClipInp>;

@group(0) @binding(1)
var<storage> path_bboxes: array<PathBbox>;

@group(0) @binding(2)
var<storage, read_write> reduced: array<Bic>;

@group(0) @binding(3)
var<storage, read_write> clip_out: array<ClipEl>;

const WG_SIZE = 256u;
var<workgroup> sh_bic: array<Bic, WG_SIZE>;
var<workgroup> sh_parent: array<u32, WG_SIZE>;
var<workgroup> sh_path_ix: array<u32, WG_SIZE>;
===== clip_leaf.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

#import config
#import bbox
#import clip
#import drawtag

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> clip_inp: array<ClipInp>;

@group(0) @binding(2)
var<storage> path_bboxes: array<PathBbox>;

@group(0) @binding(3)
var<storage> reduced: array<Bic>;

@group(0) @binding(4)
var<storage> clip_els: array<ClipEl>;
===== binning.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// The binning stage

#import config
#import drawtag
#import bbox
#import bump

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> draw_monoids: array<DrawMonoid>;

@group(0) @binding(2)
var<storage> path_bbox_buf: array<PathBbox>;

@group(0) @binding(3)
var<storage> clip_bbox_buf: array<vec4<f32>>;

===== tile_alloc.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Tile allocation (and zeroing of tiles)

#import config
#import bump
#import drawtag
#import tile

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> draw_bboxes: array<vec4<f32>>;

@group(0) @binding(3)
var<storage, read_write> bump: BumpAllocators;

===== path_count.wgsl =====
// Copyright 2023 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Stage to compute counts of number of segments in each tile

#import bump
#import config
#import segment
#import tile

// TODO: this is cut'n'pasted from path_coarse.
struct AtomicTile {
    backdrop: atomic<i32>,
    segment_count_or_ix: atomic<u32>,
}

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage, read_write> bump: BumpAllocators;

===== path_tiling.wgsl =====
// Copyright 2023 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Write path segments

#import bump
#import config
#import segment
#import tile

@group(0) @binding(0)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(1)
var<storage> seg_counts: array<SegmentCount>;

@group(0) @binding(2)
var<storage> lines: array<LineSoup>;

@group(0) @binding(3)
var<storage> paths: array<Path>;

===== coarse.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// The coarse rasterization stage.

#import config
#import bump
#import drawtag
#import ptcl
#import tile

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> scene: array<u32>;

@group(0) @binding(2)
var<storage> draw_monoids: array<DrawMonoid>;

// TODO: dedup
struct BinHeader {
===== fine.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Fine rasterizer.
//
// To enable multisampled rendering, turn on both the msaa ifdef and one of msaa8
// or msaa16.

struct Tile {
    backdrop: i32,
    segments: u32,
}

#import segment
#import config

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage> segments: array<Segment>;

===== backdrop_dyn.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Prefix sum for dynamically allocated backdrops

#import bump
#import config
#import tile

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(2)
var<storage> paths: array<Path>;

@group(0) @binding(3)
var<storage, read_write> tiles: array<Tile>;

const WG_SIZE = 256u;
===== bbox_clear.wgsl =====
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

#import config
#import bbox

@group(0) @binding(0)
var<uniform> config: Config;

@group(0) @binding(1)
var<storage, read_write> path_bboxes: array<PathBbox>;

@compute @workgroup_size(256)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
) {
    let ix = global_id.x;
    if ix < config.n_path {
        path_bboxes[ix].x0 = 0x7fffffff;
        path_bboxes[ix].y0 = 0x7fffffff;
        path_bboxes[ix].x1 = -0x80000000;
        path_bboxes[ix].y1 = -0x80000000;
===== path_count_setup.wgsl =====
// Copyright 2023 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Set up dispatch size for path count stage.

#import bump

@group(0) @binding(0)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(1)
var<storage, read_write> indirect: IndirectCount;

// Partition size for path count stage
const WG_SIZE = 256u;

@compute @workgroup_size(1)
fn main() {
    if atomicLoad(&bump.failed) != 0u {
        indirect.count_x = 0u;
    } else {
        let lines = atomicLoad(&bump.lines);
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\clip.rs (lines 301-530)
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\render\webgl\mod.rs (lines 1471-1600)
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\paint.rs
Bash Vello indirect dispatch and bump allocator
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -n "dispatch_indirect\|DispatchIndirect\|dispatch(" vello/src/render.rs | head -40; echo "=== BUMP ==="; cat vello_shaders/shader/shared/bump.wgsl

OUT
250:        recording.dispatch(
263:            recording.dispatch(
272:            recording.dispatch(
290:        recording.dispatch(
304:        recording.dispatch(
317:        recording.dispatch(
333:        recording.dispatch(
346:        recording.dispatch(
369:            recording.dispatch(
380:            recording.dispatch(
405:        recording.dispatch(
425:        recording.dispatch(
443:        recording.dispatch(
452:        recording.dispatch_indirect(
465:        recording.dispatch(
470:        recording.dispatch(
485:        recording.dispatch(
490:        recording.dispatch_indirect(
565:                recording.dispatch(
601:                recording.dispatch(
=== BUMP ===
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Bitflags for each stage that can fail allocation.
const STAGE_BINNING: u32 = 0x1u;
const STAGE_TILE_ALLOC: u32 = 0x2u;
const STAGE_FLATTEN: u32 = 0x4u;
const STAGE_PATH_COUNT: u32 = 0x8u;
const STAGE_COARSE: u32 = 0x10u;

// This must be kept in sync with the struct in config.rs in the encoding crate.
struct BumpAllocators {
    // Bitmask of stages that have failed allocation.
    failed: atomic<u32>,
    binning: atomic<u32>,
    ptcl: atomic<u32>,
    tile: atomic<u32>,
    seg_counts: atomic<u32>,
    segments: atomic<u32>,
    blend: atomic<u32>,
    lines: atomic<u32>,
}

struct IndirectCount {
    count_x: u32,
    count_y: u32,
    count_z: u32,
}
Bash Vello GPU requirements in lib.rs
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -n "limits\|Limits\|max_storage\|downlevel\|Features\|features" vello/src/lib.rs | head -40; echo "=== AaConfig ==="; grep -n "AaConfig\|Msaa16\|Msaa8\|Area\|antialiasing" vello/src/lib.rs | head -40

OUT
258:    /// There is no available device with the features required by Vello.
=== AaConfig ===
38://!       antialiasing_support: vello::AaSupport::all(),
71://!          antialiasing_method: AaConfig::Msaa16,
169:/// Can be configured for a render operation by setting [`RenderParams::antialiasing_method`].
175:pub enum AaConfig {
176:    /// Area anti-aliasing, where the alpha value for a pixel is computed from integrating
184:    Area,
188:    Msaa8,
192:    Msaa16,
198:/// [`RendererOptions::antialiasing_support`].
200:/// This can be created from a set of `AaConfig` using [`Iterator::collect`],
204:    /// Support [`AaConfig::Area`].
206:    /// Support [`AaConfig::Msaa8`].
208:    /// Support [`AaConfig::Msaa16`].
224:    /// Support only [`AaConfig::Area`].
236:impl FromIterator<AaConfig> for AaSupport {
237:    fn from_iter<T: IntoIterator<Item = AaConfig>>(iter: T) -> Self {
245:                AaConfig::Area => result.area = true,
246:                AaConfig::Msaa8 => result.msaa8 = true,
247:                AaConfig::Msaa16 => result.msaa16 = true,
368:    pub antialiasing_method: AaConfig,
387:    pub antialiasing_support: AaSupport,
412:            antialiasing_support: AaSupport::all(),
Bash Find GL instancing and texture format details
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/render" && grep -n "draw_arrays_instanced\|TRIANGLE_STRIP\|vertex_attrib_divisor\|RGBA32UI\|RGBA_INTEGER\|UNSIGNED_INT\|tex_image_2d\|R32UI" webgl/mod.rs | head -50; echo ---; grep -n "draw(0..4\|draw(\|TriangleStrip\|step_mode\|VertexStepMode\|instance_count\|0..4" wgpu/mod.rs | head -40

OUT
1086:    /// RGBA32UI texture storing filter parameters.
1430:        gl.tex_image_2d_with_i32_and_i32_and_i32_and_format_and_type_and_opt_array_buffer_view(
1433:            WebGl2RenderingContext::RGBA32UI as i32,
1437:            WebGl2RenderingContext::RGBA_INTEGER,
1438:            WebGl2RenderingContext::UNSIGNED_INT,
1667:        gl.tex_image_2d_with_i32_and_i32_and_i32_and_format_and_type_and_opt_u8_array(
2238:            WebGl2RenderingContext::UNSIGNED_INT,
2242:        gl.vertex_attrib_divisor(loc, 1);
2305:/// Create a 1x1 RGBA32UI placeholder texture.
2330:    gl.tex_image_2d_with_i32_and_i32_and_i32_and_format_and_type_and_opt_u8_array(
2476:    gl.tex_image_2d_with_i32_and_i32_and_i32_and_format_and_type_and_opt_array_buffer_view(
2572:            WebGl2RenderingContext::UNSIGNED_INT,
2577:        gl.vertex_attrib_divisor(location, 1);
2643:            .draw_arrays_instanced(WebGl2RenderingContext::TRIANGLE_STRIP, 0, 4, count);
2664:                WebGl2RenderingContext::UNSIGNED_INT,
2824:                self.gl.draw_arrays_instanced(
2825:                    WebGl2RenderingContext::TRIANGLE_STRIP,
2940:            .draw_arrays_instanced(WebGl2RenderingContext::TRIANGLE_STRIP, 0, 4, instance_count);
2976:            .draw_arrays_instanced(WebGl2RenderingContext::TRIANGLE_STRIP, 0, 4, instance_count);
3011:            self.gl.draw_arrays_instanced(
3012:                WebGl2RenderingContext::TRIANGLE_STRIP,
3079:        self.gl.draw_arrays_instanced(
3080:            WebGl2RenderingContext::TRIANGLE_STRIP,
3409:// Upload the data to the currently bound texture assuming a RGBA32UI format.
3424:    // The `tex_image_2d` method is synchronous in the sense that once it returns, it is guaranteed
3440:    gl.tex_image_2d_with_i32_and_i32_and_i32_and_format_and_type_and_opt_array_buffer_view(
3443:        WebGl2RenderingContext::RGBA32UI as i32,
3447:        WebGl2RenderingContext::RGBA_INTEGER,
3448:        WebGl2RenderingContext::UNSIGNED_INT,
---
680:        render_pass.draw(0..4, 0..1);
1201:            step_mode: wgpu::VertexStepMode::Instance,
1227:                        topology: wgpu::PrimitiveTopology::TriangleStrip,
1274:                    step_mode: wgpu::VertexStepMode::Instance,
1295:                topology: wgpu::PrimitiveTopology::TriangleStrip,
1332:                topology: wgpu::PrimitiveTopology::TriangleStrip,
1408:                    step_mode: wgpu::VertexStepMode::Instance,
1434:                topology: wgpu::PrimitiveTopology::TriangleStrip,
1515:            step_mode: wgpu::VertexStepMode::Instance,
1529:            step_mode: wgpu::VertexStepMode::Instance,
1562:                        topology: wgpu::PrimitiveTopology::TriangleStrip,
2861:            render_pass.draw(0..4, 0..opaque_count);
2875:                render_pass.draw(0..4, alpha_start..alpha_start + alpha_count);
2892:                    render_pass.draw(0..4, alpha_start + start..alpha_start + end);
2946:        let instance_count = u32::try_from(self.scratch_buffers.blend_instances.len()).unwrap();
2975:            render_pass.draw(0..4, 0..instance_count);
3103:        render_pass.draw(
3104:            0..4,
3187:    render_pass.draw(0..4, 0..u32::try_from(instances.len()).unwrap());
3201:    let instance_count = u32::try_from(instances.len()).unwrap();
3229:    render_pass.draw(0..4, 0..instance_count);
Read lib.rs (lines 161-240)
Bash Read Vello render pipeline dispatch order
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && sed -n '230,510p' vello/src/render.rs

OUT
        let config_buf = ResourceProxy::Buffer(
            recording.upload_uniform("vello.config", bytemuck::bytes_of(&cpu_config.gpu)),
        );
        let info_bin_data_buf = ResourceProxy::new_buf(
            buffer_sizes.bin_data.size_in_bytes() as u64,
            "vello.info_bin_data_buf",
        );
        let tile_buf =
            ResourceProxy::new_buf(buffer_sizes.tiles.size_in_bytes().into(), "vello.tile_buf");
        let segments_buf = ResourceProxy::new_buf(
            buffer_sizes.segments.size_in_bytes().into(),
            "vello.segments_buf",
        );
        let ptcl_buf =
            ResourceProxy::new_buf(buffer_sizes.ptcl.size_in_bytes().into(), "vello.ptcl_buf");
        let reduced_buf = ResourceProxy::new_buf(
            buffer_sizes.path_reduced.size_in_bytes().into(),
            "vello.reduced_buf",
        );
        // TODO: really only need pathtag_wgs - 1
        recording.dispatch(
            shaders.pathtag_reduce,
            wg_counts.path_reduce,
            [config_buf, scene_buf, reduced_buf],
        );
        let mut pathtag_parent = reduced_buf;
        let mut large_pathtag_bufs = None;
        let use_large_path_scan = wg_counts.use_large_path_scan && !shaders.pathtag_is_cpu;
        if use_large_path_scan {
            let reduced2_buf = ResourceProxy::new_buf(
                buffer_sizes.path_reduced2.size_in_bytes().into(),
                "vello.reduced2_buf",
            );
            recording.dispatch(
                shaders.pathtag_reduce2,
                wg_counts.path_reduce2,
                [reduced_buf, reduced2_buf],
            );
            let reduced_scan_buf = ResourceProxy::new_buf(
                buffer_sizes.path_reduced_scan.size_in_bytes().into(),
                "reduced_scan_buf",
            );
            recording.dispatch(
                shaders.pathtag_scan1,
                wg_counts.path_scan1,
                [reduced_buf, reduced2_buf, reduced_scan_buf],
            );
            pathtag_parent = reduced_scan_buf;
            large_pathtag_bufs = Some((reduced2_buf, reduced_scan_buf));
        }

        let tagmonoid_buf = ResourceProxy::new_buf(
            buffer_sizes.path_monoids.size_in_bytes().into(),
            "vello.tagmonoid_buf",
        );
        let pathtag_scan = if use_large_path_scan {
            shaders.pathtag_scan_large
        } else {
            shaders.pathtag_scan
        };
        recording.dispatch(
            pathtag_scan,
            wg_counts.path_scan,
            [config_buf, scene_buf, pathtag_parent, tagmonoid_buf],
        );
        recording.free_resource(reduced_buf);
        if let Some((reduced2, reduced_scan)) = large_pathtag_bufs {
            recording.free_resource(reduced2);
            recording.free_resource(reduced_scan);
        }
        let path_bbox_buf = ResourceProxy::new_buf(
            buffer_sizes.path_bboxes.size_in_bytes().into(),
            "vello.path_bbox_buf",
        );
        recording.dispatch(
            shaders.bbox_clear,
            wg_counts.bbox_clear,
            [config_buf, path_bbox_buf],
        );
        let bump_buf = BufferProxy::new(
            buffer_sizes.bump_alloc.size_in_bytes().into(),
            "vello.bump_buf",
        );
        recording.clear_all(bump_buf);
        let bump_buf = ResourceProxy::Buffer(bump_buf);
        let lines_buf =
            ResourceProxy::new_buf(buffer_sizes.lines.size_in_bytes().into(), "vello.lines_buf");
        recording.dispatch(
            shaders.flatten,
            wg_counts.flatten,
            [
                config_buf,
                scene_buf,
                tagmonoid_buf,
                path_bbox_buf,
                bump_buf,
                lines_buf,
            ],
        );
        let draw_reduced_buf = ResourceProxy::new_buf(
            buffer_sizes.draw_reduced.size_in_bytes().into(),
            "vello.draw_reduced_buf",
        );
        recording.dispatch(
            shaders.draw_reduce,
            wg_counts.draw_reduce,
            [config_buf, scene_buf, draw_reduced_buf],
        );
        let draw_monoid_buf = ResourceProxy::new_buf(
            buffer_sizes.draw_monoids.size_in_bytes().into(),
            "vello.draw_monoid_buf",
        );
        let clip_inp_buf = ResourceProxy::new_buf(
            buffer_sizes.clip_inps.size_in_bytes().into(),
            "vello.clip_inp_buf",
        );
        recording.dispatch(
            shaders.draw_leaf,
            wg_counts.draw_leaf,
            [
                config_buf,
                scene_buf,
                draw_reduced_buf,
                path_bbox_buf,
                draw_monoid_buf,
                info_bin_data_buf,
                clip_inp_buf,
            ],
        );
        recording.free_resource(draw_reduced_buf);
        let clip_el_buf = ResourceProxy::new_buf(
            buffer_sizes.clip_els.size_in_bytes().into(),
            "vello.clip_el_buf",
        );
        let clip_bic_buf = ResourceProxy::new_buf(
            buffer_sizes.clip_bics.size_in_bytes().into(),
            "vello.clip_bic_buf",
        );
        if wg_counts.clip_reduce.0 > 0 {
            recording.dispatch(
                shaders.clip_reduce,
                wg_counts.clip_reduce,
                [clip_inp_buf, path_bbox_buf, clip_bic_buf, clip_el_buf],
            );
        }
        let clip_bbox_buf = ResourceProxy::new_buf(
            buffer_sizes.clip_bboxes.size_in_bytes().into(),
            "vello.clip_bbox_buf",
        );
        if wg_counts.clip_leaf.0 > 0 {
            recording.dispatch(
                shaders.clip_leaf,
                wg_counts.clip_leaf,
                [
                    config_buf,
                    clip_inp_buf,
                    path_bbox_buf,
                    clip_bic_buf,
                    clip_el_buf,
                    draw_monoid_buf,
                    clip_bbox_buf,
                ],
            );
        }
        recording.free_resource(clip_inp_buf);
        recording.free_resource(clip_bic_buf);
        recording.free_resource(clip_el_buf);
        let draw_bbox_buf = ResourceProxy::new_buf(
            buffer_sizes.draw_bboxes.size_in_bytes().into(),
            "vello.draw_bbox_buf",
        );
        let bin_header_buf = ResourceProxy::new_buf(
            buffer_sizes.bin_headers.size_in_bytes().into(),
            "vello.bin_header_buf",
        );
        recording.dispatch(
            shaders.binning,
            wg_counts.binning,
            [
                config_buf,
                draw_monoid_buf,
                path_bbox_buf,
                clip_bbox_buf,
                draw_bbox_buf,
                bump_buf,
                info_bin_data_buf,
                bin_header_buf,
            ],
        );
        recording.free_resource(draw_monoid_buf);
        recording.free_resource(clip_bbox_buf);
        // Note: this only needs to be rounded up because of the workaround to store the tile_offset
        // in storage rather than workgroup memory.
        let path_buf =
            ResourceProxy::new_buf(buffer_sizes.paths.size_in_bytes().into(), "vello.path_buf");
        recording.dispatch(
            shaders.tile_alloc,
            wg_counts.tile_alloc,
            [
                config_buf,
                scene_buf,
                draw_bbox_buf,
                bump_buf,
                path_buf,
                tile_buf,
            ],
        );
        recording.free_resource(draw_bbox_buf);
        recording.free_resource(tagmonoid_buf);
        let indirect_count_buf = BufferProxy::new(
            buffer_sizes.indirect_count.size_in_bytes().into(),
            "vello.indirect_count",
        );
        recording.dispatch(
            shaders.path_count_setup,
            wg_counts.path_count_setup,
            [bump_buf, indirect_count_buf.into()],
        );
        let seg_counts_buf = ResourceProxy::new_buf(
            buffer_sizes.seg_counts.size_in_bytes().into(),
            "vello.seg_counts_buf",
        );
        recording.dispatch_indirect(
            shaders.path_count,
            indirect_count_buf,
            0,
            [
                config_buf,
                bump_buf,
                lines_buf,
                path_buf,
                tile_buf,
                seg_counts_buf,
            ],
        );
        recording.dispatch(
            shaders.backdrop,
            wg_counts.backdrop,
            [config_buf, bump_buf, path_buf, tile_buf],
        );
        recording.dispatch(
            shaders.coarse,
            wg_counts.coarse,
            [
                config_buf,
                scene_buf,
                draw_monoid_buf,
                bin_header_buf,
                info_bin_data_buf,
                path_buf,
                tile_buf,
                bump_buf,
                ptcl_buf,
            ],
        );
        recording.dispatch(
            shaders.path_tiling_setup,
            wg_counts.path_tiling_setup,
            [bump_buf, indirect_count_buf.into(), ptcl_buf],
        );
        recording.dispatch_indirect(
            shaders.path_tiling,
            indirect_count_buf,
            0,
            [
                bump_buf,
                seg_counts_buf,
                lines_buf,
                path_buf,
                tile_buf,
                segments_buf,
            ],
        );
        recording.free_buffer(indirect_count_buf);
        recording.free_resource(seg_counts_buf);
        recording.free_resource(scene_buf);
        recording.free_resource(draw_monoid_buf);
        recording.free_resource(bin_header_buf);
        recording.free_resource(path_buf);
        let out_image = ImageProxy::new(params.width, params.height, ImageFormat::Rgba8);
        let blend_spill_buf = BufferProxy::new(
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\rect.rs
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\rect.rs
Now the swapchain in wayland_shm.dart. Rewriting the handle interface and the surface.

Bash Search sparse_strips references
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -rn "sparse_strips\|sparse strips\|Sparse Strips\|vello_hybrid\|vello_cpu" README.md CHANGELOG.md doc/ARCHITECTURE.md Cargo.toml sparse_strips/README.md 2>/dev/null | head -40

OUT
Cargo.toml:16:    "sparse_strips/vello_bench",
Cargo.toml:17:    "sparse_strips/vello_common",
Cargo.toml:18:    "sparse_strips/vello_cpu",
Cargo.toml:19:    "sparse_strips/vello_cpu/examples/wasm_cpu",
Cargo.toml:20:    "sparse_strips/vello_cpu/examples/winit",
Cargo.toml:21:    "sparse_strips/vello_hybrid",
Cargo.toml:22:    "sparse_strips/vello_sparse_shaders",
Cargo.toml:23:    "sparse_strips/vello_hybrid/examples/native_webgl",
Cargo.toml:24:    "sparse_strips/vello_example_scenes",
Cargo.toml:25:    "sparse_strips/vello_hybrid/examples/wgpu_webgl",
Cargo.toml:26:    "sparse_strips/vello_hybrid/examples/winit",
Cargo.toml:27:    "sparse_strips/vello_toy",
Cargo.toml:28:    "sparse_strips/vello_dev_macros",
Cargo.toml:29:    "sparse_strips/vello_sparse_tests",
Cargo.toml:131:vello_common = { version = "0.2.0", path = "sparse_strips/vello_common", default-features = false }
Cargo.toml:132:vello_cpu = { version = "0.2.0", path = "sparse_strips/vello_cpu" }
Cargo.toml:133:vello_hybrid = { version = "0.2.0", path = "sparse_strips/vello_hybrid" }
Cargo.toml:134:vello_sparse_shaders = { version = "0.2.0", path = "sparse_strips/vello_sparse_shaders" }
Cargo.toml:136:vello_example_scenes = { path = "sparse_strips/vello_example_scenes" }
Cargo.toml:137:vello_dev_macros = { path = "sparse_strips/vello_dev_macros" }
sparse_strips/README.md:1:# Vello Sparse Strips
sparse_strips/README.md:22:- **`vello_cpu`** – Implements a CPU-based renderer optimized for multithreading and SIMD.
sparse_strips/README.md:23:- **`vello_hybrid`** – A hybrid CPU/GPU renderer, balancing workload between CPU and GPU.
sparse_strips/README.md:24:- **`vello_sparse_shaders`** – Provide compilation of wgsl to glsl to support the WebGL `vello_hybrid` backend.
sparse_strips/README.md:39:./sparse_strips/web/check_wasm_sizes.sh
Bash Vello buffer sizes config
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -n "BufferSize\|pub struct BufferSizes\|const\|BUFFER_SIZE\|size_in_bytes\|WorkgroupSize\|pub struct WorkgroupCounts" vello_encoding/src/config.rs | head -60

OUT
12:const TILE_WIDTH: u32 = 16;
13:const TILE_HEIGHT: u32 = 16;
16:pub(crate) const PATH_REDUCE_WG: u32 = 256;
17:const PATH_BBOX_WG: u32 = 256;
18:const FLATTEN_WG: u32 = 256;
19:const CLIP_REDUCE_WG: u32 = 256;
42:    pub binning: BufferSize<u32>,
43:    pub ptcl: BufferSize<u32>,
44:    pub tile: BufferSize<Tile>,
45:    pub seg_counts: BufferSize<SegmentCount>,
46:    pub segments: BufferSize<PathSegment>,
47:    pub lines: BufferSize<LineSoup>,
52:        let binning = BufferSize::new(self.binning);
53:        let ptcl = BufferSize::new(self.ptcl);
54:        let tile = BufferSize::new(self.tile);
55:        let seg_counts = BufferSize::new(self.seg_counts);
56:        let segments = BufferSize::new(self.segments);
57:        let lines = BufferSize::new(self.lines);
59:            total: binning.size_in_bytes()
60:                + ptcl.size_in_bytes()
61:                + tile.size_in_bytes()
62:                + seg_counts.size_in_bytes()
63:                + segments.size_in_bytes()
64:                + lines.size_in_bytes(),
91:            self.binning.size_in_bytes(),
93:            self.ptcl.size_in_bytes(),
95:            self.tile.size_in_bytes(),
97:            self.seg_counts.size_in_bytes(),
99:            self.segments.size_in_bytes(),
101:            self.lines.size_in_bytes()
164:    pub buffer_sizes: BufferSizes,
176:        let buffer_sizes = BufferSizes::new(layout, &workgroup_counts);
200:pub type WorkgroupSize = (u32, u32, u32);
204:pub struct WorkgroupCounts {
206:    pub path_reduce: WorkgroupSize,
207:    pub path_reduce2: WorkgroupSize,
208:    pub path_scan1: WorkgroupSize,
209:    pub path_scan: WorkgroupSize,
210:    pub bbox_clear: WorkgroupSize,
211:    pub flatten: WorkgroupSize,
212:    pub draw_reduce: WorkgroupSize,
213:    pub draw_leaf: WorkgroupSize,
214:    pub clip_reduce: WorkgroupSize,
215:    pub clip_leaf: WorkgroupSize,
216:    pub binning: WorkgroupSize,
217:    pub tile_alloc: WorkgroupSize,
218:    pub path_count_setup: WorkgroupSize,
220:    pub backdrop: WorkgroupSize,
221:    pub coarse: WorkgroupSize,
222:    pub path_tiling_setup: WorkgroupSize,
224:    pub fine: WorkgroupSize,
278:pub struct BufferSize<T: Sized> {
283:impl<T: Sized> BufferSize<T> {
285:    pub const fn new(len: u32) -> Self {
290:            // Note: not using `Ord::max` here because it doesn't support const eval yet (except
298:    pub const fn from_size_in_bytes(size: u32) -> Self {
304:    pub const fn len(self) -> u32 {
309:    pub const fn size_in_bytes(self) -> u32 {
314:    pub const fn aligned_in_bytes(self, alignment: u32) -> u32 {
315:        align_up(self.size_in_bytes(), alignment)
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_shm.dart
Added 5 lines
Read README.md
Bash Vello encoding lib.rs overview
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && sed -n '1,60p' vello_encoding/src/lib.rs

OUT
// Copyright 2023 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT

//! Raw scene encoding.

// LINEBENDER LINT SET - lib.rs - v2
// See https://linebender.org/wiki/canonical-lints/
// These lints aren't included in Cargo.toml because they
// shouldn't apply to examples and tests
#![warn(unused_crate_dependencies)]
#![warn(clippy::print_stdout, clippy::print_stderr)]
// Targeting e.g. 32-bit means structs containing usize can give false positives for 64-bit.
#![cfg_attr(target_pointer_width = "64", warn(clippy::trivially_copy_pass_by_ref))]
// END LINEBENDER LINT SET
#![cfg_attr(docsrs, feature(doc_cfg))]
// The following lints are part of the Linebender standard set,
// but resolving them has been deferred for now.
// Feel free to send a PR that solves one or more of these.
// Need to allow instead of expect until Rust 1.83 https://github.com/rust-lang/rust/pull/130025
#![allow(missing_docs, reason = "We have many as-yet undocumented items.")]
#![expect(
    missing_debug_implementations,
    clippy::cast_possible_truncation,
    clippy::missing_assert_message,
    reason = "Deferred"
)]
#![allow(
    unnameable_types,
    reason = "Deferred, only apply in some feature sets so not expect"
)]

mod binning;
mod clip;
mod config;
mod draw;
mod encoding;
#[cfg(feature = "bump_estimate")]
mod estimate;
mod glyph;
mod glyph_cache;
mod image_cache;
mod mask;
pub mod math;
mod monoid;
mod path;
mod ramp_cache;
mod resolve;

pub use binning::BinHeader;
pub use clip::{Clip, ClipBbox, ClipBic, ClipElement};
pub use config::{
    BufferSize, BufferSizes, BumpAllocatorMemory, BumpAllocators, ConfigUniform, IndirectCount,
    RenderConfig, WorkgroupCounts, WorkgroupSize,
};
pub use draw::{
    DRAW_INFO_FLAGS_FILL_RULE_BIT, DrawBbox, DrawBeginClip, DrawBlurRoundedRect, DrawColor,
    DrawImage, DrawLinearGradient, DrawMonoid, DrawRadialGradient, DrawSweepGradient, DrawTag,
};
pub use encoding::{Encoding, Resources, StreamOffsets};
pub use glyph::{FontEmbolden, Glyph, GlyphRun};
Bash Read READMEs
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips" && sed -n '1,80p' vello_cpu/README.md; echo "=== COMMON README ==="; sed -n '1,60p' vello_common/README.md; echo "=== toy ==="; sed -n '1,60p' vello_toy/README.md

OUT
<div align="center">

# Vello CPU

**CPU-based renderer**

[![Latest published version.](https://img.shields.io/crates/v/vello_cpu.svg)](https://crates.io/crates/vello_cpu)
[![Documentation build status.](https://img.shields.io/docsrs/vello_cpu.svg)](https://docs.rs/vello_cpu)
[![Apache 2.0 or MIT license.](https://img.shields.io/badge/license-Apache--2.0_OR_MIT-blue.svg)](#license)
\
[![Linebender Zulip chat.](https://img.shields.io/badge/Linebender-%23vello-blue?logo=Zulip)](https://xi.zulipchat.com/#narrow/channel/197075-vello)
[![GitHub Actions CI status.](https://img.shields.io/github/actions/workflow/status/linebender/vello/ci.yml?logo=github&label=CI)](https://github.com/linebender/vello/actions)
[![Dependency staleness status.](https://deps.rs/crate/vello_cpu/latest/status.svg)](https://deps.rs/crate/vello_cpu)

</div>

<!-- We use cargo-rdme to update the README with the contents of lib.rs.
To edit the following section, update it in lib.rs, then run:
cargo rdme --workspace-project=vello_cpu
Full documentation at https://github.com/orium/cargo-rdme -->

<!-- Intra-doc links used in lib.rs should be evaluated here.
See https://linebender.org/blog/doc-include/ for related discussion. -->

[`RenderContext`]: https://docs.rs/vello_cpu/latest/vello_cpu/struct.RenderContext.html
[RenderContext::set_paint]: https://docs.rs/vello_cpu/latest/vello_cpu/struct.RenderContext.html#method.set_paint
[RenderContext::fill_path]: https://docs.rs/vello_cpu/latest/vello_cpu/struct.RenderContext.html#method.fill_path
[RenderContext::stroke_path]: https://docs.rs/vello_cpu/latest/vello_cpu/struct.RenderContext.html#method.stroke_path
[RenderContext::glyph_run]: https://docs.rs/vello_cpu/latest/vello_cpu/struct.RenderContext.html#method.glyph_run
[RenderMode::OptimizeSpeed]: https://docs.rs/vello_cpu/latest/vello_cpu/enum.RenderMode.html#variant.OptimizeSpeed
[RenderMode::OptimizeQuality]: https://docs.rs/vello_cpu/latest/vello_cpu/enum.RenderMode.html#variant.OptimizeQuality
[`RenderContext::render`]: https://docs.rs/vello_cpu/latest/vello_cpu/struct.RenderContext.html#method.render
[`Pixmap`]: https://docs.rs/vello_cpu/latest/vello_cpu/struct.Pixmap.html
[`Resources`]: https://docs.rs/vello_cpu/latest/vello_cpu/struct.Resources.html

<!-- cargo-rdme start -->

Vello CPU is a 2D graphics rendering engine written in Rust, for devices with no or underpowered GPUs.

We also develop [Vello](https://crates.io/crates/vello), which makes use of the GPU for 2D rendering and has higher performance than Vello CPU.
Vello CPU is being developed as part of work to address shortcomings in Vello.

## Usage

To use Vello CPU, you need to:

- Create a [`RenderContext`][], a 2D drawing context for a fixed-size scene area.
- For each object in your scene:
  - Set how the object will be painted, using [`set_paint`][RenderContext::set_paint].
  - Set the shape to be drawn for that object, using methods like [`fill_path`][RenderContext::fill_path],
    [`stroke_path`][RenderContext::stroke_path], or [`glyph_run`][RenderContext::glyph_run].
- Render it to an image using [`RenderContext::render`][].

```rust
use vello_cpu::{RenderContext, Resources, Pixmap};
use vello_cpu::{color::{palette::css, PremulRgba8}, kurbo::Rect};
let width = 10;
let height = 5;
let mut context = RenderContext::new(width, height);
let mut resources = Resources::new();
context.set_paint(css::MAGENTA);
context.fill_rect(&Rect::from_points((3., 1.), (7., 4.)));

let mut target = Pixmap::new(width, height);
// While calling `flush` is only strictly necessary if you are rendering using
// multiple threads, it is recommended to always do this.
context.flush();
context.render(&mut target, &mut resources);

let expected_render = b"\
    0000000000\
    0001111000\
    0001111000\
    0001111000\
    0000000000";
let magenta = css::MAGENTA.premultiply().to_rgba8();
let transparent = PremulRgba8 {r: 0, g: 0, b: 0, a: 0};
let mut result = Vec::new();
for pixel in target.data() {
    if *pixel == magenta {
=== COMMON README ===
<div align="center">

# Vello Common

**Shared data structures**

[![Latest published version.](https://img.shields.io/crates/v/vello_common.svg)](https://crates.io/crates/vello_common)
[![Documentation build status.](https://img.shields.io/docsrs/vello_common.svg)](https://docs.rs/vello_common)
[![Apache 2.0 or MIT license.](https://img.shields.io/badge/license-Apache--2.0_OR_MIT-blue.svg)](#license)
\
[![Linebender Zulip chat.](https://img.shields.io/badge/Linebender-%23vello-blue?logo=Zulip)](https://xi.zulipchat.com/#narrow/channel/197075-vello)
[![GitHub Actions CI status.](https://img.shields.io/github/actions/workflow/status/linebender/vello/ci.yml?logo=github&label=CI)](https://github.com/linebender/vello/actions)
[![Dependency staleness status.](https://deps.rs/crate/vello_common/latest/status.svg)](https://deps.rs/crate/vello_common)

</div>

<!-- We use cargo-rdme to update the README with the contents of lib.rs.
To edit the following section, update it in lib.rs, then run:
cargo rdme --workspace-project=vello_common
Full documentation at https://github.com/orium/cargo-rdme -->

<!-- Intra-doc links used in lib.rs should be evaluated here.
See https://linebender.org/blog/doc-include/ for related discussion. -->

[libm]: https://crates.io/crates/libm
[crate::pixmap::Pixmap]: https://docs.rs/vello_common/latest/vello_common/pixmap/struct.Pixmap.html
<!-- cargo-rdme start -->

This crate includes common geometry representations, tiling logic, and other fundamental components used by both [Vello CPU][vello_cpu] and Vello Hybrid.

## Usage

This crate should not be used on its own, and you should instead use one of the renderers which use it.
At the moment, only [Vello CPU][vello_cpu] is published, and you probably want to use that.

We also develop [Vello](https://crates.io/crates/vello), which makes use of the GPU for 2D rendering and has higher performance than Vello CPU.
Vello CPU is being developed as part of work to address shortcomings in Vello.
Vello does not use this crate.

## Features

- `std` (enabled by default): Get floating point functions from the standard library
  (likely using your target's libc).
- `libm`: Use floating point implementations from [libm][].
- `png` (enabled by default): Allow loading [`Pixmap`][crate::pixmap::Pixmap]s from PNG images.
  Also required for rendering glyphs with an embedded PNG.
  Implies `std`.

At least one of `std` and `libm` is required; `std` overrides `libm`.

## Contents

- Shared data structures for paths, tiles, and strips
- Geometry processing utilities
- Common logic for rendering stages

This crate acts as a foundation for `vello_cpu` and `vello_hybrid`, providing essential components to minimize duplication.

[vello_cpu]: https://crates.io/crates/vello_cpu

=== toy ===
# Vello Toy

Vello Toy is a small internal crate that contains a number of utility binaries useful for development.

## debug.rs
When running this binary, you can provide an SVG path that you want to render and inspect the results of different stages of the rendering pipeline, in the form of an SVG.

For example, if you run:

`cargo run --bin debug -- --path "M 5 5 L 40 23 L 7 44 Z"  --stages line_segments,tile_areas`

A new SVG file will be generated that allows you to easily visualize the generated flattened lines and tiles.

## svg.rs
This binary allows you to render SVG files to PNG. Note that support is very primitive, and only very basic filling/stroking as well as clip paths are currently supported. In addition to that, the binary also allows you to define a target time during which it should be running.

For example, if you run:

`cargo run --bin svg --release  -- --path examples/assets/Ghostscript_Tiger.svg --scale 5 --runtime 2000`

The binary will run for two seconds and render the ghostscript tiger in a loop for 2 seconds, until it finally saves the result as a PNG file and prints the average runtime per iteration.
Bash Encoding struct and flatten stroke handling
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -n "pub struct Encoding" -A 40 vello_encoding/src/encoding.rs | head -50; echo "=== FLATTEN STROKE ==="; grep -n "stroke\|Euler\|espc\|offset_curve\|flatten_arc\|flatten_euler\|ESPC" vello_shaders/shader/flatten.wgsl | head -40

OUT
26:pub struct Encoding {
27-    /// The path tag stream.
28-    pub path_tags: Vec<PathTag>,
29-    /// The path data stream.
30-    /// Stores all coordinates on paths.
31-    /// Stored as `u32` as all comparisons are performed bitwise.
32-    pub path_data: Vec<u32>,
33-    /// The draw tag stream.
34-    pub draw_tags: Vec<DrawTag>,
35-    /// The draw data stream.
36-    pub draw_data: Vec<u32>,
37-    /// The transform stream.
38-    pub transforms: Vec<Transform>,
39-    /// The style stream
40-    pub styles: Vec<Style>,
41-    /// Late bound resource data.
42-    pub resources: Resources,
43-    /// Number of encoded paths.
44-    pub n_paths: u32,
45-    /// Number of encoded path segments.
46-    pub n_path_segments: u32,
47-    /// Number of encoded clips/layers.
48-    pub n_clips: u32,
49-    /// Number of unclosed clips/layers.
50-    pub n_open_clips: u32,
51-    /// Flags that capture the current state of the encoding.
52-    pub flags: u32,
53-}
54-
55-impl Encoding {
56-    /// Forces encoding of the next transform even if it matches
57-    /// the current transform in the stream.
58-    pub const FORCE_NEXT_TRANSFORM: u32 = 1;
59-
60-    /// Forces encoding of the next style even if it matches
61-    /// the current style in the stream.
62-    pub const FORCE_NEXT_STYLE: u32 = 2;
63-
64-    /// Creates a new encoding.
65-    pub fn new() -> Self {
66-        Self::default()
=== FLATTEN STROKE ===
56:// Functions for Euler spirals
65:struct EulerParams {
73:struct EulerSeg {
76:    params: EulerParams,
86:// Robust ESPC computation: below this value, treat curve as circular arc
88:// Robust ESPC: below this value, evaluate ES rather than parallel curve
110:    // Estimate error of geometric Hermite interpolation to Euler spiral.
135:fn es_params_from_angles(th0: f32, th1: f32) -> EulerParams {
157:    return EulerParams(th0, k0, k1, ch);
160:fn es_params_eval_th(params: EulerParams, t: f32) -> f32 {
164:// Integrate Euler spiral.
197:fn es_params_eval(params: EulerParams, t: f32) -> vec2f {
210:fn es_params_eval_with_offset(params: EulerParams, t: f32, offset: f32) -> vec2f {
216:fn es_seg_from_params(p0: vec2f, p1: vec2f, params: EulerParams) -> EulerSeg {
217:    return EulerSeg(p0, p1, params);
221:fn es_seg_eval_with_offset(es: EulerSeg, t: f32, normalized_offset: f32) -> vec2f {
250:fn espc_int_approx(x: f32) -> f32 {
264:fn espc_int_inv_approx(x: f32) -> f32 {
321:const ESPC_ROBUST_NORMAL = 0;
322:const ESPC_ROBUST_LOW_K1 = 1;
323:const ESPC_ROBUST_LOW_DIST = 2;
325:// This function flattens a cubic Bézier by first converting it into Euler spiral
327:// the Euler spiral segments.
328:fn flatten_euler(
418:            var robust = ESPC_ROBUST_NORMAL;
422:                robust = ESPC_ROBUST_LOW_K1;
430:                robust = ESPC_ROBUST_LOW_DIST;
434:                int0 = espc_int_approx(b);
435:                let int1 = espc_int_approx(a + b);
452:                    if robust != ESPC_ROBUST_LOW_K1 {
455:                        if robust == ESPC_ROBUST_LOW_DIST {
458:                            inv = espc_int_inv_approx(u);
494:fn flatten_arc(
529:        flatten_arc(path_ix, cap0, cap1, point, 3.1415927, transform);
626:            flatten_arc(path_ix, arc0, arc1, p0, abs(atan2(cr, d)), transform);
710:fn read_path_segment(tag: PathTagData, is_stroke: bool) -> CubicPoints {
718:    let is_stroke_cap_marker = is_stroke && (tag.tag_byte & PATH_TAG_SUBPATH_END) != 0u;
741:    if is_stroke_cap_marker && is_open {
742:        // The stroke cap marker for an open path is encoded as a quadto where the p1 and p2 store
748:        // segment preceding the cap marker). This scheme is only used for strokes.
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\flatten_simd.rs (lines 451-730)
Bash Vello robustness / bump failure handling
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -rn "failed\|BumpAllocators\|robust\|Robust\|resize\|out of memory\|OutOfMemory" vello/src/lib.rs | head -40

OUT
133:    pub use vello_encoding::BumpAllocators;
150:use low_level::{BumpAllocators, FullShaders, Recording, Render};
424:    bump: Option<BumpAllocators>,
633:    /// The return value is the value of the `BumpAllocators` in this rendering, which is currently used
650:    ) -> Result<Option<BumpAllocators>> {
730:        let robust = cfg!(feature = "debug_layers");
737:            robust,
753:        let mut bump: Option<BumpAllocators> = None;
795:        bump: &BumpAllocators,
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_shm.dart
Added 17 lines
Bash Read Vello roadmap 2023
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && sed -n '1,80p' doc/roadmap_2023.md

OUT
# Roadmap for 2023

Vello is a GPU accelerated 2D rendering engine, with ambitious goals to deliver efficient and high quality rendering by using compute shaders effectively. Last year saw progress on many fronts, including implementations of gradients, moving the clip stack processing to GPU, blends with almost arbitrarily deep nesting, and advances in the efficiency of scene encoding both to generate CPU-side and to process GPU-side. We also did a rewrite into WGSL, which we expect will improve collaboration with the rest of the ecosystem. This work has been fruitful research. In 2023, we plan to build on that research and ship a renderer that can be used in a variety of applications including GUI rendering, creative applications, and potentially 2D games and scientific visualization.

Late last year, we also renamed the project from piet-gpu, as it's no longer based on the Piet API (which had a number limitations including not supporting multi-threaded encoding). Vello, the new name, suggests both vellum (as used in illuminated manuscripts) and velocity.

The core team – Raph Levien and Chad Brokaw, with help from Arman Uguray – will be able to do most of the tasks listed here. Help from the community could speed things up or add even more features. We also rely heavily on the wgpu community to build solid GPU infrastructure for our uses, and also expect a nontrivial amount of integration work as people adopt Vello for their projects.

Large parts of the [piet-gpu vision] are still valid, but of course there are updates in the two years since it was written.

This roadmap is in roughly chronological in order of when we expect to complete the work. For each bullet point in the outline

* Completing the basic imaging model, to handle the needs of real applications.
* CPU fallback implementation, for better compatibility, testing, and debuggability.
* Stroke rework, to correctly and efficiently render the diversity of stroke styles.
* A writeup, so people can better understand and evaluate the project.
* Glyph caching, for higher performance for UI applications.
* Blurs and filter effects, as they are an important imaging primitive.
* A semi-stable encoding format, to offer more flexibility in getting scenes into the engine.

In addition, there are a few optional aspects to the roadmap, which will be implemented if there is demand from users or motivation from contributors:

* Native rendering back-ends, to reduce the overhead of WebGPU, especially runtime shader compilation.
* A solution to conflation artifacts, to improve rendering quality for some classes of vector art.
* Subpixel RGB rendering, to improve rendering quality on low-dpi LCD screens.
* High Dynamic Range (HDR) rendering, to exploit capabilities of new displays.

## Completing a basic imaging model

A 2D renderer needs to support at least a basic imaging model. The biggest single thing missing from Vello right now is images; without those, it is unsuitable for many applications.

Supporting images *well* is tricky, in large part because of limitations in GPU infrastructure. The number of images that may appear in a scene is not bounded, which is not a good fit for the basic descriptor binding model. Ideally a single shader (the fine rasterization stage) can sample from all the images in the scene directly, but that's not really possible in WebGPU 1.0. Perhaps a future extension will have version of this; in Vulkan it's descriptor indexing (and [buffer device address] and [descriptor buffer], as GPU approaches to this problem keep evolving, but it's less likely the latter will be standardized in WebGPU, as they're basically variants of raw pointers and thus extremely difficult to make safe).

Until then, we'll do a workaround of having a single atlas image containing all the images in the scene. That has nontrivial cost in memory allocation and bandwidth for texture copying, and the logic is tricky to write robustly, but the impact of copying on total rendering time is not expected to be that bad. And in the common case where an image is reused across multiple frames, it should in most cases be possible to avoid those copies.

One tricky part is changes to the scene encoding. At the moment, it's more or less self-contained, but will need to be extended so that scene fragments can contain references to image resources (which will be a reference counted pointer to either the image bytes or to an external image reference, which might be rendered by some other WebGPU task). Additionally, there needs to be an additional pass between encoding and submission to the GPU, where references to these resources are replaced by uv quads in the texture atlas. Similar logic is needed to resolve cached glyphs, about which more below.

Direct support for rectangles is also included in the "basic imaging model" category even though it's technically just an optimization, because it's important to get right architecturally. Right now, every draw object has an associated Bézier path, but that is going to be a performance problem when draw objects are images (or basically anything other than a vector path). Also, rectangles are important in UI, so it makes sense for drawing to be fast.

The last thing that belongs in "basic imaging model" is a proper API for glyph runs. At the moment, text is basically encoded as filled vector paths, but that doesn't scale to supporting glyph caching (about which more below). This is about getting the API right so clients won't be locked into fully dynamic vector text rendering.

* [vello#176]\: Image resources
* [vello#187]\: Rectangles
* TODO: no issue yet for the glyph run API

## CPU fallback implementation

Vello primarily runs in GPU compute shader stages, but there are three motivations for also having a CPU fallback path.

The most important reason is to improve testing and debuggability. At the moment, we have two or three cases where there are artifacts or missing objects, but only in certain configurations. The systematic approach to this problem is to have a CPU implementation of each compute stage, and then the CPU and GPU outputs can be compared. Other problems might be isolated by swapping out one implementation for another.

In addition, in some cases a competent GPU won't be available, or perhaps it is on a denylist because of known bugs. In that case, a CPU implementation is necessary in order to display anything.

Lastly, because of various overhead, GPU dispatch is only efficient when working with large datasets. When rendering an extremely simple scene, it might be more efficient just to do the compute work on CPU, and save the GPU dispatch. Generally you'll still want to do fine rasterization (production of actual pixels) on GPU, as even if the CPU could do that really quickly there would still be the cost of getting them uploaded.

Because of the emphasis on testing, at least the initial CPU implementations will be optimized for clarity and simplicity, not so much performance. It is possible to imagine doing SIMD optimization and running the work on multiple threads, but that is not planned (see non-goals below).

## Stroke rework

The current stroke implementation is based on distance fields, and is appealing in some ways (GPUs are good at distance field rendering). However, it also has some limitations and we plan to rework it.

The limitations include:
* Only doing round styles for stroke join and cap (not miter etc)
* Not drawing with an elliptical pen when affine transformed
* Quality issues on [very thin strokes]
* No clear, good solution to [stem darkening]

These limitations motivated work in analytically computing offset curves. We explored a [cubic-to-cubic approach][Parallel curves of cubic Béziers] but ultimately concluded that it wasn't suitable for GPU implementation, as there are numeric robustness issues with using f32's for quartic root-finding, and also it's tricky to find and handle the cusps.

A better approach is to combine offset and flattening in one operation. See [Fast approaches to simplify and offset Bézier curves within specified error limits] for a detailed exploration, which describes the techniques used in Blend2D.

At the moment, the most promising approach is to convert cubic Béziers (and possibly other source curves, potentially including the rational Béziers that would result from perspective transformation) into Euler spirals, derive the [parallel curve][Cleaner parallel curves with Euler spirals] as an Euler-to-Euler transformation, then flatten those using [similar techniques][Flattening quadratic Béziers] as is done today, just with Euler spirals instead of quadratic Béziers. This is prototyped and the results are encouraging, and it seems likely all this can be adapted to running efficiently in a compute shader. Another compute shader would handle corners.

The result would be a transformation of the stroke into a filled path, tiled into path segments. This is thus a simplification of fine rasterization, as it no longer needs to handle strokes and fills separately, but can just treat everything as a filled path. Another benefit is that the same mechanism can apply stroke thickening to glyphs while retaining very high quality.

## Writeup

We often hear that the Vello design is intimidating, that it seems too much like rocket science and that it is hard to contribute to the code. There are many advanced ideas, including extensive use of prefix sum techniques (including the [stack monoid]), sophisticated math for curves and 2D geometry (see above), clever binary encoding techniques, and quite a bit of work to adapt to the tricky requirements of portable GPU compute shaders. While it draws extensively from published work, it is not a straightforward extension of any existing system.

Such work deserves a good writeup. The current plan is to write an approximately 20 to 30 page report that explains all important aspects of the design, how they fit together, and enough empirical performance measurement that people can make good decisions based on it. It's always tricky to know *when* to invest in a writeup, especially as we keep iterating on the design itself, but this seems like a good place in the roadmap.
Bash Outline single threaded dispatcher
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips" && grep -n "fn \|//!" vello_cpu/src/dispatch/single_threaded.rs | head -50

OUT
51:    pub(crate) fn new(width: u16, height: u16, level: Level) -> Self {
66:    fn rasterize_f32(
85:    fn rasterize_u8(
101:    fn rasterize_with<S: Simd, F: FineKernel<S>>(
131:    fn bucket_and_rasterize<S: Simd, F: FineKernel<S>>(
170:    fn rasterize_target<S: Simd, F: FineKernel<S>>(
192:    fn record_fill(
207:    fn rasterize_filter_layers<S: Simd, F: FineKernel<S>>(
273:    fn has_layers(&self) -> bool {
277:    fn fill_path(
303:    fn stroke_path(
329:    fn fill_rect_fast(
345:    fn push_layer(
395:    fn pop_layer(&mut self) {
404:    fn reset(&mut self, width: u16, height: u16) {
411:    fn flush(&mut self) {
415:    fn rasterize(
492:    fn push_clip_path(
503:    fn pop_clip_path(&mut self) {
507:    fn is_multi_threaded(&self) -> bool {
519:fn save_filtered_layer_debug(pixmap: &Pixmap, layer_id: usize) {
543:    fn buffers_cleared_on_reset() {
Bash Fine shader AA and blend stack
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -n "area\|MSAA\|msaa\|blend_stack\|BLEND_STACK\|CMD_BEGIN_CLIP\|CMD_END_CLIP\|spill\|fill_path\|winding" vello_shaders/shader/fine.wgsl | head -60

OUT
6:// To enable multisampled rendering, turn on both the msaa ifdef and one of msaa8
7:// or msaa16.
41:var<storage, read_write> blend_spill: array<u32>;
52:// MSAA-only bindings and utilities
53:#ifdef msaa
57:#ifdef msaa8
67:#ifdef msaa16
79:// This array contains the winding number of the top left corner of each
84:// The values are biased signed integers, with 0x80 representing a winding
89:// word contains 16 one-bit winding parity values packed to the word.
90:var<workgroup> sh_winding_y: array<atomic<u32>, 4u>;
91:// This array contains the winding number of the top left corner of each
93:// It is expanded from sh_winding_y by inclusive prefix sum.
94:var<workgroup> sh_winding_y_prefix: array<atomic<u32>, 4u>;
95:// This array contains winding numbers of the top left corner of each
99:// During winding number accumulation, it stores a delta (winding number
103:// The encoding and packing is the same as `sh_winding_y`. For the even-odd
106:var<workgroup> sh_winding: array<atomic<u32>, 64u>;
107:// This array contains winding numbers of multiple sample points within
108:// a pixel, relative to the winding number of the top left corner of the
109:// pixel. The encoding and packing is the same as `sh_winding_y`.
129:// winding number deltas as the results of edge crossings detected in the
138:// directions, then counting nonzero winding numbers for all samples within
142:// are a great many winding numbers to be computed. The interested reader
144:// needed to represent a winding number parity, thus there is a lot less
146:fn fill_path_ms(fill: CmdFill, local_id: vec2<u32>, result: ptr<function, array<f32, PIXELS_PER_THREAD>>) {
151:        fill_path_ms_evenodd(fill, local_id, result);
156:    // Initialize winding number arrays to a winding number of 0, which is 0x80 in an
160:            atomicStore(&sh_winding_y[th_ix], 0x80808080u);
162:        atomicStore(&sh_winding[th_ix], 0x80808080u);
193:                atomicAdd(&sh_winding_y[y_edge >> 2u], u32(delta) << ((y_edge & 3u) << 3u));
263:            // pixel. If so, then a delta is added to `sh_winding`, followed by
264:            // a prefix sum, so that a winding number delta is applied to all
293:                    atomicAdd(&sh_winding[delta_pix >> 2u], delta);
302:#ifdef msaa8
334:#ifdef msaa16
385:    var area: array<f32, PIXELS_PER_THREAD>;
387:    var packed_w = atomicLoad(&sh_winding[major]);
388:    // Compute prefix sums of both `sh_winding` and `sh_winding_y`. Both
399:    var packed_y = atomicLoad(&sh_winding_y[local_id.y >> 2u]);
405:        atomicStore(&sh_winding_y_prefix[local_id.y >> 2u], prefix_y);
408:    // reuse sh_winding to store prefix as well
409:    atomicStore(&sh_winding[major], prefix_x);
412:        packed_w += atomicLoad(&sh_winding[i]);
414:    // packed_w now contains the winding numbers for a slice of 4 pixels,
417:        wind_y += atomicLoad(&sh_winding_y_prefix[i]);
419:    // wind_y now contains the winding number of the top left of the row of
423:    // The winding number of a sample point is the sum of four levels of
425:    // * The winding number of the top left of the tile (backdrop)
426:    // * The winding number of the pixel row relative to tile (wind_y)
427:    // * The winding number of the pixel relative to row (packed_w)
428:    // * The winding number of the sample relative to pixel (sh_samples)
430:    // Conceptually, we want to compute each of these total winding numbers
453:            area[i] = 1.0;
455:#ifdef msaa8
468:            area[i] = f32(countOneBits(xored8 & 0xC0C0C0C0u)) * 0.125;
470:#ifdef msaa16
495:            area[i] = f32(countOneBits(xored8 & 0xF0F0F0F0u)) * 0.0625;
499:    *result = area;
504:// This proceeds very much the same as `fill_path_ms`, but is simpler because
Bash Outline dispatch and region
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips" && grep -n "fn render_strips\|fn rasterize\|fn flush\|struct \|pub fn " vello_cpu/src/dispatch/mod.rs | head -40; echo "=== region ==="; grep -n "pub\|fn \|struct" vello_cpu/src/region.rs | head -40

OUT
69:    fn flush(&mut self);
70:    fn rasterize(
=== region ===
14:pub struct Region<'a> {
15:    pub(crate) row_idx: usize,
17:    pub(crate) height: u16,
23:    pub fn new(pixmap: &'a mut PixmapMut<'_>, rect: RectU16) -> Self {
27:    pub(crate) fn new_from_row(
48:    pub(crate) fn row_mut(&mut self, y: u16) -> &mut [u8] {
52:    pub(crate) fn width(&self) -> u16 {
57:    pub(crate) fn sub_span(&mut self, x: u16, width: u16) -> Region<'_> {
81:    pub(crate) fn areas(&mut self) -> &mut [&'a mut [u8]; Tile::HEIGHT as usize] {
85:    fn from_rows(
114:pub(crate) struct Regions<'a> {
119:    pub(crate) fn new(
159:    pub(crate) fn update(&mut self, func: impl FnMut(&mut Region<'_>)) {
164:    pub(crate) fn update_par(&mut self, func: impl Fn(&mut Region<'_>) + Send + Sync) {
177:    fn regions_with_off_target_offsets_do_not_panic() {
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_shm.dart
Added 6 lines
Bash Impeller compute usage and glossary
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && echo "=== compute usage in entity/display_list ==="; grep -rn "ComputePass\|SupportsCompute" entity/ display_list/ | head -20; echo "=== glossary ==="; sed -n '1,60p' docs/glossary.md

OUT
=== compute usage in entity/display_list ===
display_list/aiks_dl_blend_unittests.cc:334:  FLT_FORWARD(mock_capabilities, old_capabilities, SupportsCompute);
display_list/aiks_dl_blur_unittests.cc:1269:  FLT_FORWARD(mock_capabilities, old_capabilities, SupportsCompute);
=== glossary ===
# Glossary

### Device & Host

In the context of graphics and Impeller, the device is the GPU and the host, the CPU.

### Client Rendering API

The API Impeller uses to talk to devices. Examples of these are OpenGL, Metal, Vulkan, Direct X.

### Window System Integration (WSI)

Impeller can render using one of the client rendering APIs into a render target. However, that render target needs to be presented in the platform's window system. A Window System Integration API does this and is usually extremely platform specific. For instance, OpenGL may be available on macOS and Linux, but the WSI API for macOS is EAGL and usually (but not always) EGL for Linux.

### Varying

In the context of shaders, a varying is a value that is interpolated between two vertices (specified by the vertex shader) and provided to the fragment shader.

### OpenGL

[OpenGL and OpenGL ES (Embedded Systems)](https://www.opengl.org/) are [client rendering APIs](#client-rendering-api). Impeller uses these on older versions of Android today.

### Vulkan

[Vulkan](https://www.vulkan.org/) is a modern [client rendering API](#client-rendering-api) used by Impeller on Android. It is also available natively on the major non-Apple platforms. On the Apple platforms, Vulkan is implemented on top of [Metal](#metal) via a translation layer called [MoltenVK](https://github.com/KhronosGroup/MoltenVK).

Impeller supports a baseline of Vulkan 1.1 and uses extensions where available.

### Metal

[Metal](https://developer.apple.com/metal/) is a modern [client rendering API](#client-rendering-api) used by Impeller on macOS and iOS. It is not available on non-Apple platforms.

### EGL

[EGL](https://www.khronos.org/egl) provides [WSI](#window-system-integration-wsi) for OpenGL ES.

### Android Hardware Buffers (AHB)

Available only on Android and used by Impeller on API levels at or above 29, [AHBs](https://developer.android.com/ndk/reference/group/a-hardware-buffer) are resources that can be treated as textures by both [OpenGL](#opengl) and [Vulkan](#vulkan) and shared with the system compositor for [WSI](#window-system-integration-wsi).

In the Impeller codebase, classes that deal with AHBs have the `ahb_` prefix.
Bash Search for Footprint struct
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips" && grep -rn "Footprint\|footprint" --include=*.rs --include=*.wesl | head -20; echo "EXIT:$?"

OUT
vello_common/src/mask.rs:18:// to reduce the memory footprint of the struct.
vello_cpu/src/coarse/cmd.rs:13:// TODO: If we wanted to, we could likely reduce the memory footprint from 16 bytes to 8 bytes
vello_hybrid/src/filter.rs:239:    // Needed since drop shadow has a bigger footprint.
EXIT:0
Bash Impeller text contents and shaders list
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && grep -n "GlyphAtlas\|atlas\|SubpixelPosition\|scale\|kColorBitmap\|kAlphaBitmap" entity/contents/text_contents.cc | head -30; echo "=== SHADERS ==="; ls entity/shaders/ | head -60

OUT
19:#include "impeller/typographer/glyph_atlas.h"
84:  const std::shared_ptr<GlyphAtlas>& atlas =
85:      renderer.GetLazyGlyphAtlas()->CreateOrGetGlyphAtlas(
88:  if (!atlas || !atlas->IsValid()) {
89:    VALIDATION_LOG << "Cannot render glyphs without prepared atlas.";
101:  pass.SetPipeline(renderer.GetGlyphAtlasPipeline(opts));
103:  using VS = GlyphAtlasPipeline::VertexShader;
104:  using FS = GlyphAtlasPipeline::FragmentShader;
110:  ISize atlas_size = atlas->GetTexture()->GetSize();
111:  bool is_translation_scale = entity.GetTransform().IsTranslationScaleOnly();
121:  frag_info.is_color_glyph = type == GlyphAtlas::Type::kColorBitmap;
127:  if (is_translation_scale) {
131:    // Currently, we only propagate the scale of the transform to the atlas
140:  // No mipmaps for glyph atlas (glyphs are generated at exact scales).
143:  FS::BindGlyphAtlasSampler(
145:      atlas->GetTexture(),  // texture
155:  // sample from the glyph atlas.
178:          Scalar rounded_scale = TextFrame::RoundScaledFontSize(scale_);
179:          FontGlyphAtlas* font_atlas = nullptr;
205:            auto atlas_glyph_bounds = frame_bounds.atlas_bounds;
209:            // the glyph has been rendered and so its atlas position was not
211:            // glyph atlas hash table.
213:              if (!font_atlas) {
214:                font_atlas = atlas->GetOrCreateFontGlyphAtlas(
215:                    ScaledFont{font, rounded_scale});
218:              if (!font_atlas) {
219:                VALIDATION_LOG << "Could not find font in the atlas.";
222:              Point subpixel = TextFrame::ComputeSubpixelPosition(
224:                  rounded_scale);
226:              std::optional<FrameBounds> maybe_atlas_glyph_bounds =
=== SHADERS ===
blending
clip.frag
clip.vert
downsample.glsl
filters
glyph_atlas.frag
glyph_atlas.vert
gradients
rrect_blur.frag
rrect_blur.vert
runtime_effect.vert
solid_fill.frag
solid_fill.vert
texture_downsample.frag
texture_downsample_gles.frag
texture_fill.frag
texture_fill.vert
texture_fill_strict_src.frag
texture_uv_fill.vert
tiled_texture_fill.frag
tiled_texture_fill_external.frag
Enquanto os agentes estudam as referências, vou fechar os detalhes de API que o spike precisa.

Bash Check version and changelog
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main" && git log --oneline -5 2>/dev/null | head; echo "---"; grep -n "version" sparse_strips/vello_common/Cargo.toml | head -5; echo "--- CHANGELOG cpu head ---"; sed -n '1,60p' sparse_strips/vello_cpu/CHANGELOG.md

OUT
f1ca720 test(widgets): cobre InfoBar, Toast, NumberBox, Badge e galeria de dados
a08aa28 diagnostics: trace WSLg virtiofs node reset bug
d5aaa3c perf: avoid D3D12 readback on external X11
b515b2c fix: fall back to VcXsrv when WSLg copy mode fails
ff0c60a feat: expand native backends and WSL graphics POCs
---
3:# When updating, also update the version in the workspace dependency in the root Cargo.toml
4:version = "0.2.0"
9:rust-version.workspace = true
24:roxmltree = { version = "0.20.0", optional = true }
28:libm = { version = "0.2.16", optional = true }
--- CHANGELOG cpu head ---
<!-- Instructions

This changelog follows the patterns described here: <https://keepachangelog.com/en/>.

Subheadings to categorize changes are `added, changed, deprecated, removed, fixed, security`.

-->

# Changelog

## [Unreleased]

This release has an [MSRV][] of 1.88.

## [0.2.0][] - 2026-08-07

This release has an [MSRV][] of 1.88.

### Fixed

- Wrong application of extend mode in the y-direction. ([#1803][] by [@LaurenzV][], [@ShiroKSH][])

### Optimized

- Multi-threaded render contexts now initialize task dispatch lazily on the first drawing operation, avoiding unnecessary setup for empty frames and after resets. ([#1787][] by [@LaurenzV][], [@yezhizhen][])

## [0.1.0][] - 2026-07-29

This release has an [MSRV][] of 1.88.

### Added

- `RenderContext::reset_and_resize`, allowing a render context to be reused after its target size changes. ([#1705][] by [@LaurenzV][])
- `RenderContext::is_multi_threaded` for querying whether the context uses multi-threaded rendering. ([#1703][] by [@LaurenzV][])
- Inverse blurred rounded rectangles through the new `invert` parameter on `RenderContext::fill_blurred_rounded_rect`, enabling inset box shadows. ([#1715][] by [@nicoburns][])
- `FilterPrimitive::DropShadowOnly` for rendering a drop shadow without compositing the original input over it. ([#1763][] by [@LaurenzV][])

### Changed

- Breaking change: The methods `render_to_pixmap` and `composite_to_pixmap_at_offset`
  have been replaced with unified `render` and `render_with` methods, whose settings
  control the target, pixel format, compositing, and rendering mode.
  ([#1665][] by [@LaurenzV][])
- The Vello CPU frontend and coarse rasterizer have been rewritten. As a result:
    - Filter layers always render correctly, even at viewport boundaries.
    - A number of issues with layer clipping have been fixed.
    - Performance improves by up to 10% across a variety of rendering workloads. ([#1701][] by [@LaurenzV][])

### Fixed

- Opaque image rendering when blend modes or masks are active. ([#1697][] by [@LaurenzV][])
- Gaussian blur strength changing abruptly at decimation thresholds. ([#1720][] by [@grebmeg][])
- Panics when resetting or dropping a multi-threaded render context while worker tasks are still in flight. ([#1732][], [#1756][] by [@yezhizhen][])

### Optimized

- x86 rendering, including blending and high-quality image sampling, through improved SIMD code generation. ([#1688][] by [@LaurenzV][])
- Clip-path intersection by skipping rows outside the paths' shared vertical extent and locating the first relevant strip with binary search. ([#1690][], [#1691][] by [@LaurenzV][])
- Radial-gradient evaluation and gradient lookup-table generation. ([#1723][], [#1726][] by [@LaurenzV][])
- Rendering opaque `peniko::ImageData` by computing and retaining its transparency hint during conversion. ([#1760][] by [@tronical][])
Read C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_pipeline.dart
Grep "void addQuad|required double|createTexture\(|uploadRegion\(|GpuTextureFormat|GpuTextureFilter" (in C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\gpu_vertex_buffer.dart)
16 lines of output
Grep "D3d12Texture createTexture|D3d12Texture\? createTexture|void uploadRegion|bool uploadRegion|createTexture\(\{|uploadRegion\(" (in C:\MyDartProjects\dart_ui\lib\src\backends\win32\d3d12\d3d12_device.dart)
63 lines of output
Bash Impeller blending shaders and framebuffer fetch caps
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && ls entity/shaders/blending/; echo "=== GLES FB FETCH ==="; grep -n "framebuffer_fetch\|FramebufferFetch\|GL_EXT_shader_framebuffer_fetch\|ARM_shader" renderer/backend/gles/capabilities_gles.cc | head; echo "=== VK ==="; grep -n "SupportsFramebufferFetch\|supports_framebuffer_fetch\|subpass" renderer/backend/vulkan/capabilities_vk.cc | head

OUT
advanced_blend.frag
advanced_blend.vert
blend_select.glsl
framebuffer_blend.frag
framebuffer_blend.vert
porter_duff_blend.frag
porter_duff_blend.vert
vertices_uber.frag
=== GLES FB FETCH ===
12:// https://registry.khronos.org/OpenGL/extensions/EXT/EXT_shader_framebuffer_fetch.txt
13:static const constexpr char* kFramebufferFetchExt =
14:    "GL_EXT_shader_framebuffer_fetch";
120:  supports_framebuffer_fetch_ = desc->HasExtension(kFramebufferFetchExt);
174:bool CapabilitiesGLES::SupportsFramebufferFetch() const {
175:  return supports_framebuffer_fetch_;
=== VK ===
628:bool CapabilitiesVK::SupportsFramebufferFetch() const {
Bash Vello coarse/binning/tile details
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -n "^//\|^// " vello_shaders/shader/coarse.wgsl | head -30; echo "=== BINNING doc ==="; sed -n '22,60p' vello_shaders/shader/binning.wgsl; echo "=== TILE ==="; sed -n '1,30p' vello_shaders/shader/shared/tile.wgsl

OUT
1:// Copyright 2022 the Vello Authors
2:// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense
4:// The coarse rasterization stage.
21:// TODO: dedup
47:// Much of this code assumes WG_SIZE == N_TILE. If these diverge, then
48:// a fair amount of fixup is needed.
62:// helper functions for writing ptcl
67:// Make sure there is space for a command of given size, plus a jump if needed
=== BINNING doc ===

@group(0) @binding(4)
var<storage, read_write> intersected_bbox: array<vec4<f32>>;

@group(0) @binding(5)
var<storage, read_write> bump: BumpAllocators;

@group(0) @binding(6)
var<storage, read_write> bin_data: array<u32>;

// TODO: put in common place
struct BinHeader {
    element_count: u32,
    chunk_offset: u32,
}

@group(0) @binding(7)
var<storage, read_write> bin_header: array<BinHeader>;

// conversion factors from coordinates to bin
const SX = 1.0 / f32(N_TILE_X * TILE_WIDTH);
const SY = 1.0 / f32(N_TILE_Y * TILE_HEIGHT);

const WG_SIZE = 256u;
const N_SLICE = WG_SIZE / 32u;
const N_SUBSLICE = 4u;

var<workgroup> sh_bitmaps: array<array<atomic<u32>, N_TILE>, N_SLICE>;
// store count values packed two u16's to a u32
var<workgroup> sh_count: array<array<u32, N_TILE>, N_SUBSLICE>;
var<workgroup> sh_chunk_offset: array<u32, N_TILE>;
var<workgroup> sh_previous_failed: u32;

@compute @workgroup_size(256)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) wg_id: vec3<u32>,
) {
=== TILE ===
// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT OR Unlicense

// Common datatypes for path and tile intermediate info.

struct Path {
    // bounding box in tiles
    bbox: vec4<u32>,
    // offset (in u32's) to tile rectangle
    tiles: u32,
}

struct Tile {
    backdrop: i32,
    // This is used for the count of the number of segments in the
    // tile up to coarse rasterization, and the index afterwards.
    // In the latter variant, the bits are inverted so that tiling
    // can detect whether the tile was allocated; it's best to
    // consider this an enum packed into a u32.
    segment_count_or_ix: u32,
}
Read C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\render\wgpu\mod.rs (lines 2821-2900)
Bash Check depth buffer config
IN
cd "C:/MyDartProjects/dart_ui/referencias/vello-main/sparse_strips/vello_hybrid/src/render" && grep -n "Depth24\|Depth32\|DepthStencilState\|depth_compare\|depth_write_enabled\|CompareFunction" wgpu/mod.rs | head -30; echo "=== webgl depth ==="; grep -n "DEPTH\|depth_func\|depth_mask\|LEQUAL\|GREATER" webgl/mod.rs | head -30

OUT
1197:        let depth_format = wgpu::TextureFormat::Depth24Plus;
1206:            |label, format, blend, depth_stencil: Option<wgpu::DepthStencilState>| {
1237:        let depth_stencil = |depth_write_enabled| wgpu::DepthStencilState {
1239:            depth_write_enabled: Some(depth_write_enabled),
1240:            depth_compare: Some(wgpu::CompareFunction::LessEqual),
1781:            format: wgpu::TextureFormat::Depth24Plus,
=== webgl depth ===
302:            gl.get_parameter(WebGl2RenderingContext::DEPTH_BITS)
1761:    depth_mask: bool,
1826:            config.depth_test && gl.is_enabled(WebGl2RenderingContext::DEPTH_TEST);
1828:        let depth_mask = if config.depth_mask {
1829:            gl.get_parameter(WebGl2RenderingContext::DEPTH_WRITEMASK)
1867:            depth_mask,
1906:                depth_mask: true,
1936:                self.gl.enable(WebGl2RenderingContext::DEPTH_TEST);
1938:                self.gl.disable(WebGl2RenderingContext::DEPTH_TEST);
1942:        if self.config.depth_mask {
1943:            self.gl.depth_mask(self.depth_mask);
2023:    pub(crate) depth_mask: bool,
2445:        // Note: we use DEPTH (not DEPTH_ATTACHMENT) because we render to the default
2447:        // to DEPTH_ATTACHMENT.
2448:        depth_attachment_array: js_sys::Array::of1(&WebGl2RenderingContext::DEPTH.into()),
2810:            self.gl.enable(WebGl2RenderingContext::DEPTH_TEST);
2811:            self.gl.depth_func(WebGl2RenderingContext::LEQUAL);
2817:                self.gl.clear(WebGl2RenderingContext::DEPTH_BUFFER_BIT);
2822:                self.gl.depth_mask(true);
2834:                self.gl.depth_mask(false);
2840:            self.gl.disable(WebGl2RenderingContext::DEPTH_TEST);
2841:            self.gl.depth_mask(true);
2870:        self.gl.disable(WebGl2RenderingContext::DEPTH_TEST);
2871:        self.gl.depth_mask(false);
2985:        self.gl.disable(WebGl2RenderingContext::DEPTH_TEST);
2986:        self.gl.depth_mask(false);
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_shm.dart
Added 31 lines
Bash Vello tile/bin constants and buffer size defaults
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && sed -n '1,50p' vello_encoding/src/config.rs; echo "=== defaults ==="; grep -n "BufferSizes::new" -A 60 vello_encoding/src/config.rs | sed -n '1,80p'

OUT
// Copyright 2023 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT

use crate::SegmentCount;

use super::{
    BinHeader, Clip, ClipBbox, ClipBic, ClipElement, DrawBbox, DrawMonoid, Layout, LineSoup, Path,
    PathBbox, PathMonoid, PathSegment, Tile,
};
use bytemuck::{Pod, Zeroable};

const TILE_WIDTH: u32 = 16;
const TILE_HEIGHT: u32 = 16;

// TODO: Obtain these from the vello_shaders crate
pub(crate) const PATH_REDUCE_WG: u32 = 256;
const PATH_BBOX_WG: u32 = 256;
const FLATTEN_WG: u32 = 256;
const CLIP_REDUCE_WG: u32 = 256;

/// Counters for tracking dynamic allocation on the GPU.
///
/// This must be kept in sync with the struct in `shader/shared/bump.wgsl`
#[derive(Clone, Copy, Debug, Default, Zeroable, Pod)]
#[repr(C)]
pub struct BumpAllocators {
    pub failed: u32,
    // Final needed dynamic size of the buffers. If any of these are larger
    // than the corresponding `_size` element reallocation needs to occur.
    pub binning: u32,
    pub ptcl: u32,
    pub tile: u32,
    pub seg_counts: u32,
    pub segments: u32,
    pub blend: u32,
    pub lines: u32,
}

#[derive(Default)]
pub struct BumpAllocatorMemory {
    pub total: u32,
    pub binning: BufferSize<u32>,
    pub ptcl: BufferSize<u32>,
    pub tile: BufferSize<Tile>,
    pub seg_counts: BufferSize<SegmentCount>,
    pub segments: BufferSize<PathSegment>,
    pub lines: BufferSize<LineSoup>,
}

impl BumpAllocators {
=== defaults ===
176:        let buffer_sizes = BufferSizes::new(layout, &workgroup_counts);
177-        Self {
178-            gpu: ConfigUniform {
179-                width_in_tiles,
180-                height_in_tiles,
181-                target_width: width,
182-                target_height: height,
183-                base_color: base_color.premultiply().to_rgba8().to_u32(),
184-                lines_size: buffer_sizes.lines.len(),
185-                binning_size: buffer_sizes.bin_data.len() - layout.bin_data_start,
186-                tiles_size: buffer_sizes.tiles.len(),
187-                seg_counts_size: buffer_sizes.seg_counts.len(),
188-                segments_size: buffer_sizes.segments.len(),
189-                blend_size: buffer_sizes.blend_spill.len(),
190-                ptcl_size: buffer_sizes.ptcl.len(),
191-                layout: *layout,
192-            },
193-            workgroup_counts,
194-            buffer_sizes,
195-        }
196-    }
197-}
198-
199-/// Type alias for a workgroup size.
200-pub type WorkgroupSize = (u32, u32, u32);
201-
202-/// Computed sizes for all dispatches.
203-#[derive(Copy, Clone, Debug, Default)]
204-pub struct WorkgroupCounts {
205-    pub use_large_path_scan: bool,
206-    pub path_reduce: WorkgroupSize,
207-    pub path_reduce2: WorkgroupSize,
208-    pub path_scan1: WorkgroupSize,
209-    pub path_scan: WorkgroupSize,
210-    pub bbox_clear: WorkgroupSize,
211-    pub flatten: WorkgroupSize,
212-    pub draw_reduce: WorkgroupSize,
213-    pub draw_leaf: WorkgroupSize,
214-    pub clip_reduce: WorkgroupSize,
215-    pub clip_leaf: WorkgroupSize,
216-    pub binning: WorkgroupSize,
217-    pub tile_alloc: WorkgroupSize,
218-    pub path_count_setup: WorkgroupSize,
219-    // Note: `path_count` must use an indirect dispatch
220-    pub backdrop: WorkgroupSize,
221-    pub coarse: WorkgroupSize,
222-    pub path_tiling_setup: WorkgroupSize,
223-    // Note: `path_tiling` must use an indirect dispatch
224-    pub fine: WorkgroupSize,
225-}
226-
227-impl WorkgroupCounts {
228-    pub fn new(
229-        layout: &Layout,
230-        width_in_tiles: u32,
231-        height_in_tiles: u32,
232-        n_path_tags: u32,
233-    ) -> Self {
234-        let n_paths = layout.n_paths;
235-        let n_draw_objects = layout.n_draw_objects;
236-        let n_clips = layout.n_clips;
Bash Where Impeller uses framebuffer fetch
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && grep -n "SupportsFramebufferFetch" entity/contents/filters/blend_filter_contents.cc display_list/canvas.cc entity/contents/content_context.cc | head -20

OUT
entity/contents/filters/blend_filter_contents.cc:1006:    if (renderer.GetDeviceCapabilities().SupportsFramebufferFetch()) {
display_list/canvas.cc:1076:          renderer_.GetDeviceCapabilities().SupportsFramebufferFetch() &&
display_list/canvas.cc:1262:      if (renderer_.GetDeviceCapabilities().SupportsFramebufferFetch()) {
display_list/canvas.cc:1488:    if (renderer_.GetDeviceCapabilities().SupportsFramebufferFetch()) {
entity/contents/content_context.cc:361:  if (context_->GetCapabilities()->SupportsFramebufferFetch()) {
Now the framebuffer getter, present and dispose logic.

Bash Vello default buffer sizes
IN
cd C:/MyDartProjects/dart_ui/referencias/vello-main && grep -n "impl BufferSizes" -A 75 vello_encoding/src/config.rs | grep -n "BufferSize::new\|let \|1 <<\|4096\|// " | head -50

OUT
3:364-        let n_paths = layout.n_paths;
4:365-        let n_draw_objects = layout.n_draw_objects;
5:366-        let n_clips = layout.n_clips;
6:367-        let path_tag_wgs = workgroups.path_reduce.0;
7:368-        let reduced_size = if workgroups.use_large_path_scan {
12:373-        let path_reduced = BufferSize::new(reduced_size);
13:374-        let path_reduced2 = BufferSize::new(PATH_REDUCE_WG);
14:375-        let path_reduced_scan = BufferSize::new(reduced_size);
15:376-        let path_monoids = BufferSize::new(path_tag_wgs * PATH_REDUCE_WG);
16:377-        let path_bboxes = BufferSize::new(n_paths);
17:378-        let binning_wgs = workgroups.binning.0;
18:379-        let draw_monoid_wgs = workgroups.draw_reduce.0;
19:380-        let draw_reduced = BufferSize::new(draw_monoid_wgs);
20:381-        let draw_monoids = BufferSize::new(n_draw_objects);
21:382-        let info = BufferSize::new(layout.bin_data_start);
22:383-        let clip_inps = BufferSize::new(n_clips);
23:384-        let clip_els = BufferSize::new(n_clips);
24:385-        let clip_bics = BufferSize::new(n_clips / CLIP_REDUCE_WG);
25:386-        let clip_bboxes = BufferSize::new(n_clips);
26:387-        let draw_bboxes = BufferSize::new(n_paths);
27:388-        let bump_alloc = BufferSize::new(1);
28:389-        let indirect_count = BufferSize::new(1);
29:390-        let n_paths_aligned = align_up(n_paths, 256);
30:391-        let paths = BufferSize::new(n_paths_aligned);
31:392-        let width_in_bins = workgroups.coarse.0;
32:393-        let height_in_bins = workgroups.coarse.1;
33:394-        let n_bins = width_in_bins * height_in_bins;
34:395-        let aligned_n_bins = align_up(n_bins, 256);
35:396-        let bin_headers = BufferSize::new(binning_wgs * aligned_n_bins);
37:398-        // The following buffer sizes have been hand picked to accommodate the vello test scenes as
38:399-        // well as paris-30k. These should instead get derived from the scene layout using
39:400-        // reasonable heuristics.
40:401-        let bin_data = BufferSize::new(1 << 18);
41:402-        let tiles = BufferSize::new(1 << 21);
42:403-        let lines = BufferSize::new(1 << 21);
43:404-        let seg_counts = BufferSize::new(1 << 21);
44:405-        let segments = BufferSize::new(1 << 21);
45:406-        // 16 * 16 (1 << 8) is one blend spill, so this allows for 4096 spills.
46:407-        let blend_spill = BufferSize::new(1 << 20);
47:408-        let ptcl = BufferSize::new(1 << 23);
Bash Impeller compute pass use and TessellateConvex impl
IN
cd C:/MyDartProjects/dart_ui/referencias/engine-main/impeller && grep -rn "ComputePass" --include=*.cc --include=*.h --include=*.mm . | grep -v backend/ | grep -v unittest | grep -v mocks | head -20; echo "=== TessellateConvex ==="; grep -n "TessellateConvex" -A 45 tessellator/tessellator.cc | head -70

OUT
./renderer/capabilities.h:55:  /// @brief  Whether the context backend supports `ComputePass`.
./renderer/capabilities.h:58:  /// @brief  Whether the context backend supports configuring `ComputePass`
./renderer/command_buffer.cc:60:std::shared_ptr<ComputePass> CommandBuffer::CreateComputePass() {
./renderer/command_buffer.cc:64:  auto pass = OnCreateComputePass();
./renderer/command_buffer.cc:66:    pass->SetLabel("ComputePass");
./renderer/command_buffer.h:16:class ComputePass;
./renderer/command_buffer.h:98:  std::shared_ptr<ComputePass> CreateComputePass();
./renderer/command_buffer.h:116:  virtual std::shared_ptr<ComputePass> OnCreateComputePass() = 0;
./renderer/compute_pass.cc:9:ComputePass::ComputePass(std::shared_ptr<const Context> context)
./renderer/compute_pass.cc:12:ComputePass::~ComputePass() = default;
./renderer/compute_pass.cc:14:void ComputePass::SetLabel(const std::string& label) {
./renderer/compute_pass.h:23:class ComputePass : public ResourceBinder {
./renderer/compute_pass.h:25:  virtual ~ComputePass();
./renderer/compute_pass.h:67:  explicit ComputePass(std::shared_ptr<const Context> context);
./renderer/compute_pass.h:72:  ComputePass(const ComputePass&) = delete;
./renderer/compute_pass.h:74:  ComputePass& operator=(const ComputePass&) = delete;
=== TessellateConvex ===
40:VertexBuffer Tessellator::TessellateConvex(const Path& path,
41-                                           HostBuffer& host_buffer,
42-                                           Scalar tolerance,
43-                                           bool supports_primitive_restart,
44-                                           bool supports_triangle_fan) {
45-  if (supports_primitive_restart) {
46-    // Primitive Restart.
47-    const auto [point_count, contour_count] = path.CountStorage(tolerance);
48-    BufferView point_buffer = host_buffer.Emplace(
49-        nullptr, sizeof(Point) * point_count, alignof(Point));
50-    BufferView index_buffer = host_buffer.Emplace(
51-        nullptr, sizeof(uint16_t) * (point_count + contour_count),
52-        alignof(uint16_t));
53-
54-    if (supports_triangle_fan) {
55-      FanVertexWriter writer(
56-          reinterpret_cast<Point*>(point_buffer.GetBuffer()->OnGetContents() +
57-                                   point_buffer.GetRange().offset),
58-          reinterpret_cast<uint16_t*>(
59-              index_buffer.GetBuffer()->OnGetContents() +
60-              index_buffer.GetRange().offset));
61-      path.WritePolyline(tolerance, writer);
62-      point_buffer.GetBuffer()->Flush(point_buffer.GetRange());
63-      index_buffer.GetBuffer()->Flush(index_buffer.GetRange());
64-
65-      return VertexBuffer{
66-          .vertex_buffer = std::move(point_buffer),
67-          .index_buffer = std::move(index_buffer),
68-          .vertex_count = writer.GetIndexCount(),
69-          .index_type = IndexType::k16bit,
70-      };
71-    } else {
72-      StripVertexWriter writer(
73-          reinterpret_cast<Point*>(point_buffer.GetBuffer()->OnGetContents() +
74-                                   point_buffer.GetRange().offset),
75-          reinterpret_cast<uint16_t*>(
76-              index_buffer.GetBuffer()->OnGetContents() +
77-              index_buffer.GetRange().offset));
78-      path.WritePolyline(tolerance, writer);
79-      point_buffer.GetBuffer()->Flush(point_buffer.GetRange());
80-      index_buffer.GetBuffer()->Flush(index_buffer.GetRange());
81-
82-      return VertexBuffer{
83-          .vertex_buffer = std::move(point_buffer),
84-          .index_buffer = std::move(index_buffer),
85-          .vertex_count = writer.GetIndexCount(),
--
93:  TessellateConvexInternal(path, *point_buffer_, *index_buffer_, tolerance);
94-
95-  if (point_buffer_->empty()) {
96-    return VertexBuffer{
97-        .vertex_buffer = {},
98-        .index_buffer = {},
99-        .vertex_count = 0u,
100-        .index_type = IndexType::k16bit,
101-    };
102-  }
103-
104-  BufferView vertex_buffer = host_buffer.Emplace(
105-      point_buffer_->data(), sizeof(Point) * point_buffer_->size(),
106-      alignof(Point));
107-
108-  BufferView index_buffer = host_buffer.Emplace(
109-      index_buffer_->data(), sizeof(uint16_t) * index_buffer_->size(),
110-      alignof(uint16_t));
111-
112-  return VertexBuffer{
113-      .vertex_buffer = std::move(vertex_buffer),
114-      .index_buffer = std::move(index_buffer),
115-      .vertex_count = index_buffer_->size(),
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_shm.dart
Added 58 lines
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_shm.dart
Added 12 lines
Now the transport additions — pipes and fd I/O for clipboard transfers.

Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_transport.dart
Added 16 lines
Grep "^ (void|Path|PathBuilder) [a-zA-Z]+\(|kDefaultFlattenTolerance =" (in C:\MyDartProjects\dart_ui\lib\src\geometry\path.dart)
21 lines of output
Read C:\MyDartProjects\dart_ui\lib\src\rendering\path\scanline_filler.dart (lines 151-230)
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_transport.dart
Added 69 lines
Inventário concluído nos pontos-chave. Agora preciso ver os detalhes das rotas de fill do CPU sink, o debug dump e o recording sink.

Read C:\MyDartProjects\dart_ui\lib\src\rendering\cpu_renderer.dart (lines 381-495)
Read C:\MyDartProjects\dart_ui\lib\src\rendering\cpu_renderer.dart (lines 701-950)
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_transport.dart
Modified
Read C:\MyDartProjects\dart_ui\lib\src\rendering\cpu_renderer.dart (lines 1051-1180)
Bash Find fill style guard, debug dump, recording sink
IN
grep -n "_requireFillStyle" lib/src/rendering/cpu_renderer.dart | head -3; echo ---; grep -n "paint\|Paint" lib/src/graphics/display_list_debug.dart | head -25; echo ---; grep -n "ReplayPaint\|class RecordingSink" lib/src/rendering/replay/recording_sink.dart | head -15

OUT
476:    _requireFillStyle(paint, 'rectangle');
487:    _requireFillStyle(paint, 'rounded rectangle');
516:  void _requireFillStyle(ReplayPaint paint, String what) {
---
35:    required this.paintId,
42:  final int paintId;
46:      'SaveLayer(($left, $top, $right, $bottom), paint: $paintId)';
113:    required this.paintId,
120:  final int paintId;
124:      'DrawRect(($left, $top, $right, $bottom), paint: $paintId)';
134:    required this.paintId,
146:  final int paintId;
150:      'radii: $radii, paint: $paintId)';
154:  const DrawPathCommand({required this.pathId, required this.paintId});
157:  final int paintId;
160:  String toString() => 'DrawPath(path: $pathId, paint: $paintId)';
174:    required this.paintId,
186:  final int paintId;
191:      'dst: ($dstLeft, $dstTop, $dstRight, $dstBottom), paint: $paintId)';
197:    required this.paintId,
206:  final int paintId;
217:  String toString() => 'DrawGlyphRun(font: $fontId, paint: $paintId, '
246:        paintId: reader.intAt(0),
275:        paintId: reader.intAt(0),
286:        paintId: reader.intAt(0),
289:      return DrawPathCommand(pathId: reader.intAt(0), paintId: reader.intAt(1));
301:        paintId: reader.intAt(1),
307:        paintId: reader.intAt(1),
335:    ..writeln('paints: ${list.paintCount}, paths: ${list.pathCount}, '
---
40:  final ReplayPaint paint;
58:  final ReplayPaint paint;
73:  final ReplayPaint paint;
88:  final ReplayPaint paint;
107:  final ReplayPaint paint;
137:  final ReplayPaint paint;
147:final class RecordingSink implements RasterSink {
174:  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint) =>
181:  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) =>
189:    ReplayPaint paint,
200:    ReplayPaint paint,
210:    ReplayPaint paint,
225:    ReplayPaint paint,
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_transport.dart
Added 2 lines
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_transport.dart
Removed 3 lines
Now the raw-event repeat flag and translator support.

Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_events.dart
Added 5 lines
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_events.dart
Added 1 line
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_events.dart
Added 1 line
Tenho todos os detalhes de API. Vou escrever o spike agora (o estágio CPU primeiro), enquanto os agentes de pesquisa terminam.

Now the pure key-repeat engine.

Bash GPU sink entry points, test override, exports, debug tail
IN
grep -n "@override" lib/src/rendering/gpu/gpu_raster_sink.dart | head; grep -n "void fillDeviceRect\|void fillDeviceRRect\|void drawDevicePath\|void drawDeviceImage\|void drawDeviceGlyphRun\|void beginLayer" lib/src/rendering/gpu/gpu_raster_sink.dart; echo ---; sed -n '580,650p' test/rendering/replay/display_list_player_test.dart; echo ---; grep -n "graphics" lib/dart_ui.dart | head -15; echo ---; sed -n '320,345p' lib/src/graphics/display_list_debug.dart

OUT
222:  @override
295:  @override
318:  @override
602:  @override
734:  @override
796:  @override
913:  @override
223:  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) {
296:  void fillDeviceRRect(
319:  void drawDevicePath(
603:  void drawDeviceImage(
735:  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint) {
914:  void drawDeviceGlyphRun(
---
          DisplayListReader(list),
          DisplayListResources(list),
          deviceBounds: _surface,
        );
      }
      expect(player.state.saveDepth, 0);
      expect(player.state.stackGrowths, 0);
      expect(
        sink.allOf<FillRectCall>().map((c) => c.deviceRect).toSet(),
        <Rect>{const Rect.fromLTRB(0, 0, 3, 3)},
      );
    });
  });
}

/// Answers with a style the encoder cannot write, which is the only way to
/// reach the player's "unknown paint style" branch without a corrupt buffer.
final class _PaintStyleOverride implements ReplayResources {
  _PaintStyleOverride(this._inner, this._style);

  final ReplayResources _inner;
  final int _style;

  @override
  int paintStyle(int id) => _style;

  @override
  int paintColor(int id) => _inner.paintColor(id);

  @override
  double paintStrokeWidth(int id) => _inner.paintStrokeWidth(id);

  @override
  int paintBlendMode(int id) => _inner.paintBlendMode(id);

  @override
  bool paintAntiAlias(int id) => _inner.paintAntiAlias(id);

  @override
  int paintFillRule(int id) => _inner.paintFillRule(id);

  @override
  Object pathAt(int id) => _inner.pathAt(id);

  @override
  Object imageAt(int id) => _inner.imageAt(id);

  @override
  Object fontAt(int id) => _inner.fontAt(id);
}
---
15:///   graphics    <- ffi, foundation, geometry
18:///   text        <- foundation, geometry, graphics
19:///   rendering   <- foundation, geometry, graphics, text
20:///   layout      <- foundation, geometry, graphics, rendering, text
68:export 'src/graphics/color.dart';
69:export 'src/graphics/display_list.dart';
70:export 'src/graphics/display_list_debug.dart';
71:export 'src/graphics/display_list_geometry.dart';
72:export 'src/graphics/display_list_opcodes.dart';
73:export 'src/graphics/display_list_reader.dart';
74:export 'src/graphics/image/decoded_image.dart';
75:export 'src/graphics/image/image_errors.dart';
76:export 'src/graphics/image/inflate.dart';
77:export 'src/graphics/image/png.dart';
78:export 'src/graphics/image/raster_codec.dart';
---
      // shows up in the debug path rather than silently dropping a command.
      throw DisplayListFormatException(
        'no debug expansion for opcode ${reader.opcode}',
        wordOffset: reader.headerOffset,
      );
  }
}

/// One line per command, preceded by the resource tables.
///
/// Meant to be pasted into a bug report or diffed as a golden.
String dumpDisplayList(DisplayList list) {
  final buffer = StringBuffer()
    ..writeln('DisplayList: ${list.commandCount} commands, '
        '${list.opLength} words, ${list.floatLength} floats')
    ..writeln('paints: ${list.paintCount}, paths: ${list.pathCount}, '
        'images: ${list.imageCount}');
  for (var id = 0; id < list.paintCount; id++) {
    buffer.writeln('  paint $id: '
        'color 0x${list.paintColor(id).toRadixString(16).padLeft(8, '0')}, '
        'style ${list.paintStyle(id)}, '
        'strokeWidth ${list.paintStrokeWidth(id)}, '
        'blend ${list.paintBlendMode(id)}, '
        'aa ${list.paintAntiAlias(id)}');
  }
  final commands = expandDisplayList(list);
Write C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_key_repeat.dart
109 lines
/// Key auto-repeat for Wayland, where the client does the repeating.
///
/// X11 servers and Win32 repeat keys for you; a Wayland compositor does not.
/// It tells the client the user's setting once - `wl_keyboard.repeat_info`
/// with a rate in characters per second and an initial delay in milliseconds -
/// and every client synthesises its own repeats. This class is that machine,
/// kept pure: time is an argument, never a clock, so a test can play a whole
/// repeat run in microseconds and assert the exact cadence.
///
/// One key repeats at a time, which is exactly xkb's model: pressing a second
/// repeating key replaces the first (type `aaaa`, press `s` while holding `a`,
/// and it is `s` that repeats). Releasing a key that is not the repeating one
/// changes nothing.
library;

/// The repeating state machine. The owner feeds it presses, releases, focus
/// changes and the current time; it answers with how many repeats are due.
final class WaylandKeyRepeat {
  /// Repeats per second, from `repeat_info`. Zero disables repeat, which is
  /// what the protocol means by a zero rate.
  int _rateHz = 25;

  /// Milliseconds a key must stay down before the first repeat.
  int _delayMilliseconds = 400;

  int get rateHz => _rateHz;
  int get delayMilliseconds => _delayMilliseconds;

  /// The evdev keycode currently armed, or -1.
  int _armedKey = -1;

  /// The wl_surface the armed press was delivered to; repeats carry it so a
  /// focus change between press and repeat cannot leak keys elsewhere.
  int _armedSurfaceId = 0;

  /// When the *next* repeat is due, in the caller's clock.
  int _nextDueMilliseconds = 0;

  bool get isArmed => _armedKey >= 0;
  int get armedKey => _armedKey;
  int get armedSurfaceId => _armedSurfaceId;

  /// Applies `wl_keyboard.repeat_info`. A change takes effect from the next
  /// press; re-arming mid-hold for a settings change is not worth the state.
  void configure({required int rateHz, required int delayMilliseconds}) {
    _rateHz = rateHz < 0 ? 0 : rateHz;
    _delayMilliseconds = delayMilliseconds < 0 ? 0 : delayMilliseconds;
  }

  /// Arms [key] pressed at [nowMilliseconds] on [surfaceId], replacing any
  /// previously armed key. A disabled rate arms nothing.
  void onKeyDown(int key, int surfaceId, int nowMilliseconds) {
    if (_rateHz <= 0) {
      cancel();
      return;
    }
    _armedKey = key;
    _armedSurfaceId = surfaceId;
    _nextDueMilliseconds = nowMilliseconds + _delayMilliseconds;
  }

  /// Disarms when [key] is the repeating key. Any other release is one of the
  /// keys the user is *also* holding, and must not stop the repeat.
  void onKeyUp(int key) {
    if (_armedKey == key) cancel();
  }

  /// Disarms unconditionally - keyboard focus left, the window died, the
  /// connection dropped. A repeat delivered after any of those would be the
  /// classic stuck-key bug.
  void cancel() {
    _armedKey = -1;
    _armedSurfaceId = 0;
    _nextDueMilliseconds = 0;
  }

  /// Milliseconds until the next repeat is due, or null when disarmed. Zero
  /// when overdue. This is what the event pump clamps its poll timeout to.
  int? millisecondsUntilDue(int nowMilliseconds) {
    if (!isArmed) return null;
    final remaining = _nextDueMilliseconds - nowMilliseconds;
    return remaining < 0 ? 0 : remaining;
  }

  /// How many repeats have become due by [nowMilliseconds], advancing the
  /// schedule past them. At most [maximumBurst], so a laptop waking from
  /// sleep types a bounded burst instead of a screenful.
  int takeDueRepeats(int nowMilliseconds, {int maximumBurst = 8}) {
    if (!isArmed || _rateHz <= 0) return 0;
    if (nowMilliseconds < _nextDueMilliseconds) return 0;
    final intervalMilliseconds = 1000 ~/ _rateHz == 0 ? 1 : 1000 ~/ _rateHz;
    var due = 1 + (nowMilliseconds - _nextDueMilliseconds) ~/ intervalMilliseconds;
    if (due > maximumBurst) {
      due = maximumBurst;
      // Skip the backlog entirely: repeats older than the burst window are
      // lost time, not owed keystrokes.
      _nextDueMilliseconds = nowMilliseconds + intervalMilliseconds;
    } else {
      _nextDueMilliseconds += due * intervalMilliseconds;
    }
    return due;
  }

  @override
  String toString() => 'WaylandKeyRepeat(rate: ${_rateHz}Hz, '
      'delay: ${_delayMilliseconds}ms, '
      'armed: ${isArmed ? 'key $_armedKey' : 'no'})';
}
Inventário completo. Escrevendo o formato — primeiro o tipo público Gradient.

Write C:\MyDartProjects\dart_ui\lib\src\graphics\gradient.dart
277 lines
/// Gradient paints: the value types a display-list producer describes a
/// linear or radial ramp with.
///
/// ## Where a gradient lives in the wire format
///
/// A paint record stays two words and one float - see `DisplayList.addPaint` -
/// and a gradient does not widen it. The flag word gains a *shader kind* in
/// bits 4..5 and, for a non-solid kind, a gradient id in bits 16..31 that
/// indexes the display list's gradient table. The table itself holds these
/// objects, interned by value exactly as paints are: two draws describing the
/// same ramp share one id, and the solid-colour path pays one null check and
/// nothing else.
///
/// Objects rather than flat arrays, deliberately: paints are flat because the
/// encoder writes thousands per frame on the hottest path there is, while a
/// frame has a handful of gradients and each is interned once. This is the
/// same trade the path, image and font tables already made.
///
/// ## Coordinate space
///
/// Gradient geometry is written in the same coordinate space as the command
/// that uses the paint - the space `drawRect` coordinates are in before the
/// replay transform. The player maps it to device space with the transform in
/// force at each draw, so a gradient translated or scaled with its shape
/// stays glued to it. Under skew or non-uniform scale a radial gradient's
/// circle is approximated by scaling its radius with the average axis length,
/// the same class of approximation the replay layer documents for rounded
/// rectangle radii.
///
/// ## Interpolation, stated once for every backend
///
/// Colours are interpolated **channel-wise on the straight (non-premultiplied)
/// sRGB values**, then premultiplied at the edge that needs it. That is what
/// the CPU shader computes, what a GPU `mix()` of straight colours computes,
/// and what Direct2D's `D2D1_GAMMA_2_2` collection specifies - the encoded
/// values are interpolated as they are, with no linearisation. With opaque
/// stops every backend agrees to rounding; with translucent stops Direct2D
/// may interpolate premultiplied and differ in the low bits, which the
/// differential tolerance absorbs and this comment records.
library;

import 'dart:typed_data';

/// How a gradient continues outside the 0..1 range of its stops.
enum GradientSpread {
  /// The edge stop extends forever. `D2D1_EXTEND_MODE_CLAMP`.
  pad,

  /// The ramp tiles: t wraps modulo 1. `D2D1_EXTEND_MODE_WRAP`.
  repeat,

  /// The ramp mirrors on every repetition. `D2D1_EXTEND_MODE_MIRROR`.
  reflect,
}

/// Shader kind values stored in bits 4..5 of a paint's flag word.
const int shaderKindSolid = 0;
const int shaderKindLinear = 1;
const int shaderKindRadial = 2;

/// The most gradients one display list can intern: the paint flag word gives
/// the id 16 bits. A frame that reaches this is generating gradients in a
/// loop, and the error names the limit rather than wrapping the id.
const int kMaxGradientsPerList = 0x10000;

/// One colour stop: an offset in 0..1 and a straight-alpha `0xAARRGGBB`.
final class GradientStop {
  const GradientStop(this.offset, this.colorArgb);

  final double offset;
  final int colorArgb;

  @override
  bool operator ==(Object other) =>
      other is GradientStop &&
      other.offset == offset &&
      other.colorArgb == colorArgb;

  @override
  int get hashCode => Object.hash(offset, colorArgb);

  @override
  String toString() =>
      '($offset: 0x${colorArgb.toRadixString(16).padLeft(8, '0')})';
}

/// A gradient paint description, interned by value in the display list.
///
/// Immutable; the stop lists are copied into typed arrays at construction so
/// a renderer can read them without touching caller-owned lists, and so the
/// value equality the intern table relies on is over exactly the stored
/// (float32-narrowed) values - the same rule paint dedup follows.
///
/// When a paint carries a gradient, the paint's own colour is **not
/// sampled**: the stop colours carry the alpha. This is stated here once and
/// every backend follows it, which is what keeps a differential test able to
/// compare them.
sealed class Gradient {
  Gradient._(List<GradientStop> stops, this.spread)
      : stopOffsets = Float32List(stops.length),
        stopColors = Uint32List(stops.length) {
    if (stops.length < 2) {
      throw ArgumentError.value(
          stops.length, 'stops', 'a gradient needs at least two stops');
    }
    var previous = double.negativeInfinity;
    for (var i = 0; i < stops.length; i++) {
      final double offset = stops[i].offset;
      if (offset.isNaN || offset < 0 || offset > 1) {
        throw ArgumentError.value(
            offset, 'stops', 'stop offsets must be in 0..1');
      }
      if (offset < previous) {
        throw ArgumentError.value(
            offset, 'stops', 'stop offsets must be non-decreasing');
      }
      previous = offset;
      stopOffsets[i] = offset;
      stopColors[i] = stops[i].colorArgb & 0xFFFFFFFF;
    }
  }

  final GradientSpread spread;

  /// Stop offsets, narrowed to float32 - the stored truth equality runs over.
  final Float32List stopOffsets;

  /// Straight-alpha `0xAARRGGBB` per stop.
  final Uint32List stopColors;

  int get stopCount => stopOffsets.length;

  /// The wire value for bits 4..5 of the paint flag word.
  int get shaderKind;

  /// The geometry as the renderers consume it; length and meaning depend on
  /// the subtype. Exposed so replay code reads one shape instead of two.
  List<double> get geometry;

  bool _sameStops(Gradient other) {
    if (other.spread != spread) return false;
    if (other.stopOffsets.length != stopOffsets.length) return false;
    for (var i = 0; i < stopOffsets.length; i++) {
      if (other.stopOffsets[i] != stopOffsets[i]) return false;
      if (other.stopColors[i] != stopColors[i]) return false;
    }
    return true;
  }

  int _stopsHash() {
    var hash = spread.index;
    for (var i = 0; i < stopOffsets.length; i++) {
      hash = Object.hash(hash, stopOffsets[i], stopColors[i]);
    }
    return hash;
  }

  String _describeStops() {
    final buffer = StringBuffer();
    for (var i = 0; i < stopOffsets.length; i++) {
      if (i > 0) buffer.write(', ');
      buffer.write(GradientStop(stopOffsets[i], stopColors[i]));
    }
    return buffer.toString();
  }
}

/// A linear ramp from ([startX], [startY]) to ([endX], [endY]).
final class LinearGradient extends Gradient {
  LinearGradient({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required List<GradientStop> stops,
    GradientSpread spread = GradientSpread.pad,
  })  : _geometry = Float32List(4),
        super._(stops, spread) {
    _geometry[0] = startX;
    _geometry[1] = startY;
    _geometry[2] = endX;
    _geometry[3] = endY;
  }

  final Float32List _geometry;

  double get startX => _geometry[0];
  double get startY => _geometry[1];
  double get endX => _geometry[2];
  double get endY => _geometry[3];

  @override
  int get shaderKind => shaderKindLinear;

  @override
  List<double> get geometry => _geometry;

  @override
  bool operator ==(Object other) =>
      other is LinearGradient &&
      other._geometry[0] == _geometry[0] &&
      other._geometry[1] == _geometry[1] &&
      other._geometry[2] == _geometry[2] &&
      other._geometry[3] == _geometry[3] &&
      other._sameStops(this);

  @override
  int get hashCode => Object.hash(
      LinearGradient, startX, startY, endX, endY, _stopsHash());

  @override
  String toString() => 'LinearGradient(($startX, $startY) -> ($endX, $endY), '
      '${spread.name}, [${_describeStops()}])';
}

/// A radial ramp out of ([centerX], [centerY]) to [radius].
///
/// [focusX]/[focusY] optionally place the t = 0 point off-centre, the
/// `gradientOriginOffset` of Direct2D and the focal point of an SVG radial
/// gradient. They default to the centre.
final class RadialGradient extends Gradient {
  RadialGradient({
    required double centerX,
    required double centerY,
    required double radius,
    double? focusX,
    double? focusY,
    required List<GradientStop> stops,
    GradientSpread spread = GradientSpread.pad,
  })  : _geometry = Float32List(5),
        super._(stops, spread) {
    if (radius.isNaN || radius <= 0) {
      throw ArgumentError.value(radius, 'radius', 'must be finite and > 0');
    }
    _geometry[0] = centerX;
    _geometry[1] = centerY;
    _geometry[2] = radius;
    _geometry[3] = focusX ?? centerX;
    _geometry[4] = focusY ?? centerY;
  }

  final Float32List _geometry;

  double get centerX => _geometry[0];
  double get centerY => _geometry[1];
  double get radius => _geometry[2];
  double get focusX => _geometry[3];
  double get focusY => _geometry[4];

  bool get hasFocus => focusX != centerX || focusY != centerY;

  @override
  int get shaderKind => shaderKindRadial;

  @override
  List<double> get geometry => _geometry;

  @override
  bool operator ==(Object other) =>
      other is RadialGradient &&
      other._geometry[0] == _geometry[0] &&
      other._geometry[1] == _geometry[1] &&
      other._geometry[2] == _geometry[2] &&
      other._geometry[3] == _geometry[3] &&
      other._geometry[4] == _geometry[4] &&
      other._sameStops(this);

  @override
  int get hashCode => Object.hash(
      RadialGradient, centerX, centerY, radius, focusX, focusY, _stopsHash());

  @override
  String toString() => 'RadialGradient(($centerX, $centerY) r $radius'
      '${hasFocus ? ', focus ($focusX, $focusY)' : ''}, '
      '${spread.name}, [${_describeStops()}])';
}
Agora o DisplayList: parâmetro gradient no addPaint, tabela interna e acessores.

Edit C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart
Added 1 line
Edit C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart
Added 7 lines
Edit C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart
Added 2 lines
Edit C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart
Added 2 lines
Relatório Técnico: Impeller (Flutter) vs. Vello clássico
PARTE A — Impeller
C:\MyDartProjects\dart_ui\referencias\engine-main\impeller

A.1 Arquitetura em camadas (HAL → Renderer → Entity → DisplayList)
O README (C:\MyDartProjects\dart_ui\referencias\engine-main\impeller\README.md, linhas 31–118) define a hierarquia estrita:

Camada	Diretório	Responsabilidade
HAL / backends	impeller/renderer/backend/{metal,vulkan,gles}	Implementação por API. Verificado: só existem esses três (renderer/backend/).
Renderer (backend-agnóstico)	impeller/renderer	RenderPass, ComputePass, Pipeline, HostBuffer, Capabilities.
Entity (framework 2D)	impeller/entity	Entity, Contents, Geometry, otimização/reescrita de passes.
DisplayList	impeller/display_list	Substituiu o antigo //impeller/aiks; implementa flutter::DisplayListDispatcher. Não existe mais diretório aiks/ — a documentação docs/blending.md ainda cita "camada Aiks", mas é texto legado.
Typographer	impeller/typographer	Atlas de glifos; não faz layout nem shaping.
Compiler	impeller/compiler	impellerc offline.
Ponto arquitetural central: separação Geometry × ColorSourceContents. Documentado em entity/contents/color_source_contents.h (linhas 18–34): "Color sources are geometry-agnostic Contents capable of shading any area defined by an impeller::Geometry". Isso dá N geometrias × M color sources sem explosão combinatória de código (mas sim de PSOs — ver ContentContextOptions).

Pipeline de shaders totalmente offline (README linhas 120–148): GLSL 4.60 → SPIR-V → transpile (MSL / SPIR-V Vulkan / GLSL ES 1.00) → blob binário embutido no executável + reflexão gerando C++ (structs com padding/alinhamento corretos). Zero compilação e zero reflexão de shader em runtime.

A.2 Como Impeller preenche paths (o achado mais importante)
Não usa libtess2 no caminho de renderização. tessellator_libtess.cc / .h existem, mas o grep por TessellatorLibtess retorna apenas: tessellator/BUILD.gn, tessellator/c/tessellator.cc (API C standalone), geometry/geometry_benchmarks.cc, tessellator_unittests.cc. Nenhuma referência em entity/ ou display_list/.

O caminho real é stencil-then-cover:

entity/geometry/fill_path_geometry.cc:46 chama sempre Tessellator::TessellateConvex(), mesmo para paths côncavos/auto-intersectantes. Isso apenas converte cada contorno em polyline (flattening por tolerância derivada de Matrix::GetMaxBasisLengthXY) e emite um triangle fan (ou triangle strip com primitive restart, se o backend não suportar fan) — ver tessellator/tessellator.cc:40-93 (FanVertexWriter / StripVertexWriter). Não há tessellação real de polígono.

fill_path_geometry.cc:60-75 (GetResultMode) decide: se path.IsConvex() → Mode::kNormal (desenho direto, 1 draw call). Senão → Mode::kNonZero ou Mode::kEvenOdd conforme FillType.

O consumo está em entity/contents/color_source_contents.h:126-232 (DrawGeometry<>), que é o coração do renderer:

Passe de stencil: mesma geometria em fan/strip, blend_mode = kDestination (não escreve cor), stencil_mode = kStencilNonZeroFill ou kStencilEvenOddFill, usando GetClipPipeline (clip.vert/clip.frag).
Passe de cover: RectGeometry do bounding box (GetGeometry()->GetCoverage({})), com stencil_mode = kCoverCompare, que também zera o stencil ao passar (documentado em entity/contents/content_context.h:291-297).
Ou seja: paths convexos = 1 draw; paths gerais = 2 draws (stencil + cover retangular). O custo de CPU é apenas flattening de curvas, não tessellação de polígono.

entity/geometry/geometry.h:21-41 define os quatro modos: kNormal, kNonZero, kEvenOdd, kPreventOverdraw.

A.3 Antialiasing
MSAA 4x é o mecanismo principal. Não há AA analítico por cobertura para paths gerais.

renderer/render_target.cc:401 e :492 — CreateOffscreenMSAA fixa sample_count = SampleCount::kCount4 tanto para a cor quanto para o depth/stencil.
display_list/canvas.cc:126-133 — o target raiz é MSAA quando SupportsOffscreenMSAA().
renderer/capabilities.h:18-25 — dois booleans: SupportsOffscreenMSAA() e SupportsImplicitResolvingMSAA() (resolve implícito no tile memory, típico de mobile — evita store/load do buffer MSAA).
renderer/capabilities.h:78-84 — SupportsDeviceTransientTextures() ("memoryless"): "This feature is especially useful for MSAA and stencils". Em tilers Metal/Vulkan o attachment MSAA e o stencil nunca chegam à DRAM.
entity/contents/content_context.cc:233,281,285,330 — variantes de pipeline pré-construídas com sample_count = kCount4.
Truques complementares (não são AA geométrico):

entity/geometry/geometry.h:94-97 — ComputeStrokeAlphaCoverage(): strokes com espessura sub-pixel são desenhados com largura mínima kMinStrokeSize = 1.0f (geometry.h:19) e o alpha é atenuado para simular a cobertura fracionária. Aplicado em stroke_path_geometry.cc:573,588.
entity/shaders/rrect_blur.frag + solid_rrect_blur_contents.cc — round-rects borrados são analíticos, sem geometria.
Consequência do MSAA 4x: qualidade inferior à cobertura analítica em bordas quase-horizontais/verticais e em texto vetorizado, mas custo previsível e resolve gratuito em GPUs tile-based.

A.4 Strokes — geração de geometria na CPU
Toda a expansão de stroke é feita na CPU, em entity/geometry/stroke_path_geometry.cc:

CreateSolidStrokeVertices() (linha 488) recebe a polyline já achatada e emite triângulos.
Joins completos: Join::kBevel, kMiter, kRound (linhas 504–508); caps: Cap::kButt, kRound, kSquare (linhas 515–519).
Miter limit escalado: scaled_miter_limit = stroke_width * miter_limit * 0.5f (linha 532); ao exceder, degrada para bevel (linhas 428–430).
Flattening de curvas usa geometry/wangs_formula.h (fórmula de Wang para número de subdivisões).
O problema do auto-overlap (stroke que se cruza consigo mesmo, gerando dupla aplicação de alpha) é resolvido no stencil, não na geometria: stroke_path_geometry.cc:618,647,651 retornam Mode::kPreventOverdraw, que mapeia para StencilMode::kOverdrawPreventionIncrement — incrementa o stencil se zero, descarta fragmentos onde já é não-zero (content_context.h:307-325). O comentário no código é explícito: "this is done for rendering correctness, not performance... we don't adjust the geometry to prevent self-intersection".

A.5 Clipping
entity/contents/clip_contents.cc. Modelo híbrido stencil + depth:

Passe de stencil da forma do clip: kStencilNonZeroFill / kStencilEvenOddFill (linhas 95, 100), ou kOverdrawPreventionIncrement para clips de stroke (linha 106).
Passe de escrita de depth (depth_write_enabled = true, linha 120): kIntersect usa kCoverCompareInverted (marca a área fora do clip), kDifference usa kCoverCompare (linhas 124–132).
O clip é assim convertido em profundidade: cada entidade recebe um clip_depth (Entity::GetShaderClipDepth), e o depth test descarta o que está fora. Ver clip_contents.cc:19-23.
RenderClipRestore (linha 152) usa kOverdrawPreventionRestore para restaurar o stencil.
Gerenciamento da pilha: entity/entity_pass_clip_stack.cc.
Esse design permite reordenação de draws por profundidade (entity/draw_order_resolver.cc): entidades opacas são coagidas para BlendMode::kSource e escrevem depth (color_source_contents.h:222-225), possibilitando front-to-back para rejeição precoce.

A.6 Blending
docs/blending.md divide em dois grupos:

Pipeline blends (linhas 39–64) — os 13 Porter-Duff (Clear, Source, SourceOver, Xor, Plus, Modulate, ...). Custam zero: são o blend state do raster pipeline. Requerem que todas as cores de saída sejam premultiplicadas (linhas 28–38) — é uma invariante de todo shader de Entity.

Advanced blends (linhas 66–105) — os 15 blends W3C (Overlay, Multiply, HardLight, Hue, Saturation, Luminosity, ...). Implementados por fragment shader. Custo documentado (linhas 80–87): (a) o render pass corrente termina para poder amostrar o backdrop, (b) amostra-se uma textura potencialmente grande, (c) aloca-se textura intermediária + blit de volta.

Framebuffer fetch é a otimização decisiva: renderer/capabilities.h:36-53 define SupportsFramebufferFetch() com exemplo de subpassInput/subpassLoad. Quando disponível, o advanced blend vira um shader in-pass sem quebrar o render pass — entity/shaders/blending/framebuffer_blend.frag + entity/contents/framebuffer_blend_contents.cc. Usado em:

entity/contents/content_context.cc:361
display_list/canvas.cc:1076, 1262, 1488
entity/contents/filters/blend_filter_contents.cc:1006
Disponibilidade real:

GLES: extensão GL_EXT_shader_framebuffer_fetch (renderer/backend/gles/capabilities_gles.cc:12-14, 120) — presente em PowerVR/Adreno/Mali, ausente em muitos desktops.
Vulkan: CapabilitiesVK::SupportsFramebufferFetch() (renderer/backend/vulkan/capabilities_vk.cc:628) via input attachments de subpass.
Metal: nativo ([[color(0)]]), em renderer/backend/metal/context_mtl.mm.
Shaders relevantes: entity/shaders/blending/{advanced_blend.frag, porter_duff_blend.frag, blend_select.glsl, framebuffer_blend.frag, vertices_uber.frag}.

A.7 Texto — atlas de glifos rasterizados
impeller/typographer. Impeller não faz layout nem shaping (README linhas 89–92); recebe glyph runs já moldados.

typographer/glyph_atlas.h:68-80 — GlyphAtlas com Type::{kAlphaBitmap, kColorBitmap}. O alpha atlas é 8-bit, backing red-channel ou gray dependendo do backend (Capabilities::GetDefaultGlyphAtlasFormat(), renderer/capabilities.h:108-112).
typographer/rectangle_packer.h — empacotamento de retângulos no atlas.
typographer/lazy_glyph_atlas.h — atlas construído sob demanda por frame.
Único backend: typographer/backends/skia (usa SkFont/Skia para rasterizar os glifos em CPU).
Renderização: entity/contents/text_contents.cc + entity/shaders/glyph_atlas.{vert,frag}. Detalhes verificados:
text_contents.cc:121 — frag_info.is_color_glyph (COLR/CBDT).
text_contents.cc:127-140 — se a transform é apenas translate+scale, a escala é propagada ao atlas (glifos rasterizados na escala exata); sem mipmaps ("glyphs are generated at exact scales").
text_contents.cc:178, 222 — TextFrame::RoundScaledFontSize() e ComputeSubpixelPosition(): quantização de escala + posicionamento subpixel, chaveando entradas distintas no atlas.
Em transforms arbitrários (rotação), cai no caminho de amostragem do atlas com filtragem — perde nitidez.
A.8 Compute shaders
Impeller expõe ComputePass (renderer/compute_pass.h) e Capabilities::SupportsCompute(), mas o grep em entity/ e display_list/ retorna zero usos fora de mocks de teste. Todo o pipeline 2D é raster clássico (vertex/fragment). Compute existe apenas como facilidade do renderer de baixo nível.

A.9 Requisitos mínimos de API gráfica — Impeller
Do docs/android.md e docs/glossary.md:

Backend	Mínimo	Fonte
Vulkan	1.1 + Android API 29+ + VK_ANDROID_external_memory_android_hardware_buffer	docs/android.md:37-68; docs/glossary.md ("baseline de Vulkan 1.1")
Metal	iOS/macOS (default no iOS)	README.md:179
OpenGL ES	2.0 (fallback)	docs/android.md:8; docs/ubo_gles2.md ("How Impeller Works Around The Lack of Uniform Buffers in OpenGL ES 2.0")
Features realmente exigidas (piso duro):

Stencil buffer de 8 bits com ops separadas front/back e CompareFunction — indispensável para fills não-convexos, clips e overdraw prevention.
Depth buffer — para clip-as-depth e reordenação de draws.
Blend state configurável (Porter-Duff) — universal desde GL ES 2.0.
Nada mais é obrigatório. Tudo o resto é Capabilities com fallback: SupportsSSBO, SupportsFramebufferFetch, SupportsCompute, SupportsTriangleFan, SupportsPrimitiveRestart, SupportsOffscreenMSAA, SupportsDeviceTransientTextures, SupportsTextureToTextureBlits, SupportsDecalSamplerAddressMode, SupportsReadFromResolve (renderer/capabilities.h:18-117).
Sem MSAA (SupportsOffscreenMSAA() == false), Impeller ainda renderiza — apenas com bordas serrilhadas (display_list/canvas.cc:126). Sem framebuffer fetch, advanced blends ficam caros mas funcionam. Sem UBO (GLES 2.0), há emulação documentada. Isso é o oposto de Vello: o piso é GL ES 2.0 + stencil, ou seja, praticamente qualquer GPU dos últimos 15 anos.

PARTE B — Vello clássico
C:\MyDartProjects\dart_ui\referencias\vello-main (crates vello, vello_encoding, vello_shaders)

B.1 Filosofia e camadas
README.md:55-59: "Vello's selling point is that it gets better performance... In traditional PostScript-style renderers, some steps like sorting and clipping either need to be handled in the CPU or done through the use of intermediary textures. Vello avoids this by using prefix-sum algorithms to parallelize work that usually needs to happen in sequence... This means that Vello needs a GPU with support for compute shaders to run."

doc/ARCHITECTURE.md:69-78 — três camadas intermediárias:

Scene → Encoding (buffers linearizados de comandos comprimidos).
Encoding → Recording (array de Command: upload buffer, dispatch, download...).
Recording → WgpuEngine (único backend implementado; outros poderiam consumir Recording).
B.2 O encoding da cena
vello_encoding/src/encoding.rs:26-53 — a Encoding é composta por streams paralelos, não uma árvore:


pub struct Encoding {
    pub path_tags: Vec<PathTag>,      // tags de segmento (moveto/lineto/quadto/curveto, flags)
    pub path_data: Vec<u32>,          // coordenadas cruas (u32 p/ comparação bitwise)
    pub draw_tags: Vec<DrawTag>,      // tipo do objeto de desenho
    pub draw_data: Vec<u32>,          // payload (cor, gradiente, imagem, blur rrect...)
    pub transforms: Vec<Transform>,
    pub styles: Vec<Style>,           // fill rule / stroke
    pub resources: Resources,         // imagens/glifos late-bound
    pub n_paths, n_path_segments, n_clips, n_open_clips: u32,
}
Módulos de suporte: binning.rs, clip.rs, config.rs, draw.rs, glyph_cache.rs, image_cache.rs, mask.rs, monoid.rs, path.rs, ramp_cache.rs, resolve.rs (vello_encoding/src/lib.rs:32-46).

O formato de path é descrito em doc/pathseg.md. A chave é que os streams são monoid-friendly: um prefix-sum sobre path_tags recupera todos os offsets absolutos (posição no path_data, índice de transform, índice de style) sem dependência sequencial.

Encoding CPU-side é multi-threaded-friendly (motivo do abandono da API Piet, doc/roadmap_2023.md, parágrafo 3).

B.3 Os estágios compute WGSL
Diretório vello_shaders/shader/. Ordem de dispatch autoritativa: vello/src/render.rs:250-500. Bindings: vello/src/shaders.rs:102-247.

#	Estágio	Arquivo	O que faz
1	pathtag_reduce	vello_shaders/shader/pathtag_reduce.wgsl	Primeira metade do prefix-sum sobre o stream de path tags. Cada workgroup (256 threads) reduz seu bloco a um TagMonoid (contadores de segmentos, offsets de path/transform/style) e grava em reduced.
1b	pathtag_reduce2 / pathtag_scan1	pathtag_reduce2.wgsl, pathtag_scan1.wgsl	Nível extra para cenas grandes (scan de 3 níveis). Ativado por wg_counts.use_large_path_scan (render.rs:257). Sem fallback CPU (CpuShaderType::Skipped).
2	pathtag_scan	pathtag_scan.wgsl	Segunda metade: combina os monoides reduzidos com o scan local para produzir o TagMonoid absoluto de cada tag. Duas variantes (small/large) via #ifdef — ver vello_shaders/shader/permutations.
3	bbox_clear	bbox_clear.wgsl	Inicializa path_bboxes com bbox invertida (0x7fffffff / -0x80000000) para posterior atomicMin/atomicMax.
4	flatten	flatten.wgsl	O estágio mais denso. Lê cada segmento (com o TagMonoid do scan), aplica a transform, e achata curvas em linhas (LineSoup). Para strokes, calcula a curva paralela (offset curve) via espirais de Euler, gerando joins e caps — flatten_euler() (linha 328), flatten_arc() (linha 494), EulerParams/EulerSeg (linhas 65–76), aproximações espc_int_approx/espc_int_inv_approx (250, 264) com três modos de robustez numérica (ESPC_ROBUST_NORMAL/LOW_K1/LOW_DIST, linhas 321–323). Também acumula bbox por path via atomics. Resultado: strokes viram fills; o resto do pipeline só conhece paths preenchidos.
5	draw_reduce / draw_leaf	draw_reduce.wgsl, draw_leaf.wgsl	Prefix-sum sobre draw tags → DrawMonoid (offsets de path e de info por objeto de desenho). draw_leaf decodifica os objetos e escreve info_bin_data + clip_inp.
6	clip_reduce / clip_leaf	clip_reduce.wgsl, clip_leaf.wgsl	Resolvem a pilha de clips na GPU usando o stack monoid (Bic = bicyclic semigroup, ClipEl). Produzem bboxes de clip intersectadas. É o que permite "blends com aninhamento quase arbitrário" (doc/roadmap_2023.md).
7	binning	binning.wgsl	Atribui cada objeto de desenho aos bins (blocos de 16×16 tiles) que sua bbox toca, via bitmaps em workgroup memory (sh_bitmaps: array<array<atomic<u32>, N_TILE>, N_SLICE>). Aloca ranges em bin_data por bump allocator. É a etapa de "sorting" que normalmente exigiria CPU.
8	tile_alloc	tile_alloc.wgsl	Aloca (e zera) o retângulo de Tile para cada path a partir de sua bbox, com bump allocation em bump.tile.
9	path_count_setup → path_count	path_count_setup.wgsl, path_count.wgsl	_setup roda com workgroup_size(1) e escreve IndirectCount a partir de bump.lines; se bump.failed != 0 zera o dispatch. path_count (indirect, render.rs:452) conta quantos segmentos caem em cada tile, acumulando backdrop e segment_count com atomics.
10	backdrop_dyn	backdrop_dyn.wgsl	Prefix-sum horizontal do winding "backdrop" ao longo de cada linha de tiles do path — dá o winding number do canto superior-esquerdo de cada tile.
11	coarse	coarse.wgsl	Rasterização grosseira: percorre os objetos de cada bin e monta a PTCL (per-tile command list) por tile — comandos CmdFill, CmdColor, CmdLinGrad, CmdImage, CmdBeginClip/CmdEndClip, com CmdJump para encadear chunks (shader/shared/ptcl.wgsl). Assume WG_SIZE == N_TILE (comentário linha 47).
12	path_tiling_setup → path_tiling	path_tiling_setup.wgsl, path_tiling.wgsl	_setup monta o dispatch indireto; path_tiling (indirect, render.rs:490) escreve os PathSegment finais recortados por tile no segments_buf.
13	fine	fine.wgsl	Rasterização fina: um workgroup por tile 16×16, interpreta a PTCL, calcula cobertura, aplica gradientes/imagens/blends, escreve na imagem de saída via Image(Rgba8) storage texture. Mantém uma blend stack para clips/layers aninhados, com spill para blend_spill: array<u32> quando estoura.
Estágios sem equivalente CPU: fine_* (CpuShaderType::Missing, vello/src/shaders.rs:225,235,244), confirmando doc/ARCHITECTURE.md:86 ("Fine rasterization doesn't work in CPU yet").

B.4 Antialiasing no Vello
Três modos, compilados como permutações do fine.wgsl (vello_shaders/shader/permutations):

Area (AaConfig::Area, vello/src/lib.rs:176-184): "the alpha value for a pixel is computed from integrating the winding number over its square area". Cobertura analítica exata. Melhor performance. Limitação documentada: "can result in conflation artifacts" quando o winding number não é 0 ou 1 (bordas adjacentes de shapes distintos não somam corretamente).
Msaa8 / Msaa16 (lib.rs:185-192): multisampling em software dentro do compute shader. fine.wgsl:79-146 mantém winding numbers empacotados em workgroup memory (sh_winding_y, sh_winding, sh_samples — arrays de atomic<u32> com winding number parity de 1 bit por amostra). A cobertura é countOneBits(xored8 & 0xC0C0C0C0u) * 0.125 para 8x (linha 468) e * 0.0625 com máscara 0xF0F0F0F0u para 16x (linha 495). Usa uma LUT de máscaras num storage buffer extra (shaders.rs:216-217). Mais lento, mas resolve conflation.
AaSupport::area_only() é descrito como "should be the default choice for most users" (lib.rs:224-227). Cada modo habilitado = mais shaders compilados no startup (lib.rs:215).

B.5 Requisitos de GPU — Vello
Alvo declarado (README.md:159-163): "We aim to target all environments which can support WebGPU with the default limits. We defer to wgpu for this support."

Requisitos concretos verificados no código:

Compute shaders — obrigatório, sem alternativa. README.md:59, README.md:167.
Storage buffers read-write — em praticamente todo estágio: var<storage, read_write> em pathtag_reduce.wgsl:15, binning.wgsl:22-38, path_count.wgsl:21, backdrop_dyn.wgsl:14,19, etc. Bindings declarados como Buffer (RW) vs BufReadOnly em vello/src/shaders.rs:102-218.
Operações atômicas em storage buffers — atomicAdd, atomicLoad, atomicStore, atomicMin/Max. Todo o BumpAllocators é atomic<u32> (vello_shaders/shader/shared/bump.wgsl). Também atomics em workgroup memory (fine.wgsl:90-109, binning.wgsl:49).
Indirect dispatch — sim, obrigatório. Duas chamadas: path_count (render.rs:452) e path_tiling (render.rs:490). Marcado explicitamente em vello_encoding/src/config.rs:219 (// Note: 'path_count' must use an indirect dispatch) e :223. Isso é inerente: o número de segmentos só é conhecido na GPU.
Storage textures graváveis (Image(ImageFormat::Rgba8), shaders.rs:213) — o fine escreve direto na imagem.
Workgroup size 256 e workgroup memory considerável (binning.wgsl tem array<array<atomic<u32>, N_TILE>, N_SLICE> + sh_count + sh_chunk_offset; fine.wgsl tem ~72 atomic<u32> só de winding).
Na prática: WebGPU / Vulkan 1.1+ / Metal 2 / D3D12 / GL ES 3.1+ (via wgpu, com ressalvas). OpenGL ES 2.0 e WebGL2 estão fora, categoricamente.

Sobre a Web (README.md:165-186): "Because Vello relies heavily on compute shaders, we rely on the emerging WebGPU standard... Vello has been tested using production versions of Chrome, but WebGPU support in Firefox and Safari is still experimental... The web is not currently a primary target for Vello."

B.6 Limitações conhecidas e robustez
Estado alfa (README.md:40-46), com lista explícita de pendências:

Blur e filter effects não implementados (issue #476).
Conflation artifacts (issue #49).
Estratégia de alocação de memória GPU (issue #366).
Glyph caching (issue #204).
Memória intermediária — o ponto mais frágil. vello_encoding/src/config.rs:398-408 traz um comentário revelador:


// The following buffer sizes have been hand picked to accommodate the vello test scenes as
// well as paris-30k. These should instead get derived from the scene layout using
// reasonable heuristics.
let bin_data    = BufferSize::new(1 << 18);  // 1 MiB
let tiles       = BufferSize::new(1 << 21);  // 2M tiles × 8 B = 16 MiB
let lines       = BufferSize::new(1 << 21);
let seg_counts  = BufferSize::new(1 << 21);
let segments    = BufferSize::new(1 << 21);
let blend_spill = BufferSize::new(1 << 20);  // "4096 spills"
let ptcl        = BufferSize::new(1 << 23);  // 32 MiB
São constantes hard-coded, escolhidas à mão, somando na casa de dezenas a >100 MiB de buffers intermediários por render, independentemente da complexidade real da cena. Tiles são 16×16 (config.rs:12-13).

Mecanismo de robustez: cinco estágios podem falhar alocação — STAGE_BINNING, STAGE_TILE_ALLOC, STAGE_FLATTEN, STAGE_PATH_COUNT, STAGE_COARSE (shader/shared/bump.wgsl:4-9). Cada um seta um bit em bump.failed via atomic. Os estágios seguintes checam (path_count_setup.wgsl: if atomicLoad(&bump.failed) != 0u { indirect.count_x = 0u; }) e abortam graciosamente. O host lê de volta BumpAllocators (vello/src/lib.rs:424, 650, 753) com os tamanhos realmente necessários, para realocar no próximo frame. Mas o frame corrente é perdido/corrompido. Note que o readback só é habilitado por padrão sob cfg!(feature = "debug_layers") (lib.rs:730) — em release, a detecção não é automática.

Fallback CPU (doc/ARCHITECTURE.md:81-89): existe em vello_shaders/src/cpu/, mas "It's called through WgpuEngine, so the dependency on wgpu is still there", "Fine rasterization doesn't work in CPU yet (#386)", e "Every single WGSL shader needs a CPU equivalent, which is pretty cumbersome".

B.7 Roadmap e relação com sparse_strips
doc/ARCHITECTURE.md:22-27: "The roadmap for 2023 is still largely applicable. The 'Semi-stable encoding format' section and most of the 'CPU fallback' section can be considered implemented. Our current priority is to fill in missing features and to fix rendering artifacts, so that Vello can reach feature parity with other 2D graphics engines."

Do doc/roadmap_2023.md, o que se confirma implementado: "Stroke rework" via espirais de Euler (a seção descreve exatamente o flatten_euler que hoje está em flatten.wgsl), atlas único de imagens (workaround por falta de descriptor indexing em WebGPU 1.0), retângulos diretos, API de glyph runs. Pendentes/opcionais: blurs e filtros, solução para conflation, subpixel RGB, HDR, backends nativos.

sparse_strips é uma reimplementação, não uma evolução incremental. sparse_strips/README.md:3-13:

"We are developing a new implementation for Vello that aims to:

Be compatible with a wider range of devices (should be able to run on GPUs without compute shader support, using only fragment and vertex shaders).
Mitigate some performance cliffs.
Handle a wider range of memory conditions (e.g., when less memory is available).
This folder is being used to develop this implementation and is not yet suitable for production use. Our plan is to move the packages in this folder to the top level of the repository once they are ready."

Baseado no design "Potato: a hybrid CPU/GPU 2D renderer" de Raph Levien. Crates: vello_common (estruturas compartilhadas), vello_cpu (CPU multithread + SIMD), vello_hybrid (CPU/GPU balanceado), vello_sparse_shaders (compila WGSL→GLSL para backend WebGL). Já estão no workspace (Cargo.toml:16-29) na versão 0.2.0.

Leitura: os três objetivos declarados do sparse_strips são exatamente as três fraquezas do Vello clássico identificadas acima — piso de API alto demais, buffers hard-coded, e cliffs de performance. O Vello clássico está em manutenção/feature-completion enquanto o sucessor amadurece.

Tabela comparativa
Dimensão	Impeller	Vello clássico
Pré-requisitos de API	GL ES 2.0 + stencil 8-bit + depth (piso duro). Vulkan 1.1 / Metal preferidos. Tudo além disso é Capabilities opcional com fallback (renderer/capabilities.h)	Compute shaders obrigatórios, storage buffers RW, atomics (device + workgroup), indirect dispatch, storage textures graváveis. WebGPU default limits / Vulkan 1.1+ / Metal 2 / D3D12 / GL ES 3.1+. GL ES 2.0 e WebGL2 impossíveis
Onde roda o trabalho pesado	Dividido. CPU: flattening de curvas, expansão de stroke (joins/caps/miter, stroke_path_geometry.cc), rasterização de glifos (Skia), tessellação em fans. GPU: raster fixed-function + stencil + fragment shaders. Zero compute no caminho 2D	Quase tudo na GPU. CPU faz apenas o encoding em streams lineares (vello_encoding). 13+ estágios compute fazem flattening, offset curves de stroke, sorting/binning, resolução da pilha de clips, coarse raster e fine raster
Qualidade de AA	MSAA 4x fixo (render_target.cc:401) — sem cobertura analítica para paths gerais. Serrilhado residual em bordas quase-axiais. Hack de alpha para strokes sub-pixel (ComputeStrokeAlphaCoverage). Resolve grátis em tilers. Degrada graciosamente para "sem AA"	Superior. Area = cobertura analítica exata por integração do winding number (mas sofre conflation artifacts). Msaa8/Msaa16 em software no compute shader, com winding parity empacotado — resolve conflation ao custo de performance. Escolha por frame
Custo de memória	Baixo e proporcional. Vertex buffers transientes num HostBuffer por frame + attachments (color/depth/stencil). Em tilers, MSAA e stencil são kDeviceTransient (memoryless, nunca tocam DRAM). Texturas offscreen só para saveLayers e advanced blends sem framebuffer fetch	Alto, fixo e não-adaptativo. Buffers intermediários com tamanhos hard-coded (ptcl 32 MiB, tiles/lines/seg_counts/segments 2²¹ entradas cada, blend_spill 1 MiB) — comentário no código admite serem "hand picked" e que "should instead get derived from the scene layout" (config.rs:398-400). Overflow → bump.failed, frame perdido; issue #366 aberta
Complexidade de implementação	Moderada. Conceitos de raster clássico: tessellação em fan, stencil-then-cover (2 draws), depth para clip, blend state. A complexidade real está no tooling offline (impellerc: GLSL→SPIR-V→MSL/SPIR-V/GLSL ES + reflexão C++) e no matriz de Capabilities × fallbacks × PSOs pré-construídos	Muito alta. O próprio roadmap admite: "the Vello design is intimidating... seems too much like rocket science and it is hard to contribute" (doc/roadmap_2023.md, seção "Writeup", que propõe um relatório de 20–30 páginas). Exige domínio de prefix sums/monoids, stack monoid para clips, espirais de Euler + aproximações ESPC robustas, bump allocators atômicos, PTCL, e um pré-processador WGSL próprio (#import/#ifdef) por falta de metaprogramação
Texto	Atlas rasterizado em CPU via Skia, escala quantizada + subpixel positioning, sem mipmaps (text_contents.cc:127-224). Maduro	Glifos encodados como paths vetoriais; glyph caching ainda é issue aberta (#204). Vantagem: stem darkening/embolden de altíssima qualidade via o mesmo mecanismo de stroke
Blending avançado	13 Porter-Duff grátis (pipeline) + 15 W3C via shader. Com framebuffer fetch: in-pass e barato. Sem: quebra o render pass + textura intermediária + blit (docs/blending.md:80-87)	Blend stack no fine.wgsl, aninhamento quase arbitrário, tudo dentro de um único dispatch. Mais elegante e mais barato — mas depende de spill buffer dimensionado à mão
Maturidade	Produção: default no iOS, preview em Android/macOS (README.md:169-230)	Alpha declarado (README.md:40). Sucessor (sparse_strips) já em desenvolvimento ativo para corrigir justamente API floor, memória e performance cliffs
Síntese para decisão de arquitetura
As duas abordagens ocupam extremos opostos do espectro portabilidade ↔ qualidade/paralelismo:

Impeller aposta em nunca ser bloqueado por hardware. Aceita AA inferior (MSAA 4x) e trabalho de CPU (stroke expansion, flattening) em troca de rodar em GL ES 2.0 com stencil. A engenhosidade está no stencil-then-cover, que evita tessellação de polígono por completo — o custo de CPU é O(pontos), não O(pontos·log·complexidade).

Vello aposta em a GPU faz tudo, em paralelo. Obtém AA analítico e escalabilidade para cenas de dezenas de milhares de paths (177 fps em paris-30k num M1 Max, README.md:122), ao custo de exigir compute + indirect dispatch e de carregar dezenas de MiB de buffers dimensionados por chute.

Para um projeto Dart/Flutter-adjacente com alvo amplo de dispositivos, o modelo Impeller (Geometry × ColorSourceContents + stencil-then-cover + Capabilities com fallbacks) é substancialmente mais realizável e mais fácil de degradar graciosamente. Vale notar que o próprio time do Vello chegou à mesma conclusão de piso de API — daí o sparse_strips, que explicitamente busca "GPUs without compute shader support, using only fragment and vertex shaders".

Now the connection — pacing, deferred destroy, data device, serial tracking. Multiple edits.

Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_connection.dart
Added 2 lines
Edit C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart
Added 15 lines
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_connection.dart
Added 32 lines
Edit C:\MyDartProjects\dart_ui\lib\src\backends\wayland\wayland_connection.dart
Added 4 lines
Edit C:\MyDartProjects\dart_ui\lib\src\graphics\display_list.dart
Added 32 lines
You've hit your weekly limit · resets 10pm (America/Sao_Paulo)

You've hit your weekly limit · resets 10pm (America/Sao_Paulo)

You've hit your weekly limit · resets 10pm (America/Sao_Paulo)

You've hit your weekly limit · resets 10pm (America/Sao_Paulo)

Write C:\MyDartProjects\dart_ui\lib\src\rendering\gpu\vector\sparse_strips.dart
355 lines
/// Sparse coverage strips: a path's antialiasing reduced to its boundary.
///
/// ## What a strip is, and what problem it removes
///
/// The mask-atlas route (`gpu_mask_atlas.dart`) rasterises the *whole clipped
/// bounding box* of a path into alpha8 texels: a 300x300 rounded card costs
/// 90 000 texels of staging, upload and atlas residency, of which all but a
/// thin ring are either 0 or 255 - two values a shader could have produced
/// without a texture. The cost is proportional to **area**.
///
/// A sparse strip representation keeps only the pixels where coverage is
/// *interesting* - the antialiased boundary - and describes everything else as
/// runs: fully-covered runs become solid quads with no texture at all, and
/// empty runs become nothing. The cost is proportional to **perimeter**, which
/// for UI shapes is one to two orders of magnitude smaller. This is the core
/// idea of Vello's sparse-strip renderers (`vello_cpu` / `vello_hybrid`,
/// Apache-2.0/MIT); the representation here is a Dart reimplementation of that
/// *concept* - strips of [kStripHeight] rows carrying alpha texels, separated
/// by sparse fill runs - not a port of the Rust code. See
/// `THIRD_PARTY_NOTICES.md`.
///
/// ## Where the coverage itself comes from
///
/// From [ScanlineFiller], deliberately. Vello computes coverage with its own
/// tile pipeline (flatten -> 4x4 tiles -> per-column accumulation); this
/// framework already owns an exact analytic coverage rasteriser that the CPU
/// renderer, the mask atlas and every parity test share, and *one*
/// implementation of coverage is the property that makes CPU/GPU comparison a
/// measurement instead of a coincidence. So phase 1 keeps the filler as the
/// single source of coverage truth and changes only the *representation* of
/// its output: spans in, strips + fills out, byte-identical when
/// reconstructed - a test asserts exactly that. Replacing the filler with a
/// Vello-style tile pipeline (multithreadable, SIMD-friendly) is a phase-2
/// swap behind this same output format, and is discussed in
/// `doc/architecture/ACELERACAO_GPU_VETORIAL.md`.
///
/// ## The output format, stated tightly
///
/// A [StripBuffer] holds three arrays:
///
///   * **strips** - each is `x, y, width, alphaOffset`, with `y` a multiple of
///     [kStripHeight]. Its coverage lives at `alphaOffset` in [StripBuffer.alphas]:
///     `width * kStripHeight` bytes, row-major, top row first - the layout an
///     alpha8 texture upload wants.
///   * **fills** - each is `x, y, width`: a run of columns whose
///     [kStripHeight] rows are all fully covered. No texels; a solid quad.
///   * **alphas** - the strips' texels, strip-major.
///
/// Runs never overlap, cover every non-zero-coverage column exactly once, and
/// within one strip row appear left to right; strip rows appear top to bottom.
/// Coverage bytes mean what [CoverageSpanSink] says they mean: the value
/// `mul255` folds into the paint's alpha, so a reconstruction of this buffer
/// is comparable byte for byte against the filler's own spans.
library;

import 'dart:typed_data';

import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../path/coverage_span_sink.dart';
import '../../path/fill_rule.dart';
import '../../path/scanline_filler.dart';

/// Rows per strip. Four, matching Vello's `Tile::HEIGHT`/`STRIP_HEIGHT`: tall
/// enough that a strip quad amortises its vertex cost over four scanlines,
/// short enough that a nearly-horizontal edge does not drag whole rows of
/// interior pixels into the "boundary" class.
const int kStripHeight = 4;

/// Ints per strip record in [StripBuffer.strips]: `x, y, width, alphaOffset`.
const int kStripStride = 4;

/// Ints per fill record in [StripBuffer.fills]: `x, y, width`.
const int kFillStride = 3;

/// A zero- or full-coverage run shorter than this, sitting between two
/// boundary runs, is folded into the surrounding strip instead of splitting
/// it. Splitting costs two quads and a state-compatible-but-separate record;
/// four columns of redundant texels cost 16 bytes. The exact value is a
/// heuristic, not a contract, and the reconstruction test does not depend on
/// it - both encodings reconstruct identically.
const int kRunMergeThreshold = 4;

/// The sparse-strip encoding of one filled path. Reused across fills by
/// [SparseStripGenerator]; a caller must copy what it keeps.
final class StripBuffer {
  /// `kStripStride` ints per strip. Only the first [stripCount] records are
  /// meaningful; the array is pooled and keeps its high-water length.
  Int32List strips = Int32List(64 * kStripStride);
  int stripCount = 0;

  /// `kFillStride` ints per fill run.
  Int32List fills = Int32List(64 * kFillStride);
  int fillCount = 0;

  /// Strip texels, strip-major, `width * kStripHeight` bytes each, row-major.
  Uint8List alphas = Uint8List(1024);
  int alphaCount = 0;

  void reset() {
    stripCount = 0;
    fillCount = 0;
    alphaCount = 0;
  }

  int stripX(int i) => strips[i * kStripStride];
  int stripY(int i) => strips[i * kStripStride + 1];
  int stripWidth(int i) => strips[i * kStripStride + 2];
  int stripAlphaOffset(int i) => strips[i * kStripStride + 3];

  int fillX(int i) => fills[i * kFillStride];
  int fillY(int i) => fills[i * kFillStride + 1];
  int fillWidth(int i) => fills[i * kFillStride + 2];

  /// Coverage of strip [i] at column [column] (0-based within the strip) and
  /// row [row] (0..kStripHeight-1). For tests and debugging; the composer
  /// reads [alphas] in bulk.
  int stripAlpha(int i, int column, int row) =>
      alphas[stripAlphaOffset(i) + row * stripWidth(i) + column];

  void addStrip(int x, int y, int width, int alphaOffset) {
    final int base = stripCount * kStripStride;
    if (base + kStripStride > strips.length) {
      final Int32List grown = Int32List(strips.length * 2);
      grown.setRange(0, base, strips);
      strips = grown;
    }
    strips[base] = x;
    strips[base + 1] = y;
    strips[base + 2] = width;
    strips[base + 3] = alphaOffset;
    stripCount++;
  }

  void addFill(int x, int y, int width) {
    final int base = fillCount * kFillStride;
    if (base + kFillStride > fills.length) {
      final Int32List grown = Int32List(fills.length * 2);
      grown.setRange(0, base, fills);
      fills = grown;
    }
    fills[base] = x;
    fills[base + 1] = y;
    fills[base + 2] = width;
    fillCount++;
  }

  /// Reserves [count] alpha bytes and returns their offset.
  int reserveAlphas(int count) {
    final int offset = alphaCount;
    if (offset + count > alphas.length) {
      var length = alphas.length * 2;
      while (offset + count > length) {
        length *= 2;
      }
      final Uint8List grown = Uint8List(length);
      grown.setRange(0, offset, alphas);
      alphas = grown;
    }
    alphaCount = offset + count;
    return offset;
  }
}

/// Converts a path into a [StripBuffer], one fill at a time.
///
/// One instance per thread, kept across frames: the filler, the row staging
/// and the output buffer all grow to the busiest fill and are then reused.
final class SparseStripGenerator {
  SparseStripGenerator();

  final ScanlineFiller _filler = ScanlineFiller();
  final StripBuffer _buffer = StripBuffer();
  late final _StripRowSink _sink = _StripRowSink(this);

  /// Staging for the strip row being accumulated: `kStripHeight` rows of
  /// `_width` coverage bytes each, indexed `row * _width + (x - _clipLeft)`.
  Uint8List _rows = Uint8List(0);

  /// Per-column class for the flush pass: `_classZero`, `_classSolid` or
  /// `_classPartial`. Reused.
  Uint8List _classes = Uint8List(0);

  int _clipLeft = 0;
  int _width = 0;

  /// Top scanline of the strip row in `_rows`, always a multiple of
  /// [kStripHeight]; -1 when nothing is staged.
  int _stagedTop = -1;

  /// Columns of `_rows` that any span has touched since the last flush, so
  /// clearing is proportional to the shape and not the clip.
  int _touchedLeft = 0;
  int _touchedRight = 0;

  static const int _classZero = 0;
  static const int _classSolid = 1;
  static const int _classPartial = 2;

  /// Fills [path] and returns its sparse-strip encoding.
  ///
  /// Same contract as [ScanlineFiller.fill], because it *is* that fill with a
  /// different sink: [clip] is expanded outward to whole pixels, [transform]
  /// is applied during flattening, [tolerance] is in device pixels. The
  /// returned buffer is owned by this generator and valid until the next call.
  StripBuffer fill(
    Path path,
    Rect clip, {
    FillRule rule = FillRule.nonZero,
    Transform2D transform = Transform2D.identity,
    double tolerance = kDefaultFlattenTolerance,
  }) {
    _buffer.reset();
    _clipLeft = clip.left.floor();
    final int clipRight = clip.right.ceil();
    _width = clipRight - _clipLeft;
    if (_width <= 0) return _buffer;
    if (_rows.length < _width * kStripHeight) {
      _rows = Uint8List(_width * kStripHeight);
      _classes = Uint8List(_width);
    }
    _stagedTop = -1;
    _touchedLeft = _width;
    _touchedRight = 0;

    _filler.fill(
      path,
      clip,
      _sink,
      rule: rule,
      transform: transform,
      tolerance: tolerance,
    );
    _flushStripRow();
    return _buffer;
  }

  /// One span from the filler. Spans arrive with `y` non-decreasing, so strip
  /// rows complete in order and one staging buffer suffices.
  void _span(int y, int xStart, int xEnd, int coverage) {
    final int top = y & ~(kStripHeight - 1);
    if (top != _stagedTop) {
      _flushStripRow();
      _stagedTop = top;
    }
    final int row = y - top;
    final int from = row * _width + (xStart - _clipLeft);
    _rows.fillRange(from, from + (xEnd - xStart), coverage);
    final int left = xStart - _clipLeft;
    final int right = xEnd - _clipLeft;
    if (left < _touchedLeft) _touchedLeft = left;
    if (right > _touchedRight) _touchedRight = right;
  }

  /// Classifies the staged columns and emits strips and fills.
  void _flushStripRow() {
    if (_stagedTop < 0 || _touchedRight <= _touchedLeft) {
      _stagedTop = -1;
      return;
    }
    final int left = _touchedLeft;
    final int right = _touchedRight;
    final int w = _width;

    // Pass 1: classify each touched column.
    for (var x = left; x < right; x++) {
      final int a0 = _rows[x];
      final int a1 = _rows[w + x];
      final int a2 = _rows[2 * w + x];
      final int a3 = _rows[3 * w + x];
      if (a0 == 0 && a1 == 0 && a2 == 0 && a3 == 0) {
        _classes[x] = _classZero;
      } else if (a0 == 255 && a1 == 255 && a2 == 255 && a3 == 255) {
        _classes[x] = _classSolid;
      } else {
        _classes[x] = _classPartial;
      }
    }

    // Pass 2: fold short interior zero/solid runs into the surrounding
    // boundary, so a star's centre does not shatter into dozens of one-column
    // strips. Runs at the row's ends are never folded - a strip must not grow
    // past the ink.
    var runStart = left;
    while (runStart < right) {
      final int cls = _classes[runStart];
      var runEnd = runStart + 1;
      while (runEnd < right && _classes[runEnd] == cls) {
        runEnd++;
      }
      if (cls != _classPartial &&
          runEnd - runStart < kRunMergeThreshold &&
          runStart > left &&
          runEnd < right &&
          _classes[runStart - 1] == _classPartial &&
          _classes[runEnd] == _classPartial) {
        _classes.fillRange(runStart, runEnd, _classPartial);
      }
      runStart = runEnd;
    }

    // Pass 3: emit maximal runs.
    runStart = left;
    while (runStart < right) {
      final int cls = _classes[runStart];
      var runEnd = runStart + 1;
      while (runEnd < right && _classes[runEnd] == cls) {
        runEnd++;
      }
      final int runWidth = runEnd - runStart;
      switch (cls) {
        case _classSolid:
          _buffer.addFill(_clipLeft + runStart, _stagedTop, runWidth);
        case _classPartial:
          final int offset = _buffer.reserveAlphas(runWidth * kStripHeight);
          final Uint8List alphas = _buffer.alphas;
          for (var row = 0; row < kStripHeight; row++) {
            alphas.setRange(
              offset + row * runWidth,
              offset + (row + 1) * runWidth,
              _rows,
              row * w + runStart,
            );
          }
          _buffer.addStrip(_clipLeft + runStart, _stagedTop, runWidth, offset);
        default:
          break; // zero coverage: nothing to represent.
      }
      runStart = runEnd;
    }

    // Clear only what was written.
    for (var row = 0; row < kStripHeight; row++) {
      _rows.fillRange(row * w + left, row * w + right, 0);
    }
    _touchedLeft = _width;
    _touchedRight = 0;
    _stagedTop = -1;
  }
}

/// The [CoverageSpanSink] face of the generator, kept as a separate object so
/// the generator's public API cannot be mistaken for a sink and fed spans from
/// somewhere else mid-fill.
final class _StripRowSink implements CoverageSpanSink {
  _StripRowSink(this._generator);

  final SparseStripGenerator _generator;

  @override
  void span(int y, int xStart, int xEnd, int coverage) =>
      _generator._span(y, xStart, xEnd, coverage);
}
You've hit your weekly limit · resets 10pm (America/Sao_Paulo)

You've hit your weekly limit · resets 10pm (America/Sao_Paulo)

Explorei o código a fundo. Segue o relatório técnico.

Relatório Técnico: Arquitetura "Sparse Strips" do Vello (CPU + Híbrido CPU/GPU)
Base analisada: C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips — versão 0.2.0 (CHANGELOG datado 2026-08-07).

Aviso importante de versão. Esta árvore é bem mais recente do que a maior parte da documentação pública sobre "vello sparse strips". Duas mudanças estruturais que invalidam o que você provavelmente leu em blog posts:

Não existe mais struct Footprint (bitmask de 4 bits de colunas cobertas por tile). Grep em toda a árvore não retorna nenhuma ocorrência. O "merge de footprints" foi substituído por acumulação analítica de área em f32x4 diretamente em strip::render.
Não existe mais WideTile nem Cmd::Fill / Cmd::AlphaFill no vello_cpu. O estágio coarse foi reescrito (PR #1701) para um CommandBucketer com buckets por linha de strip (largura = viewport inteiro) + um depth buffer de CPU com granularidade de 128px. Vou descrever o que existe hoje e apontar o mapeamento para a nomenclatura antiga onde for útil.
0. Visão geral do pipeline

PathEl (kurbo)  ──flatten──►  Vec<Line>          (f32, espaço de device)
                                  │
                                  ├─ make_tiles_analytic_aa ──►  Vec<Tile>  (4x4 px, um por par linha×tile)
                                  │                              + CulledWindings (winding fora-de-tela)
                                  ├─ sort_tiles (u64 key: y|x|line_idx)
                                  │
                                  └─ strip::render ──►  Vec<Strip>  +  Vec<u8> (alphas)
                                                             │
                    ┌────────────────────────────────────────┴──────────────────────────────┐
                    │                                                                        │
              vello_cpu                                                              vello_hybrid
   CommandBucketer (buckets por linha)                              GpuStrip[] (instâncias) + textura de alphas
   + DepthBuffer(128px)                                             + render.wesl (vertex/fragment)
   → Fine rasterization SIMD (u8 ou f32)                            → quads instanciados, depth test, blend
Toda a geometria acontece em coordenadas de pixel em f32 após a aplicação do Affine. O tile é a unidade de subdivisão 4×4 pixels. A "strip" é uma faixa horizontal de 1 linha de tiles (4px de altura) × N colunas de tiles.

1. Constantes fundamentais
Arquivo: C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\tile.rs


impl Tile {
    /// The width of a tile in pixels.
    pub const WIDTH: u16 = 4;

    /// The height of a tile in pixels.
    pub const HEIGHT: u16 = 4;

    /// A special tile used to signal the end of a tile stream during rendering.
    pub const SENTINEL: Self = Self::new(u16::MAX, u16::MAX, 0, 0);
}
Não existe STRIP_HEIGHT como constante separada no Rust: a altura da strip é Tile::HEIGHT. Ela só aparece explicitamente ao ser enviada à GPU:

C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\render\webgl\mod.rs:1570


strip_height: u32::from(Tile::HEIGHT),
Outras constantes-chave:

Constante	Valor	Arquivo
Tile::WIDTH	4	vello_common/src/tile.rs:263
Tile::HEIGHT	4	vello_common/src/tile.rs:266
MAX_LINES_PER_PATH	1 << 27 = 134 217 728	vello_common/src/tile.rs:41
SQRT_TOL	0.5	vello_common/src/flatten.rs:17
TOL	0.25	vello_common/src/flatten.rs:18
TOL_2	0.0625	vello_common/src/flatten.rs:19
TO_QUAD_TOL	0.1	vello_common/src/flatten_simd.rs:638
MAX_QUADS	16	vello_common/src/flatten_simd.rs:338
COLOR_COMPONENTS	4 (RGBA)	vello_cpu/src/fine/mod.rs:58
TILE_HEIGHT_COMPONENTS	4*4 = 16	vello_cpu/src/fine/mod.rs:61
DEPTH_BUCKET_WIDTH	128 px	vello_cpu/src/coarse/depth.rs:43
LARGE_RECT_SPLIT_THRESHOLD	32 px	vello_hybrid/src/rect.rs:11
Strip::FILL_GAP_MASK	1 << 31	vello_common/src/strip.rs:200
2. Flattening de curvas
Arquivos:

C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\flatten.rs (API pública + culling doc)
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\flatten_simd.rs (algoritmo real)
2.1 Tolerância

// C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\flatten.rs
// The current tolerance is set to 0.25. Since `sqrt` doesn't work in const contexts, we instead
// hardcode the squared tolerance and derive the others from that.
pub(crate) const SQRT_TOL: f64 = 0.5;
pub(crate) const TOL: f64 = SQRT_TOL * SQRT_TOL;   // 0.25
pub(crate) const TOL_2: f64 = TOL * TOL;           // 0.0625
Para strokes, a tolerância é dividida pela escala do transform antes da expansão para path preenchido:


// flatten.rs, fn stroke
let tolerance = TOL
    / affine.as_coeffs()[0].abs()
        .max(affine.as_coeffs()[3].abs())
        .max(1.);
expand_stroke(path, style, tolerance, stroke_ctx);   // kurbo::stroke_with
fill(level, stroke_ctx.output(), affine, line_buf, flatten_ctx, cull_bbox);
Ou seja: stroke = expansão para outline preenchido via kurbo + fill NonZero. Não há rasterização de stroke dedicada.

2.2 Estrutura de saída

// C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\flatten.rs
pub struct Point { pub x: f32, pub y: f32 }

pub struct Line { pub p0: Point, pub p1: Point }
A saída é um Vec<Line> plano. Subpaths abertos são fechados implicitamente (ligando o último ponto ao start_pt), exceto quando trechos foram culled — o comentário no topo de flatten.rs (linhas 90-177, com arte ASCII) explica que fechar subpaths após culling produziria geometria errada, então as linhas resultantes podem descrever subpaths abertos deliberadamente.

2.3 Culling durante o flatten
O flatten recebe um cull_bbox: RectU16. Regra crítica (comentário nas linhas 62-84 de flatten_simd.rs): o topo do bbox precisa ser alinhado à borda da linha de strips, senão geometria quase-horizontal logo acima do clip seria removida e os tiles intermediários necessários para o sparse fill não seriam emitidos:


let left   = cull_bbox.x0 as f64;
let top    = ((cull_bbox.y0 / Tile::HEIGHT) * Tile::HEIGHT) as f64;   // alinhado!
let right  = cull_bbox.x1 as f64;
let bottom = cull_bbox.y1 as f64;
Regras de descarte por elemento (aplicadas ao bbox dos pontos de controle):

Se todos os pontos de controle estão à direita de right, ou acima de top, ou abaixo de bottom → emite MoveTo(p_final) (descarta a curva, quebrando o subpath).
Se todos estão à esquerda de left → emite LineTo(p_final): a forma exata não importa, só a contribuição de winding (a varredura de winding é da esquerda para a direita).
2.4 Quadráticas (PathEl::QuadTo)
Teste de "achatamento" (early-out para uma única linha), com derivação documentada no código:


// dist(q(t), [p0,p2]) <= B1(t) * dist(p1, [p0,p2]) = 2(1-t)t * dist(...)
// máximo em t=1/2  =>  max dist <= 1/2 * dist(p1, [p0,p2])
else if [p0, p1, p2].into_iter().all(|p| p.x < left)
    || line.nearest(p1, 0.).distance_sq <= 4. * TOL_2
{
    callback.callback(LinePathEl::LineTo(p2));
}
Ou seja: dist²(p1, segmento) <= 4 * TOL_2 ⟺ dist(p1,seg)/2 <= TOL.

Caso contrário, subdivisão por integral de parábola aproximada (algoritmo de Raph Levien, o mesmo do kurbo):


let q = QuadBez::new(p0, p1, p2);
let params = q.estimate_subdiv(SQRT_TOL);
let n = ((0.5 / SQRT_TOL * params.val).ceil() as usize).max(1);
let step = 1.0 / (n as f64);
for i in 1..n {
    let u = (i as f64) * step;
    let t = q.determine_subdiv_t(&params, u);
    callback.callback(LinePathEl::LineTo(q.eval(t)));
}
callback.callback(LinePathEl::LineTo(p2));
As funções auxiliares (copiadas do kurbo, flatten_simd.rs:246-311) — você vai precisar delas em Dart:


/// An approximation to $\int (1 + 4x^2) ^ -0.25 dx$
fn approx_parabola_integral(x: f64) -> f64 {
    const D: f64 = 0.67;
    x / (1.0 - D + (D.powi(4) + 0.25 * x * x).sqrt().sqrt())
}

/// An approximation to the inverse parabola integral.
fn approx_parabola_inv_integral(x: f64) -> f64 {
    const B: f64 = 0.39;
    x * (1.0 - B + (B * B + 0.25 * x * x).sqrt())
}

impl FlattenParamsExt for QuadBez {
    fn estimate_subdiv(&self, sqrt_tol: f64) -> FlattenParams {
        // Determine transformation to $y = x^2$ parabola.
        let d01 = self.p1 - self.p0;
        let d12 = self.p2 - self.p1;
        let dd = d01 - d12;
        let cross = (self.p2 - self.p0).cross(dd);
        let x0 = d01.dot(dd) * cross.recip();
        let x2 = d12.dot(dd) * cross.recip();
        let scale = (cross / (dd.hypot() * (x2 - x0))).abs();

        // Compute number of subdivisions needed.
        let a0 = approx_parabola_integral(x0);
        let a2 = approx_parabola_integral(x2);
        let val = if scale.is_finite() {
            let da = (a2 - a0).abs();
            let sqrt_scale = scale.sqrt();
            if x0.signum() == x2.signum() {
                da * sqrt_scale
            } else {
                // Handle cusp case (segment contains curvature maximum)
                let xmin = sqrt_tol / sqrt_scale;
                sqrt_tol * da / approx_parabola_integral(xmin)
            }
        } else { 0.0 };
        let u0 = approx_parabola_inv_integral(a0);
        let u2 = approx_parabola_inv_integral(a2);
        let uscale = (u2 - u0).recip();
        FlattenParams { a0, a2, u0, uscale, val }
    }

    fn determine_subdiv_t(&self, params: &FlattenParams, x: f64) -> f64 {
        let a = params.a0 + (params.a2 - params.a0) * x;
        let u = approx_parabola_inv_integral(a);
        (u - params.u0) * params.uscale
    }
}
2.5 Cúbicas (PathEl::CurveTo)
Early-out análogo, com constante 16/9:


// max(dist(c(t), [p0,p3])) <= 3/4 * max(dist(p1,·), dist(p2,·))
else if [p0, p1, p2, p3].into_iter().all(|p| p.x < left)
    || f64::max(
        line.nearest(p1, 0.).distance_sq,
        line.nearest(p2, 0.).distance_sq,
    ) <= 16. / 9. * TOL_2
{
    callback.callback(LinePathEl::LineTo(p3));
}
Senão, o caminho é cúbica → N quadráticas → linhas (algoritmo de dois estágios), implementado em SIMD em flatten_cubic_simd:


// C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\flatten_simd.rs
fn flatten_cubic_simd<S: Simd>(simd: S, c: CubicBez, ctx: &mut FlattenCtx) -> usize {
    let n_quads = estimate_num_quads(c, TOL as f32);
    eval_cubics_simd(simd, &c, n_quads, ctx);
    let tol = (TOL as f32) * (1.0 - TO_QUAD_TOL);     // 0.25 * 0.9 = 0.225
    let sqrt_tol = tol.sqrt();                         // ≈ 0.474342
    estimate_subdiv_simd(simd, sqrt_tol, ctx);
    let sum: f32 = ctx.val[..n_quads].iter().sum();
    let n = ((0.5 * sum / sqrt_tol).ceil() as usize).max(1);
    // ...
    let step = sum / (n as f32);
    let step_recip = 1.0 / step;
    let mut val_sum = 0.0;
    let mut last_n = 0;
    let mut x0base = 0.0;

    for i in 0..n_quads {
        let val = ctx.val[i];
        val_sum += val;
        let this_n = val_sum * step_recip;
        let this_n_next = 1.0 + this_n.floor();
        let dn = this_n_next as usize - last_n;
        if dn > 0 {
            let dx = step / val;
            let x0 = x0base * dx;
            output_lines_simd(simd, ctx, i, x0, dx, dn, last_n);
        }
        x0base = this_n_next - this_n;
        last_n = this_n_next as usize;
    }

    ctx.flattened_cubics[n] = ctx.even_pts[n_quads];
    n + 1
}
Quantidade de quadráticas:


const TO_QUAD_TOL: f32 = 0.1;

fn estimate_num_quads(c: CubicBez, accuracy: f32) -> usize {
    let q_accuracy = (accuracy * TO_QUAD_TOL) as f64;   // 0.025
    let max_hypot2 = 432.0 * q_accuracy * q_accuracy;
    let p1x2 = c.p1.to_vec2() * 3.0 - c.p0.to_vec2();
    let p2x2 = c.p2.to_vec2() * 3.0 - c.p3.to_vec2();
    let err = (p2x2 - p1x2).hypot2();
    estimate(err / max_hypot2)
}

// equivalente a  clamp(ceil(err_div^(1/6)), 1, 16)  via LUT de i^6
fn estimate(err_div: f64) -> usize {
    const LUT: [f64; MAX_QUADS] = [
        1.0, 64.0, 729.0, 4096.0, 15625.0, 46656.0, 117649.0, 262144.0, 531441.0, 1000000.0,
        1771561.0, 2985984.0, 4826809.0, 7529536.0, 11390625.0, 16777216.0,
    ];
    for i in 0..MAX_QUADS { if err_div <= LUT[i] { return i + 1; } }
    MAX_QUADS
}
A cúbica é amostrada em 2*n_quads+1 pontos (even_pts = t = 0, 1/n, 2/n…; odd_pts = pontos intermediários em meio-passo), e o ponto de controle de cada quadrática é reconstruído como p1 = 2*p_half - 0.5*p0 - 0.5*p2 (linhas 479-483). Cada quadrática recebe um val (número relativo de subdivisões), somados globalmente, e a distribuição de linhas entre as quadráticas é feita proporcional ao val acumulado — daí o laço com val_sum/step_recip.

Para Dart: você pode implementar isso escalar (sem SIMD) sem problema. A estrutura conceitual é:

n_quads = estimate_num_quads(cubic, 0.25)
Avalie a cúbica em 2*n_quads+1 pontos igualmente espaçados em t.
Para cada quadrática i, calcule params_i = estimate_subdiv(quad_i, sqrt(0.225)), guarde a0, da=a2-a0, u0, uscale, val.
n_total = max(ceil(0.5*Σval / sqrt(0.225)), 1).
Distribua n_total pontos entre as quadráticas proporcionalmente a val, usando determine_subdiv_t dentro de cada uma.
3. Geração de Tiles
Arquivo: C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\tile.rs

3.1 A struct Tile (8 bytes)

#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct Tile {
    #[cfg(target_endian = "big")]  pub y: u16,
    #[cfg(target_endian = "big")]  pub x: u16,

    /// - **Bits 0-4 (5 bits):** Intersection and Winding Mask (`W | R | L | B | T`).
    ///   - Bit 0 (0b00001): Intersects top edge (T)
    ///   - Bit 1 (0b00010): Intersects bottom edge (B)
    ///   - Bit 2 (0b00100): Intersects left edge (L)
    ///   - Bit 3 (0b01000): Intersects right edge (R)
    ///   - Bit 4 (0b10000): Winding (W) - 1 if crosses top edge.
    /// - **Bits 5-31 (27 bits):** The line index (`line_idx`).
    pub packed_winding_line_idx: u32,

    #[cfg(target_endian = "little")] pub x: u16,
    #[cfg(target_endian = "little")] pub y: u16,
}
Tamanho: 8 bytes (u16 + u16 + u32). A ordenação dos campos é escolhida para que a chave de ordenação u64 seja literalmente a representação em memória (no-op):


const fn to_bits(self) -> u64 {
    // Note that for correct rendering, tiles only need to be sorted on `(y, x)`. Sorting on
    // the line index in addition to the coordinate improves data locality in strip rendering.
    ((self.y as u64) << 48) | ((self.x as u64) << 32) | self.packed_winding_line_idx as u64
}
Ordem de sort: y crescente → x crescente → line_idx crescente → intersection_mask.

Constantes de bit:


const T: u32 = 0b00001;  // top
const B: u32 = 0b00010;  // bottom
const L: u32 = 0b00100;  // left
const R: u32 = 0b01000;  // right
const W: u32 = 0b10000;  // winding
const INTERSECTION_MASK: u32 = W | R | L | B | T;
const INT_MASK_SHIFT: u32 = INTERSECTION_MASK.count_ones();  // = 5
pub const MAX_LINES_PER_PATH: u32 = 1 << (32 - INT_MASK_SHIFT);  // 2^27
Nota crucial para Dart: existem duas funções de tiling. make_tiles_msaa calcula os 5 bits completos (T/B/L/R/W) e é usada pelo caminho MSAA. make_tiles_analytic_aa — a que o StripGenerator realmente usa — só preenche o bit W; os bits T/B/L/R são deixados em zero, porque o cálculo exato de cobertura é feito depois, em strip::render, direto a partir da equação da linha. Implemente apenas a versão analítica.

3.2 make_tiles_analytic_aa
Assinatura e primeiros passos:


fn make_tiles_analytic_aa_impl<S: Simd>(&mut self, s: S, lines: &[Line], width: u16, height: u16) -> bool {
    self.reset(width, height);
    if width == 0 || height == 0 { return self.windings.culled; }

    let tile_columns = width.div_ceil(Tile::WIDTH);
    let tile_rows    = height.div_ceil(Tile::HEIGHT);

    for (line_idx, line) in lines.iter().take(MAX_LINES_PER_PATH as usize).enumerate() {
        // Trabalha em ESPAÇO DE TILE: divide por 4.
        let p0_x = line.p0.x / f32::from(Tile::WIDTH);
        let p0_y = line.p0.y / f32::from(Tile::HEIGHT);
        let p1_x = line.p1.x / f32::from(Tile::WIDTH);
        let p1_y = line.p1.y / f32::from(Tile::HEIGHT);
        ...
Ordenação canônica: (line_top_y, line_top_x, line_bottom_y, line_bottom_x) = extremidade de menor y primeiro. E:


let dir = if p0_y >= p1_y { 1 } else { -1 };   // +1 = sobe (y decrescente), -1 = desce
Culling rápido:

line_left_x > tile_columns → descarta (totalmente à direita).
y_top_tiles >= y_bottom_tiles → descarta (totalmente acima/abaixo, ou horizontal alinhada à grade).
Depois há três caminhos:

(a) Linha inteiramente à esquerda do viewport (line_right_x < 0.0) — não gera tiles, mas gera winding, que é registrado em CulledWindings (ver §3.3). Marca self.windings.culled = true.

(b) Linha contida em um único tile (p0_tile == p1_tile):


let tile = Tile::new_clamped(
    (line_left_x as u16).min(tile_columns + 1),
    y_top_tiles,
    line_idx,
    ((f32::from(y_top_tiles) >= line_top_y) as u32) << WINDING_SHIFT,
);
self.tile_buf.push(tile);
(c) Caso geral. Para linhas puramente verticais (line_left_x == line_right_x): um tile por linha de tiles, todos com W exceto possivelmente o primeiro. Para o caso geral (não vertical), percorre-se linha de tiles por linha de tiles, calculando o intervalo horizontal [row_left_x, row_right_x] da linha dentro daquela faixa:


let dx = p1_x - p0_x;
let dy = p1_y - p0_y;
let x_slope = dx / dy;
let dx_dir = (line_bottom_x >= line_top_x) as u32;     // 1 se vai para a direita
let not_dx_dir = dx_dir ^ 1;
let w_start_base = dx_dir     << WINDING_SHIFT;
let w_end_base   = not_dx_dir << WINDING_SHIFT;
e emite os tiles daquela faixa:


let push_row_extents = |tile_buf: &mut Vec<Tile>,
                        y_idx: u16, row_left_x: f32, row_right_x: f32,
                        w_start: u32, w_end: u32, w_single: u32| {
    let x_start = row_left_x as u16;
    let x_end = (row_right_x as u16).min(tile_columns - 1);

    if x_start <= x_end {
        let winding = if x_start == x_end { w_single } else { w_start };
        tile_buf.push(Tile::new(x_start, y_idx, line_idx, winding));

        for x_idx in x_start.saturating_add(1)..x_end {
            tile_buf.push(Tile::new(x_idx, y_idx, line_idx, 0));
        }

        if x_start < x_end {
            tile_buf.push(Tile::new(x_end, y_idx, line_idx, w_end));
        }
    }
};
Semântica do bit W: W marca o tile onde a linha cruza a borda superior daquele tile. Se a linha desce para a direita (dx_dir=1), a travessia da borda superior acontece no tile mais à esquerda da faixa (w_start = W); se vai para a esquerda, acontece no tile mais à direita (w_end = W). Quando a faixa tem um único tile, w_single = W. Para a primeira faixa de tiles da linha, isso só vale se a linha realmente começa acima da borda: máscara mask = ((y >= line_top_y) as u32) << WINDING_SHIFT aplicada com AND.

Otimização importante: existe um caminho rápido quando a linha inteira está dentro do viewport horizontalmente (line_left_x >= 0.0 && line_right_x < tile_columns), que pula todo o clamping e a lógica de winding culled, e reaproveita row_top_x da iteração anterior:


let mut row_top_x = p0_x + (f32::from(y_start) - p0_y) * x_slope;
for y_idx in y_start..y_bottom_tiles {
    let y = f32::from(y_idx);
    // Note: We purposefully don't precompute it once and just increment by `x_slope`
    // after every iteration to avoid errors due to floating point inaccuracies.
    let row_bottom_x = if line_bottom_y < y + 1.0 { line_bottom_x }
                       else { p0_x + (y + 1.0 - p0_y) * x_slope };
    push_row_extents(&mut self.tile_buf, y_idx,
                     f32::min(row_top_x, row_bottom_x),
                     f32::max(row_top_x, row_bottom_x),
                     w_start_base, w_end_base, W);
    row_top_x = row_bottom_x;
}
3.3 CulledWindings — winding de geometria fora da tela à esquerda
Este é o mecanismo que permite culling agressivo mantendo correção: geometria totalmente à esquerda do viewport não gera tiles, mas ainda precisa contribuir para o winding.


pub struct CulledWindings {
    /// Fractional winding coverage for each individual scanline in a row.
    pub partial: Vec<[f32; Tile::HEIGHT as usize]>,   // 4 f32 por linha de tiles
    /// Accumulated integer winding deltas for each tile row.
    pub coarse: Vec<i16>,
    /// Bitmask tracking which rows contain active geometry or winding data.
    pub active: Vec<u32>,
    /// Flag indicating if any geometry was early-culled outside the viewport.
    pub culled: bool,
    height: u16,
}
coarse[row]: winding inteiro em x = 0 para aquela linha de tiles (± dir por travessia de borda superior).
partial[row][k] (k = 0..3, uma scanline de pixel cada): cobertura fracionária em x = 0.
active: bitset (32 linhas por palavra u32) para varredura rápida de linhas não-vazias, com mark_row_active, mark_row_range_active e for_active_rows_in_range.
Cobertura fracionária por scanline (SIMD 4-wide, uma lane por scanline do tile):


macro_rules! calc_fractional_coverage {
    ($y_idx:expr, $segment_top_y:expr, $segment_bottom_y:expr) => {{
        let y_idx_f32 = f32::from($y_idx);
        let local_y_start = ($segment_top_y    - y_idx_f32) * tile_height_f32;
        let local_y_end   = ($segment_bottom_y - y_idx_f32) * tile_height_f32;
        let start_v = f32x4::splat(s, local_y_start);
        let end_v   = f32x4::splat(s, local_y_end);
        // px_top = [0,1,2,3], px_bottom = [1,2,3,4]
        (px_bottom.min(end_v) - px_top.max(start_v)).max(simd_zero)
    }};
}
Isto é a fração vertical da scanline k coberta pelo segmento. Multiplicada por dir (f_dir_v) e acumulada. Cuidado com contagem dupla: quando a linha cruza a borda superior do tile, o coarse já contabilizou 1 unidade inteira, então o fracionário subtrai f_dir:


let double_count = if at_top_of_tile { f_dir_v } else { f32x4::splat(s, 0.0) };
let next = fractional_coverage.mul_add(f_dir_v, current - double_count);
next.store_slice(target_row);
4. Geração de Strips — o coração do algoritmo
Arquivo: C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\strip.rs

4.1 A struct Strip (8 bytes)

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Strip {
    /// The x coordinate of the strip, in user coordinates.
    pub x: u16,
    /// The y coordinate of the strip, in user coordinates.
    pub y: u16,
    /// Packed alpha index and fill gap flag.
    ///
    /// Bit layout (u32):
    /// - bit 31: `fill_gap` (See `Strip::fill_gap()`).
    /// - bits 0..=30: `alpha_idx` (See `Strip::alpha_idx()`).
    packed_alpha_idx_fill_gap: u32,
}
8 bytes. Note que não há campo width nem winding. Isso é fundamental:


impl Strip {
    const FILL_GAP_MASK: u32 = 1 << 31;

    pub fn new(x: u16, y: u16, alpha_idx: u32, fill_gap: bool) -> Self { ... }

    /// Creates a sentinel strip.
    pub fn sentinel(y: u16, alpha_idx: u32) -> Self {
        Self::new(u16::MAX, y, alpha_idx, false)
    }

    pub fn is_sentinel(&self) -> bool { self.x == u16::MAX }

    /// Return the y coordinate of the strip, in strip units.
    pub fn strip_y(&self) -> u16 { self.y / Tile::HEIGHT }

    /// Returns the horizontal pixel width of this strip.
    /// **IMPORTANT**: This assumes that the `next` is actually the next adjacent strip
    /// to `self`, otherwise this method will return a garbage value!
    pub fn width_to(&self, next: &Self) -> u16 {
        let col      = self.alpha_idx() / u32::from(Tile::HEIGHT);
        let next_col = next.alpha_idx() / u32::from(Tile::HEIGHT);
        next_col.saturating_sub(col) as u16
    }

    pub fn alpha_idx(&self) -> u32 { self.packed_alpha_idx_fill_gap & !Self::FILL_GAP_MASK }
    pub fn fill_gap(&self) -> bool { (self.packed_alpha_idx_fill_gap & Self::FILL_GAP_MASK) != 0 }
}
Invariantes essenciais:

x e y são coordenadas de pixel (tile.x * 4, tile.y * 4), sempre alinhados a tile.
A largura de uma strip é derivada da diferença de alpha_idx entre ela e a próxima strip do buffer. Cada coluna de pixel consome Tile::HEIGHT = 4 bytes de alpha. Logo width_px = (next.alpha_idx - this.alpha_idx) / 4.
Por isso a lista sempre termina com uma sentinel strip (x = u16::MAX), que fornece o alpha_idx final.
fill_gap significa: "o espaço entre o fim da strip anterior (na mesma linha) e o início desta strip deve ser preenchido sólido" — este é o sparse fill, a região interior da forma. Ele substitui o campo "winding" que você esperava: a decisão nonzero/evenodd já foi resolvida na geração e comprimida em 1 bit.
4.2 Iterando strips: visit_strip_fill_segments
Esta é a função que todo consumidor (CPU coarse e híbrido) usa para transformar [Strip] em regiões desenháveis:


pub struct StripAlphaFillSegment {
    pub fill: StripFillSegment,
    pub alpha_idx: u32,
}

pub struct StripFillSegment {
    /// The inclusive start x coordinate in tile units.
    pub tile_x0: u16,
    /// The exclusive end x coordinate in tile units.
    pub tile_x1: u16,
    /// The y coordinate in tile units.
    pub tile_y: u16,
}

pub fn visit_strip_fill_segments<C>(
    strips: &[Strip],
    tile_bounds: RectU16,
    context: &mut C,
    mut alpha_fill: impl FnMut(&mut C, StripAlphaFillSegment),
    mut fill: impl FnMut(&mut C, StripFillSegment),
) {
    if strips.len() < 2 || tile_bounds.is_empty() { return; }

    for pair in strips.windows(2) {
        let strip = pair[0];
        let tile_y = strip.strip_y();

        if tile_y < tile_bounds.y0 { continue; }
        if tile_y >= tile_bounds.y1 { break; }

        let next_strip = pair[1];
        let strip_width = strip.width_to(&next_strip);

        let strip_tile_x0 = strip.x / Tile::WIDTH;
        let strip_tile_x1 = strip_tile_x0.saturating_add(strip_width / Tile::WIDTH);
        let tile_x0 = strip_tile_x0.max(tile_bounds.x0);
        let tile_x1 = strip_tile_x1.min(tile_bounds.x1);

        if tile_x0 < tile_x1 {
            alpha_fill(context, StripAlphaFillSegment {
                fill: StripFillSegment { tile_x0, tile_x1, tile_y },
                // Make sure to recalculate the index in case we had to clip.
                alpha_idx: strip.alpha_idx()
                    + u32::from(tile_x0 - strip_tile_x0)
                        * u32::from(Tile::WIDTH) * u32::from(Tile::HEIGHT),
            });
        }

        if next_strip.fill_gap() && next_strip.y == strip.y {
            let tile_x0 = strip_tile_x1.max(tile_bounds.x0);
            let tile_x1 = (next_strip.x / Tile::WIDTH).min(tile_bounds.x1);
            if tile_x0 < tile_x1 {
                fill(context, StripFillSegment { tile_x0, tile_x1, tile_y });
            }
        }
    }
}
Resumo mental: cada par (strip[i], strip[i+1]) produz

uma região anti-aliased [strip.x, strip.x + width) com máscara de alpha;
opcionalmente uma região sólida [strip.x + width, next.x) se next.fill_gap() e mesma linha.
4.3 Layout do buffer de alphas
Cada tile location (4×4 pixels) contribui com 16 bytes para alpha_buf, organizados column-major:


byte offset:  0  1  2  3 | 4  5  6  7 | 8  9 10 11 | 12 13 14 15
pixel:       (0,0..3)    | (1,0..3)   | (2,0..3)   | (3,0..3)
Isto é, alpha[col*4 + row]. Portanto:

alpha_idx é um índice em bytes;
coluna de pixel = alpha_idx / Tile::HEIGHT;
clipping horizontal de n tiles ⇒ deslocamento de n * 4 * 4 = n*16 bytes.
4.4 strip::render — acumulação de cobertura e winding
Esta é a função central. Assinatura:


pub fn render(
    level: Level,
    tiles: &Tiles,
    strip_buf: &mut Vec<Strip>,
    alpha_buf: &mut Vec<u8>,
    fill_rule: Fill,
    aliasing_threshold: Option<u8>,
    lines: &[Line],
)
Estado do laço

let should_fill = |winding: i32| match fill_rule {
    Fill::NonZero => winding != 0,
    Fill::EvenOdd => winding % 2 != 0,
};

// The accumulated tile winding delta. A line that crosses the top edge of a tile
// increments the delta if the line is directed upwards, and decrements it if goes
// downwards. Horizontal lines leave it unchanged.
let mut winding_delta: i32 = 0;

let mut prev_tile = *tiles.get(0);

// The accumulated (fractional) winding of the tile-sized location we're currently at.
// Note multiple tiles can be at the same location.
// Note that we are also implicitly assuming here that the tile height exactly fits into a
// SIMD vector (i.e. 128 bits).
let mut location_winding = [f32x4::splat(s, 0.0); Tile::WIDTH as usize];

// The accumulated (fractional) windings at this location's right edge. When we move to the
// next location, this is splatted to that location's starting winding.
let mut accumulated_winding = f32x4::splat(s, 0.0);
location_winding[x] é um vetor de 4 floats: a área acumulada (winding fracionário) do pixel (x, y) para y = 0..3 do tile atual. accumulated_winding é o winding na borda direita do tile, propagado para o próximo tile.

Núcleo: acumulação analítica de área por pixel
O comentário do código explica a teoria (linhas 584-612 de strip.rs):

Conceptually, horizontal rays are shot from left to right. Every time the ray crosses a line that is directed upwards (decreasing y), the winding is incremented. Every time the ray crosses a line moving downwards (increasing y), the winding is decremented. The fractional area coverage of a pixel is the integral of the winding within it.

Practically, to calculate this, each pixel is considered individually, and we determine whether the line moves through this pixel. The line's y-delta within this pixel is accumulated and added to the area coverage of pixels to the right. Within the pixel itself, the area to the right of the line segment forms a trapezoid (or a triangle in the degenerate case).


// coordenadas relativas ao canto superior-esquerdo do tile
let tile_left_x = f32::from(tile.x) * f32::from(Tile::WIDTH);
let tile_top_y  = f32::from(tile.y) * f32::from(Tile::HEIGHT);
let p0_x = line.p0.x - tile_left_x;   let p0_y = line.p0.y - tile_top_y;
let p1_x = line.p1.x - tile_left_x;   let p1_y = line.p1.y - tile_top_y;

if p0_y == p1_y { continue; }   // horizontal não contribui

// Lines moving upwards (in a y-down coordinate system) add to winding;
// lines moving downwards subtract from winding.
let sign = (p0_y - p1_y).signum();

let (line_top_y, line_top_x, line_bottom_y, line_bottom_x) =
    if p0_y < p1_y { (p0_y, p0_x, p1_y, p1_x) } else { (p1_y, p1_x, p0_y, p0_x) };

let y_slope = (line_bottom_y - line_top_y) / (line_bottom_x - line_top_x);
let x_slope = 1. / y_slope;

winding_delta += sign as i32 * i32::from(tile.winding());

let line_top_y    = f32x4::splat(s, line_top_y);
let line_bottom_y = f32x4::splat(s, line_bottom_y);
let line_px_base_yx = line_top_y.mul_add(-x_slope, line_top_x);

let px_top_y    = f32x4::simd_from(s, [0., 1., 2., 3.]);
let px_bottom_y = 1. + px_top_y;

let ymin = line_top_y.max(px_top_y);
let ymax = line_bottom_y.min(px_bottom_y);

let mut acc = f32x4::splat(s, 0.0);

for x_idx in 0..Tile::WIDTH {
    let x_idx_s   = f32x4::splat(s, x_idx as f32);
    let px_left_x  = x_idx_s;
    let px_right_x = 1.0 + x_idx_s;

    // y da interseção da linha com as bordas esquerda/direita do pixel, clampado a [ymin, ymax]
    let line_px_left_y = (px_left_x - line_top_x)
        .mul_add(y_slope, line_top_y)
        .max_if_first_nan_take_second(ymin)
        .min(ymax);
    let line_px_right_y = (px_right_x - line_top_x)
        .mul_add(y_slope, line_top_y)
        .max_if_first_nan_take_second(ymin)
        .min(ymax);

    // x correspondentes
    let line_px_left_yx  = line_px_left_y.mul_add(x_slope, line_px_base_yx);
    let line_px_right_yx = line_px_right_y.mul_add(x_slope, line_px_base_yx);
    let h = (line_px_right_y - line_px_left_y).abs();

    // The trapezoidal area enclosed between the line and the right edge of the pixel
    // square. More straightforwardly written as follows, but the `madd` is faster.
    // 0.5 * h * (2. * px_right_x - line_px_right_yx - line_px_left_yx).
    let area = h * (line_px_right_yx + line_px_left_yx).mul_add(-0.5, px_right_x);
    location_winding[x_idx as usize] += area.mul_add(sign, acc);
    acc = h.mul_add(sign, acc);
}

accumulated_winding += acc;
Explicação passo a passo (para reimplementar):

Para cada uma das 4 scanlines (lane do f32x4) e cada uma das 4 colunas de pixel:
line_px_left_y / line_px_right_y = onde a linha entra/sai da coluna do pixel, verticalmente, já recortado ao intervalo [max(topo_linha, topo_pixel), min(base_linha, base_pixel)].
h = altura do segmento dentro daquele pixel (0 se a linha não passa por ele).
area = área do trapézio entre a linha e a borda direita do pixel = h * (px_right_x - média_dos_x).
acc acumula h*sign da esquerda para a direita: pixels à direita da linha recebem cobertura total daquela travessia.
sign = +1 se a linha sobe (y decrescente), -1 se desce.
Armadilhas de ponto flutuante documentadas (comentário de 30 linhas em strip.rs:645-696): para linhas puramente verticais, y_slope = ±inf; 0*inf = NaN quando a borda do pixel coincide exatamente com a linha. A convenção é que a linha pertence ao pixel de cuja borda esquerda ela está. O código exige que max(NaN, ymin) retorne ymin (semântica de _mm_max_ps no x86; em ARM usa max_precise). Em Dart você precisará tratar isso explicitamente, ex.: final v = a.isNaN ? ymin : math.max(a, ymin).

Conversão para alpha (aplicação da fill rule)
Quando o laço avança para um novo tile location (!prev_tile.same_loc(&tile)), os 16 valores de location_winding viram 16 bytes de alpha:


match fill_rule {
    Fill::NonZero => {
        let p1 = f32x4::splat(s, 0.5);
        let p2 = f32x4::splat(s, 255.0);
        for x in 0..Tile::WIDTH as usize {
            let area = location_winding[x];
            let coverage = area.abs();
            let mulled = coverage.mul_add(p2, p1);
            // Note that we are not storing the location winding here but the actual
            // alpha value as f32, so we reuse the variable as a temporary storage.
            // Also note that we need the `min` here because the winding can be > 1
            // and thus the calculated alpha value need to be clamped to 255.
            location_winding[x] = mulled.min(p2);
        }
    }
    Fill::EvenOdd => {
        let p1 = f32x4::splat(s, 0.5);
        let p2 = f32x4::splat(s, -2.0);
        let p3 = f32x4::splat(s, 255.0);
        for x in 0..Tile::WIDTH as usize {
            let area = location_winding[x];
            let im1 = area.mul_add(p1, p1).floor();          // floor(area*0.5 + 0.5)
            let coverage = p2.mul_add(im1, area).abs();      // |area - 2*im1|
            let mulled = p3.mul_add(coverage, p1);
            location_winding[x] = mulled.min(p3);
        }
    }
};

let p1 = s.combine_f32x4(location_winding[0], location_winding[1]);
let p2 = s.combine_f32x4(location_winding[2], location_winding[3]);
let mut u8_vals = f32_to_u8(s.combine_f32x8(p1, p2));

if let Some(aliasing_threshold) = aliasing_threshold {
    u8_vals = s.select_u8x16(
        u8_vals.simd_ge(u8x16::splat(s, aliasing_threshold)),
        u8x16::splat(s, 255),
        u8x16::splat(s, 0),
    );
}

alpha_buf.extend_from_slice(u8_vals.as_slice());

for x in 0..Tile::WIDTH as usize {
    location_winding[x] = accumulated_winding;   // propaga para o próximo tile
}
NonZero: alpha = min(255, round(|w| * 255)).
EvenOdd: dobra triangular — alpha = min(255, round(|w - 2*floor(w/2 + 0.5)| * 255)). Isto mapeia w para o "sawtooth" [-1, 1] e toma o valor absoluto.
aliasing_threshold: Option<u8> desliga o AA (binariza em 0/255) — usado para renderização "crisp"/aliased.
f32_to_u8 faz truncamento, por isso o +0.5 embutido no mul_add para arredondar.
Emissão de strips e do bit fill_gap

// Push out the strip if we're moving to a next strip.
if !prev_tile.same_loc(&tile) && !prev_tile.prev_loc(&tile) {
    strip_buf.push(strip);

    let is_sentinel = tile_idx == tiles.len() as usize;
    let left_viewport = tile.x == 0;
    if !prev_tile.same_row(&tile) {
        // Emit a final strip in the row if there is non-zero winding for the sparse fill
        if winding_delta != 0 {
            strip_buf.push(Strip::new(
                viewport_width,
                prev_tile.y * Tile::HEIGHT,
                alpha_buf.len() as u32,
                should_fill(winding_delta),
            ));
        }
        ...
        winding_delta = 0;
        accumulated_winding = f32x4::splat(s, 0.0);
        for x in 0..Tile::WIDTH as usize { location_winding[x] = accumulated_winding; }
    } else {
        // Note: this fill is mathematically not necessary. It provides a way to reduce
        // accumulation of float rounding errors.
        accumulated_winding = f32x4::splat(s, winding_delta as f32);
    }

    if is_sentinel { break; }

    strip = Strip::new(
        tile.x * Tile::WIDTH,
        tile.y * Tile::HEIGHT,
        alpha_buf.len() as u32,
        should_fill(winding_delta) && !left_viewport,
    );
}
prev_tile = tile;
Regras de merge (as três condições que você precisa reproduzir exatamente):

prev_tile.same_loc(&tile) (mesmo x e y): múltiplas linhas no mesmo tile — apenas continua acumulando em location_winding, sem flush.
prev_tile.prev_loc(&tile) (same_row && prev.x + 1 == tile.x): tiles adjacentes horizontalmente — faz flush do alpha do tile anterior mas continua a mesma strip (a strip cresce em largura).
Caso contrário: quebra de strip. Empurra a strip corrente e começa uma nova em tile.x*4, com fill_gap = should_fill(winding_delta) && !left_viewport.
Note que o fill_gap da nova strip descreve o gap anterior a ela — por isso visit_strip_fill_segments lê next_strip.fill_gap().

Quando muda de linha de tiles, se winding_delta != 0, emite-se uma strip de largura zero na borda direita do viewport (viewport_width) com fill_gap = should_fill(winding_delta), para preencher até a borda direita. viewport_width é arredondado para múltiplo de Tile::WIDTH:


let viewport_width = tiles.width()
    // We need to make sure strips are tile-aligned.
    .checked_next_multiple_of(Tile::WIDTH)
    .unwrap_or(u16::MAX);
Sentinel final

let maybe_emit_sentinel_strip = |strip_buf: &mut Vec<Strip>, alpha_buf: &Vec<u8>| {
    if let Some(last_y) = strip_buf[strip_start..].last().map(|s| s.y) {
        strip_buf.push(Strip::sentinel(last_y, alpha_buf.len() as u32));
    }
};
Reconstrução do fundo culled
Se houve culling à esquerda, linhas sem nenhum tile precisam ser reconstruídas a partir de windings.coarse:


/// We reconstruct this "background" fill using `row_windings` (the winding at x=0) to emit solid
/// strips for:
///      1. All rows vertically above the first visible tile.
///      2. 'Captive' rows between two tile-containing rows.
///      3. All rows vertically below the last visible tile.
fn emit_culled_background<F>(start: u16, end: u16, viewport_width: u16,
                             strips: &mut Vec<Self>, alphas: &mut Vec<u8>,
                             windings: &CulledWindings, mut should_fill: F)
where F: FnMut(i32) -> bool {
    windings.for_active_rows_in_range(start as usize, end as usize, |row| {
        if should_fill(windings.coarse[row] as i32) {
            let y_pos = row as u16 * Tile::HEIGHT;
            strips.push(Self::new(0, y_pos, alphas.len() as u32, false));
            // TODO: Would be nice to get rid of this, but the current clipping code only
            // allows zero-width strips as a row terminator, not in-between.
            alphas.extend([255_u8; Tile::HEIGHT as usize * Tile::WIDTH as usize]);
            strips.push(Self::new(viewport_width, y_pos, alphas.len() as u32, true));
        }
    });
}
E o "captive strip", quando uma linha tem tiles mas o primeiro não está em x=0:


let emit_captive_strip = |y: u16, is_left_viewport: bool, strips: &mut Vec<Strip>, alphas: &mut Vec<u8>| {
    let coarse_wd = tiles.windings.coarse[y as usize] as i32;
    if should_fill(coarse_wd) && !is_left_viewport {
        strips.push(Strip::new(0, y * Tile::HEIGHT, alphas.len() as u32, false));
        alphas.extend([255_u8; Tile::HEIGHT as usize * Tile::WIDTH as usize]);
    }
    let mut acc = f32x4::splat(s, coarse_wd as f32);
    if is_left_viewport {
        let fine_winding: f32x4<_> = tiles.windings.partial[y as usize].simd_into(s);
        acc += fine_winding;
    }
    (coarse_wd, acc)
};
Simplificação sugerida para Dart: se você não implementar culling agressivo (i.e., passar sempre cull_bbox = viewport inteiro e não emitir CulledWindings), pode omitir toda essa lógica de culled/captive. O algoritmo core funciona sem ela; ela é uma otimização para paths gigantes fora da tela.

4.5 Caminho rápido para retângulos
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\rect.rs gera strips diretamente, sem flatten/tile/sort. Estratégia documentada no cabeçalho:

Linhas de borda (topo/base do retângulo caem no meio do tile): uma única strip larga cobrindo todas as colunas de tile, com alpha = x_alpha * y_alpha.
Linhas interiores: uma strip à esquerda (máscara x) + uma strip à direita com fill_gap = true (o preenchimento sólido entre elas é implícito).

// `fill_gap = true` tells the renderer to fill solid 0xFF
// between the previous strip's end and this strip's start.
strip_buf.push(Strip::new(right_tile_x, strip_y, alpha_start, true));
Há testes exaustivos (rect_fractional_exhaustive, 10 000 casos) que verificam que este caminho produz bytes idênticos ao caminho geral.

4.6 Orquestração: StripGenerator
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\strip_generator.rs


pub struct StripStorage {
    pub strips: Vec<Strip>,
    pub alphas: Vec<u8>,
    generation_mode: GenerationMode,   // Replace | Append | ReplaceAfter(usize)
}

fn generate_with_clip(&mut self, aliasing_threshold, strip_storage, fill_rule, clip_path) {
    self.tiles.make_tiles_analytic_aa(self.level, &self.line_buf, self.width, self.height);
    self.tiles.sort_tiles();
    render_with_clip(level, &mut self.temp_storage, strip_storage, clip_path, |strips, alphas| {
        strip::render(level, tiles, strips, alphas, fill_rule, aliasing_threshold, line_buf);
    });
}
5. Clipping via interseção de strips (CPU, compartilhado)
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_common\src\clip.rs, fn intersect_impl.

Documentação literal do algoritmo:

Conceptually, it is relatively simple: We iterate over each strip and fill region of the two paths in lock step and determine all overlaps between the two. For each overlap, we proceed depending on what kind of region we have in the first path and the second one.

In case we have two fill regions, the overlap region will also be filled.
In case we have one strip and one fill region, the overlap region will copy the alpha mask of the strip region.
Finally, if we have two strip regions, we combine the alpha masks of both.
All regions that are not filled in either path are simply ignored.
Combinação de duas máscaras (multiplicação normalizada, 16 bytes = 1 tile por vez):


let num_blocks = overlap.width() / Tile::HEIGHT;
let s1_alphas = s_region_1.alphas[(overlap.start - s_region_1.start) as usize * 4..]
    .chunks_exact(16).take(num_blocks as usize);
let s2_alphas = ...;
for (s1_alpha, s2_alpha) in s1_alphas.zip(s2_alphas) {
    let s1 = u8x16::from_slice(simd, s1_alpha);
    let s2 = u8x16::from_slice(simd, s2_alpha);
    let res = simd.narrow_u16x16(normalized_mul_u8x16(s1, s2));
    target.alphas.extend(res.as_slice());
}
Otimizações: partition_point (busca binária) para achar a primeira strip de uma linha; recorte vertical ao intervalo compartilhado dos dois bboxes; extensão de strip corrente em vez de criar nova quando contígua.

O clip é resolvido inteiramente na CPU, em espaço de strips. Tanto vello_cpu quanto vello_hybrid reusam isso — no híbrido, é o clip_path.strip_range que gera as strips de composição de layer.

6. Fine rasterization no vello_cpu
6.1 Estágio coarse: CommandBucketer (substituto do WideTile)
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\coarse\bucketer.rs


/// State for a single row of strips.
pub(crate) struct RowState {
    /// Normal render commands rendered in back-to-front with depth buffer read.
    pub(crate) render_cmds: Vec<RenderCmd>,
    /// Opaque fill commands rendered front-to-back with depth buffer read and write.
    pub(crate) depth_cmds: Vec<DepthFill>,
    depth: DepthState,
    pub(super) layer_depth: usize,
    layer_stack: Vec<RowLayerState>,
}
O número de linhas é viewport.height() / Tile::HEIGHT. Cada linha cobre a largura inteira do viewport — não há mais subdivisão em wide tiles de 256px.

6.2 Comandos
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\coarse\cmd.rs


/// A bucketed render command.
pub(crate) enum RenderCmd {
    /// See [`PaintFill`].
    PaintFill(PaintFill),
    /// Push a new temporary layer buffer.
    PushBuf(Option<Span>),
    /// Pop the last temporary layer buffer.
    PopBuf,
    /// See [`LayerFill`].
    LayerFill(LayerFill),
}

/// Fill a span with the given paint and optionally some alpha coverage.
pub(crate) struct PaintFill {
    pub(crate) span: Span,
    alpha_idx: Option<AlphaIdx>,   // NonZeroU32 => Option cabe em 4 bytes
    pub(crate) attrs_idx: u32,
}

/// Fill a whole range of depth buckets with the given paint.
pub(crate) struct DepthFill {
    bucket_range: BucketRange,
    pub(crate) attrs_idx: u32,
}

/// Composite a span from the current temporary layer buffer into the parent buffer
/// and optionally apply some alpha coverage.
pub(crate) struct LayerFill {
    pub(crate) span: Span,
    alpha_idx: Option<AlphaIdx>,
    pub(crate) attrs_idx: u32,
}
Com testes de tamanho: size_of::<RenderCmd>() == 16 e size_of::<Option<AlphaIdx>>() == 4.

Mapeamento para a nomenclatura antiga:

Cmd::AlphaFill ≡ RenderCmd::PaintFill com alpha_idx = Some(_)
Cmd::Fill ≡ RenderCmd::PaintFill com alpha_idx = None
Cmd::PushBuf / PopBuf ≡ idem
Cmd::ClipFill/ClipStrip ≡ RenderCmd::LayerFill
Span (vello_cpu/src/util.rs) é {x: u16, width: u16} em pixels, com helpers tile_x(), tile_end(), intersect(), extend().

6.3 Depth buffer de CPU
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\coarse\depth.rs — módulo com documentação excelente:

Unlike GPUs, it is not feasible to have a per-pixel depth buffer. […] It is much faster to just fill a 256x1 buffer of pixels with a single colors than doing it in 32 chunks of 4x1, just to save 50% pixel work.


pub(crate) const DEPTH_BUCKET_WIDTH: u16 = 128;
const DEPTH_BUCKET_TILE_WIDTH: u16 = DEPTH_BUCKET_WIDTH / Tile::WIDTH;   // 32
Fluxo:

Fills opacos (sem blend, sem mask, sem layer, paint opaco) são divididos por split_opaque_span em: bordas não-alinhadas (DepthSegment::Regular) + miolo alinhado a buckets de 128px (DepthSegment::Opaque).
Na rasterização, primeiro renderiza-se depth_cmds front-to-back com escrita no depth buffer (for_each_unset_run_and_write).
Depois render_cmds back-to-front com leitura (for_each_visible_run), pulando trechos já cobertos por opaco de z maior.
init_uncovered_range só limpa/descompacta as regiões não cobertas por opacos.
O depth buffer é Vec<u32> de draw_id máximo por bucket; draw_id começa em 1 (0 = "vazio").

6.4 Buffer de fine rasterization
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_cpu\src\fine\mod.rs


pub(crate) const COLOR_COMPONENTS: usize = 4;
pub(crate) const TILE_HEIGHT_COMPONENTS: usize = Tile::HEIGHT as usize * COLOR_COMPONENTS; // 16

pub struct Fine<S: Simd, T: FineKernel<S>> {
    simd: S,
    buffer_span: Span,
    /// Stack of blend buffers for managing layers and composition.
    blend_buffers: Vec<Vec<T::Numeric>>,
    buffer_pool: VecPool<T::Numeric>,
    paint_buf: Vec<T::Numeric>,
    f32_buf: Vec<f32>,
    row_y: u16,
    origin: (u16, u16),
}

fn scratch_range(span: Span) -> core::ops::Range<usize> {
    let start = usize::from(span.pixel_x()) * TILE_HEIGHT_COMPONENTS;
    let len   = usize::from(span.pixel_width()) * TILE_HEIGHT_COMPONENTS;
    start..start + len
}
Layout do buffer de pixels: column-major dentro do tile, igual ao alpha buffer. De vello_cpu/src/fine/lowp/mod.rs:390:


let idx = COLOR_COMPONENTS * (Tile::HEIGHT as usize * dx + usize::from(y));
Isto é: buffer[4 * (4*coluna + linha) + canal]. Uma coluna de tile = 16 floats/bytes contíguos = exatamente 1 registrador SIMD de 128 bits (u8) ou 4 (f32).

6.5 Execução de um comando

fn run_cmd(&mut self, cmd: RenderCmd, bucketer: &CommandBucketer, row: &RowState,
           row_y: u16, resources: FineResources<'_>, depth: &DepthBuffer) {
    match cmd {
        RenderCmd::PaintFill(cmd) => {
            let attrs = &bucketer.paint_fill_attrs[cmd.attrs_idx as usize];
            let alpha_buffer = resources.alpha_buffers[attrs.thread_idx as usize];
            let Some(span) = cmd.span.intersect(self.buffer_span) else { return; };

            let paint_fill = |fine: &mut Self, span: Span| {
                let alphas = cmd.alpha_idx().map(|alpha_idx| {
                    let alpha_offset = alpha_idx as usize
                        + usize::from(span.pixel_x() - cmd.span.pixel_x()) * Tile::HEIGHT as usize;
                    &alpha_buffer[alpha_offset..]
                });
                fine.paint_fill(span, attrs, resources, alphas);
            };

            if !row.can_skip_depth(span, attrs.draw_id) {
                depth.for_each_visible_run(span, attrs.draw_id, |span| paint_fill(self, span));
            } else {
                paint_fill(self, span);
            }
        }
        RenderCmd::PushBuf(span) => {
            let mut buf = self.buffer_pool.take();
            buf.resize(self.blend_buffers[0].len(), T::Numeric::ZERO);
            // Instead of always zeroing out the whole buffer, only zero the
            // row-local span that will be read when compositing this layer.
            if let Some(span) = span.and_then(|span| span.intersect(self.buffer_span)) {
                buf[Self::scratch_range(span)].fill(T::Numeric::ZERO);
            }
            self.blend_buffers.push(buf);
        }
        RenderCmd::PopBuf => {
            let popped = self.blend_buffers.pop().unwrap();
            self.buffer_pool.submit(popped);
        }
        RenderCmd::LayerFill(cmd) => { /* análogo, mas compõe do buffer filho para o pai */ }
    }
}
Repare a aritmética de offset de alpha ao recortar um span: alpha_offset = alpha_idx + (span.x - cmd.span.x) * Tile::HEIGHT — 4 bytes por coluna de pixel.

Existem dois kernels: U8Kernel (lowp, u8x32) e F32Kernel (highp, f32x16), selecionados por RenderMode::OptimizeSpeed / OptimizeQuality.

7. vello_hybrid — o que vai para a GPU
7.1 Filosofia
A CPU faz tudo até as strips. A GPU recebe:

Uma textura de alphas (não storage buffer!) — RGBA32Uint, 16 bytes por texel = 16 alphas.
Um vertex buffer de instâncias GpuStrip — 20 bytes cada.
Texturas auxiliares: encoded_paints_texture (RGBA32Uint), gradient_texture (RGBA8), atlas_texture_array (imagens), layer_input_texture (layers intermediários).
Um UBO Config.
Cada strip vira um quad de 4 vértices desenhado como TRIANGLE_STRIP instanciado.

7.2 GpuStrip — 20 bytes
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\render\common.rs


#[repr(C)]
#[derive(Debug, Clone, Copy, Zeroable, Pod)]
pub struct GpuStrip {
    pub x: u16,                              // 0..2
    pub y: u16,                              // 2..4
    pub width: u16,                          // 4..6
    pub dense_width_or_rect_height: u16,     // 6..8
    pub col_idx_or_rect_frac: u32,           // 8..12
    pub payload: u32,                        // 12..16
    pub paint_and_rect_flag: u32,            // 16..20
    /// Painter's-order index used to compute z-depth for early-z rejection in shader.
    pub depth_index: u32,                    // 20..24
}
(24 bytes com depth_index; os 4 primeiros campos são empacotados em 2 u32 no shader via @location(0) e @location(1).)

7.3 Config (UBO)

#[repr(C, align(16))]
pub struct Config {
    pub width: u32,
    pub height: u32,
    /// Height of a strip in the rendering.
    pub strip_height: u32,                     // = 4
    /// Number of trailing zeros in `alphas_tex_width` (log2 of width).
    /// Pre-calculated on CPU since downlevel targets do not support `firstTrailingBit`.
    pub alphas_tex_width_bits: u32,
    pub encoded_paints_tex_width_bits: u32,
    pub strip_offset_x: i32,
    pub strip_offset_y: i32,
    /// Whether to flip the y-component of the NDC position.
    pub negate_ndc: u32,
}
7.4 Strip → instância
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\draw.rs


visit_strip_fill_segments(
    strips, tile_bounds, self,
    |builder, segment| {                        // região com alpha
        let shifted = segment.shift(geometry_shift);
        let strip = GpuStrip::from_fill_segment(
            shifted, Some(segment.col_idx()),
            paint.payload_at(segment.x0(), segment.y()),
            paint.paint, depth_index,
        );
        builder.draw.push(builder.strips, strip, paint.external_texture_id);
    },
    |builder, segment| {                        // sparse fill sólido
        let shifted = segment.shift(geometry_shift);
        let strip = GpuStrip::from_fill_segment(shifted, None, ..., depth_index);
        if !paint.opaque || !builder.push_opaque(strip) {
            builder.draw.push(builder.strips, strip, paint.external_texture_id);
        }
    },
);

impl StripAlphaFillSegmentExt for StripAlphaFillSegment {
    fn col_idx(self) -> u32 { self.alpha_idx / u32::from(Tile::HEIGHT) }
}

impl GpuStrip {
    fn from_fill_segment(rect: RectU16, col_idx: Option<u32>, payload: u32,
                         paint: u32, depth_index: u32) -> Self {
        let width = rect.width();
        let (dense_width_or_rect_height, col_idx_or_rect_frac) =
            if let Some(col_idx) = col_idx { (width, col_idx) } else { (0, 0) };
        Self { x: rect.x0, y: rect.y0, width, dense_width_or_rect_height,
               col_idx_or_rect_frac, payload, paint_and_rect_flag: paint, depth_index }
    }
}
Regra: dense_width == width ⇒ strip com AA; dense_width == 0 ⇒ preenchimento sólido (o fragment shader usa alpha = 1.0).

Strips opacas e sólidas na raiz vão para um buffer separado opaque_strips, desenhado em um passe front-to-back com escrita de depth:


pub(crate) struct DepthCounter { count: u32 }
impl DepthCounter {
    fn next(&mut self, opaque: bool) -> u32 { self.count += opaque as u32; self.count }
}
7.5 Empacotamento de paint
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\paint.rs


const COLOR_SOURCE_PAYLOAD: u32 = 0;
pub(crate) const COLOR_SOURCE_LAYER: u32 = 1;

const PAINT_TYPE_SOLID: u32 = 0;
const PAINT_TYPE_IMAGE: u32 = 1;
const PAINT_TYPE_LINEAR_GRADIENT: u32 = 2;
const PAINT_TYPE_RADIAL_GRADIENT: u32 = 3;
const PAINT_TYPE_SWEEP_GRADIENT: u32 = 4;
const PAINT_TYPE_BLURRED_ROUNDED_RECT: u32 = 5;

pub(crate) const COLOR_SOURCE_SHIFT: u32 = 29;
const PAINT_TYPE_SHIFT: u32 = 26;
const PAINT_TEXTURE_INDEX_MASK: u32 = (1 << PAINT_TYPE_SHIFT) - 1;   // 0x03FF_FFFF
Layout de paint_and_rect_flag (do comentário em render.wesl):


Bit  31   : RECT_STRIP_FLAG  0 = normal strip, 1 = rect strip
Bits 29-30: color_source     0 = use payload, 1 = use layer texture
Bits 26-28: paint_type       (quando color_source == 0)
Bits 0-25 : paint_texture_idx (índice de texel na encoded_paints_texture)
Bits 0-7  : opacity 0-255     (quando color_source == 1)
E payload é:

cor RGBA8 premultiplicada (solid);
pack_u16_pair(x, y) = coordenadas de cena (gradiente/imagem/blur);
pack_u16_pair(src_x, src_y) = origem na textura do layer.
7.6 O shader render.wesl
C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_sparse_shaders\shaders\render.wesl

Vertex shader — expande a instância em um quad:


// Map vertex_index (0-3) to quad corners: 0 → (0,0), 1 → (1,0), 2 → (0,1), 3 → (1,1)
let x = f32(in_vertex_index & 1u);
let y = f32(in_vertex_index >> 1u);
let x0 = instance.xy & 0xffffu;
let y0 = instance.xy >> 16u;
let width       = instance.widths_or_rect_height & 0xffffu;
let dense_width = instance.widths_or_rect_height >> 16u;

let is_rect = (instance.paint_and_rect_flag & RECT_STRIP_FLAG) != 0u;
var height = config.strip_height;              // = 4 para strips normais
if is_rect {
    height = dense_width;                      // rect: reaproveita como altura
    out.dense_end_or_rect_size = width | (dense_width << 16u);
    out.rect_frac = instance.col_idx_or_rect_frac;
} else {
    out.dense_end_or_rect_size = instance.col_idx_or_rect_frac + dense_width;
    out.rect_frac = 0u;
}

let pix_x = f32(i32(x0) + config.strip_offset_x) + x * f32(width);
let pix_y = f32(i32(y0) + config.strip_offset_y) + y * f32(height);
let ndc_x = pix_x * 2.0 / f32(config.width) - 1.0;
let ndc_y = 1.0 - pix_y * 2.0 / f32(config.height);

let col_offset = select(f32(instance.col_idx_or_rect_frac), 0.0, is_rect);
out.tex_coord = vec2<f32>(col_offset + x * f32(width), y * f32(height));

// Divide by a power of 2 to ensure exact f32 arithmetic (and divide by the expected depth
// buffer precision of 24 bits).
let z = 1.0 - f32(instance.depth_index) / f32(1u << 24u);
let final_ndc_y = select(ndc_y, -ndc_y, config.ndc_y_negate != 0u);
out.position = vec4<f32>(ndc_x, final_ndc_y, z, 1.0);
Fragment shader — leitura do alpha (a parte mais importante):


} else if !is_rect && dense_end_or_rect_size != 0u {
    let x = u32(floor(tex_coord.x));
    let y = u32(floor(tex_coord.y));
    // Retrieve alpha value from the texture. We store 16 1-byte alpha
    // values per texel, with each color channel packing 4 alpha values.
    // The code here assumes the strip height is 4, i.e., each color
    // channel encodes the alpha values for a single column within a strip.
    let alphas_index = x;
    let tex_dimensions = textureDimensions(alphas_texture);
    let alphas_tex_width = tex_dimensions.x;
    // Which texel contains the alpha values for this column
    let texel_index = alphas_index / 4u;
    // Which channel (R,G,B,A) in the texel contains the alpha values for this column
    let channel_index = alphas_index % 4u;
    let tex_x = texel_index & (alphas_tex_width - 1u);
    let tex_y = texel_index >> config.alphas_tex_width_bits;

    let rgba_values = textureLoad(alphas_texture, vec2<u32>(tex_x, tex_y), 0);
    let alphas_u32 = unpack_alphas_from_channel(rgba_values, channel_index);
    alpha = f32((alphas_u32 >> (y * 8u)) & 0xffu) * (1.0 / 255.0);
}
Ou seja: coluna global de alpha = col_idx + offset_x_dentro_da_strip; texel = coluna/4; canal = coluna%4; byte = y dentro do u32. Isso casa exatamente com o layout column-major do alpha_buf da CPU (4 bytes por coluna, little-endian).

Como a largura da textura é potência de 2 (é sempre max_texture_dimension_2d), tex_x usa AND e tex_y usa shift — evitando divisões e a falta de firstTrailingBit no WebGL2.

Aplicação final:


if paint_type == PAINT_TYPE_SOLID {
    final_color = alpha * unpack4x8unorm(payload);
}
...
} else if color_source == COLOR_SOURCE_LAYER {
    let layer_opacity = f32(paint_and_rect_flag & 0xffu) * (1.0 / 255.0);
    final_color = alpha * layer_opacity * textureLoad(layer_input_texture, vec2<i32>(sample_xy), 0);
}
Tudo em alpha premultiplicado; o blend state é PREMULTIPLIED_ALPHA_BLENDING (ONE, ONE_MINUS_SRC_ALPHA).

7.7 "Rect strips" — AA analítico de retângulos no fragment shader
Quando RECT_STRIP_FLAG está setado, a instância representa um retângulo inteiro (não uma faixa de 4px), e o AA é calculado no shader a partir das frações das 4 bordas:


if is_rect && rect_frac != 0u {
    let frac = unpack4x8unorm(rect_frac);
    let rect_size = vec2<f32>(f32(dense_end_or_rect_size & 0xFFFFu),
                              f32(dense_end_or_rect_size >> 16u));
    let tc = tex_coord;
    // + 0.5 and -0.5 since the fragment shader positions the coordinates in the center of the pixel.
    let bottom_and_right = min(tc + 0.5, rect_size - frac.zw);
    let top_and_left     = max(tc - 0.5, frac.xy);
    let a = clamp(bottom_and_right - top_and_left, vec2(0.0), vec2(1.0));
    alpha = a.x * a.y;
}
Do lado da CPU, split_rect (vello_hybrid/src/rect.rs) decompõe retângulos grandes (≥ 32px em ambas as direções) em 5 partes: miolo sem AA + 4 faixas de borda de 1px:


// Note that `top_frac` and `left_frac` store the actual coverage, while
// `right_frac` and `bottom_frac` store one minus the coverage. This is on purpose
// and handled that way in the shader.
let left_frac   = (rect.x0 - sx0) as f32;
let top_frac    = (rect.y0 - sy0) as f32;
let right_frac  = (sx1 - rect.x1) as f32;
let bottom_frac = (sy1 - rect.y1) as f32;
7.8 Backend WebGL2 — como contorna a falta de storage buffers
Resposta curta: nunca houve dependência de storage buffer. O design "sparse strips" foi feito desde o início para rodar só com vertex+fragment shader. Os dados vão como texturas inteiras.

C:\MyDartProjects\dart_ui\referencias\vello-main\sparse_strips\vello_hybrid\src\render\webgl\mod.rs

Textura de alphas: RGBA32UI / RGBA_INTEGER / UNSIGNED_INT (linhas 3440-3448). Largura = max_texture_dimension_2d (potência de 2), altura crescida sob demanda:

fn maybe_resize_alphas_tex(&mut self, max_texture_dimension_2d: u32, alphas_len: usize) {
    let required_alpha_height = (alphas_len as u32)
        // There are 16 1-byte alpha values per texel.
        .div_ceil(max_texture_dimension_2d << 4);
    ...
}
Instâncias: ARRAY_BUFFER + vertex_attrib_divisor(loc, 1) + draw_arrays_instanced(TRIANGLE_STRIP, 0, 4, count) (linhas 2242, 2824-2826).
Depth: DEPTH_TEST + depth_func(LEQUAL) + depth_mask(true) no passe opaco, depth_mask(false) no passe alpha (linhas 2810-2841). No framebuffer padrão usa-se DEPTH (não DEPTH_ATTACHMENT).
negate_ndc: naga aplica um y-flip ao transpilar WGSL→GLSL (WebGPU y-down vs. WebGL y-up). Para escrever direto no framebuffer do usuário sem uma passagem extra de flip, o Config.negate_ndc desfaz manualmente. Comentário completo em render/common.rs:339-357.
Toolchain de shaders: os shaders são escritos uma única vez em WESL (vello_sparse_shaders/shaders/*.wesl), linkados para WGSL e transpilados para GLSL via naga no build.rs. Existe um lint próprio no_structs_in_fragment (vello_sparse_shaders/src/lint/) porque estruturas em entradas de fragment shader quebram no GLSL gerado — daí o fs_main receber @location(N) soltos.
Shaders existentes: render.wesl (principal), blend.wesl, clear.wesl, copy.wesl, filter.wesl.

7.9 Clipping, layers e blending no híbrido
Clip: resolvido na CPU (§5). Um layer com clip guarda um LayerClip { strip_range, thread_idx, bbox }. Ao compor, as strips do clip são percorridas com visit_strip_fill_segments e cada segmento vira uma instância com COLOR_SOURCE_LAYER — ou seja, o clip é aplicado como uma máscara de alpha ao amostrar a textura do layer filho:

// vello_hybrid/src/draw.rs, push_layer_fill
if let Some(clip_path) = clip_path {
    // If a clip path is associated with the layer, simply draw the strips and use the rendered
    // layer as a fill.
    ...
} else {
    // Otherwise, a simple rect blit covering the whole layer is enough.
}
Layers: renderizados em texturas intermediárias organizadas em atlas. O escalonador (vello_hybrid/src/schedule/mod.rs) tem três princípios documentados:

Bottom-up layer scheduling — layers de profundidade par usam o grupo "even", ímpar usam "odd", fazendo ping-pong entre duas páginas (no máximo 2 alocações vivas em cadeias lineares).
Lazy layer allocation — o alvo só é alocado quando o layer recebe o primeiro draw ou filho.
Batching into rounds — operações independentes que precisam do mesmo par de páginas são agrupadas na mesma round/render pass. O escalonador é monotônico: nunca retrocede para rounds anteriores.
Blending: source-over não precisa de passe extra (o parent amostra a textura do filho diretamente). Blend modes não-default precisam ler filho e parent, então são adiados para o próximo blend stage; o backend escreve numa scratch texture e copia de volta. Se o blend não-default tem a raiz como alvo, a raiz é primeiro renderizada num layer intermediário (o target do usuário não pode ser amostrado).

Gradientes: LUT pré-calculada na CPU e empacotada numa gradient_texture RGBA8 plana; o shader calcula t (linear = grad_pos.x; radial = fórmula focal do Skia; sweep = aproximação polinomial de atan do Skia) e amostra:


fn sample_gradient_lut(t_value: f32, extend_mode: u32, gradient_start: u32, texture_width: u32) -> vec4<f32> {
    let clamped_t = extend_mode_normalized(t_value, extend_mode);
    let t_offset = u32(clamped_t * f32(texture_width - 1u));
    let flat_coord = gradient_start + t_offset;
    let gradient_tex_width = textureDimensions(gradient_texture).x;
    return textureLoad(gradient_texture, vec2<u32>(flat_coord % gradient_tex_width,
                                                    flat_coord / gradient_tex_width), 0);
}
Os parâmetros do gradiente ficam na encoded_paints_texture (RGBA32Uint, 4 u32 = 16 bytes por texel), lidos com load_encoded_paint_texel(paint_tex_idx, texel_offset).

8. Estado de maturidade e limitações (extraído dos docs)
sparse_strips/README.md
This folder is being used to develop this implementation and is not yet suitable for production use. Our plan is to move the packages in this folder to the top level of the repository once they are ready for use.

This implementation is based on the sparse rendering approach outlined by Raph Levien (@raphlinus) in Potato: a hybrid CPU/GPU 2D renderer design.

vello_hybrid (README/lib.rs) — limitações declaradas
Vello Hybrid is a solid GPU-accelerated 2D renderer with broad, reliable feature support. Although it does not match Vello Classic's raw performance on dynamic and vector-heavy workloads, it provides excellent performance on workloads that benefit from GPU acceleration, such as images, gradients, and filters. Overall, we still consider it to be slightly less mature than its CPU-only counterpart Vello CPU.

Known limitations include:

The following features are not yet supported and will panic: Mask layers, complex filter graphs as well as certain blend modes for non-isolated blending.
Parts of the API and its documentation are still suboptimal, for example the lifecycle and ownership of external resources through Resources.
Some exposed features remain experimental and are not recommended for use, including glyph caching.
Parts of the rendering pipeline are not yet fully optimized, particularly the wgpu backend.
Some failures panic instead of being reported through a user-facing error.
Limitações técnicas embutidas no código
MAX_LINES_PER_PATH = 2^27: "Trying to render a path with more lines than this may result in visual artifacts."
CulledWindings.coarse é Vec<i16>: "this will cause issues if we have windings greater/less than i16, but this should only occur in pathological cases."
Strip::alpha_idx só tem 31 bits (bit 31 é fill_gap), com assert! em new/set_alpha_idx.
TODO em strip.rs: "horizontal geometry has no impact on winding. This branch will be removed when horizontal geometry is culled at the tile-generation stage."
TODO em render.wesl: width e dense_width poderiam virar 1 bit + 15 bits livres; strip e sparse fill poderiam ser fundidos numa única instância.
TODO em coarse/cmd.rs: RenderCmd de 16 bytes poderia ser 8.
TODO em bucketer.rs: "Instead of always pushing the full layer bbox across all rows, it would be nice to instead only emit the per-row bounding box."
Recursão em bucket_commands: "TODO: Avoid recursion to prevent stack overflows for deeply nested layers."
Masks dentro de filter layers "are currently probably broken".
Offsets de 0.00001 no shader para gradientes e imagens, porque "45 degree skewing seems to cause artifacts on the GPU".
vello_cpu CHANGELOG 0.1.0/0.2.0 (destaques relevantes)
"The Vello CPU frontend and coarse rasterizer have been rewritten" (#1701) — daí o CommandBucketer.
Correções de filter layers em bordas de viewport e de clipping de layers.
Otimização de interseção de clip-path com busca binária (#1690, #1691).
9. Roteiro sugerido de reimplementação em Dart
Uma ordem que minimiza risco (cada etapa é testável isoladamente):

Point, Line (Float32List plana funciona bem: [x0,y0,x1,y1, ...]).
Flatten escalar: LineTo direto; QuadTo com estimate_subdiv/determine_subdiv_t; CurveTo via estimate_num_quads + N quadráticas. Comece sem culling (cull_bbox = viewport). Valide contra Path.computeMetrics ou contra o próprio kurbo.
Tile como Int32List/Uint32List paralelas ou um Uint64List com a chave (y<<48)|(x<<32)|packed. Em Dart, use Uint32List com 2 words por tile ([xy, packed]) e ordene por índice com um radix sort ou List<int>.sort sobre chaves int de 64 bits (Dart nativo tem inteiros de 64 bits; em web use BigInt não — prefira ordenar por (y, x, lineIdx) com comparador).
make_tiles_analytic_aa sem os caminhos de culling (só os casos b e c com push_row_extents). Só o bit W importa.
strip::render escalar: o laço de 4 colunas × 4 scanlines. Trate NaN explicitamente. Valide comparando alphas contra um rasterizador de referência (ex.: dart:ui Canvas.drawPath numa Picture 1×) — ou porte os testes de rect.rs que comparam caminho rápido vs. caminho geral.
visit_strip_fill_segments + o consumidor mais simples possível: um blit direto para Uint8List RGBA (fine rasterization ingênua).
Só então: depth buffer, layers, clip por interseção de strips, e a camada GPU.
Pontos onde é fácil errar (checklist):

Alpha buffer é column-major: alpha[col*4 + row], 16 bytes por tile.
alpha_idx está em bytes; col_idx = alpha_idx / 4; largura em pixels = Δalpha_idx / 4.
A sentinel strip é obrigatória — sem ela a última strip tem largura indefinida.
fill_gap da strip i+1 descreve o gap antes dela.
winding_delta só muda quando tile.winding() (bit W) é verdadeiro, multiplicado por sign.
Merge de strips acontece quando prev.y == cur.y && prev.x + 1 == cur.x (tiles adjacentes); múltiplas linhas no mesmo tile não fazem flush nenhum.
sign = signum(p0.y - p1.y) — positivo para linhas subindo em sistema y-down.
A área do trapézio é medida em relação à borda direita do pixel; o acc propaga para a direita.
Ao mudar de linha de tiles, zere winding_delta, accumulated_winding e location_winding; ao permanecer na mesma linha, re-splat accumulated_winding = winding_delta (reduz erro de arredondamento acumulado).

## 10. Checkpoint implementado — Wayland, gradientes e renderer vetorial

**Data:** 22 de agosto de 2026

**Branch obrigatória:** `main`

### Fechado nesta rodada

- Wayland `wl_shm` deixou de sobrescrever sempre um único buffer: a superfície
  cresce sob demanda até três slots e gira pelos buffers liberados por
  `wl_buffer.release`.
- Destruição de buffer ocupado agora é adiada até o release do compositor; a
  memória não é mais desmontada enquanto ainda pode estar sendo lida.
- Auto-repeat Wayland foi implementado a partir de
  `wl_keyboard.repeat_info`, com deadline integrado ao timeout do pump, limite
  de burst, cancelamento em focus-out/close e teste com relógio injetado.
- O transporte e as constantes de `wl_data_device`/pipes estão preparados para
  clipboard, mas a state machine de selection/offer **ainda não está ligada**.
- Gradientes lineares/radiais agora são valores imutáveis públicos, validados,
  internados no display list e empacotados no paint sem aumentar o record.
- Replay de gradiente ainda não existe: por segurança o player lança
  `UnsupportedError` explícito em vez de renderizar a cor sólida errada.
- `SparseStripGenerator` foi implementado como protótipo comum aos backends.
  Ele conserva somente alpha parcial em faixas de quatro linhas e transforma o
  interior 255 em fills sólidos.
- A reconstrução sparse é idêntica byte a byte ao `ScanlineFiller` para
  retângulo, elipse, triângulo transformado e even-odd. Um retângulo 256×256
  usa menos de 1 KiB de records contra 64 KiB de máscara alpha8 densa.
- Arquitetura e decisão registradas em
  `doc/architecture/ACELERACAO_GPU_VETORIAL.md` e
  `doc/adr/0006-aceleracao-vetorial-sparse-strips.md`.

### Validação focada concluída

```text
dart analyze lib/src/rendering/replay test/rendering/replay \
  lib/src/backends/wayland test/backends/wayland
No issues found

dart test test/rendering/replay/display_list_player_test.dart \
  test/backends/wayland
157 testes passaram

dart test test/rendering/gpu/vector/sparse_strips_test.dart
5 testes passaram

dart analyze
No issues found

dart test
4.494 testes passaram; 21 ignorados por requisito de plataforma
```

### Próxima sequência recomendada

1. Implementar `GradientLut` comum (mesmo rounding na CPU/GPU) e replay CPU.
2. Criar o atlas alpha sparse + buffer de instâncias e o primeiro shader
   strip/fill em OpenGL, mantendo `GpuMaskAtlas` como fallback.
3. Portar o mesmo shader/layout para HLSL, MSL, SPIR-V e WGSL; a lógica de
   seleção deve ficar acima dos backends.
4. Adicionar modelo de custo: primitiva analítica → cache denso → sparse →
   tesselação/compute, conforme cena e capacidades.
5. Completar clipboard Wayland (manager/device/source/offer), depois frame
   callbacks para pacing.
6. Medir separadamente geração Dart, bytes de upload, GPU e apresentação em
   Linux normal, WSLg, Windows e macOS. Um problema de presenter WSLg nunca
   deve contaminar o contrato do renderer comum.
