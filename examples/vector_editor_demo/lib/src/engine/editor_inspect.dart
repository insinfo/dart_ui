/// The editor described as data, for an automation client's
/// `document.inspect` and `ui.inspect`.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';

/// The open tabs, the active one's page with its layers and objects, the
/// selection and the history.
///
/// An object is named by its index in its layer, bottom first - the index
/// `selection.select` takes.
Map<String, Object?> inspectDocument(EditorModel model) {
  if (!model.hasDocument) {
    return <String, Object?>{'documents': const <Object?>[]};
  }
  final DocumentSession session = model.active;
  final Set<SelectableObject> selected =
      session.selection.selectedObjects.toSet();
  return <String, Object?>{
    'documents': <Object?>[
      for (final DocumentSession document in model.documents)
        <String, Object?>{
          'name': document.name,
          'path': document.filePath,
          'modified': document.modified,
        },
    ],
    'active': model.activeIndex,
    'page': _rect(session.page.rect),
    'activeLayer': session.layers.indexOf(session.layer),
    'layers': <Object?>[
      for (final VectorLayer layer in session.layers)
        <String, Object?>{
          'name': layer.name,
          'visible': layer.isVisible,
          'locked': !layer.isEditable,
          'objects': <Object?>[
            for (final SelectableObject object
                in layer.children.whereType<SelectableObject>())
              _object(object, selected.contains(object)),
          ],
        },
    ],
    'selected': selected.length,
    'undo': session.api.undoDescription,
    'redo': session.api.redoDescription,
  };
}

/// What the window shows besides the document: tool, zoom, units.
Map<String, Object?> inspectEditor(EditorModel model) => <String, Object?>{
      'tool': model.tool.name,
      'units': model.units.name,
      'status': model.status,
      if (model.hasDocument) ...<String, Object?>{
        'zoom': model.active.zoom,
        'pan': <double>[model.active.pan.dx, model.active.pan.dy],
      },
    };

Map<String, Object?> _object(SelectableObject object, bool selected) {
  final VectorStyle style = object.style;
  return <String, Object?>{
    'type': switch (object) {
      VectorRectangle() => 'rectangle',
      VectorCircle() => 'ellipse',
      VectorPolygon() => 'polygon',
      VectorCurve() => 'curve',
      VectorText() => 'text',
      VectorGroup() => 'group',
      _ => object.className,
    },
    'bounds': _rect(object.cacheBbox),
    if (selected) 'selected': true,
    'fill': style.fill.isNone ? null : _hex(style.fill.color),
    'outline': style.stroke.isNone || style.stroke.width <= 0
        ? null
        : <String, Object?>{
            'color': _hex(style.stroke.color),
            'width': style.stroke.width,
          },
    if (object is VectorText) 'text': object.textContent,
    if (object is VectorGroup)
      'children': object.children.whereType<SelectableObject>().length,
  };
}

List<double> _rect(Rect rect) => <double>[
      _round(rect.left),
      _round(rect.top),
      _round(rect.width),
      _round(rect.height),
    ];

double _round(double value) => (value * 100).roundToDouble() / 100;

String _hex(Color color) =>
    '#${(color.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
