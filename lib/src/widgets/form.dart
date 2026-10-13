/// Forms: a group of fields validated, saved and reset together - Flutter's
/// `Form`, `FormState`, `FormField`, `FormFieldState` and `AutovalidateMode`.
///
/// The shape is Flutter's, and so is the protocol. A [FormField] registers
/// its [FormFieldState] with the nearest [Form] when it builds; the form's
/// [FormState] - reached through a `GlobalKey<FormState>` or [Form.of] -
/// validates, saves or resets every registered field. A field that changes
/// tells the form, which calls [Form.onChanged] and rebuilds every field, so
/// fields that depend on each other ("confirm password") re-validate.
///
/// ## What differs from Flutter
///
///  * **No state restoration.** [FormField.restorationId] is accepted and
///    ignored: the framework has no restoration buckets. An error message
///    does not survive the application being killed and relaunched.
///  * **No announcement.** Flutter's [FormState.validate] asks the platform's
///    screen reader to read the first error aloud; here the error is a
///    visible text in the field's decoration, which the semantics tree
///    carries, and nothing is announced.
///  * **[Form.onPopInvokedWithResult] always receives a null result**: the
///    route's [PopScope] reports only whether the pop happened.
library;

import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'routes.dart' show PopScope;
import 'widget.dart';

/// When a form or a field validates by itself, without [FormState.validate]
/// being called.
enum AutovalidateMode {
  /// Never.
  disabled,

  /// On every build, from the first.
  always,

  /// After the user has changed the field - or, for a form, any field.
  onUserInteraction,

  /// When focus leaves the field.
  onUnfocus,

  /// After the user has changed the field, while it shows an error: the
  /// error clears as soon as the input is fixed, and does not appear before
  /// the first explicit validation.
  onUserInteractionIfError,
}

/// Checks a field's value: the error to show, or null when it is valid.
typedef FormFieldValidator<T> = String? Function(T? value);

/// Builds the error a field shows in place of its error text.
typedef FormFieldErrorBuilder = Widget Function(
  BuildContext context,
  String errorText,
);

/// Receives a field's value when the form is saved.
typedef FormFieldSetter<T> = void Function(T? newValue);

/// Builds a field from its state.
typedef FormFieldBuilder<T> = Widget Function(FormFieldState<T> field);

/// Groups the [FormField]s below it, so they can be validated, saved and
/// reset together through its [FormState].
class Form extends StatefulWidget {
  const Form({
    super.key,
    required this.child,
    this.canPop,
    this.onPopInvoked,
    this.onPopInvokedWithResult,
    this.onChanged,
    AutovalidateMode? autovalidateMode,
  }) : autovalidateMode = autovalidateMode ?? AutovalidateMode.disabled;

  /// The state of the closest enclosing form, or null.
  ///
  /// Makes [context] depend on the form, so it rebuilds whenever a field
  /// changes.
  static FormState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FormScope>()?._formState;

  /// The state of the closest enclosing form.
  ///
  /// Throws [StateError] when there is none, where Flutter asserts.
  static FormState of(BuildContext context) {
    final FormState? form = maybeOf(context);
    if (form == null) {
      throw StateError(
        'Form.of() was called with a context that does not contain a Form; '
        'wrap the fields in a Form, or use Form.maybeOf()',
      );
    }
    return form;
  }

  /// The fields, somewhere below.
  final Widget child;

  /// Whether the enclosing route may be popped - false keeps a form with
  /// unsaved changes on screen. Null leaves popping alone.
  final bool? canPop;

  /// Called after a pop of the enclosing route is attempted, with whether it
  /// happened. Flutter's deprecated spelling of [onPopInvokedWithResult].
  final void Function(bool didPop)? onPopInvoked;

  /// Called after a pop of the enclosing route is attempted, with whether it
  /// happened; the result is always null here.
  final void Function(bool didPop, Object? result)? onPopInvokedWithResult;

  /// Called when any field changes.
  final void Function()? onChanged;

  /// When the fields validate by themselves; see [AutovalidateMode].
  final AutovalidateMode autovalidateMode;

  @override
  FormState createState() => FormState();
}

/// The state of a [Form]: the registered fields, and what to do with them.
class FormState extends State<Form> {
  int _generation = 0;
  bool _hasInteractedByUser = false;
  final Set<FormFieldState<dynamic>> _fields = <FormFieldState<dynamic>>{};

  /// The fields registered with this form.
  Iterable<FormFieldState<dynamic>> get fields => _fields;

  /// A field changed: tell [Form.onChanged], and rebuild every field so the
  /// ones that depend on each other re-validate.
  void _fieldDidChange() {
    widget.onChanged?.call();
    _hasInteractedByUser =
        _fields.any((FormFieldState<dynamic> field) => field._interacted);
    _forceRebuild();
  }

  void _forceRebuild() {
    if (!mounted) return;
    setState(() => ++_generation);
  }

