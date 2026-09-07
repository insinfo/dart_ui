# Reprodutor Lottie

Toca uma animação Lottie e mostra, ao vivo, o que cada quadro custou. Existe
para ser medido: o arquivo de amostra é uma animação real do LottieFiles e não
uma cena sintética, o que importa — um benchmark feito de mil retângulos
arredondados iguais mede um caminho de código só, e animação vetorial de
verdade é sobretudo contorno cúbico com morph por quadro.

```powershell
dart run .\examples\lottie_player_demo\main.dart                # interativo
dart run .\examples\lottie_player_demo\main.dart --dotlottie    # do contêiner ZIP
dart run .\examples\lottie_player_demo\main.dart --frames=300 --report
dart run .\examples\lottie_player_demo\main.dart --bench        # todos os modos
```

O decodificador está em `lib/src/graphics/lottie/` e é Dart puro: JSON pelo
`dart:convert`, ZIP pelo leitor em `lib/src/graphics/container/`, e nenhuma
dependência nova.

## Por que trocar o renderizador reinicia o programa

Não é limitação do exemplo, é decisão do framework: **`RenderPolicy` é lida uma
vez, quando o dispositivo abre.** O `GpuPathPlanner` escreve o motivo no
próprio comentário — uma política que pudesse mudar debaixo de um quadro em
andamento faria dois desenhos da mesma forma, no mesmo quadro, responderem
diferente. E `RenderingPolicy` é mais forte ainda: CPU e GPU são dispositivos e
swap chains diferentes.

Então os botões não fingem. Cada um relança o programa com as flags do modo que
nomeia, e a interface diz isso. Um botão que não fizesse nada em silêncio seria
pior que botão nenhum.

## Medido nesta máquina

Intel UHD Graphics, janela de 980×720, 300 quadros por modo, `--bench`:

| modo | backend | fps | display list (µs/quadro) | caminhos |
|---|---|---|---|---|
| GPU (padrão) | direct3d11 | 102,0 | 192 | 29 |
| GPU só atlas | direct3d11 | 100,0 | 146 | 29 |
| GPU caminhos grandes | direct3d11 | 102,6 | 176 | 29 |
| CPU | win32-dib | **227,7** | 125 | 29 |

**A CPU ganha, e o número merece explicação em vez de ser escondido.** Esta
cena tem 29 caminhos, 15 preenchimentos e 18 contornos numa área de menos de um
megapixel — é pequena. A GPU cobra por quadro um custo fixo que não depende
disso: montar o lote, subir o atlas, apresentar pela swap chain. Abaixo de
certo tamanho de cena esse custo fixo é o quadro inteiro, e o rasterizador de
CPU desenhando direto num DIB não o paga.

Isso não inverte a §8.1.1 do roteiro. O framework é GPU primeiro porque a
escala em que ele precisa ganhar é a outra: mil caminhos, texto, imagens,
vídeo, várias janelas. O que esta tabela mostra é onde a curva cruza, e uma
animação Lottie de personagem fica do lado pequeno dela.

A coluna que compara os modos de GPU entre si é a do custo da display list, e
ali a diferença é de montagem no lado da CPU, não de rasterização: as três
rotas emitem os mesmos 29 caminhos.

## O que não é desenhado neste arquivo

`Cute Mascot Jumping Character` usa **matte de alfa invertido** em duas camadas
de perna. As camadas-fonte do matte não são desenhadas — correto de qualquer
jeito, nenhum reprodutor desenha uma fonte de matte por si — e as duas pernas
desenham sem o recorte. O reprodutor mostra isso em amarelo na barra de status
em vez de deixar a diferença invisível.

A lista completa do que o decodificador recusa por nome está no comentário de
`lib/src/graphics/lottie/lottie_parser.dart`: texto, imagens, máscaras, mattes,
trim path, gradientes, repetidores, merge path e 3D.

## Se a janela demora segundos para aparecer

`dart run` sobre um arquivo `.dart` compila o grafo de imports inteiro a cada
execução — cerca de **6 segundos** para este pacote, contra ~50 ms em AOT. Veja
`tool/startup_cost.dart`. Para medir o que seria entregue:

```powershell
dart compile exe -o build\lottie.exe .\examples\lottie_player_demo\main.dart
.\build\lottie.exe --bench --frames=300
```
