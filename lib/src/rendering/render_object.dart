library;

import '../geometry/offset.dart';
import '../geometry/size.dart';

abstract class RenderObject {
  RenderObject? parent;

  void attach(RenderObject? parent) {
    this.parent = parent;
  }

  void detach() {
    parent = null;
  }

  void layout(Size constraints);
  void paint(Offset offset);
}
