# ADR 0005 — Metal no macOS: IOSurface compartilhada, não comandos no protocolo

**Status:** proposto — **nada foi executado num Mac**
**Data:** 16 de agosto de 2026
**Depende de:** [`0001-worker-process-com-iosurface-no-macos.md`](0001-worker-process-com-iosurface-no-macos.md)
**Pendência que fecha:** "Metal além do framebuffer de CPU", listada em
[`MACOS_TRES_BACKENDS.md`](../MACOS_TRES_BACKENDS.md) § *Ainda fora da suíte*

## Escopo deste ADR

**Este ADR não decide se Metal funciona.** Ele decide *onde Metal roda* quando
o backend é o `appkitNativeHost` — o recomendado — e o que a palavra
"apresentar" significa nesse caminho. É a pergunta que o roteiro deixou em
aberto e que travava qualquer linha de código: sem ela, metade do backend seria
escrita duas vezes.

Ele também **não reduz o número de backends macOS**, pelo mesmo motivo que o
ADR 0001 precisou dizer isso em voz alta. `skylight` e `appkitSignal` rodam no
mesmo processo do Dart e por isso podem falar com um `CAMetalLayer`
diretamente; a decisão abaixo é o que permite que os três compartilhem o mesmo
`MTLDevice` e as mesmas pipelines em vez de terem cada um o seu.

E ele **não substitui o caminho de CPU**. O framebuffer BGRA por `IOSurface`
continua sendo o caminho medido e o fallback obrigatório de
`gpu_recovery.dart`.

## Contexto

Três fatos que já existem e não estão em disputa:

1. **A pilha de GPU é agnóstica de backend e está provada.** `GpuRasterSink`,
   `GpuBatcher`, `GpuMaskAtlas`, `GpuGlyphAtlas` e `GpuLayerStack` são código
   comum, exercidos por OpenGL, Direct3D 11 e Direct3D 12 — os dois últimos com
   paridade de pixel contra o rasterizador de CPU medida em **desvio 0**. Um
   quarto backend que reimplementasse qualquer uma dessas peças estaria
   violando a única regra que torna a comparação possível.
2. **O `appkitNativeHost` é um processo separado.** O ADR 0001 decidiu isso e
   mediu o custo. O `NSWindow`, a `NSView` e portanto qualquer `CAMetalLayer`
   pertencem ao processo host em Objective-C; o Dart é o worker.
3. **A travessia já existe e é barata.** Frames atravessam por `IOSurface`, com
   `SURFACE_PORT RENDEZVOUS` para entregar a superfície e `PRESENT_SLOT <seq>
   <slot>` para apresentá-la — protocolo versão 4. Medido em 66 µs a 480×320 e
   130 µs a 3840×2160, praticamente independente da resolução.

O que falta é a ponte: hoje o Dart escreve pixels naquela `IOSurface` com a
CPU. A pergunta é como a GPU entra.

## Opções

### (a) O Dart codifica comandos e o host executa Metal

O `host_protocol.dart` ganha um vocabulário de desenho. O Dart continua
montando batches, mas em vez de rasterizar os serializa; o host os decodifica e
emite as chamadas Metal.

### (b) `IOSurface` como textura Metal compartilhada

O Dart abre o seu próprio `MTLDevice` **no processo worker**, embrulha a
`IOSurface` do `surface_pool.dart` com
`newTextureWithDescriptor:iosurface:plane:`, renderiza nela com exatamente o
mesmo `GpuRasterSink` que o GL e o D3D usam, e apresenta com o `PRESENT_SLOT`
que já existe. O host nunca vê um comando de desenho: continua sendo consumidor
de uma superfície pronta, como já é.

### (c) `CAMetalLayer` no processo do Dart

Não é alternativa para o `appkitNativeHost` — a layer está do outro lado da
fronteira. É o que `skylight` e `appkitSignal` fazem, e está listada aqui
porque é a razão de a decisão precisar de uma costura e não só de uma escolha.

## Decisão

**Opção (b).** O Metal roda no processo Dart, escreve na `IOSurface`
compartilhada, e a apresentação continua sendo `PRESENT_SLOT`.

