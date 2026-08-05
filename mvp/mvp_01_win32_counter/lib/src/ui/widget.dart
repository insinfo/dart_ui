/// Núcleo mínimo de widgets do MVP-01.
///
/// Modelo imperativo porém estruturado: cada widget tem `bounds`, `layout` e
/// `paint`, recebe input roteado pela raiz e participa do rastreio de dirty
/// rect. Não há árvore de elementos/reconciliação ainda — isso é o escopo das
/// fases do roteiro principal.
library;

import '../core/color.dart';
import '../core/geometry.dart';
import '../render/canvas.dart';

/// Códigos virtuais Win32 usados pelo teclado (subset do MVP).
const int vkTab = 0x09;
const int vkReturn = 0x0D;
const int vkSpace = 0x20;

/// Widget base: posição, layout, pintura e entrada.
abstract class Widget {
  /// Raiz que gerencia dirty rect; anexada no layout.
  UiRoot? _root;
  UiRoot? get root => _root;

  Rect bounds = const Rect.fromLTWH(0, 0, 0, 0);

  void _attach(UiRoot root) {
    _root = root;
  }

  /// Marca a região [rect] como suja; chama [repaint] na raiz.
  void markNeedsPaint(Rect rect) {
    root?.markDirty(rect);
  }

  /// Marca o próprio bounds como sujo.
  void repaint() {
    root?.markDirty(bounds);
  }

  /// Calcula `bounds` (e filhos) dado o tamanho da área visível.
  void layout(int width, int height);

  /// Desenha o widget (dentro do seu bounds).
  void paint(Canvas canvas);

  /// Widget focado (para navegação por Tab).
  void onFocusGained() {}
  void onFocusLost() {}

  /// Input: retorno `true` = evento consumido (não propaga).
  bool onMouseMove(int x, int y) => false;
  bool onMouseDown(int x, int y, int button) => false;
  bool onMouseUp(int x, int y, int button) => false;
  bool onKeyDown(int vk) => false;
  bool onKeyUp(int vk) => false;

  /// Hit-test padrão: dentro do bounds.
  bool contains(int x, int y) => bounds.contains(x, y);

  /// Alvo de foco para Tab (botões, campos, etc.).
  bool get isFocusable => false;
}

/// Raiz da árvore de widgets.
///
/// Possui o canvas, roteia entrada para os filhos, gerencia o foco e acumula
/// a região suja. A pintura reaproveita o framebuffer: apenas a união das
/// regiões sujas é limpa e repintada (partial raster); resizes forçam full
/// repaint.
class UiRoot {
  UiRoot(this._canvas);

  final Canvas _canvas;

  final List<Widget> _children = [];
  Widget? _focused;
  Widget? _hovered;
  final List<Widget> _focusOrder = [];

  Rect _dirty = const Rect.fromLTWH(0, 0, 0, 0);
  bool _fullDirty = false;
  int paintCount = 0;
  int _dirtyCount = 0;
  int get dirtyCount => _dirtyCount;

  /// Região suja efetivamente repintada no último `paint()`.
  Rect lastPaintedDirty = const Rect.fromLTWH(0, 0, 0, 0);

  int get width => _canvas.width;
  int get height => _canvas.height;

  void addChild(Widget child) {
    child._attach(this);
    _children.add(child);
    if (child.isFocusable) _focusOrder.add(child);
  }

  void markDirty(Rect rect) {
    _dirty = _fullDirty
        ? _dirty
        : _dirty.isEmpty
            ? rect
            : _dirty.union(rect);
    _dirtyCount++;
  }

  void markFullDirty() {
    _fullDirty = true;
  }

  /// Layout de todos os filhos (medição em toda a área).
  void layout() {
    _dirty = const Rect.fromLTWH(0, 0, 0, 0);
    _fullDirty = true;
    for (final child in _children) {
      child.layout(width, height);
    }
  }

  /// Repinta apenas a região suja (ou tudo se `markFullDirty` foi chamado).
  void paint() {
    if (_fullDirty) {
      _dirty = Rect.fromLTWH(0, 0, width, height);
      _fullDirty = false;
    }
    if (_dirty.isEmpty) return;
    lastPaintedDirty = _dirty;

    // 1) Limpa a região suja para o fundo.
    _canvas.fillRect(_dirty, _background);

    // 2) Repinta cada widget que intersecta a região suja.
    for (final child in _children) {
      final intersect = child.bounds.intersect(_dirty);
      if (!intersect.isEmpty) {
        child.paint(_canvas);
      }
    }
    paintCount++;
    _dirty = const Rect.fromLTWH(0, 0, 0, 0);
  }

  /// Região suja acumulada pendente de pintura.
  Rect get pendingDirtyRect => _dirty;

  /// Cor de fundo da área (default: escura, para destacar o conteúdo).
  Color get _background => const Color.opaque(30, 34, 42);

  // ---- Input routing ------------------------------------------------------

  /// Widget sob [x, y] (o último adicionado tem prioridade).
  Widget? hitTest(int x, int y) {
    for (final child in _children.reversed) {
      if (child.contains(x, y)) return child;
    }
    return null;
  }

  bool _routeMouse(bool Function(Widget w) action, int x, int y) {
    final target = hitTest(x, y);
    if (target == null) return false;
    return action(target);
  }

  void handleMouseMove(int x, int y) {
    final target = hitTest(x, y);
    if (!identical(_hovered, target)) {
      _hovered?.onMouseMove(-1, -1);
      _hovered = target;
    }
    target?.onMouseMove(x, y);
  }

  void handleMouseDown(int x, int y, int button) {
    _routeMouse((w) => w.onMouseDown(x, y, button), x, y);
    // Click fora de widget focável move o foco.
    final target = hitTest(x, y);
    if (target == null || !target.isFocusable) {
      setFocus(null);
    }
  }

  void handleMouseUp(int x, int y, int button) {
    _routeMouse((w) => w.onMouseUp(x, y, button), x, y);
  }

  void handleKeyDown(int vk) {
    // Tab: avança o foco na ordem de foco.
    if (vk == vkTab) {
      focusNext();
      return;
    }
    final focused = _focused;
    if (focused != null) focused.onKeyDown(vk);
  }

  void handleKeyUp(int vk) {
    final focused = _focused;
    if (focused != null) focused.onKeyUp(vk);
  }

  void setFocus(Widget? widget) {
    if (identical(_focused, widget)) return;
    _focused?.onFocusLost();
    _focused = widget;
    _focused?.onFocusGained();
  }

  void focusNext() {
    if (_focusOrder.isEmpty) return;
    final currentIndex = _focused == null ? -1 : _focusOrder.indexOf(_focused!);
    final next = _focusOrder[(currentIndex + 1) % _focusOrder.length];
    setFocus(next);
  }

  Widget? get focused => _focused;
}
