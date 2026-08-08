# Pacing de apresentação e a janela de tearing

**Run:** [`31274010694`](https://github.com/insinfo/dart_ui/actions/runs/31274010694)
— `macos-14` arm64, superfície 1920×1080
**Código:** [`vsync_probe.dart`](../../poc/poc_20_macos_three_backends/bin/vsync_probe.dart)

O benchmark de transporte respondeu **quanto custa** apresentar. Ele não
responde se o compositor acompanha, e não diz nada sobre o risco que existe com
uma superfície compartilhada única: o Dart escreve nas mesmas páginas que o
WindowServer está escaneando, então um frame pode ser composto pela metade. Um
present de 80 µs não melhora nem piora isso — a escrita e o scan-out
simplesmente não são sincronizados.

## Medição

| métrica | valor | fração de 16 667 µs |
|---|---|---|
| preencher a superfície (Dart) | 7 098 µs | 42,6% |
| apresentar | 409 µs | 2,5% |
| **frame completo** | **7 577 µs** | **45,5%** |
| frames atrasados em 120 | 0 | — |
| janela de escrita não sincronizada | 3 339 µs | 20,0% |

Teto sustentado: 266 fps, com o round trip do present em 188 µs de mediana.

## Correção de uma métrica minha

A primeira versão reportava `BUDGET_SHARE=2.08%`. Era verdade sobre o
*present* e enganosa sobre o *frame*: preencher a superfície custa uma ordem de
grandeza mais, e é essa parte que precisa caber no orçamento. Agora preenchimento,
present e total são reportados separadamente, e a fração vem do total.

Diferença entre a leitura errada e a certa: 2% contra 45%.

## Duas conclusões

### 1. O gargalo não é o present — é o loop de pixels em Dart

409 µs para apresentar contra **7 098 µs para preencher**. São 8,3 MB em
7,1 ms, ou ~1,2 GB/s, o que é lento para uma operação equivalente a um `memset`.

A causa provável é a escrita byte a byte: tanto o `fillBgra` da POC quanto o
`Framebuffer.clear` do framework escrevem quatro `Uint8List[i]` por pixel.
Escrever a palavra de 32 bits inteira por uma view `Uint32List` deve cortar
isso várias vezes, e é uma mudança local.

Isso é achado do framework, não da POC: o `CpuRasterizer` tem o mesmo padrão no
loop interno.

### 2. Double buffering é justificado, e agora com número

3 339 µs — **20% de um frame a 60 Hz** — é o tempo em que o processo continua
escrevendo em pixels que o compositor pode estar lendo. Não é hipótese: é a
duração medida de uma sobrescrita de superfície inteira sem present.

A sonda deliberadamente **não** afirma ter visto um tear. Provar um tear de
dentro do processo não é possível; o que ela faz é medir a largura da janela
em que ele pode acontecer, e 20% de frame é largo demais para ignorar.

**O que isso implica:** duas superfícies alternadas, com o host apresentando a
que acabou de ser completada enquanto o Dart escreve na outra. O protocolo já
suporta — `SURFACE` pode ser enviado mais de uma vez — então o trabalho é
lifecycle, não mecanismo.

## O que esta sonda não é

Não é um gate. Ela falha apenas se o host parar de responder, porque aí os
números não descrevem nada. O objetivo é dimensionar um problema, não guardá-lo.
