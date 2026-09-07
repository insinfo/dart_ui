# Corrida do Lobo — um jogo de plataforma lateral

Corra, pule, role, esmague os inimigos, pegue os anéis e chegue à bandeira. Um
nível, do começo ao fim, em Dart puro, com os triângulos desenhados pela GPU.

## Navegador

Compile o launcher portátil, sirva a raiz do repositório e abra
`examples/side_scroller_game/web/`:

```powershell
dart compile js examples/side_scroller_game/web/main.dart -o examples/side_scroller_game/web/main.dart.js
python -m http.server 8080
```

`dart compile wasm examples/side_scroller_game/web/main.dart -o build/side_scroller_game/main.wasm`
confere o segundo compilador. O launcher tenta WebGPU primeiro e cai para
WebGL2 quando não recebe um adaptador.

```powershell
dart run .\examples\side_scroller_game\main.dart
dart run .\examples\side_scroller_game\main.dart --frames=1800 --demo --report
dart run .\examples\side_scroller_game\main.dart --script
```

| tecla | o que faz |
|---|---|
| `A` `D` ou `←` `→` | corre |
| espaço, `W` ou `↑` | pula — **segure para pular mais alto** |
| `ESC` ou `P` | pausa |
| `R` | recomeça |
| `ENTER` | recomeça depois que a corrida acabou |
| botão SOMBREADO | alterna suave / facetado / arame |

`--frames=N` roda N quadros e fecha a janela sozinha. `--demo` põe o piloto
automático no controle. `--script` roda o nível inteiro **sem abrir janela
nenhuma** e imprime o estado final. `--cpu` força o rasterizador de CPU.

Compile antes de julgar a velocidade: `dart run` gasta uns seis segundos
compilando o pacote antes de `main` (veja `tool/startup_cost.dart`).

## O que já existia e o que foi feito agora

A simulação já estava pronta e não foi tocada, além de um método novo
(`GameWorld.advanceWith`, explicado abaixo): `collision.dart`, `world.dart`,
`level.dart`, `follow_camera.dart` e `motion_state.dart` — a aritmética, sem
janela, sem malha e sem relógio.

O que faltava era tudo que se vê: `main.dart` (aplicação, teclado, HUD),
`game/mesh_builder.dart` (caixas, esferas, anéis), `game/actors.dart` (o elenco,
posado), `game/scene.dart` (a cena de cada quadro) e `game/autopilot.dart` (o
jogador que não é gente). E os testes.

## Por que o elenco é feito de código e não de modelos

Esta é a decisão que definiu a direção de arte inteira, e ela veio de um fato do
renderizador: **`MeshScene` desenha exatamente um `Mesh3D`, e uma
`MeshPrimitive` guarda os vértices já no espaço da cena.** Não existe transformação
por instância em lugar nenhum do caminho de desenho. Um nível com um
personagem, quatro inimigos e dezoito anéis é *uma* malha cujas partes móveis
são reconstruídas a cada quadro.

E os pipelines de GPU guardam os buffers de vértice pela **identidade** da
primitiva (`d3d11_mesh_pipeline.dart`). Primitiva reconstruída a cada quadro é
primitiva reenviada a cada quadro. Um personagem de 25 mil vértices são 600 KB
por quadro, 36 MB/s para *um* ator — e o comentário do próprio renderizador
Direct3D 11 aponta 200 MB/s como o tráfego que aquele cache existe para evitar.
A figura da Mixamo tem 167.742 vértices; aplicar o esqueleto nela em Dart e
reenviá-la sessenta vezes por segundo custaria três vezes isso antes de um
triângulo ser desenhado.

O elenco construído em código tem algumas centenas de vértices por ator. O mundo
visível inteiro deu **1.510 a 2.134 triângulos**, dos quais 636 a 1.080 vértices
são reconstruídos por quadro. E, o que importa mais: ele pode ser **posado**, que
é o que a máquina de estados de animação existe para pedir. Um modelo rígido
carregado pode ser girado e transladado, mas não balança uma perna, e um
personagem que nunca muda de forma é um adesivo num cartaz.

### Os modelos que foram pesados e recusados

