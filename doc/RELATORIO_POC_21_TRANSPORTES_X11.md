# Relatório POC-21 — libxcb, dart:io e sockets libc FFI no X11

Data: 22 de agosto de 2026
Escopo: transporte e codificação do protocolo X11 core em aplicações Dart

## 1. Decisão resumida

A hipótese de que `dart:io Socket` terá desempenho próximo de chamadas diretas
à libc é plausível para fluxos já agrupados em buffers grandes. Isso, porém,
não torna `dart:io` um substituto funcional ou arquiteturalmente superior à
libxcb.

As três opções não ocupam a mesma camada:

| Opção | Transporte | Codec e estado X11 | Autenticação | Extensões |
|---|---|---|---|---|
| libxcb via FFI | socket interno da libxcb | libxcb | libxcb/xauth | ecossistema libxcb-* |
| dart:io Socket | runtime nativo do Dart | precisa ser escrito em Dart | precisa ser escrita | precisa ser escrita |
| socket libc via FFI | syscalls chamadas pelo aplicativo | precisa ser escrito em Dart | precisa ser escrita | precisa ser escrita |

Para o backend de produção, a recomendação permanece:

1. libxcb via FFI para conexão, protocolo, eventos e extensões;
2. EGL/OpenGL ou Vulkan para apresentação GPU;
3. MIT-SHM para o framebuffer CPU local;
4. `PutImage` core como fallback para display remoto ou SHM indisponível.

O cliente X11 direto sobre `dart:io` é valioso como experimento, implementação
de referência e ferramenta diferencial contra a libxcb. Não é, com as
evidências atuais, a melhor base para substituir a libxcb no backend completo.

## 2. Afirmações avaliadas

### 2.1 “dart:io empata em desempenho com FFI”

É uma hipótese razoável somente quando a comparação é transporte contra
transporte e ambos recebem buffers equivalentes. `Socket.add` chega ao sistema
operacional através do runtime nativo do Dart; uma implementação libc FFI
também termina em `write(2)`. O resultado depende de:

- quantidade de transições Dart/nativo;
- quantidade e tamanho das cópias;
- batching;
- pressão no event loop;
- bloqueio ou não bloqueio;
- custo do servidor X para processar a requisição.

Uma única escrita de 400 KiB em `dart:io` pode superar 100 mil chamadas FFI
pequenas. Isso demonstra a importância do batching, não que todo cliente X11
direto terá desempenho igual à libxcb.

O caminho libxcb também pode expor o descritor da conexão por
`xcb_get_file_descriptor`, permitindo integração com um poller sem recriar o
protocolo. A documentação XCB confirma que `xcb_connect` abre a conexão,
`xcb_get_file_descriptor` expõe seu FD e `xcb_get_maximum_request_length`
negocia inclusive BIG-REQUESTS:
<https://xcb.freedesktop.org/manual/group__XCB__Core__API.html>.

### 2.2 “dart:io é infinitamente mais seguro”

`dart:io` oferece segurança de memória melhor que chamadas manuais a
`socket`, `connect`, `read` e `write` via ponteiros FFI. A palavra
“infinitamente”, entretanto, oculta que o risco principal muda de lugar.

Um cliente X11 direto ainda precisa implementar corretamente:

- framing fragmentado e múltiplos pacotes na mesma leitura;
- byte order e alinhamento de quatro bytes;
- setup success/failure/authenticate;
- leitura e proteção do `MIT-MAGIC-COOKIE-1`;
- geração de resource IDs dentro da máscara entregue pelo servidor;
- sequência de requests, replies, errors e events intercalados;
- eventos genéricos com corpo variável;
- BIG-REQUESTS;
- limites `CARD16`, `CARD32`, `INT16` e padding de imagens;
- versões e opcodes dinâmicos de extensões;
- reconexão, encerramento parcial e backpressure.

Logo, `dart:io` remove uma classe de corrupção de memória, mas amplia muito a
superfície de erros de protocolo. A libxcb é justamente o codec e gerenciador
dessa máquina de estados, não apenas um wrapper de `socket(2)`.

### 2.3 “RawSecureSocket/RawSocket é a opção ideal”

