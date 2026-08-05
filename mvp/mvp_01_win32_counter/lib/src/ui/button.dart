/// Botão com estados visuais (normal, hover, pressed, focused).
///
/// Desenhado 100% em Dart sobre o canvas BGRA. Ativa via clique ou teclado
/// (Enter/Space quando focado), que é o requisito do MVP-01.
library;

import '../core/color.dart';
import '../core/geometry.dart';
import '../render/canvas.dart';
import 'widget.dart';

enum ButtonState { normal, hover, pressed, focused }

final class Button extends Widget {
  Button({required this.label, this.onActivate});

  final String label;
  final void Function()? onActivate;

  ButtonState state = ButtonState.normal;
  bool _pressedInside = false;

  static const Color _baseColor = Color.opaque(68, 74, 92);
  static const Color _hoverColor = Color.opaque(82, 92, 116);
  static const Color _pressedColor = Color.opaque(48, 54, 68);
  static const Color _focusBorderColor = Color.opaque(96, 200, 255);
  static const Color _borderColor = Color.opaque(130, 138, 160);
  static const Color _textColor = Color.white;

  void _updateState(ButtonState next) {
    if (state == next) return;
    state = next;
    repaint();
  }

  @override
  bool get isFocusable => true;

  @override
  void layout(int width, int height) {
    bounds = Rect(
      bounds.left,
      bounds.top,
      bounds.right,
      bounds.bottom,
    );
  }

  @override
  void paint(Canvas canvas) {
    if (bounds.isEmpty) return;
    const radius = 6;
    final base = switch (state) {
      ButtonState.pressed => _pressedColor,
      ButtonState.hover => _hoverColor,
      _ => _baseColor,
    };
    canvas.fillRoundRect(bounds, radius, base);
    final focused =
        state == ButtonState.focused || state == ButtonState.pressed;
    canvas.strokeRect(
      bounds,
      focused ? 2 : 1,
      focused ? _focusBorderColor : _borderColor,
    );
    final labelArea =
        const Insets.symmetric(horizontal: 8, vertical: 4).deflate(bounds);
    canvas.drawText(label, labelArea, _textColor);
  }

  @override
  bool onMouseMove(int x, int y) {
    final inside = contains(x, y);
    if (inside) {
      if (!_pressedInside) {
        _updateState(_hasFocus ? ButtonState.focused : ButtonState.hover);
      }
    } else {
      _updateState(_hasFocus ? ButtonState.focused : ButtonState.normal);
    }
    return true;
  }

  bool get _hasFocus => identical(root?.focused, this);

  @override
  bool onMouseDown(int x, int y, int button) {
    if (contains(x, y)) {
      root?.setFocus(this);
      _pressedInside = true;
      _updateState(ButtonState.pressed);
      return true;
    }
    return false;
  }

  @override
  bool onMouseUp(int x, int y, int button) {
    final wasInside = _pressedInside;
    _pressedInside = false;
    if (wasInside && contains(x, y)) {
      _updateState(_hasFocus ? ButtonState.focused : ButtonState.hover);
      onActivate?.call();
      return true;
    }
    _updateState(_hasFocus ? ButtonState.focused : ButtonState.normal);
    return wasInside;
  }

  @override
  void onFocusGained() {
    _updateState(ButtonState.focused);
  }

  @override
  void onFocusLost() {
    _updateState(_pressedInside ? ButtonState.pressed : ButtonState.normal);
  }

  @override
  bool onKeyDown(int vk) {
    if (vk == vkReturn || vk == vkSpace) {
      onActivate?.call();
      return true;
    }
    return false;
  }
}
