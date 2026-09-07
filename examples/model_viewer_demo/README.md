# Visualizador de modelos 3D

Abre OBJ, STL, glTF e GLB, orbita com o mouse, e mostra ao vivo o que cada
quadro custou. Tudo em Dart puro, sem dependência nova.

```powershell
dart run .\examples\model_viewer_demo\main.dart "D:\3d\sonic.glb"
dart run .\examples\model_viewer_demo\main.dart              # abre pelo diálogo
dart run .\examples\model_viewer_demo\main.dart --frames=200 --report modelo.stl
```

Arraste para girar. Os botões trocam o sombreado (suave, facetado, sem luz,
arame), param o giro automático e aproximam ou afastam.

## O que desenha, e o que não desenha

Os triângulos são rasterizados **pela CPU**, dentro de um framebuffer que o
backend da janela apresenta como *uma* imagem. Isso não é recuo nem provisório:
a display list deste framework tem comandos para caminhos, imagens, texto e
recortes, e **não tem triângulo nem buffer de profundidade**. Não existe
pipeline 3D aqui para receber uma malha.

A barra de status nomeia as duas metades — o tempo do rasterizador e o backend
que apresenta a saída — porque ler `direct3d11` ali e concluir que a GPU está
desenhando o modelo seria exatamente a conclusão errada.

Um caminho de malha na GPU seria formato de vértice novo, anexo de
profundidade, shader e pipeline em cinco backends. Nada aqui é passo nessa
direção.

## Medido nesta máquina

AOT, janela de 1080×780, Direct3D 11 apresentando:

| modelo | triângulos | rasterizador | fps |
|---|---|---|---|
| `sonic.glb` | 1.086 | 13,1 ms | 68,5 |
| `robotnik.obj` | 9.896 | 14,2 ms | 69,3 |
| `SciFi_Island.glb` | 115.752 | 62,1 ms | 17,5 |
| `Mario+Kart+3D+Statue.stl` | 451.838 | 142,2 ms | 8,1 |

Duas leituras que valem mais que os números:

- **abaixo de dez mil triângulos o custo é por pixel, não por triângulo.** Os
  dois primeiros modelos diferem por um fator de nove em geometria e por 8% em
  tempo. O que domina ali é limpar o alvo, limpar a profundidade e sombrear os
  pixels cobertos;
- **acima disso o custo é por triângulo**, e o que sobra para otimizar é
  alocação: o caminho por triângulo ainda constrói objetos de vértice e de tela
  em vez de trabalhar sobre os arrays. Está nomeado como o próximo passo em vez
  de escondido.

Duas otimizações já foram feitas e medidas:

| mudança | de | para |
|---|---|---|
| funções de aresta incrementais (1.086 triângulos, 512×512) | 5,44 ms | 1,57 ms |
| normal de face preguiçosa (451.838 triângulos, 512×512) | 91,4 ms | 64,0 ms |
| expressão regular içada para fora do laço (`robotnik.obj`) | 3.105 ms | 70 ms |

A última é a mais instrutiva: `line.split(RegExp(r'\s+'))` compila um padrão
novo a cada chamada, e mover a expressão para fora do laço rendeu **44 vezes**.
O código lê igual dos dois jeitos, que é por que isso sobrevive a revisão.

## Formatos

| formato | estado |
|---|---|
| OBJ | posições, normais, faces de qualquer aridade; `.mtl` é nomeado e não lido |
| STL | binário e ASCII; sem compartilhamento de vértices, por definição do formato |
| glTF 2.0 | nós, hierarquia, acessores com stride, cor base do material |
| GLB | o mesmo, com o buffer binário embutido |
| **FBX** | **recusado pelo nome**, com o que exportar no lugar |

O FBX é binário da Autodesk com árvore de nós e sistema de propriedades
próprios, e um histórico de versões que mudou o layout mais de uma vez.
Suportá-lo é um projeto; suportá-lo pela metade são modelos que abrem e estão
errados em silêncio.

Um `.gltf` aponta para um `.bin` ao lado por URI relativa. A biblioteca não
abre arquivos de propósito — um decodificador que abre arquivos não roda em
navegador, em teste, nem sobre bytes que vieram da rede — então o caminho fica
com quem chama, por `GltfBufferResolver`. Este exemplo o fornece.

## O que um arquivo pode ter e não é desenhado

Texturas, mapas de normal, mapas emissivos, animação, skinning e câmeras entram
em `unsupported` e aparecem em amarelo na barra de status. Um modelo que chega
sem textura porque texturas não estão implementadas não pode ser
indistinguível de um modelo que não tem textura.

## Se demorar segundos para abrir

`dart run` compila o grafo de imports inteiro a cada execução, cerca de **6
segundos** para este pacote contra ~50 ms em AOT, e o rasterizador é duas a
três vezes mais rápido compilado. Veja `tool/startup_cost.dart`.

```powershell
dart compile exe -o build\viewer.exe .\examples\model_viewer_demo\main.dart
.\build\viewer.exe "D:\3d\sonic.glb"
```

## Ferramentas ao lado

```powershell
dart run tool/mesh_load_probe.dart D:\3d          # carrega tudo e relata
dart run tool/mesh_render_probe.dart D:\3d\sonic.glb   # desenha em ASCII
```

O segundo imprime o quadro como texto. É grosseiro e responde as perguntas que
importam sem abrir janela: a silhueta tem a forma certa, a luz vem do lado
certo, e o que está atrás fica atrás.