Com uma consequência estrutural que faz parte da decisão: o backend é cortado
em **dispositivo** e **apresentador**.

| Peça | Conteúdo | Compartilhada? |
|---|---|---|
| `MetalRenderDevice` | `MTLDevice`, `MTLCommandQueue`, biblioteca MSL, as três `MTLRenderPipelineState`, texturas, atlas | sim, pelos três backends |
| `MetalSurfacePresenter` | textura sobre `IOSurface` + `PRESENT_SLOT` | `appkitNativeHost` |
| `MetalLayerPresenter` | `CAMetalLayer`, `nextDrawable`, `presentDrawable:` | `skylight`, `appkitSignal` |

`presentDrawable:` e o triple buffering do `CAMetalLayer` existem apenas no
segundo apresentador. No caminho recomendado, **o triple buffering é o do
`surface_pool.dart`**, que já existe, já é medido e já sobrevive à morte do
host.

## Justificativa

### O que a opção (a) custaria, em bytes e em código duplicado

O payload por frame da opção (a) é a saída do `GpuBatcher`: 48 bytes por
vértice, 4 vértices e 6 índices por quad — **216 bytes por quad**. Um frame de
UI modesto de 2 000 quads são 432 KB, e a 60 Hz são ~26 MB/s de pipe. Aplicando
a taxa implícita na linha `pipe` de 1920×1080 do ADR 0001 (8,1 MiB em 14 361
µs), 432 KB sairiam por volta de **750 µs por frame** — contra os 107 µs que a
`IOSurface` custa naquela mesma resolução.

**Esse número é aritmética sobre uma medição alheia, não uma medição desta
opção.** É provavelmente pessimista: aquele 14 361 µs inclui a reconstrução do
`CGImage` por frame, que a opção (a) não teria. Vale como ordem de grandeza e
não como evidência.

O custo que decide não é esse. É que a opção (a) **reescreve o renderizador em
Objective-C**: pipeline states, blend por batch, scissor, upload das duas
atlases por região suja, passes de layer com render-into-texture. Tudo isso é
`gpu_raster_sink.dart` e `gpu_layer_stack.dart`, que já existem, já têm testes
e já são comparados pixel a pixel contra a CPU. Um segundo renderizador em
outra linguagem, do outro lado de um pipe, é a definição de divergência não
testável — e o `native/dart_ui_macos_host.m` é explicitamente pequeno o
bastante para ser auditado linha a linha, propriedade que ele perderia.

Some-se que as atlases também teriam de atravessar: máscara e glifos são
1024×1024 alpha8, 1 MiB cada, com upload por região suja.

### Por que a superfície compartilhada não custa protocolo nenhum

A opção (b) não acrescenta um único verbo ao `host_protocol.dart`. O host
recebe `PRESENT_SLOT <seq> <slot>` e não tem como saber — nem precisa saber —
se aqueles bytes foram escritos por `raster/` ou por uma `MTLRenderCommandEncoder`.
A superfície pertence ao Dart, como o ADR 0001 já estabeleceu ao provar que ela
sobrevive ao `SIGKILL` do host.

### A aresta afiada: quem sabe que a GPU terminou

Este é o problema real que a opção (b) introduz e que a opção (a) não teria.

No caminho de CPU, quando o Dart manda `PRESENT_SLOT` os pixels já estão na
memória. Com Metal, `commit` só **enfileira**: a GPU ainda está escrevendo a
`IOSurface` quando a chamada retorna. Mandar `PRESENT_SLOT` ali entrega ao host
uma superfície meio escrita, e o artefato — tearing dentro do próprio frame —
aparece de forma intermitente e dependente de carga, que é a pior forma de
aparecer.

Três formas de resolver, e a escolhida:

1. **`waitUntilCompleted`.** Correto e caro: serializa CPU e GPU a cada frame,
   destruindo exatamente o paralelismo pelo qual se adotou Metal.
2. **`addCompletedHandler:`, mandando `PRESENT_SLOT` de dentro do handler.**
   Escolhido. Custa uma volta pelo isolate — o handler é chamado numa thread da
   Metal, então a `NativeCallable` por trás do bloco **tem de ser**
   `NativeCallable.listener`, cuja entrega é assíncrona.
