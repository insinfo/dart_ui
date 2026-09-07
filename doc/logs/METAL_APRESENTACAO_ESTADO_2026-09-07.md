# Metal no macOS — o que já foi medido e o que o roteiro ainda dizia errado

**Runs:**
[`34148425779`](https://github.com/insinfo/dart_ui/actions/runs/34148425779)
(`Metal mesh ABI probe`, `macos-14` arm64, sucesso, 07/09/2026 17:38 UTC) e
[`34153314897`](https://github.com/insinfo/dart_ui/actions/runs/34153314897)
(`macOS native popup probe`, mesma máquina, sucesso, 07/09/2026 18:51 UTC).

**Código:** [`metal_mesh_abi_probe.dart`](../../tool/metal_mesh_abi_probe.dart),
[`metal_mesh_runtime_probe.dart`](../../tool/metal_mesh_runtime_probe.dart),
[`macos_popup_probe.dart`](../../tool/macos_popup_probe.dart),
[`macos_backend_smoke.dart`](../../tool/macos_backend_smoke.dart).

Este arquivo existe porque três afirmações repetidas em `doc/` deixaram de ser
verdade sem que ninguém as corrigisse, e a regra deste diretório é que quando
uma medição contradiz um documento de arquitetura, **o documento é corrigido**.
Nenhuma das três é opinião: cada uma tem uma linha de log com número de run.

## 1. A MSL de `metal_shaders.dart` já foi compilada num Mac

`metal_shaders.dart` afirmava, em negrito: *"**Nothing here has been
compiled.** There is no Mac in this loop and `newLibraryWithSource:options:
error:` has never been called on this string."*

**Falso desde a run `34148425779`.** O caminho é direto e vale a pena escrever
porque não é óbvio pelo nome do probe: `MetalPipelineCache.build` chama
`gpu.compileShaderLibrary()`, que sem argumento compila `kMetalShaderSource` —
a string que vive em `metal_shaders.dart`. A run imprime:

```
METAL_DEVICE=PASS name=Apple Paravirtual device
METAL_MESH_PIPELINE_STATE=PASS
```

Um `MTLRenderPipelineState` só existe se a biblioteca compilou e se as duas
entry points foram encontradas. O que **continua** verdadeiro é o resto do
parágrafo: os testes que rodam fora do Mac seguem sendo estruturais, e o que
eles garantem não é sintaxe de MSL. A afirmação foi estreitada, não apagada.

## 2. O runner tem GPU de verdade — e é paravirtualizada

`MTLCreateSystemDefaultDevice()` devolve um device, e ele se chama
**`Apple Paravirtual device`**. Isso responde a metade da dúvida que travava o
trabalho — o runner não é headless a ponto de não ter Metal — e **abre a outra
metade**, que é exatamente onde este nome importa: um device paravirtualizado é
a classe de hardware em que `newTextureWithDescriptor:iosurface:plane:` pode
recusar, e em que uma `CAMetalLayer` sem janela pode nunca entregar um
drawable. Nenhuma das duas foi exercida até hoje.

A run também mostra o que já está provado além do device: 27 seletores com o
encoding lido de volta do runtime Objective-C (`source=protocolDeclaration`,
`concreteClass`, `classMethod` — as três rotas que `metalRuntimeEncoding`
percorre) e quatro modos de sombreamento desenhados e lidos de volta
(`SHADING=PASS mode=smooth changed=19022`).

## 3. O runner tem sessão gráfica real, com `NSWindow` de verdade

A run `34153314897` não é sobre Metal e mesmo assim é a evidência mais
importante para ele, porque diz que existe uma janela para apresentar:

```
popup: WINDOW_ID=24
popup: SCREEN_INFO=0:0:1920:1080:0:25:1920:970:1.0000:1:Apple Virtual
popup: WINDOW=EXPOSED:0.0000:0.0000:180.0000:100.0000
popup: WINDOW_INSPECT=popup:NSPanel:128:101:0:0:1
MACOS_BACKEND_WINDOW=PASS id=1
MACOS_SCREENS=PASS count=1
```

`NSPanel` reais, com número de janela, evento `EXPOSED` e uma `NSScreen`
enumerada. O `macos-14` não é uma VM sem WindowServer: é uma sessão gráfica
completa a 1920×1080.

### E a limitação que essa mesma linha impõe

**`scale: 1.0`, num display chamado `Apple Virtual`.**

O runner não tem display Retina e não há como pedir um. Portanto o item
**"resize Retina"** da §21.6 **não pode ser provado neste CI** — nem agora nem
depois que a apresentação funcionar. Ele fica desmarcado com o motivo escrito
ao lado, e não marcado por um teste a 1× que passaria sem tocar no código que
importa: a conversão de pontos para pixels só erra quando os dois números
diferem.

É a mesma disciplina que manteve Metal honesto enquanto ele era recusado. Um
checkbox marcado por uma medição que não podia falhar vale menos que um
checkbox vazio com a razão nomeada.

## O que continua verdadeiro no roteiro

A frase central da §21.6 — **"clear/present — não há apresentação nenhuma"** —
**segue correta**, e foi reconferida contra o código e não contra o texto:

- `lib/src/rendering/gpu/metal/` tem sete arquivos e **nenhum
  `metal_window_target.dart`** nem `metal_surface_descriptor.dart`, enquanto
  `d3d11/` tem os dois;
- `MetalRendererBackend.supportsSurface` aceita só `MemorySurfaceDescriptor`;
- a capacidade anunciada continua `cpuPresentation`.

E há um detalhe que o roteiro não registrava: os três seletores que separam
este repositório da apresentação —
`newTextureWithDescriptor:iosurface:plane:`, `addCompletedHandler:` e a leitura
por `IOSurfaceLock` — estão **declarados em `kMetalSelectors` e com encoding
verificado a cada push**, e mesmo assim **nunca foram enviados**, em lugar
nenhum de `lib/`, `test/` ou `tool/`. Nenhum `ObjCBlock` jamais foi construído
neste repositório; os testes conferem `sizeOf<ObjCBlockLiteral>() == 32` e
param aí.

Encoding conferido não é chamada feita. É essa distinção que
[`metal_present_probe.dart`](../../tool/metal_present_probe.dart) existe para
fechar.

## Por que o alvo é a `IOSurface` e não uma `CAMetalLayer`

Registrado aqui porque é o erro natural de quem chega pelo
`d3d11_window_target.dart` e raciocina por analogia.

`macos_backend_selection.dart` fixa `canCreateWindow: false` para **`skylight`
e `appkitSignal`** — os dois seguem em POC. O único backend macOS que cria
janela em `lib/` é o `appkitNativeHost`, e o ADR 0001 colocou o `NSWindow`
dele, e portanto qualquer `CAMetalLayer`, **em outro processo**.

Logo, um apresentador por `CAMetalLayer` **não tem janela neste repositório
para se prender**. Escrevê-lo seria exatamente o apresentador Metal
inverificável que este projeto já recusou uma vez. O ADR 0005 já tinha decidido
isso e continua valendo: Metal escreve na `IOSurface` compartilhada e a
apresentação segue sendo `PRESENT_SLOT`.

## Como reproduzir

```bash
gh workflow run "Metal presentation probe"
gh run watch
```