`RawSecureSocket` não se aplica ao socket Unix local do X11: ele adiciona TLS,
que o servidor X11 não fala nesse endpoint. `RawSocket` ou `Socket` são as
alternativas pertinentes. A POC usa `Socket`, cuja conexão assíncrona é a API
documentada pelo Dart:
<https://api.dart.dev/dart-io/Socket/connect.html>.

Para `DISPLAY` remoto, TCP X11 puro também não se torna seguro por usar
`Socket`; seria necessário um transporte protegido, normalmente SSH
forwarding. O `MIT-MAGIC-COOKIE-1` autentica o cliente, mas não cifra o tráfego.

### 2.4 “o GC pode mover o Uint8List enquanto o socket envia”

Esse não é um problema que o usuário de `Socket.add` precisa resolver. A API
recebe uma lista Dart e o runtime preserva a validade dos dados durante sua
operação, copiando ou mantendo a referência conforme a implementação. O custo
de cópia deve ser medido, mas não se deve expor um ponteiro para a memória Dart
ao kernel manualmente.

Memória nativa passa a ser necessária quando uma API exige endereço estável ou
memória compartilhada, como MIT-SHM. Para core `PutImage`, tanto uma lista Dart
enviada por socket quanto um ponteiro nativo entregue à libxcb terminam em um
payload de imagem no fluxo X11.

### 2.5 “a arquitetura híbrida socket Dart + XShm é perfeita”

Ela é tecnicamente possível, mas para usar XShm sem libxcb ainda é necessário
codificar a extensão MIT-SHM no protocolo:

- `QueryExtension` e negociação de versão;
- `ShmAttach`/`ShmAttachFd`;
- `ShmPutImage`;
- erro `BadShmSeg` e fallback;
- completion events para impedir sobrescrita prematura;
- detach e teardown em todas as falhas.

A API oficial mostra que `xcb_shm_put_image` já representa largura total,
origem da região, dimensões parciais, segmento, offset e solicitação de evento
de conclusão:
<https://xcb.freedesktop.org/manual/group__XCB__Shm__API.html>.

Portanto, a arquitetura de maior retorno é framebuffer nativo/compartilhado +
libxcb-shm via FFI. Ela preserva a parte boa da proposta sem reimplementar o
protocolo da extensão.

## 3. Code review do backend X11 existente

Esta seção incorpora o code review que motivou a POC. Ele não estava
reproduzido integralmente na primeira versão deste relatório.

### 3.1 Constatação arquitetural inicial

O backend de produção não implementa atualmente o transporte X11 com
`dart:io`. Ele já usa Dart FFI para carregar `libxcb` e `libc`:

- [`x11_backend.dart`](../lib/src/backends/x11/x11_backend.dart) carrega
  `XcbBindings` e `X11Libc`;
- [`x11_bindings.dart`](../lib/src/backends/x11/x11_bindings.dart) declara e
  resolve as funções de `libxcb.so.1`;
- [`x11_connection.dart`](../lib/src/backends/x11/x11_connection.dart) mantém
  o `xcb_connection_t`, cria janelas, recebe eventos e apresenta buffers;
- [`x11_libc.dart`](../lib/src/backends/x11/x11_libc.dart) chama alocação,
  pipe, `poll` e primitivas System V SHM via FFI.

Portanto, a decisão real não é “Dart puro sobre socket versus começar a usar
FFI”. A decisão é manter o codec libxcb existente ou substituí-lo por um codec
X11 próprio sobre `dart:io`/libc, além de escolher separadamente a técnica de
apresentação de pixels.

### 3.2 Alta — o caminho CPU ainda envia pixels com core PutImage

O backend detecta MIT-SHM e já contém bindings opcionais para `libxcb-shm`, mas
esses bindings não são carregados nem usados pelo caminho de apresentação.
Toda apresentação CPU termina em `xcb_put_image` em
[`x11_connection.dart`](../lib/src/backends/x11/x11_connection.dart), enquanto
`XcbShmBindings` permanece isolado em
[`x11_bindings.dart`](../lib/src/backends/x11/x11_bindings.dart).

Impacto aproximado para um frame completo BGRA 1920×1080:

- 8.294.400 bytes por frame;
- aproximadamente 498 MB/s de payload a 60 FPS;
- com o limite core de 65.535 unidades de quatro bytes, aproximadamente 32
  requests por frame completo;
- para dano com largura parcial,
  [`x11_put_image_plan.dart`](../lib/src/backends/x11/x11_put_image_plan.dart)
  usa segmentos de uma linha quando as linhas da região não são contíguas;
  uma região de mil linhas pode produzir mil chamadas FFI/XCB.

Recomendação:

1. carregar `XcbShmBindings` apenas quando a extensão MIT-SHM estiver presente;
2. consultar a versão suportada;
3. tentar `xcb_shm_attach_checked` e cair para `PutImage` quando a conexão for
   remota ou o attach falhar;
4. usar dois ou três buffers;
5. solicitar completion events antes de reutilizar um buffer ainda consumido
   pelo servidor;
6. manter o planner `PutImage` como fallback correto.

### 3.3 Alta — o caminho EGL/OpenGL escolhe o visual tarde demais

O resolver de produção já prefere EGL/OpenGL antes do presenter CPU em
[`default_platform_resolver.dart`](../lib/src/backends/default_platform_resolver.dart).
Esse é o equivalente arquitetural Linux do caminho Direct3D no Windows.

Entretanto, `X11Connection` cria a janela primeiro com o visual raiz. Somente
depois `X11GlSurface.forWindow` escolhe um `EGLConfig`. O próprio comentário em
[`x11_gl_surface.dart`](../lib/src/backends/x11/x11_gl_surface.dart) reconhece
que `EGL_NATIVE_VISUAL_ID` precisa coincidir com o visual da janela e que o
servidor rejeita a combinação com `EGL_BAD_MATCH` quando eles divergem.

O resolver chama `X11GlSurface.forWindow(native.xcbWindow)` sem informar o
visual usado pela janela. Isso reduz a qualidade do diagnóstico e pode causar
fallback para CPU em configurações que não aceitam o visual raiz para o config
8/8/8/8 escolhido.

O fluxo robusto deve ser invertido:

1. consultar e escolher o `EGLConfig`;
2. obter `EGL_NATIVE_VISUAL_ID`;
3. localizar profundidade e criar um colormap compatível;
4. criar a janela XCB com esse visual;
5. criar o `EGLSurface` sobre a janela já compatível.

Isso pede um contrato de requisitos de superfície entre renderer e windowing
backend antes da criação da janela.

### 3.4 Média — X11Dispatcher.run pode entrar em busy loop

[`x11_dispatcher.dart`](../lib/src/backends/x11/x11_dispatcher.dart) documenta
um loop que deveria bloquear em `poll(2)`, mas `_loop()` apenas chama
`_pollEvents()` repetidamente. `_connectionFd` não é usado para espera e
`nextPollTimeoutMs` é calculado, mas não é consumido pelo loop.

Não foi encontrada instanciação de `X11Dispatcher` no código de produção na
data da revisão, portanto o problema é latente. Se essa classe for integrada
como está, poderá ocupar continuamente um núcleo de CPU.

Recomendação: injetar também uma operação `waitForActivity(timeout)` ou remover
o dispatcher até que exista integração real. O loop usado pelo backend atual,
`X11WindowingBackend.pumpEvents`, já delega a espera à conexão e não apresenta
esse busy loop específico.

### 3.5 Média — a screen indicada por DISPLAY é ignorada no backend atual

`xcb_connect` devolve o número de screen selecionado, mas `_readScreen` em
[`x11_connection.dart`](../lib/src/backends/x11/x11_connection.dart) mantém o
primeiro elemento do iterador. O próprio diagnóstico registra
“DISPLAY requested screen N; using screen 0”.

Em `DISPLAY=:0.1`, isso pode escolher root window, visual, dimensões físicas e
colormap da screen errada.

Recomendação: copiar o iterador retornado por `xcb_setup_roots_iterator` e
avançá-lo com `xcb_screen_next` até `preferredScreen`. A POC-21 implementa a
travessia de screens variáveis no cliente direto e no cliente libxcb para que
esse caso também seja exercitável.