3. **`MTLSharedEvent` atravessando a fronteira.** É a resposta certa a prazo: o
   host esperaria o evento em vez de esperar uma linha no pipe. Não foi
   escolhida agora porque `MTLSharedEventHandle` é `NSSecureCoding` e quer XPC,
   enquanto o transporte aqui é um pipe mais um mach port. Fica registrada como
   otimização a medir, não como dívida.

A geração entra aqui, e é o motivo de o `GenerationToken` do
`lifecycle.dart` ser obrigatório neste caminho e não uma boa prática: o handler
de conclusão dispara depois, numa thread que não é a do isolate, e um resize
pode ter acontecido no meio. **Um `PRESENT_SLOT` emitido por um handler de uma
geração anterior é descartado**, não enviado — apresentá-lo mostraria o frame
antigo esticado no tamanho novo.

### MSL em runtime, não `.metallib` pré-compilado

Decisão separada e menor, registrada aqui porque a alternativa arrastaria uma
toolchain: **os shaders são compilados em runtime com
`newLibraryWithSource:options:error:`.**

Um `.metallib` exige `xcrun metal` e `xcrun metallib` — ferramentas da Apple,
disponíveis só em macOS com Xcode instalado. Adotá-lo significaria que:

- o repositório passaria a ter um artefato binário que **nenhum
  desenvolvedor em Windows ou Linux consegue regenerar**, e este backend
  inteiro foi escrito em Windows;
- ou o CI de macOS passaria a ser um passo de build de produção e não só de
  verificação, com o `.metallib` versionado ou publicado.

O que se paga por evitar isso é a compilação por device, uma vez por processo.
É o mesmo custo que o backend OpenGL paga com `glCompileShader` e que o
Direct3D 12 paga com `D3DCompile`, e nos dois casos ele já foi julgado
aceitável. A `MTLCompileOptions` é criada com os defaults; a fonte MSL vive em
`metal_shaders.dart` como `String`, transposta linha a linha de
`gl_shaders.dart` e `d3d12_shaders.dart`, o que é o que torna a comparação
entre backends uma comparação e não uma coincidência.

## Consequências

**Positivas.** Nenhum verbo novo no protocolo, e portanto nenhuma mudança no
host Objective-C nem no seu lifecycle já medido. A pilha de GPU comum é
reusada inteira — o mesmo `GpuRasterSink` que produziu desvio 0 contra a CPU no
D3D11 e no D3D12 produz o mesmo desenho aqui, e a suíte de paridade se aplica
sem adaptação. O `MetalRenderDevice` serve aos três backends macOS, porque o
que muda entre eles é só o apresentador. A recuperação de crash do host
continua valendo tal como medida: a `IOSurface` pertence ao Dart.

**Negativas.** São quatro, e nenhuma é hipotética.

1. **Dois `MTLDevice` no sistema, um por processo.** Em Apple silicon há uma
   GPU e `MTLCreateSystemDefaultDevice` devolve a mesma nos dois lados. **Num
   Mac Intel com GPU discreta isso não está garantido**, e uma `IOSurface`
   escrita por uma GPU e lida por outra é, na melhor hipótese, uma cópia
   silenciosa. O protocolo não carrega `registryID` hoje, então **não há como
   detectar isso** — está declarado como dúvida aberta abaixo, não como
   resolvido.
2. **Latência de apresentação sobe por uma volta de isolate**, porque o
   `PRESENT_SLOT` sai do handler de conclusão. Não medido.
3. **Sem `presentDrawable:` no caminho recomendado**, e portanto sem o
   agendamento que o `CAMetalLayer` faz por conta própria. O pacing passa a ser
   responsabilidade do `surface_pool.dart` e do host.
4. **Compilação de MSL por processo**, com o custo de arranque que isso
   implica e sem número para ele.

**Não medido, e por isso não afirmado.** Nada neste ADR foi executado num Mac.
Não há aqui nenhuma afirmação de que Metal desenhe um pixel; há uma decisão de
arquitetura tomada sobre medições que existem (as do ADR 0001) e sobre
propriedades do código que existem (a pilha comum de GPU e seus testes).

## Evidências

