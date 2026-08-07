# POC-19 — o custo de hospedar um loop nativo ao lado do event loop do Dart

Mede, em números, o que a [proposta 04](../../doc/propostas/04_proposta_dart_sdk_event_loop_nativo_ptbr.md)
pede ao SDK. A [POC-10](../poc_10_event_loop) provou que a convivência entre um
loop Win32 e o event loop do Dart **funciona**; esta POC mede **quanto ela
custa** e quanto seria recuperado com a API proposta.

```powershell
dart run poc/poc_19_event_loop_metrics/bin/main.dart              # 3s por configuração
dart run poc/poc_19_event_loop_metrics/bin/main.dart --ci         # 800ms, com asserções
dart run poc/poc_19_event_loop_metrics/bin/main.dart --json       # saída para máquina
dart run poc/poc_19_event_loop_metrics/bin/main.dart --high-res-timer
dart run poc/poc_19_event_loop_metrics/bin/yield_probe.dart       # decomposição de uma iteração
dart test poc/poc_19_event_loop_metrics
```

Somente Windows. Sem wrapper C/C++ e sem `package:win32`: os bindings são
escritos à mão em [`lib/src/win32_bindings.dart`](lib/src/win32_bindings.dart)
para que nenhuma versão de pacote intermediário altere o que está sendo medido.

## O que é comparado

| Modo | O que faz | Representa |
| --- | --- | --- |
| `baseline` | nenhum loop nativo | grupo de controle: Dart puro |
| `polling 50ms` | espera nativa com timeout fixo de 50 ms | **o que a POC-10 faz hoje** |
| `polling 16ms` / `4ms` | mesmo, com timeouts menores | tentativa de compensar por força bruta |
| `spin` | timeout 0 | o outro extremo: latência ótima |
| `oracle` | espera até o trabalho conhecido e evento de kernel sinalizado quando surge trabalho novo | **o comportamento que `onEvent`/`handleEvent` devem permitir** |

O modo `oracle` é uma simulação manual de `Isolate.onEvent` +
`Isolate.handleEvent`. A POC conhece o deadline porque é dona do timer; isso
representa o instante em que o runtime deveria emitir `onEvent` ao tornar o
timer pronto, não a exigência de um getter público de deadline. Um framework
real não conhece todos os timers, mensagens e eventos de I/O do isolate — e é
exatamente por isso que precisa da notificação do runtime.

Dois cenários: `animating` (timer de 60 Hz + mensagens a cada 50 ms) e `idle`
(sem timer, mensagens a cada 500 ms), porque uma aplicação real passa a maior
parte do tempo no segundo.

## Resultados

Máquina: Windows 11 Pro 26200, Dart 3.6.2, execução única de 3 s por
configuração. Saída completa em
[`doc/logs/poc19-event-loop-metrics.txt`](../../doc/logs/poc19-event-loop-metrics.txt).

### Animating — timer de 60 Hz

| configuração | iter/s | frame Hz | gap p50 | gap p95 | msg p50 | msg p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | 0 | 61,0 | 15,81ms | 17,38ms | 0,07ms | 0,23ms |
| polling 50ms (poc_10) | 16 | **16,0** | 62,46ms | 63,81ms | 31,60ms | **63,02ms** |
| polling 16ms | 34 | 34,0 | 30,97ms | 32,02ms | 15,61ms | 31,27ms |
| polling 4ms | 64 | 62,3 | 15,55ms | 16,43ms | 15,20ms | 16,15ms |
| spin (timeout 0) | 333.160 | 62,3 | 16,00ms | 16,12ms | 0,03ms | 0,14ms |
| oracle (API proposta) | 80 | **59,2** | 15,70ms | 31,00ms | 0,14ms | **0,54ms** |

### Idle — sem timer de frame

| configuração | iter/s | wakeups ociosos/s | Mciclos/s | CPU % |
| --- | ---: | ---: | ---: | ---: |
| baseline | 0 | 0,0 | 2,6 | 0,0 |
| polling 50ms (poc_10) | 16 | **14,0** | 12,7 | 0,5 |
| polling 16ms | 35 | 33,0 | 21,5 | 0,0 |
| polling 4ms | 64 | 62,4 | 39,3 | 4,1 |
| spin (timeout 0) | 197.233 | 197.231 | 3.116,5 | **115,6** |
| oracle (API proposta) | 2 | **0,3** | 5,5 | 0,0 |

### Leitura

