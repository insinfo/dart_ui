/// A [TextField] that is a [FormField] - Flutter's `TextFormField`.
///
/// The field's text is the form field's value: typing calls
/// [FormFieldState.didChange], the validator's message is shown as the
/// decoration's error text, [FormFieldState.reset] puts the text back to
/// [FormField.initialValue], and [FormState.save] hands the text to
/// [FormField.onSaved].
///
/// What differs from Flutter is what differs for [TextField] - see its class
/// comment - and for [FormField]: no state restoration.
library;

import 'focus.dart';
import 'form.dart';
import 'text_field.dart';

/// A text field inside a [Form]; see the library comment.
class TextFormField extends FormField<String> {
  /// Takes [TextField]'s parameters - the ones a form field has in Flutter
  /// - and [FormField]'s. [controller] and [initialValue] cannot both be
  /// given: the controller's text is the initial value.
  TextFormField({
    super.key,
    this.controller,
    String? initialValue,
    FocusNode? focusNode,
    InputDecoration? decoration = const InputDecoration(),
    TextInputType? keyboardType,
    TextCapitalization textCapitalization = TextCapitalization.none,
    TextInputAction? textInputAction,
    bool autofocus = false,
    bool readOnly = false,
    bool obscureText = false,
    int? maxLines = 1,
    int? minLines,
    int? maxLength,
    MaxLengthEnforcement? maxLengthEnforcement,
    void Function(String value)? onChanged,
    void Function()? onEditingComplete,
    void Function(String value)? onFieldSubmitted,
    super.onSaved,
    super.validator,
    super.errorBuilder,
    List<TextInputFormatter>? inputFormatters,
    bool? enabled,
    AutovalidateMode? autovalidateMode,
    super.restorationId,
    super.forceErrorText,
  }) : super(
          initialValue: _initialValue(controller, initialValue),
          enabled: enabled ?? decoration?.enabled ?? true,
          autovalidateMode: autovalidateMode ?? AutovalidateMode.disabled,
          builder: (FormFieldState<String> field) {
            final _TextFormFieldState state = field as _TextFormFieldState;
            InputDecoration? effective = decoration;
            final String? error = field.errorText;
            if (effective != null && error != null) {
              final FormFieldErrorBuilder? errorBuilder =
                  state.widget.errorBuilder;
              effective = errorBuilder != null
                  ? effective.copyWith(
                      error: errorBuilder(state.context, error),
                    )
                  : effective.copyWith(errorText: error);
            }
            void onChangedHandler(String value) {
              field.didChange(value);
              onChanged?.call(value);
            }

            return TextField(
              controller: state._effectiveController,
              focusNode: focusNode,
              decoration: effective,
              keyboardType: keyboardType,
              textInputAction: textInputAction,
              textCapitalization: textCapitalization,
              autofocus: autofocus,
              readOnly: readOnly,
              obscureText: obscureText,
              maxLines: maxLines,
              minLines: minLines,
              maxLength: maxLength,
              maxLengthEnforcement: maxLengthEnforcement,
              onChanged: onChangedHandler,
              onEditingComplete: onEditingComplete,
              onSubmitted: onFieldSubmitted,
              inputFormatters: inputFormatters,
              enabled: enabled ?? decoration?.enabled ?? true,
            );
          },
        );

  /// Controls the text. Null: the field keeps its own, starting from
  /// [FormField.initialValue].
  final TextEditingController? controller;

  static String _initialValue(
    TextEditingController? controller,
    String? initialValue,
  ) {
    if (controller != null && initialValue != null) {
      throw ArgumentError(
        'TextFormField takes a controller or an initialValue, not both: the '
        "controller's text is the initial value",
      );
    }
    return controller?.text ?? initialValue ?? '';
  }

  @override
  FormFieldState<String> createState() => _TextFormFieldState();
}

final class _TextFormFieldState extends FormFieldState<String> {
  TextEditingController? _ownController;

  TextFormField get _field => widget as TextFormField;

  TextEditingController get _effectiveController =>
      _field.controller ?? _ownController!;

  @override
  void initState() {
    super.initState();
    if (_field.controller == null) {
      _ownController = TextEditingController(widget.initialValue ?? '');
    }
    _effectiveController.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(FormField<String> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final TextEditingController? before =
        (oldWidget as TextFormField).controller;
    final TextEditingController? after = _field.controller;
    if (identical(before, after)) return;
    (before ?? _ownController)?.removeListener(_handleControllerChanged);
    if (before != null && after == null) {
      _ownController = TextEditingController(before.text);
    }
    if (after != null) {
      setValue(after.text);
      if (before == null) _ownController = null;
    }
    _effectiveController.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    _effectiveController.removeListener(_handleControllerChanged);
    super.dispose();
  }

  @override
  void didChange(String? value) {
    super.didChange(value);
    if (_effectiveController.text != value) {
      _effectiveController.text = value ?? '';
    }
  }

  @override
  void reset() {
    // The controller first, so the listener below finds the value already
    // where it is going and reports nothing.
    _effectiveController.editingValue =
        TextEditingValue(text: widget.initialValue ?? '');
    super.reset();
  }

  /// A change made through the controller - by the program, or by the field
  /// before its `onChanged` - is a change of the form field's value.
  void _handleControllerChanged(String text) {
    if (text != value) didChange(text);
  }
}
