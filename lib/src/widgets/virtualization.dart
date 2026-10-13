/// Which items exist, given a scroll offset.
///
/// The planner itself is `layout/list_virtualization.dart`: a sliver list
/// decides its window during layout, and the layout layer may not import a
/// widget, so the arithmetic moved down a layer when slivers arrived. This
/// file keeps the old import path working for the lists that decide their
/// window during build - `ListView`, `ListBox`, `TreeView`, `DataGrid`.
library;

export '../layout/list_virtualization.dart';
