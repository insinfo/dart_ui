# ADR 0002 — Transformações 2D afins em vez de `Matrix4`

**Status:** aceito
**Data:** 8 de agosto de 2026

## Contexto

A seção 9.6 do roteiro esboça a display list com

```dart
final class TransformCommand extends DrawCommand {
  final Matrix4 transform;
}
```

Uma `Matrix4` guarda 16 floats. Um `TransformCommand` por nó de árvore visual,
em cada frame, com 16 floats cada, contraria diretamente a seção 6.5 — sem
alocações nem trabalho por pixel no hot path — e a seção 9.6, que pede opcode
compacto e nenhum objeto Dart por comando no caminho final.

3D está explicitamente em **escopo posterior** (seção 4.2). Toda transformação
que uma UI 2D precisa — translação, escala, rotação, cisalhamento e suas
composições — é afim e cabe em 6 floats.

## Decisão

O núcleo usa `Transform2D`, uma transformação afim 2D imutável de 6 doubles
(`a`, `b`, `c`, `d`, `tx`, `ty`), mapeando

```text
(x, y) -> (a*x + c*y + tx, b*x + d*y + ty)
```

`Matrix4` não entra no núcleo neste ciclo.

## Justificativa

- **Custo.** 6 floats contra 16 por transformação, em uma estrutura que aparece
  uma vez por nó por frame.
- **Escopo.** Perspectiva não é representável em afim 2D, mas 3D não é deste
  ciclo. Adotar `Matrix4` agora seria pagar por uma capacidade fora de escopo.
- **Fechamento.** Composição, inversão e transformação de retângulo são exatas
  em afim; não há caso 2D que exija a matriz completa.

## Consequências

**Positivas.** A serialização da display list fica mais barata e o encoder
consegue gravar a transformação direto no `Float32List` sem objeto intermediário.

**Negativas.** Quando 3D entrar em escopo, será preciso um segundo caminho de
transformação e uma decisão sobre como os dois convivem na display list. Isso é
um opcode novo, não uma reescrita: a codificação já é versionada por opcode.

## Nota sobre precisão

`Transform2D` guarda `double`. A display list grava coordenadas já em espaço de
dispositivo em `Float32List`, onde 24 bits de mantissa cobrem com folga
qualquer resolução de tela. A conversão acontece na fronteira do encoder, não
no modelo.

## Alternativas descartadas

- **`Matrix4` como o roteiro sugere:** custo por comando sem benefício dentro do
  escopo deste ciclo.
- **`Matrix3` (9 floats):** representa o mesmo conjunto de transformações que a
  afim 2D, com 3 floats a mais que nunca deixam de ser `0, 0, 1`.
