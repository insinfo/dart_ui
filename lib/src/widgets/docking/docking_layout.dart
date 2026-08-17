/// Mutable, serializable-in-memory layout model for desktop docking surfaces.
library;

import '../../foundation/value_notifier.dart';
import '../widget.dart';

enum DockingAreaType { item, row, column, tabs }

enum DropPosition { left, right, top, bottom, center }

/// Marks areas that accept a dropped [DockingItem].
abstract interface class DropArea {}

abstract class DockingArea {
  DockingArea({
    this.id,
    this.size,
    this.weight,
    this.minimalWeight,
    this.minimalSize,
  });

  final Object? id;
  double? size;
  double? weight;
  double? minimalWeight;
  double? minimalSize;

  int _layoutId = -1;
  int _index = -1;
  DockingParentArea? _parent;

  int get layoutId => _layoutId;
  int get index => _index;
  DockingParentArea? get parent => _parent;
  bool get disposed => _layoutId == -1 && _index == -1;
  DockingAreaType get type;

  String get typeAcronym => switch (type) {
        DockingAreaType.item => 'I',
        DockingAreaType.row => 'R',
        DockingAreaType.column => 'C',
        DockingAreaType.tabs => 'T',
      };

  String get areaAcronym => typeAcronym;

  int get level {
    var result = 0;
    DockingParentArea? current = parent;
    while (current != null) {
      result++;
      current = current.parent;
    }
    return result;
  }

  String get path {
    var result = typeAcronym;
    DockingParentArea? current = parent;
    while (current != null) {
      result = '${current.typeAcronym}$result';
      current = current.parent;
    }
    return result;
  }

  String hierarchy({
    bool indexInfo = false,
    bool levelInfo = false,
    bool hasParentInfo = false,
    bool nameInfo = false,
  }) {
    var result = typeAcronym;
    if (indexInfo) result += index.toString();
    if (levelInfo) result += level.toString();
    if (hasParentInfo) result += parent == null ? 'F' : 'T';
    return result;
  }

  void _detach() {
    _layoutId = -1;
    _index = -1;
    _parent = null;
  }
}

abstract class DockingParentArea extends DockingArea {
  DockingParentArea(
    List<DockingArea> children, {
    super.id,
    super.size,
    super.weight,
    super.minimalWeight,
    super.minimalSize,
  }) : _children = List<DockingArea>.of(children) {
    if (_children.isEmpty) {
      throw ArgumentError.value(children, 'children', 'must not be empty');
    }
  }

  final List<DockingArea> _children;

  List<DockingArea> get children => List<DockingArea>.unmodifiable(_children);
  int get childrenCount => _children.length;
  DockingArea childAt(int index) => _children[index];
  int indexOf(DockingArea area) => _children.indexOf(area);
  bool contains(DockingArea area) => _children.contains(area);
  void forEach(void Function(DockingArea child) visitor) =>
      _children.forEach(visitor);
  void forEachReversed(void Function(DockingArea child) visitor) =>
      _children.reversed.forEach(visitor);

  @override
  String hierarchy({
    bool indexInfo = false,
    bool levelInfo = false,
    bool hasParentInfo = false,
    bool nameInfo = false,
  }) =>
      '${super.hierarchy(indexInfo: indexInfo, levelInfo: levelInfo, hasParentInfo: hasParentInfo)}'
      '(${_children.map((DockingArea child) => child.hierarchy(indexInfo: indexInfo, levelInfo: levelInfo, hasParentInfo: hasParentInfo, nameInfo: nameInfo)).join(',')})';
}

class DockingItem extends DockingArea implements DropArea {
  DockingItem({
    super.id,
    this.name,
    required this.widget,
    this.value,
    this.closable = true,
    this.maximizable,
    this.leading,
    bool maximized = false,
    super.size,
    super.weight,
    super.minimalWeight,
    super.minimalSize,
  }) : _maximized = maximized;

  String? name;
  Widget widget;
  Object? value;
  bool closable;
  bool? maximizable;
  Widget? leading;
  bool _maximized;

  bool get maximized => _maximized;

  @override
  DockingAreaType get type => DockingAreaType.item;

  @override
  String hierarchy({
    bool indexInfo = false,
    bool levelInfo = false,
    bool hasParentInfo = false,
    bool nameInfo = false,
  }) =>
      '${super.hierarchy(indexInfo: indexInfo, levelInfo: levelInfo, hasParentInfo: hasParentInfo)}'
      '${nameInfo ? name ?? '' : ''}';
}

class DockingRow extends DockingParentArea {
  factory DockingRow(
    List<DockingArea> children, {
    Object? id,
    double? size,
    double? weight,
    double? minimalWeight,
    double? minimalSize,
  }) {
    final flattened = <DockingArea>[];
    for (final child in children) {
      child is DockingRow
          ? flattened.addAll(child._children)
          : flattened.add(child);
    }
    if (flattened.length < 2) {
      throw ArgumentError.value(children, 'children', 'needs at least two');
    }
    return DockingRow._(
      flattened,
      id: id,
      size: size,
      weight: weight,
      minimalWeight: minimalWeight,
      minimalSize: minimalSize,
    );
  }