Todos carregam. Nenhum é usado, e a razão é a de cima:

| arquivo | resultado |
|---|---|
| `Unarmed Walk Forward.fbx` | carrega: 55.914 triângulos, 167.742 vértices, 8 esqueletos, 838 ms |
| `Dying.fbx` | carrega: 49.112 triângulos, 147.336 vértices, 430 ms |
| `Wolf\Wolf.fbx` | carrega inteiro, com texturas: 11.172 triângulos, 917 ms |
| `Wolf\Wolf_fbx.fbx` | carrega, mas três texturas não estão ao lado do arquivo |
| `Wolf\Wolf_UDK.fbx` e mais três | **recusados pelo nome**: são FBX ASCII, e o leitor só lê FBX binário |

`dart run tool/mesh_load_probe.dart D:/3d/animated` diz isso a qualquer momento.

## O que foi medido

AOT, janela de 1120×700, corrida completa do piloto automático (1.800 quadros).

| caminho | quadro | fps | montar a cena | desenhar |
|---|---|---|---|---|
| **GPU (Direct3D 11)** | 10,0 ms | 100 | 0,23–0,46 ms | 0,21–0,47 ms |
| CPU (`--cpu`, `MeshRasterizer`) | 63,5 ms | 15,7 | 0,12 ms | 61,3 ms |

Três leituras que valem mais que os números:

- **os 10 ms são a tela, não o jogo.** O modo de apresentação é `fifo`, e o
  trabalho conhecido do quadro soma menos de 1 ms. Sobram nove milissegundos de
  folga por quadro para um nível bem maior que este;
- **o rasterizador de CPU é 6,4× mais lento com 1.638 triângulos**, o que quer
  dizer que o custo dele é *por pixel* e não por triângulo. Trocar o elenco por
  modelos de 50 mil triângulos não mudaria muito esse número — e mudaria muito o
  da GPU;
- **quando o quadro atrasa, o jogo fica em câmera lenta em vez de pular
  simulação.** O carimbo de tempo do quadro é o tempo *virtual* do dispatcher e
  não o relógio de parede (`frame_scheduler.dart` diz isso com todas as letras),
  e ele anda no máximo um intervalo de quadro por quadro. Forçado à CPU, o jogo
  rodou 400 quadros em 25,4 s de relógio e simulou 6,65 s de jogo, com o
  acumulador descartando **zero**. Isso é uma boa troca: um jogo que desacelera
  continua jogável e determinístico.

## As três emendas de `main.dart`

O arquivo é só a fiação, e a fiação é três coisas:

1. **relógio → passos fixos.** `FrameLoopOptions.continuous` faz o laço produzir
   quadro porque o tempo passou; a diferença entre dois carimbos vai para
   `GameWorld.advanceWith`, que roda passos inteiros de 10 ms e deixa um resto
   que o desenho interpola. Sem isso a janela desenha uma vez e dorme na fila de
   mensagens, e o personagem fica parado enquanto o teclado não faz nada — que é
   exatamente a cara de uma entrada quebrada;
2. **teclas → `GameInput`.** O estado de tecla pressionada é mantido aqui, porque
   nada neste framework guarda um conjunto de teclas pressionadas (só os
   modificadores). E ele é limpo quando a janela perde o foco: tecla segurada na
   hora do alt-tab nunca manda o evento de soltura, e o personagem sai correndo
   sozinho quando o foco volta;
3. **quadro → repintura, quase nunca reconstrução.** Um ticker roda *dentro* do
   quadro, então um `setState` vindo dele suja a construção que o quadro está
   assentando e a janela morre com "the frame did not settle in 8 passes". A
   imagem é `markNeedsPaint`; o HUD é reconstruído só quando um número dele
   mudou, de dentro de um `Timer.run` que cai depois do quadro.

E a regra que custa uma tarde a quem esquece: **nada opaco por cima do
viewport.** No caminho de GPU a cena é desenhada no back buffer *antes* da
display list, então um `ColoredBox` de janela inteira atrás do HUD produz uma
janela preta com uma interface funcionando — que se lê como "o modelo não
carregou", e não é. O HUD daqui é um `Stack` de painéis pequenos presos aos
cantos.

