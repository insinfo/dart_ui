# Diário de sessões

Uma entrada por sessão, a mais recente no fim. Data, o que mudou, o que ficou
pela metade e o próximo passo. Ver `AGENTS.md`.

## 13/10/2026

**Mudou**
- O editor virou um projeto Dart completo (`pubspec`, `bin/`, `lib/src/engine`,
  `lib/src/ui`, `test/`, `tool/`). Nenhum teste da raiz depende dele.
- Tudo é um comando: cerca de 80 comandos no `CommandRegistry` do framework,
  com parâmetros declarados. Menus, menus de contexto, barra padrão, caixa de
  ferramentas, paleta, abas e painel Objetos agem por ele.
- Canal de controle (`--control <porta>`) com `package:dart_ui/automation.dart`;
  `tool/control_probe.dart` desenha, inspeciona, captura e salva só por ele.
- Paridade medida: `tool/parity.dart` gera `doc/paridade.md`. Primeira medida:
  23% no total, 52% das P0.
- Converter em curvas, inclusive texto (contornos dos glifos).

**Ficou pela metade**
- Os painéis de propriedades (Transform, Align, Fill & Outline) e a barra de
  propriedades ainda chamam o modelo direto, e não `registry.execute`.
- Auditoria de sala limpa do código que cita o sK1.

**Próximo passo**
- P0 que faltam, em ordem: edição de nós (F10), Combine/Break apart,
  booleanos (Weld/Trim/Intersect), teclas de alinhamento (L R T B C E P),
  Esc para desselecionar, Mão livre (F5), Propriedades (Alt+Enter).

### Mais tarde, no mesmo dia

**Mudou**
- Teclas de alinhamento do CorelDRAW (L R T B C E P), Esc para desselecionar,
  `object.distribute`. Quando dois comandos dividem uma tecla, o habilitado
  vence (B: alinhar embaixo com seleção, Caneta sem).
- Combinar (Ctrl+L) e Separar (Ctrl+K).
- Framework: `FillRule` único (em `geometry`); o do modelo vetorial era
  escondido do público, e nenhum app conseguia escolher a regra de um objeto.
- P0 em 65% (27% no total).

**Próximo passo**
- Edição de nós (F10) é a maior P0 que falta: adicionar, apagar, mover nós e
  segmentos, linha/curva, tipos de nó, juntar/quebrar.
- Booleanos (Soldar, Aparar, Interseção), Mão livre (F5), Propriedades
  (Alt+Enter), e os painéis de propriedades passando pelo registro.

