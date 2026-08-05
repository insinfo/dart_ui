/// Geometria básica do MVP-01.
///
/// Mantida deliberadamente mínima: retângulos, pontos e insets em
/// coordenadas inteiras (pixels). Escala lógica/DPI fica para o roteiro
/// principal; neste MVP o layout é calculado em pixels físicos.
library;

/// Ponto em coordenadas inteiras.
final class Point {
  const Point(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Point($x, $y)';
}

/// Retângulo em coordenadas inteiras com `right`/`bottom` exclusivos.
final class Rect {
  const Rect(this.left, this.top, this.right, this.bottom)
      : assert(left <= right),
        assert(top <= bottom);

  const Rect.fromLTWH(int left, int top, int width, int height)
      : this(left, top, left + width, top + height);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;
  bool get isEmpty => width <= 0 || height <= 0;

  bool contains(int x, int y) =>
      x >= left && x < right && y >= top && y < bottom;

  /// Interseção com [other]; retorna um retângulo vazio se não há overlap.
  Rect intersect(Rect other) {
    final l = left > other.left ? left : other.left;
    final t = top > other.top ? top : other.top;
    final r = right < other.right ? right : other.right;
    final b = bottom < other.bottom ? bottom : other.bottom;
    if (l >= r || t >= b) return Rect(l, t, l, t);
    return Rect(l, t, r, b);
  }

  /// Maior retângulo que contém [this] e [other].
  Rect union(Rect other) {
    return Rect(
      left < other.left ? left : other.left,
      top < other.top ? top : other.top,
      right > other.right ? right : other.right,
      bottom > other.bottom ? bottom : other.bottom,
    );
  }

  /// Desloca o retângulo, arredondando para inteiros.
  Rect translate(int dx, int dy) =>
      Rect(left + dx, top + dy, right + dx, bottom + dy);

  bool containsRect(Rect other) =>
      other.left >= left &&
      other.top >= top &&
      other.right <= right &&
      other.bottom <= bottom;

  @override
  String toString() => 'Rect($left, $top, $right, $bottom) [${width}x$height]';
}

/// Margens internas (lado esquerdo, topo, lado direito, base).
final class Insets {
  const Insets.all(int value)
      : left = value,
        top = value,
        right = value,
        bottom = value;

  const Insets.symmetric({int horizontal = 0, int vertical = 0})
      : left = horizontal,
        right = horizontal,
        top = vertical,
        bottom = vertical;

  const Insets.only(
      {this.left = 0, this.top = 0, this.right = 0, this.bottom = 0});

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get horizontal => left + right;
  int get vertical => top + bottom;

  Rect deflate(Rect rect) => Rect(
        rect.left + left,
        rect.top + top,
        rect.right - right,
        rect.bottom - bottom,
      );
}