### 3.6 Média — atualização dinâmica de escala está incompleta

O tradutor em
[`x11_events.dart`](../lib/src/backends/x11/x11_events.dart) marca `scaleDirty`
ao observar mudança de `RESOURCE_MANAGER`, porém:

- a conexão não seleciona `PropertyChange` na root window;
- `flushPendingEvents` não relê `RESOURCE_MANAGER` nem recalcula a escala;
- `scaleDirty` é apagado em `reset` sem produzir evento;
- `_scale` e `_desktopScale` de `X11Window` são imutáveis.

O backend não anuncia `Capability.perMonitorDpi`, portanto sua declaração
externa permanece conservadora, mas o código de atualização existente não
produz o comportamento sugerido pelos comentários.

Recomendação: ou remover o caminho morto até implementar DPI dinâmico, ou
completar a assinatura de eventos, mutação da escala, reconstrução de surface,
invalidação da geração e emissão de `WindowScaleChangedEvent`. RANDR ainda é
necessário para DPI por monitor.

### 3.7 Baixa — contratos parcialmente implementados

- O presenter aceita dano parcial, mas
  [`x11_backend.dart`](../lib/src/backends/x11/x11_backend.dart) não anuncia
  `Capability.partialPresent`.
- `setCursor` em
  [`x11_window.dart`](../lib/src/backends/x11/x11_window.dart) apenas memoriza o
  enum Dart; não instala um cursor X11.
- `state` permanece sempre `WindowState.normal`, apesar de existirem átomos e
  auxiliares para consultar `_NET_WM_STATE`/`WM_STATE`.
- Eventos de teclado são selecionados, consumidos e descartados até existir
  integração XKB/libxkbcommon; coerentemente, o backend não anuncia
  `keyboardInput`.
- Clipboard/selections, XIM/IME, XDND e XInput2 continuam explicitamente fora
  do backend atual.

Esses itens não invalidam o bootstrap de janela e mouse, mas impedem considerar
o backend funcionalmente equivalente ao Win32.

### 3.8 Aspectos positivos observados

O code review também encontrou decisões sólidas que devem ser preservadas:

- uma conexão XCB compartilhada entre as janelas;
- separação entre interfaces testáveis sem ponteiros e implementação FFI;
- interning inicial de átomos em lote;
- verificação antecipada de bibliotecas e símbolos;
- decoding reutilizável de eventos sem objeto intermediário por evento;
- coalescência de resize e expose;
- limite fixo de eventos por pump para evitar starvation;
- geração de surfaces e descarte seguro após resize;
- leitura do formato, profundidade, byte order e máscaras do visual antes de
  anunciar BGRA `PutImage`;
- divisão de requests conforme o limite core/BIG-REQUESTS;
- shutdown em ordem e diagnósticos limitados para evitar vazamento.

### 3.9 Prioridade recomendada após o review

1. estabilizar EGL/OpenGL em Linux real e negociar o visual antes da janela;
2. concluir MIT-SHM com fallback automático para core `PutImage`;
3. integrar corretamente ou remover `X11Dispatcher`;
4. corrigir seleção de screen e atualização de DPI;
5. implementar cursor, XKB/libxkbcommon e texto;
6. implementar selections/clipboard e XDND;
7. gerar ou validar bindings contra headers XCB fixados.

### 3.10 Validação do code review

Na revisão original:

- a branch confirmada era `main`;
- `dart test test/backends/x11` passou com 78 testes;
- `dart analyze lib/src/backends/x11 test/backends/x11` não encontrou issues;
- o host era Windows, portanto o smoke real X11/Xvfb/EGL não pôde ser
  executado.

Os testes aprovados demonstram boa cobertura das regras puras e dos contratos
mockados. Eles não substituem testes Linux com Xorg/Xvfb, window manager,
Xwayland, MIT-SHM e drivers EGL reais.

### 3.11 Comparação com Flutter, Avalonia UI e OpenJFX

Os três frameworks são referências úteis, mas é necessário separar três
conceitos que frequentemente aparecem misturados:

1. a API que o framework chama diretamente;
2. a biblioteca que efetivamente serializa o protocolo X11;
3. o mecanismo usado para renderizar o conteúdo da janela.

#### Evidência local auditada

Além das fontes upstream, esta comparação foi conferida diretamente nos
snapshots disponíveis em `referencias/`:

- Flutter: `referencias/engine-main/shell/platform/linux/fl_view.cc:33` define
  `FlView` sobre `GtkBox` e a linha 36 contém o `GtkGLArea`. O template em
  `referencias/flutter-master/packages/flutter_tools/templates/app/linux.tmpl/flutter/CMakeLists.txt:25`
  exige `gtk+-3.0`, e a linha 29 aponta para `libflutter_linux_gtk.so`;
- Avalonia: `referencias/Avalonia/src/Avalonia.X11/XLib.cs:19` declara
  `libX11.so.6`; as linhas 29, 38, 64 e 459 expõem respectivamente
  `XOpenDisplay`, `XCreateWindow`, `XNextEvent` e `XPutImage`. O projeto X11
  referencia `Avalonia.Skia` em
  `referencias/Avalonia/src/Avalonia.X11/Avalonia.X11.csproj:10`, e o bootstrap
  desktop chama `UseSkia()` em
  `referencias/Avalonia/src/Avalonia.Desktop/AppBuilderDesktopExtensions.cs:53`;
- OpenJFX: `referencias/jfx/modules/javafx.graphics/src/main/native-glass/gtk/glass_window.cpp:39-45`
  inclui X11, Cairo-Xlib, GDK-X11 e GTK; a linha 746 cria a janela GTK e as
  linhas 804-818 chamam Xlib diretamente. Em
  `referencias/jfx/modules/javafx.graphics/src/main/java/com/sun/prism/impl/PrismSettings.java:213-214`,
  a ordem padrão do pipeline Linux é `es2` e depois `sw`.

Esses diretórios são úteis como prova de implementação, mas nomes como
`engine-main` e `flutter-master` não fixam sozinhos uma release. Para uma matriz
reproduzível de longo prazo, deve-se registrar posteriormente o commit ou a tag
de cada snapshot.

A presença de `libxcb.so` no processo não significa, por si só, que o
framework foi implementado contra a API XCB. Desde libX11 1.4, a implementação
Xlib usa libxcb como camada inferior e compartilha com ela a conexão X11. Isso
é documentado pelo próprio X.Org em
<https://www.x.org/guide/xlib-and-xcb/>. Portanto, a formulação correta é
"API direta libX11" ou "API direta libxcb", e não simplesmente "usa/não usa
libxcb".

#### Flutter no Linux

O ponto principal da comparação está correto: o embedder Linux padrão não
reimplementa o protocolo X11. Ele usa GTK/GDK para a janela, ciclo de vida,
entrada e integração com o desktop. No código atual do engine, `FlView` deriva
de `GtkBox`, contém um `GtkGLArea` e conecta os gerenciadores de teclado,
ponteiro, toque, texto e acessibilidade:
<https://github.com/flutter/engine/blob/main/shell/platform/linux/fl_view.cc>.

Há, porém, duas correções em relação à descrição simplificada
"GTK 3 -> libxcb":

- GTK 3 pode selecionar diferentes backends GDK em runtime, incluindo `x11` e
  `wayland`; isso é parte da API oficial do GDK:
  <https://docs.gtk.org/gdk3/func.set_allowed_backends.html>;
- quando o backend é X11, a fronteira do Flutter continua sendo GTK/GDK. Xlib,
  XCB ou ambas podem aparecer abaixo dessa fronteira conforme a construção das
  bibliotecas do sistema. `libxcb` é uma dependência indireta, não a API que o
  Flutter chama.

O conteúdo Flutter não é composto como uma árvore de widgets GTK. A engine
rasteriza seus próprios frames e o embedder os apresenta na superfície
gráfica. No embedder Linux observado, a superfície é `GtkGLArea`, portanto
OpenGL/EGL é a descrição segura desse caminho. Impeller ou Skia depende da
versão e da configuração da engine. Vulkan existe como backend da engine, mas
não deve ser apresentado como o caminho garantido do embedder GTK Linux sem
fixar a versão/build analisada. A separação entre engine e platform embedder
também consta na visão arquitetural oficial:
<https://docs.flutter.dev/resources/architectural-overview>.

