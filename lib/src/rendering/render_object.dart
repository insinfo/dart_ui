/// Compatibility name for the production render-tree node.
///
/// Widgets used to depend on a second, skeletal `RenderObject` hierarchy in
/// this directory. There is now exactly one render tree: [RenderBox], owned by
/// `layout/` and driven by `PipelineOwner`.
library;

import '../layout/render_box.dart';

typedef RenderObject = RenderBox;