## O piloto automático, que é o teste de regressão

A forma óbvia de roteirizar uma corrida é gravar quais botões estão apertados em
quais instantes. Também é inútil como teste, porque é um teste *da fita*: mova
uma plataforma e a fita anda para dentro de uma parede, e a falha não diz nada
sobre o jogo.

`game/autopilot.dart` lê o mundo e decide. Continua perfeitamente
determinístico — nenhum relógio, nenhum número aleatório —, mas o que ele afirma
é que **o nível continua terminável**: que os vãos são puláveis na velocidade que
o ajuste produz, que os degraus da escada estão a um pulo um do outro, e que a
colisão não prende o personagem numa emenda do chão. Mudar a gravidade, o corte
do pulo, o epsilon da colisão ou a largura de um vão pode deixar um jogo que roda
perfeitamente e não pode ser terminado, e nada disso aparece numa captura de
tela.

Ele **planeja** o pulo em vez de chutar: projeta o arco para cada duração de
segurar o botão e pega o pulo mais curto que cai em chão firme depois do vão. A
primeira versão segurava sempre o mesmo tanto, e morria — um pulo cheio a partir
da borda viaja 6,8 unidades, o que limpa o vão de 3,2 e depois **passa por cima
da escada inteira**, caindo na fresta de 1,8 entre dois degraus.

```
> dart run .\examples\side_scroller_game\main.dart --script
level: Corrida do Lobo
steps: 1470 de 6000 (14.70 s simulados em 52 ms)
x=121.047 y=0.850 ... score=940 rings=14/18 stomps=4 lives=3 outcome=finished
```

O mesmo piloto na janela (`--frames=1800 --demo`) termina com exatamente os
mesmos números.

### O bug que essa comparação achou

Roteiro e janela discordavam: o roteiro terminava o nível, a janela caía no
primeiro vão. A causa era a emenda entre quadro e passo. `GameWorld.advance`
segura *uma* entrada para todos os passos que um quadro comprou, que é o certo
para um teclado — uma tecla não muda entre dois passos do mesmo quadro, porque
nada rodou entre eles. É errado para qualquer coisa que *lê o mundo* para
decidir: o piloto planeja o pulo de onde o personagem está, e reusar esse plano
num segundo passo é um plano feito de uma posição que ele já deixou. A 104
quadros por segundo contra uma simulação de 100 Hz, isso bastava. `advanceWith`
é a correção, e é a única linha nova em `world.dart`.

## Os testes

```powershell
dart test -j 1 test\examples\side_scroller_game\physics_test.dart
dart test -j 1 test\examples\side_scroller_game\game_shell_test.dart
```

`physics_test.dart` (28 casos) enuncia uma situação em números e cobra um número
de volta: corpo atravessando o chão a 260 unidades por segundo, corpo andando
pela emenda entre duas caixas, corpo escorregando por uma parede enquanto cai,
o acumulador quando o quadro atrasa um segundo, a zona morta da câmera, o
avanço com atraso reproduzindo o mesmo mundo a 60 e a 144 Hz, e cada transição
da máquina de estados. Cada um desses defeitos é *invisível* num jogo rodando —
quem assiste vê "está estranho" e não sabe qual dos quatro é o culpado.

`game_shell_test.dart` (9 casos) monta a árvore de widgets de verdade, dispara
`KeyDownEvent`/`KeyUpEvent` de verdade e pergunta ao **mundo** onde o personagem
foi parar — nunca ao código de entrada, que é exatamente a camada onde o defeito
não está. Ele também roda um quadro inteiro, o que rasteriza a cena na CPU e é a
única checagem automática de que os construtores de malha produzem geometria:
um personagem feito de zero triângulos é invisível e completamente silencioso.

## O que só uma pessoa pode julgar

Nada aqui prova que o jogo é **bom de jogar**. O que precisa de mão no teclado:
se a inércia do personagem é peso ou é atraso; se a câmera enjoa numa sequência
de pulos; se a janela de perdão do esmagamento (0,22) é generosa ou injusta; se
o nível é fácil demais; e se o piscar da invulnerabilidade é legível ou irrita.