#### Avalonia UI no Linux/X11

A descrição de alto nível também está correta: Avalonia mantém um backend X11
próprio em C# e evita usar GTK/Qt como a camada principal de janelas. Seu
arquivo `XLib.cs` declara P/Invoke diretamente para `libX11.so.6`,
`libXrandr.so.2`, `libXext.so.6`, `libXi.so.6` e `libXcursor.so.1`, incluindo
`XOpenDisplay`, `XCreateWindow`, `XNextEvent`, `XPutImage` e outras operações:
<https://github.com/AvaloniaUI/Avalonia/blob/main/src/Avalonia.X11/XLib.cs>.

A frase "Avalonia não usa libxcb" precisa, entretanto, ser qualificada:
Avalonia **não chama a API XCB diretamente**, mas a libX11 moderna é uma camada
sobre libxcb. Assim, libxcb ainda pode ser uma dependência transitiva e executar
o transporte. A decisão arquitetural da Avalonia é "P/Invoke para uma biblioteca
cliente X11 madura", e não "P/Invoke para `socket`, `read`, `write` e `epoll` da
libc". Essa distinção favorece comparar Avalonia com o candidato libxcb FFI
deste relatório, não com o candidato libc FFI.

#### OpenJFX / JavaFX no Linux

O OpenJFX usa o Glass Window Toolkit como adaptação nativa de janela. O backend
Linux atual possui implementação GTK e cria janelas com `gtk_window_new`, usa
GDK para eventos, IME e integração com o desktop. O código oficial está em:
<https://github.com/openjdk/jfx/blob/master/modules/javafx.graphics/src/main/native-glass/gtk/glass_window.cpp>.

Também aqui "GTK -> libxcb" é uma simplificação excessiva. O próprio arquivo
Glass inclui `gdk/gdkx.h`, `X11/extensions/shape.h` e `cairo-xlib.h`, e executa
chamadas Xlib como `XInternAtom`, `XSendEvent` e `XFlush` em operações
específicas. Logo, a fronteira predominante é GTK/GDK, com uso pontual direto
de Xlib; libxcb fica abaixo da libX11 ou de outras bibliotecas da pilha, e não é
a API principal do JavaFX. O conteúdo JavaFX é renderizado pelo pipeline Prism,
separado da responsabilidade do Glass de criar e integrar a janela.

#### Resumo corrigido das dependências

| Framework | Como cria/integra a janela no Linux | API X11 chamada diretamente | Renderização do conteúdo | Relação correta com libxcb |
|---|---|---|---|---|
| Flutter | embedder GTK/GDK | normalmente nenhuma API X11 no nível do Flutter; GDK seleciona X11 ou Wayland | engine própria, apresentada em `GtkGLArea`; Impeller/Skia conforme versão e build | indireta quando a pilha escolhida é X11; não é contrato direto |
| OpenJFX / JavaFX | Glass GTK/GDK | GTK/GDK e algumas chamadas Xlib no código Glass | Prism: ES2 primeiro e software como fallback no snapshot local | transitiva/indireta via pilha X11; não é um cliente XCB direto |
| Avalonia UI | backend `Avalonia.X11` próprio em C# | P/Invoke direto para libX11 e bibliotecas de extensões | Skia no bootstrap desktop e no projeto X11 auditado | não chama XCB diretamente; libX11 moderna usa libxcb internamente |

#### Consequência para este backend Dart

Esses precedentes não sustentam a recriação de sockets com libc FFI. Eles
mostram dois caminhos consolidados:

- delegar janela/eventos a um toolkit completo, como Flutter e OpenJFX fazem;
- chamar por FFI uma biblioteca cliente X11 madura, como Avalonia faz com
  libX11.

Como este projeto já optou por um backend próprio e quer uma API assíncrona de
baixo nível, **libxcb via Dart FFI continua sendo o análogo mais próximo e a
recomendação principal**. O transporte X11 puro sobre `dart:io` permanece útil
como POC controlada e alternativa de dependência mínima. Recriar apenas o
socket com libc FFI continua sem precedente favorável nesses frameworks e sem
vantagem arquitetural demonstrada.

