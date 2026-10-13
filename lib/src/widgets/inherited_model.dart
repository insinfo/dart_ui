/// `InheritedModel`: an inherited widget whose dependents subscribe to
/// *aspects* of it and rebuild only when an aspect they asked for changed.
library;

import 'element.dart';
import 'widget.dart';

/// Flutter's `InheritedModel<T>`: [T] is the aspect type.
///
/// A dependent registers with [inheritFrom] and an aspect; when the model is
/// replaced and [updateShouldNotify] answers true, each dependent is rebuilt
/// only if [updateShouldNotifyDependent] says one of *its* aspects changed. A
/// dependent registered without an aspect (including one that used
/// `dependOnInheritedWidgetOfExactType`) depends on everything and is always
/// rebuilt.
///
/// ```dart
/// class Prefs extends InheritedModel<String> {
///   ...
///   @override
///   bool updateShouldNotifyDependent(Prefs old, Set<String> aspects) =>
///       (aspects.contains('theme') && theme != old.theme) ||
///       (aspects.contains('locale') && locale != old.locale);
///
///   static String themeOf(BuildContext context) =>
///       InheritedModel.inheritFrom<Prefs>(context, aspect: 'theme')!.theme;
/// }
/// ```
abstract class InheritedModel<T> extends InheritedWidget {
  const InheritedModel({super.key, required super.child});

  @override
  InheritedModelElement<T> createElement() => InheritedModelElement<T>(this);

  /// Whether a dependent of [aspects] must rebuild given the change from
  /// [oldWidget]. Asked only after [updateShouldNotify] answered true.
  bool updateShouldNotifyDependent(
    covariant InheritedModel<T> oldWidget,
    Set<T> dependencies,
  );

  /// Whether this model handles [aspect]. A model that does not is skipped by
  /// [inheritFrom], which then looks further up for one of the same type that
  /// does - how nested models split one aspect space between them.
  bool isSupportedAspect(Object aspect) => true;

  /// The nearest [M] that supports [aspect], registering [context] as its
  /// dependent for that aspect; with a null [aspect], an ordinary dependency
  /// on the nearest [M].
  ///
  /// Models of the same type skipped on the way (because they do not support
  /// [aspect]) are depended on too, as in Flutter, so the dependent still
  /// hears about a nearer model starting to support it.
  static M? inheritFrom<M extends InheritedModel<Object>>(
    BuildContext context, {
    Object? aspect,
  }) {
    if (aspect == null) return context.dependOnInheritedWidgetOfExactType<M>();
    final List<InheritedElement> models = <InheritedElement>[];
    InheritedElement? model =
        context.getElementForInheritedWidgetOfExactType<M>();
    while (model != null) {
      models.add(model);
      if ((model.widget as M).isSupportedAspect(aspect)) break;
      model = model.parent?.getElementForInheritedWidgetOfExactType<M>();
    }
    if (models.isEmpty) return null;
    final InheritedElement last = models.last;
    for (final InheritedElement element in models) {
      context.dependOnInheritedElement(element, aspect: aspect);
    }
    final M found = last.widget as M;
    return found.isSupportedAspect(aspect) ? found : null;
  }
}

/// The element of an [InheritedModel]: keeps each dependent's aspects.
class InheritedModelElement<T> extends InheritedElement {
  InheritedModelElement(InheritedModel<T> super.widget);

  /// Aspects per dependent; null means "every aspect".
  final Map<Element, Set<T>?> _aspects = <Element, Set<T>?>{};

  @override
  InheritedModel<T> get widget => super.widget as InheritedModel<T>;

  @override
  void updateDependencies(Element dependent, Object? aspect) {
    if (_aspects.containsKey(dependent) && _aspects[dependent] == null) {
      return; // Already depends on everything.
    }
    if (aspect == null) {
      _aspects[dependent] = null;
      return;
    }
    (_aspects[dependent] ??= <T>{}).add(aspect as T);
  }

  @override
  void notifyDependent(InheritedModel<T> oldWidget, Element dependent) {
    // Entries of elements that have since unmounted are dropped here rather
    // than tracked on unmount: the base class already forgets them, and this
    // is the one place the map is read.
    _aspects.removeWhere((Element element, _) => !element.mounted);
    final Set<T>? aspects = _aspects[dependent];
    if (!_aspects.containsKey(dependent) || aspects == null) {
      dependent.markNeedsBuild();
      return;
    }
    if (widget.updateShouldNotifyDependent(oldWidget, aspects)) {
      dependent.markNeedsBuild();
    }
  }
}