1. **Um timer de 60 Hz roda a 16 Hz sob o loop de polling de 50 ms.** Não é
   atraso: `Timer.periodic` reagenda a partir do momento em que dispara, então
   um timer faminto não recupera o atraso — ele simplesmente roda mais devagar.
   Com o `oracle`, 59,2 Hz contra um alvo de 60 e um baseline de 61,0.
2. **Latência de mensagem entre isolates cai de 63,02 ms p95 para 0,54 ms.** É
   o efeito isolado do wake handle: sem ele, a mensagem espera o timeout
   corrente terminar.
3. **Wakeups ociosos caem de 14,0/s para 0,3/s.**
4. **Spin não é a saída:** 116% de CPU e 3,1 bilhões de ciclos por segundo sem
   fazer nada.

## Metodologia

- **Relógio:** `QueryPerformanceCounter`, que é consistente entre threads,
  isolates e processos. É o que torna comparável um timestamp gravado no
  isolate emissor com outro gravado no isolate do loop.
- **Latência de mensagem:** um isolate secundário carimba cada mensagem com o
  QPC antes de enviar; o loop mede a diferença ao executar o handler.
- **Drift de frame:** medido como **intervalo entre ticks consecutivos**, não
  como desvio contra um cronograma absoluto, pela razão do item 1 acima.
- **Wakeup ocioso:** iteração que acordou por timeout e, após drenar a fila
  nativa e ceder ao Dart, não encontrou nem mensagem nativa nem trabalho Dart.
- **CPU:** `GetProcessTimes` (familiar, mas com granularidade de ~15,6 ms) e
  `QueryProcessCycleTime` (ciclos, muito mais fino).

## Ressalvas — leia antes de citar os números

1. **Quantum do timer do Windows.** Uma espera de 1 ms custa ~15,6 ms nesta
   máquina. A tabela `LOOP MECHANICS` mostra lado a lado o timeout **pedido** e
   o **efetivamente esperado**, justamente para que nenhuma linha seja lida como
   se de fato aguardasse o valor do rótulo. `--high-res-timer` chama
   `timeBeginPeriod(1)` para verificação — e o fato de ser preciso chamá-lo é
   argumento adicional para a proposta: é uma mudança de resolução global, com
   custo de energia, que um framework não deveria ser obrigado a fazer para
   compensar uma API ausente.
2. **A métrica de ciclos é do processo inteiro**, incluindo o isolate emissor e
   as threads de background da VM. Na taxa de wakeups do cenário ocioso ela não
   resolve o custo do loop, e os dois números chegam a se inverter entre
   execuções. A afirmação defensável é a **contagem de wakeups**, não o consumo
   de ciclos.
3. **Execução única.** Os números acima são de uma execução, em uma máquina
   desktop com CPU híbrida e power throttling. O modo `spin` variou entre 110k
   e 500k iterações/s entre execuções. As conclusões 1–4 têm margem larga o
   bastante para sobreviver a essa variância; nenhum número isolado deve ser
   citado com três casas decimais.
4. **A latência de mensagem no cenário ocioso tem poucas amostras** (~6 em 3 s),
   então seus percentis são ruidosos.
5. **Não há janela nem input real.** Esta POC mede a integração dos dois loops,
   não a entrega de input — `MsgWaitForMultipleObjectsEx` acorda imediatamente
   quando há input nativo, então esse caminho não é o problema. Janela e input
   estão nas POCs [01](../poc_01_win32_window) e [10](../poc_10_event_loop).

## Anomalia em aberto

Com `--high-res-timer`, os modos de 16 ms e 50 ms passam a honrar o timeout
pedido (16,35 ms e 50,06 ms). O modo de **4 ms continua esperando ~15,6 ms**
dentro do benchmark.

O [`yield_probe`](bin/yield_probe.dart) isolado, na mesma máquina e também com
`timeBeginPeriod(1)`, honra os 4 ms (4,02 ms) — inclusive com um
`Timer.periodic` de 60 Hz ativo, que era a hipótese mais óbvia. A causa não foi
identificada e está registrada aqui em vez de explicada por suposição.

Nenhuma das conclusões 1–4 depende da linha de 4 ms.

## Custo do `await Future.delayed(Duration.zero)`

É hoje a única forma de ceder um turno ao event loop do Dart a partir de código
Dart. Medido pelo `yield_probe`:

- ~6 µs em um laço apertado, onde o caminho rápido está sempre quente;
- ~250 µs quando precedido de uma espera nativa bloqueante.

Cerca de 1,5% de um orçamento de frame de 16,67 ms. O problema não é só o preço
por chamada: ela devolve o controle ao escalonador inteiro em vez de processar
no máximo um evento, que é o contrato já declarado de `Isolate.handleEvent()`.