## 4. POC criada

Diretório: `poc/poc_21_x11_transport_matrix`

Executáveis:

| Executável | Alternativa |
|---|---|
| `bin/libxcb.dart` | libxcb via Dart FFI |
| `bin/dart_io.dart` | protocolo core em Dart sobre Unix `Socket` |
| `bin/libc_ffi.dart` | mesmo protocolo Dart sobre libc FFI |
| `bin/compare.dart` | executa a matriz completa |

O codec direto implementa intencionalmente apenas:

- `DISPLAY` Unix local e seleção de screen;
- leitura binária de Xauthority;
- `MIT-MAGIC-COOKIE-1`;
- setup X11 11.0 little endian;
- travessia de screens/depths/visuals no setup;
- geração de resource IDs;
- `CreateWindow`, `CreateGC`, `NoOperation`, `GetInputFocus` e `PutImage`;
- demultiplexação mínima de reply/error/event.

Essa lista já é substancial apesar de não criar uma janela de aplicação
completa. X.Org documenta o pacote de setup, byte order, versões e campos de
autorização na especificação do protocolo:
<https://www.x.org/releases/X11R7.5/doc/x11proto/proto.pdf>. O Xauthority padrão
usa `XAUTHORITY` ou `$HOME/.Xauthority`, e o cookie comum é de 128 bits:
<https://www.x.org/archive/X11R6.8.0/doc/xauth.1.html>.

## 5. Metodologia

Cada cliente conecta ao mesmo `DISPLAY`, seleciona a mesma screen e cria uma
janela não mapeada de 128×128 com um GC. Em seguida executa aquecimento e quatro
medições.

### 5.1 Conexão

Inclui abertura do transporte, autenticação, setup, criação da janela/GC e uma
barreira `GetInputFocus`. Isso impede contabilizar como “conectado” um cliente
que apenas enfileirou dados localmente.

### 5.2 NoOperation em lote

Envia 100 mil requisições de quatro bytes e uma barreira final.

- os clientes diretos constroem um buffer contíguo e fazem uma escrita lógica;
- a libxcb recebe uma chamada `xcb_no_operation` por request e faz um flush.

Esse cenário mede exatamente a alegação sobre custo de muitas transições FFI,
mas favorece o cliente direto. Não deve ser usado sozinho para escolher a
arquitetura.

### 5.3 Round-trip

Executa mil `GetInputFocus`, cada um enviado e respondido antes do próximo. A
latência tende a ser dominada pelo servidor, syscall e scheduling. Diferenças
de codec aparecem, mas batching não pode esconder o custo.

### 5.4 PutImage

Envia 300 imagens BGRA 128×128, equivalentes a 19,66 MB de pixels, seguidas por
barreira. O tamanho foi escolhido para caber no limite core sem BIG-REQUESTS.

- o cliente `dart:io` reutiliza um pacote `Uint8List`;
- o cliente libc copia o lote para memória nativa antes de `write(2)`;
- a libxcb recebe um ponteiro de pixels nativo em cada `xcb_put_image`.

O teste mede core `PutImage`, não MIT-SHM. Nenhuma das três alternativas pode
eliminar o payload sem mudar a técnica de apresentação.

## 6. Execução reproduzível

Sessão existente:

```sh
dart pub get
dart test poc/poc_21_x11_transport_matrix
DISPLAY=:0 dart run poc/poc_21_x11_transport_matrix/bin/compare.dart
DISPLAY=:0 dart run poc/poc_21_x11_transport_matrix/bin/compare.dart --json
```

Xvfb efêmero:

```sh
Xvfb :99 -screen 0 1280x720x24 -nolisten tcp -ac &
DISPLAY=:99 dart run poc/poc_21_x11_transport_matrix/bin/compare.dart --quick
```

Para números de entrega, usar AOT e repetir pelo menos 20 vezes em ordem
alternada:

```sh
dart compile exe poc/poc_21_x11_transport_matrix/bin/compare.dart \
  -o build/poc_21_x11_transport_matrix
DISPLAY=:99 ./build/poc_21_x11_transport_matrix --json
```

