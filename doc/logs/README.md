# Evidência bruta

Cada arquivo aqui é o registro de uma medição real de CI, com o número da run
para conferência. A regra do diretório: **nada afirmado aqui sem um log que
sustente**, e quando uma medição contradiz um documento de arquitetura, o
documento é corrigido — não o log.

## Decisões e conformidade

| Documento | O que estabelece |
|---|---|
| [CONFORMANCE_TRES_BACKENDS_2026-08-08.md](CONFORMANCE_TRES_BACKENDS_2026-08-08.md) | Os três backends macOS passando a mesma suíte: janela, framebuffer de CPU, testemunha externa de pixels, input pela rota real e teardown sem `_exit`. Inclui a correção da regra de drenagem que escondia o `pointerMove`. |
| [DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md](DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md) | Embedder no mesmo processo vs. Dart como worker. Veredito do linker sobre o SDK de release e comparação medida de três transportes de frame. |
| [MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md](MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md) | Trace LLDB provando que `CFRunLoopRun` retorna do `_sigtramp` e o processo sai com status 0 — o shutdown do backend 2 não precisa de `_exit`. |

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