O que é evidência de verdade, e de onde vem:

| Afirmação | Evidência | Força |
|---|---|---|
| `IOSurface` atravessa a fronteira em ~100 µs, quase independente da resolução | tabela do ADR 0001, `macos-14` arm64 | medição |
| A superfície pertence ao Dart e sobrevive à morte do host | run [`31272239992`](https://github.com/insinfo/dart_ui/actions/runs/31272239992) | medição |
| `PRESENT_SLOT` já é o caminho de produção | `host_protocol.dart`, protocolo v4 | código em uso |
| A pilha comum de GPU serve a backends diferentes sem duplicação | GL, D3D11, D3D12; paridade de CPU em desvio 0 | medição |
| Um pipe custa ~578 MB/s efetivos | derivado da linha 1920×1080 do ADR 0001 | **aritmética, teto** |
| O `objc_msgSend` tipado casa com as assinaturas declaradas | `test/ffi/objc_runtime_test.dart`, roda em Windows | teste, sem Mac |
| Layout das structs Metal e do bloco de uniformes | `test/rendering/gpu/metal/metal_bindings_test.dart` mede offset por sentinela, roda em Windows | teste, sem Mac |
| Seletores, enums e ownership | `metal-cpp`, lido em 16/08/2026 — ver `kMetalBindingProvenance` | transcrição de header |
| `MTLLoadActionClear` é 2 e não 0 | `metal-cpp`, `MTLRenderPass.hpp`; o `poc_07_metal` tinha 0 | transcrição, com o erro anterior documentado |
| Metal desenha | — | **nenhuma** |

A última linha é o ponto. A seção 6.6 do roteiro diz que capacidade fingida é
pior que capacidade ausente, e este ADR é aceito sabendo que a última linha
está vazia.

## Plano de reversão

A decisão foi construída para ser barata de desfazer, e o teste disso é
concreto: **o caminho de CPU não é tocado**. Reverter é, em ordem:

1. **Desligar sem remover.** `MacosBackendOptions` já escolhe backend; a
   seleção de renderizador cai para o rasterizador de CPU, que continua sendo o
   default até que exista medição em contrário. Nenhum arquivo é revertido —
   `gpu_recovery.dart` já trata "GPU indisponível" como estado normal e o
   `RendererFellBackToCpu` já existe para descrevê-lo.
2. **Se a causa for o apresentador** — pacing, latência, a volta pelo isolate —
   trocar `MetalSurfacePresenter` por `MetalLayerPresenter` **não é reversão**,
   é a outra metade da costura, e o `MetalRenderDevice` fica de pé. Isso exige
   mudar de backend macOS, o que é uma decisão do ADR 0001 e não deste.
3. **Se a causa for a superfície compartilhada** — o caso de duas GPUs, ou
   `newTextureWithDescriptor:iosurface:plane:` recusando o formato — a reversão
   real é a opção (a), e ela custa o renderizador em Objective-C que esta
   decisão evitou. É a razão de o item 1 existir: o caminho de CPU cobre o
   intervalo.
4. **Excluir** `lib/src/rendering/gpu/metal/` e `test/rendering/gpu/metal/`
   não quebra nada fora deles. Nenhum arquivo comum foi modificado para
   acomodar este backend — a checagem é `git diff --stat` mostrando apenas
   `lib/src/ffi/objc_runtime.dart`, `lib/src/rendering/gpu/metal/`,
   `doc/adr/` e os testes correspondentes.

## Quando reabrir

- **Assim que houver um Mac na mesa.** Todo este documento é uma decisão de
  arquitetura tomada sem execução, e a primeira medição real tem autoridade
  sobre ele.
- Se um Mac Intel com GPU discreta aparecer no alvo: a dúvida do `registryID`
  deixa de ser teórica e o protocolo precisa carregá-lo para que os dois lados
  possam recusar em vez de copiar em silêncio.
- Se a latência de apresentação medida com `addCompletedHandler:` for
  significativa: `MTLSharedEvent` sobre XPC passa a valer o transporte novo.
- Se o custo de compilar MSL no arranque aparecer num perfil: o `.metallib`
  volta à mesa, junto com a decisão de toolchain que ele arrasta.