Registrar também CPU, kernel, Dart SDK, Xorg/Xvfb, libxcb, tipo de socket e
política de frequência do processador.

## 7. Resultados

O código foi criado em um host Windows, onde não existe socket X11 nem libxcb.
Por isso esta versão do relatório não apresenta números Linux fabricados.

Tabela a preencher com o JSON produzido pelo executável AOT:

| Backend | conexão | NoOp/s | RTT médio | PutImage MB/s |
|---|---:|---:|---:|---:|
| libxcb FFI | pendente | pendente | pendente | pendente |
| dart:io Socket | pendente | pendente | pendente | pendente |
| libc socket FFI | pendente | pendente | pendente | pendente |

Critérios para interpretar diferenças:

- abaixo de 5%: tratar como ruído até aumentar repetições;
- 5–15%: investigar cópias, batching e modo JIT/AOT;
- acima de 15% apenas em NoOp: provável custo de chamada por request;
- diferença semelhante em RTT: investigar event loop e bloqueio;
- diferença semelhante em PutImage: investigar cópias e tamanho das escritas;
- qualquer resultado core `PutImage` continua subordinado à comparação com
  MIT-SHM e GPU, que mudam o volume transportado.

## 8. Riscos descobertos pela implementação

### dart:io direto

Vantagens:

- sem ponteiros para transporte;
- backpressure e ciclo assíncrono administrados pelo runtime;
- batching simples com `Uint8List`/`BytesBuilder`;
- testes puros do codec em qualquer plataforma.

Custos:

- parser e máquina de estados próprios;
- suporte inicialmente restrito a Unix local;
- autenticação e segredos passam a ser responsabilidade do framework;
- extensões precisam de geração/manutenção manual;
- o event loop Dart não resolve semântica de eventos X11.

### libc socket FFI

Não oferece vantagem estrutural para este backend. Além de manter todo o codec
direto, exige:

- layout manual de `sockaddr_un`;
- ownership de descritores e buffers;
- tratamento de `errno`, `EINTR`, `EAGAIN` e escritas parciais;
- decisão entre bloquear o isolate, integrar `poll/epoll` ou criar outro
  isolate/thread;
- cópia Dart→nativo quando a origem é `Uint8List`.

Seu valor é servir de controle experimental e quantificar o custo da camada
`dart:io`.

### libxcb FFI

Vantagens:

- implementação madura do protocolo core;
- autenticação e parsing de `DISPLAY` existentes;
- batching assíncrono de requests/replies;
- erros e sequências administrados;
- ecossistema de extensões geradas de `xcb-proto`;
- FD acessível para integrar ao dispatcher.

Custos:

- dependência da biblioteca do sistema;
- bindings FFI e ABI precisam ser verificados;
- uma chamada FFI por request na API de alto nível;
- buffers XCB e Dart exigem ownership explícito.

## 9. Próximos experimentos

1. executar a matriz JIT e AOT em Xorg real, Xwayland e Xvfb;
2. repetir com requests pequenos individuais e lotes de 4, 16, 64 e 1024;
3. medir alocações e CPU, não apenas tempo de parede;
4. adicionar `xcb_shm_put_image` com dois buffers e completion event;
5. adicionar EGL/OpenGL e comparar frame time, não bytes por segundo;
6. testar carga simultânea de eventos para medir impacto no event loop Dart;
7. usar um gerador baseado em `xcb-proto` se o cliente direto continuar além
   da POC, evitando tabelas manuais de opcodes e layouts.

## 10. Conclusão

Espera-se que `dart:io` fique próximo ou à frente do socket libc FFI quando os
dados já estiverem em listas Dart e puderem ser agrupados. Essa comparação não
é suficiente para trocar libxcb por protocolo manual.

O gargalo do backend CPU atual é transportar pixels com core `PutImage`. A
otimização decisiva é MIT-SHM; para GPU, EGL/OpenGL ou Vulkan. Trocar somente a
função que escreve no socket preserva o mesmo volume de dados e assume uma
quantidade muito maior de código crítico.