  void _register(FormFieldState<dynamic> field) => _fields.add(field);

  void _unregister(FormFieldState<dynamic> field) => _fields.remove(field);

  @override
  Widget build(BuildContext context) {
    final bool hasError =
        _fields.any((FormFieldState<dynamic> field) => field.hasError);
    switch (widget.autovalidateMode) {
      case AutovalidateMode.always:
        _validate();
      case AutovalidateMode.onUserInteraction:
        if (_hasInteractedByUser) _validate();
      case AutovalidateMode.onUserInteractionIfError:
        if (_hasInteractedByUser && hasError) _validate();
      case AutovalidateMode.onUnfocus:
      case AutovalidateMode.disabled:
        break;
    }
    final Widget scope = _FormScope(
        formState: this, generation: _generation, child: widget.child);
    final void Function(bool, Object?)? withResult =
        widget.onPopInvokedWithResult;
    final void Function(bool)? plain = widget.onPopInvoked;
    if (widget.canPop == null && withResult == null && plain == null) {
      return scope;
    }
    return PopScope(
      canPop: widget.canPop ?? true,
      onPopInvoked: (bool didPop) {
        if (withResult != null) {
          withResult(didPop, null);
        } else {
          plain?.call(didPop);
        }
      },
      child: scope,
    );
  }

  /// Calls every field's [FormField.onSaved].
  void save() {
    for (final FormFieldState<dynamic> field in _fields.toList()) {
      field.save();
    }
  }

  /// Puts every field back to its [FormField.initialValue] and clears the
  /// errors.
  void reset() {
    for (final FormFieldState<dynamic> field in _fields.toList()) {
      field.reset();
    }
    _hasInteractedByUser = false;
    _fieldDidChange();
  }

  /// Clears every field's error without validating.
  void clearError() {
    for (final FormFieldState<dynamic> field in _fields.toList()) {
      field._clearErrorInternal();
    }
    _fieldDidChange();
  }

  /// Validates every field; true when all of them are valid. The errors
  /// show from now on, and a form with
  /// [AutovalidateMode.onUserInteraction] keeps re-validating.
  bool validate() {
    _hasInteractedByUser = true;
    _forceRebuild();
    return _validate();
  }

  /// Validates every field, and returns the ones that are not valid.
  Set<FormFieldState<Object?>> validateGranularly() {
    final Set<FormFieldState<Object?>> invalid = <FormFieldState<Object?>>{};
    _hasInteractedByUser = true;
    _forceRebuild();
    _validate(invalid);
    return invalid;
  }

  bool _validate([Set<FormFieldState<Object?>>? invalid]) {
    bool hasError = false;
    for (final FormFieldState<dynamic> field in _fields.toList()) {
      final bool valid = field.validate();
      hasError |= !valid;
      if (!valid) invalid?.add(field);
    }
    return !hasError;
  }
}

final class _FormScope extends InheritedWidget {
  const _FormScope({
    required super.child,
    required FormState formState,
    required int generation,
  })  : _formState = formState,
        _generation = generation;

  final FormState _formState;

  /// Bumped on every change, so every field below rebuilds.
  final int _generation;

  @override
  bool updateShouldNotify(_FormScope oldWidget) =>
      _generation != oldWidget._generation;
}

/// One field of a [Form]: a value, a validator, and the error it produced.
///
/// [builder] draws the field from its [FormFieldState]; the state is what a
/// control reports changes to ([FormFieldState.didChange]) and what the
/// form validates, saves and resets.
class FormField<T> extends StatefulWidget {
  const FormField({
    super.key,
    required this.builder,
    this.onSaved,
    this.onReset,
    this.forceErrorText,
    this.validator,
    this.errorBuilder,
    this.initialValue,
    this.enabled = true,
    AutovalidateMode? autovalidateMode,
    this.restorationId,
  }) : autovalidateMode = autovalidateMode ?? AutovalidateMode.disabled;

  /// Called by [FormState.save] with the current value.
  final FormFieldSetter<T>? onSaved;

  /// Called after [FormFieldState.reset].
  final void Function()? onReset;

  /// An error shown whatever the validator says - from a server, say.
  /// Validation is skipped while it is set.
  final String? forceErrorText;

  /// The error for a value, or null when it is valid.
  final FormFieldValidator<T>? validator;

  /// Builds the error shown under the field, in place of the plain text.
  final FormFieldErrorBuilder? errorBuilder;

  /// Draws the field from its state.
  final FormFieldBuilder<T> builder;

  /// The value the field starts with, and returns to on reset.
  final T? initialValue;

  /// Whether the field takes input and validates by itself. A disabled field
  /// is still validated by [FormState.validate], as in Flutter.
  final bool enabled;

  /// When the field validates by itself.
  final AutovalidateMode autovalidateMode;