  DockingRow._(
    super.children, {
    super.id,
    super.size,
    super.weight,
    super.minimalWeight,
    super.minimalSize,
  });

  @override
  DockingAreaType get type => DockingAreaType.row;
}

class DockingColumn extends DockingParentArea {
  factory DockingColumn(
    List<DockingArea> children, {
    Object? id,
    double? size,
    double? weight,
    double? minimalWeight,
    double? minimalSize,
  }) {
    final flattened = <DockingArea>[];
    for (final child in children) {
      child is DockingColumn
          ? flattened.addAll(child._children)
          : flattened.add(child);
    }
    if (flattened.length < 2) {
      throw ArgumentError.value(children, 'children', 'needs at least two');
    }
    return DockingColumn._(
      flattened,
      id: id,
      size: size,
      weight: weight,
      minimalWeight: minimalWeight,
      minimalSize: minimalSize,
    );
  }

  DockingColumn._(
    super.children, {
    super.id,
    super.size,
    super.weight,
    super.minimalWeight,
    super.minimalSize,
  });

  @override
  DockingAreaType get type => DockingAreaType.column;
}

class DockingTabs extends DockingParentArea implements DropArea {
  // Keep the narrower List<DockingItem> public contract; a super parameter
  // would widen this to List<DockingArea> and permit invalid nested splits.
  // ignore: use_super_parameters
  DockingTabs(
    List<DockingItem> children, {
    super.id,
    bool maximized = false,
    this.maximizable,
    this.selectedIndex = 0,
    super.size,
    super.weight,
    super.minimalWeight,
    super.minimalSize,
  })  : _maximized = maximized,
        super(children);

  bool? maximizable;
  int selectedIndex;
  bool _maximized;

  bool get maximized => _maximized;

  @override
  DockingItem childAt(int index) => _children[index] as DockingItem;

  @override
  DockingAreaType get type => DockingAreaType.tabs;
}

/// Owns a docking tree and emits a revision whenever it changes.
class DockingLayout extends ValueNotifier<int> {
  DockingLayout({DockingArea? root})
      : _root = root,
        super(0) {
    _refreshHierarchy();
  }

  static int _nextId = 1;

  final int id = _nextId++;
  DockingArea? _root;
  DockingArea? _maximizedArea;

  DockingArea? get root => _root;
  DockingArea? get maximizedArea => _maximizedArea;

  set root(DockingArea? value) {
    for (final area in layoutAreas()) {
      area._detach();
    }
    _root = value;
    _maximizedArea = null;
    _changed();
  }

  void rebuild() => _changed();

  String hierarchy({
    bool indexInfo = false,
    bool levelInfo = false,
    bool hasParentInfo = false,
    bool nameInfo = false,
  }) =>
      _root?.hierarchy(
        indexInfo: indexInfo,
        levelInfo: levelInfo,
        hasParentInfo: hasParentInfo,
        nameInfo: nameInfo,
      ) ??
      '';

  List<DockingArea> layoutAreas() {
    final result = <DockingArea>[];
    void visit(DockingArea area) {
      result.add(area);
      if (area is DockingParentArea) {
        for (final child in area._children) {
          visit(child);
        }
      }
    }

    final currentRoot = _root;
    if (currentRoot != null) visit(currentRoot);
    return result;
  }

  DockingArea? findDockingArea(Object? id) {
    for (final area in layoutAreas()) {
      if (area.id == id) return area;
    }
    return null;
  }

  DockingItem? findDockingItem(Object? id) {
    final area = findDockingArea(id);
    return area is DockingItem ? area : null;
  }

  DockingTabs? findDockingTabsWithItem(Object? itemId) {
    final parent = findDockingItem(itemId)?.parent;
    return parent is DockingTabs ? parent : null;
  }

  void selectItem(DockingItem item) {
    _requireMember(item);
    final parent = item.parent;
    if (parent is DockingTabs) parent.selectedIndex = parent.indexOf(item);
    _changed(refresh: false);
  }

  void maximizeDockingItem(DockingItem dockingItem) {
    _requireMember(dockingItem);
    _clearMaximized();
    dockingItem._maximized = true;
    _maximizedArea = dockingItem;
    _changed(refresh: false);
  }

  void maximizeDockingTabs(DockingTabs dockingTabs) {
    _requireMember(dockingTabs);
    _clearMaximized();
    dockingTabs._maximized = true;
    _maximizedArea = dockingTabs;
    _changed(refresh: false);
  }

  void restore() {
    _clearMaximized();
    _changed(refresh: false);
  }

  void removeItem({required DockingItem item}) {
    _requireMember(item);
    _remove(item);
    _maximizedArea = null;
    _changed();
  }

  void removeItemByIds(List<Object?> ids) {
    for (final id in ids) {
      final item = findDockingItem(id);
      if (item != null) _remove(item);
    }
    _maximizedArea = null;
    _changed();
  }

