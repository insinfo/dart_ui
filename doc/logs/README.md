# Evidência bruta

Cada arquivo aqui é o registro de uma medição real de CI, com o número da run
para conferência. A regra do diretório: **nada afirmado aqui sem um log que
sustente**, e quando uma medição contradiz um documento de arquitetura, o
documento é corrigido — não o log.

## Decisões e conformidade

| Documento | O que estabelece |
|---|---|
| [CONFORMANCE_TRES_BACKENDS_2026-08-08.md](CONFORMANCE_TRES_BACKENDS_2026-08-08.md) | Os três backends macOS passando a mesma suíte: janela, framebuffer de CPU, testemunha externa de pixels, input pela rota real e teardown sem `_exit`. Inclui a correção da regra de drenagem que escondia o `pointerMove`. |
| [DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md](DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md) | Embedder no mesmo processo vs. Dart como worker. Veredito do linker sobre o SDK de release, três transportes de frame medidos em 480×320/1080p/4K, e a latência de input separada nos dois trechos da viagem. |
| [PRESENT_PACING_2026-08-08.md](PRESENT_PACING_2026-08-08.md) | Se o compositor acompanha, e quão larga é a janela em que uma escrita pode cair no meio do scan-out. Mostra que o gargalo é o loop de pixels em Dart, não o present. |
| [MACH_PORT_HANDOFF_2026-08-08.md](MACH_PORT_HANDOFF_2026-08-08.md) | Qual mecanismo de passagem de mach port ainda funciona no macOS 14. Confirma, 12 anos depois, que o libxpc continua limpando os registered ports no fork. |
| [MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md](MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md) | Trace LLDB provando que `CFRunLoopRun` retorna do `_sigtramp` e o processo sai com status 0 — o shutdown do backend 2 não precisa de `_exit`. |
| [METAL_APRESENTACAO_ESTADO_2026-09-07.md](METAL_APRESENTACAO_ESTADO_2026-09-07.md) | O que Metal e o backend macOS já provaram no `macos-14` e as três afirmações de `doc/` que deixaram de ser verdade. Inclui a limitação que o runner impõe: display `Apple Virtual` a `scale 1.0`, então "resize Retina" não é provável neste CI. |
| [MACOS27_TRES_BACKENDS_2026-10-12.md](MACOS27_TRES_BACKENDS_2026-10-12.md) | Os três backends lado a lado numa máquina real com macOS 27: cinco problemas, três nossos e dois do sistema (janela SkyLight transparente e surda a cliques), cada um com a evidência e a correção. |
| [MACOS_INPUT_IME_2026-10-12.md](MACOS_INPUT_IME_2026-10-12.md) | Input, clipboard e IME pelo host AppKit, e o que foi medido no caminho: teclas mortas só existem dentro do sistema de entrada, o AppKit só despacha teclas para janela na tela, a ativação é recusada conforme quem lançou o processo, e um host que morre entre duas escritas derrubava a aplicação. |
| [METAL_AUTORELEASE_POOLS_2026-10-12.md](METAL_AUTORELEASE_POOLS_2026-10-12.md) | O que `OBJC_DEBUG_MISSING_POOLS` imprimia e ninguém lia: o `MTLDevice` vazando na abertura, em cada `dispose` e duas vezes por quadro pela thread de conclusão do Metal. As três causas, a medição antes e depois, e a asserção que passou a travar o workflow. |

## Saídas de probe preservadas

| Arquivo | Origem |
|---|---|
| `poc19-event-loop-metrics.txt` | POC-19, métricas de integração de event loop |
| `event-pump.txt`, `pump-timer.txt`, `hold-appkit.txt` | Probes F, K e O do spike de main thread |

## Como reproduzir

```bash
gh workflow run "macOS main-thread spike"
gh run watch
```

O workflow é `workflow_dispatch` apenas. Os passos de conformidade e o
comparativo de transporte são gates; os probes históricos são
`continue-on-error` e existem pelo log.