  /// Accepted for Flutter's signature; there is no state restoration.
  final String? restorationId;

  @override
  FormFieldState<T> createState() => FormFieldState<T>();
}

/// The state of a [FormField]: its value, its error, and whether the user
/// has changed it.
class FormFieldState<T> extends State<FormField<T>> {
  late T? _value = widget.initialValue;
  late String? _errorText = widget.forceErrorText;
  bool _interacted = false;

  /// The form this field registered with in its last build.
  FormState? _form;

  /// The scope that tells whether focus is inside the field, for
  /// [AutovalidateMode.onUnfocus].
  FocusScopeNode? _focusScope;
  FocusManager? _focusManager;
  bool _focusWasInside = false;

  /// The current value.
  T? get value => _value;

  /// The error the last validation produced, or null.
  String? get errorText => _errorText;

  /// Whether there is an error to show.
  bool get hasError => _errorText != null;

  /// Whether the user has changed the field since it was built or reset.
  bool get hasInteractedByUser => _interacted;

  /// Whether the value passes the validator, without showing anything.
  bool get isValid =>
      widget.forceErrorText == null && widget.validator?.call(_value) == null;

  /// Calls [FormField.onSaved] with the value.
  void save() => widget.onSaved?.call(value);

  /// Back to [FormField.initialValue], with no error.
  void reset() {
    setState(() {
      _value = widget.initialValue;
      _clearErrorInternal();
    });
    widget.onReset?.call();
    _form?._fieldDidChange();
  }

  /// Clears the error without validating.
  void clearError() {
    setState(_clearErrorInternal);
    _form?._fieldDidChange();
  }

  /// Runs the validator and shows its answer; true when the value is valid.
  bool validate() {
    setState(_validate);
    return !hasError;
  }

  void _clearErrorInternal() {
    _errorText = null;
    _interacted = false;
  }

  void _validate() {
    final String? forced = widget.forceErrorText;
    if (forced != null) {
      _errorText = forced;
      return;
    }
    _errorText = widget.validator?.call(_value);
  }

  /// The user changed the value: record it, and tell the form.
  void didChange(T? value) {
    setState(() {
      _value = value;
      _interacted = true;
    });
    _form?._fieldDidChange();
  }

  /// Changes the value without rebuilding or telling the form - for a
  /// subclass that keeps the value in step with a controller.
  void setValue(T? value) => _value = value;

  @override
  void didUpdateWidget(FormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.forceErrorText != oldWidget.forceErrorText) {
      _errorText = widget.forceErrorText;
    }
  }

  @override
  void dispose() {
    _form?._unregister(this);
    _form = null;
    _focusManager?.removeListener(_onPrimaryFocusChanged);
    _focusManager = null;
    super.dispose();
  }

  void _onPrimaryFocusChanged(FocusNode? node) {
    final FocusScopeNode? scope = _focusScope;
    if (scope == null || !mounted) return;
    final bool inside = scope.hasFocus;
    if (_focusWasInside && !inside) setState(_validate);
    _focusWasInside = inside;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.enabled) {
      switch (widget.autovalidateMode) {
        case AutovalidateMode.always:
          _validate();
        case AutovalidateMode.onUserInteraction:
          if (_interacted) _validate();
        case AutovalidateMode.onUserInteractionIfError:
          if (_interacted && hasError) _validate();
        case AutovalidateMode.onUnfocus:
        case AutovalidateMode.disabled:
          break;
      }
    }

    final FormState? form = Form.maybeOf(context);
    if (!identical(form, _form)) {
      _form?._unregister(this);
      _form = form;
      // Flutter validates a field that joins an always-validating form
      // after its first frame; here the form has already built, so the
      // field does it now.
      if (form != null &&
          form.widget.autovalidateMode == AutovalidateMode.always &&
          widget.enabled &&
          !hasError &&
          !isValid) {
        _validate();
      }
    }
    form?._register(this);

    final Widget child = widget.builder(this);
    final bool onUnfocus =
        (form?.widget.autovalidateMode == AutovalidateMode.onUnfocus &&
                widget.autovalidateMode != AutovalidateMode.always) ||
            widget.autovalidateMode == AutovalidateMode.onUnfocus;
    if (!onUnfocus) return child;

    // Validation when focus leaves the field: a scope round the field's
    // controls says whether focus is inside, and the window's focus manager
    // says when that may have changed.
    final FocusScopeNode scope = _focusScope ??= FocusScopeNode(
      debugLabel: 'FormField',
    );
    final BuildContext element = context;
    final FocusManager? manager =
        element is Element ? element.owner?.focusManager : null;
    if (!identical(manager, _focusManager)) {
      _focusManager?.removeListener(_onPrimaryFocusChanged);
      manager?.addListener(_onPrimaryFocusChanged);
      _focusManager = manager;
    }
    return FocusScope(node: scope, child: child);
  }
}