  void addItemOn({
    required DockingItem newItem,
    required DropArea targetArea,
    DropPosition? dropPosition,
    int? dropIndex,
  }) {
    final target = targetArea as DockingArea;
    _requireMember(target);
    if (newItem.layoutId == id) {
      throw ArgumentError.value(
          newItem, 'newItem', 'already belongs to layout');
    }
    _insert(newItem, target, dropPosition ?? DropPosition.center, dropIndex);
    _changed();
  }

  void addItemOnRoot({
    required DockingItem newItem,
    DropPosition? dropPosition,
    int? dropIndex,
  }) {
    final target = _root;
    if (target == null) {
      _root = newItem;
      _changed();
      return;
    }
    if (target is! DropArea) {
      throw StateError('Root is not a DropArea');
    }
    addItemOn(
      newItem: newItem,
      targetArea: target as DropArea,
      dropPosition: dropPosition,
      dropIndex: dropIndex,
    );
  }

  void moveItem({
    required DockingItem draggedItem,
    required DropArea targetArea,
    DropPosition? dropPosition,
    int? dropIndex,
  }) {
    final target = targetArea as DockingArea;
    _requireMember(draggedItem);
    _requireMember(target);
    if (identical(draggedItem, target)) return;
    _remove(draggedItem);
    _refreshHierarchy();
    if (target.layoutId != id) {
      throw StateError('The move removed its own target area');
    }
    _insert(
      draggedItem,
      target,
      dropPosition ?? DropPosition.center,
      dropIndex,
    );
    _maximizedArea = null;
    _changed();
  }

  void _insert(
    DockingItem item,
    DockingArea target,
    DropPosition position,
    int? dropIndex,
  ) {
    if (position == DropPosition.center) {
      final tabs = target is DockingTabs
          ? target
          : target.parent is DockingTabs
              ? target.parent! as DockingTabs
              : null;
      if (tabs != null) {
        final index = (dropIndex ?? tabs._children.length)
            .clamp(0, tabs._children.length);
        tabs._children.insert(index, item);
        tabs.selectedIndex = index;
        return;
      }
      _replace(target, DockingTabs(<DockingItem>[target as DockingItem, item]));
      return;
    }

    // A side drop beside a tab means beside the whole tab group. Nesting a
    // row or column inside DockingTabs would violate its item-only contract.
    if (target.parent is DockingTabs) target = target.parent!;

    final horizontal =
        position == DropPosition.left || position == DropPosition.right;
    final before =
        position == DropPosition.left || position == DropPosition.top;
    final parent = target.parent;
    final matchingParent =
        horizontal ? parent is DockingRow : parent is DockingColumn;
    if (matchingParent) {
      final index = parent!.indexOf(target) + (before ? 0 : 1);
      parent._children.insert(index, item);
      return;
    }
    final children =
        before ? <DockingArea>[item, target] : <DockingArea>[target, item];
    _replace(
        target, horizontal ? DockingRow(children) : DockingColumn(children));
  }

  void _remove(DockingItem item) {
    final parent = item.parent;
    if (parent == null) {
      _root = null;
      item._detach();
      return;
    }
    parent._children.remove(item);
    item._detach();
    _collapse(parent);
  }

  void _collapse(DockingParentArea area) {
    if (area._children.length > 1) return;
    if (area._children.isEmpty) {
      final parent = area.parent;
      if (parent == null) {
        _root = null;
      } else {
        parent._children.remove(area);
        area._detach();
        _collapse(parent);
      }
      return;
    }
    final only = area._children.single;
    _replace(area, only);
    area._detach();
  }

  void _replace(DockingArea oldArea, DockingArea newArea) {
    final parent = oldArea.parent;
    if (parent == null) {
      _root = newArea;
      return;
    }
    final index = parent.indexOf(oldArea);
    if (index < 0) throw StateError('Area is not attached to its parent');
    parent._children[index] = newArea;
  }

  void _clearMaximized() {
    for (final area in layoutAreas()) {
      if (area is DockingItem) area._maximized = false;
      if (area is DockingTabs) area._maximized = false;
    }
    _maximizedArea = null;
  }

  void _requireMember(DockingArea area) {
    if (area.layoutId != id) {
      throw ArgumentError.value(area, 'area', 'does not belong to this layout');
    }
  }

  void _refreshHierarchy() {
    var nextIndex = 1;
    final seen = <DockingArea>{};
    _maximizedArea = null;
    void visit(DockingArea area, DockingParentArea? parent) {
      if (!seen.add(area)) throw StateError('A docking area appears twice');
      area
        .._parent = parent
        .._layoutId = id
        .._index = nextIndex++;
      if (area is DockingItem && area.maximized ||
          area is DockingTabs && area.maximized) {
        if (_maximizedArea != null) {
          throw StateError('Multiple maximized areas');
        }
        _maximizedArea = area;
      }
      if (area is DockingParentArea) {
        for (final child in area._children) {
          visit(child, area);
        }
        if (area is DockingTabs) {
          area.selectedIndex =
              area.selectedIndex.clamp(0, area.childrenCount - 1);
        }
      }
    }

    final currentRoot = _root;
    if (currentRoot != null) visit(currentRoot, null);
  }

  void _changed({bool refresh = true}) {
    if (refresh) _refreshHierarchy();
    value = value + 1;
  }
}
