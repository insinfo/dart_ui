/// Text the user can select and copy but not edit - Flutter's
/// `SelectableText`.
///
/// Drawn by an ordinary [Text] - so it wraps, takes a [TextStyle] and
/// [Text.rich] spans exactly as a `Text` does - with selection on top:
///
///  * **Mouse.** Press and drag selects; Shift+click extends; a double click
///    selects a word (UAX #29) and a triple click everything.
///  * **Keyboard.** Once focused (clicking focuses it), Shift with the arrows,
///    Home and End extends the selection - Ctrl (Option on a Mac) by word -
///    Ctrl+A (Cmd+A) selects all and Ctrl+C (Cmd+C), or Ctrl+Insert, copies.
///  * **Context menu.** A secondary click, the Menu key or Shift+F10 opens
///    Copy and Select all, when a `ContextMenuScope` is installed.
///
/// ## What differs from Flutter
///
///  * **No `SelectionArea`.** Flutter's selection across several widgets
///    needs a registrar every text render object takes part in, which this
///    framework's [RenderText] does not have yet; each [SelectableText]
///    selects within itself only.
///  * **No handles or toolbar for touch**, and no drag-to-scroll: a desktop
///    selection.
///  * **[showCursor] draws a caret but the arrows move the selection's
///    moving end only with Shift** - without it they collapse the selection,
///    as a read-only text field's do.
library;

import 'dart:async';

import '../foundation/diagnostics.dart' show UnsupportedCapabilityError;
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/render_box.dart';
import '../layout/render_proxy_box.dart';
import '../platform/clipboard.dart';
import '../platform/editing_convention.dart';
import '../platform/input_events.dart';
import '../platform/native_window.dart' show SystemCursor;
import '../semantics/semantics.dart';
import '../text/paragraph.dart' as paragraph;
import 'basic.dart';
import 'context_menu.dart';
import 'control.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'menu.dart';
import 'pointer_router.dart' show MouseCursorTarget;
import 'text_editing.dart';
import 'text_field.dart' show ClipboardScope;
import 'text_span.dart';
import 'theme.dart';
import 'widget.dart';

/// What made a selection change - Flutter's `SelectionChangedCause`.
enum SelectionChangedCause {
  tap,
  doubleTap,
  longPress,
  forcePress,
  keyboard,
  toolbar,
  drag,
  stylusHandwriting,
}

/// Selectable, copyable, read-only text; see the library comment.
class SelectableText extends StatefulWidget {
  /// A plain string.
  const SelectableText(
    String this.data, {
    super.key,
    this.focusNode,
    this.style,
    this.textAlign,
    this.showCursor = false,
    this.autofocus = false,
    this.minLines,
    this.maxLines,
    this.enableInteractiveSelection = true,
    this.onTap,
    this.onSelectionChanged,
    this.semanticsLabel,
  }) : textSpan = null;

  /// Rich text: [textSpan]'s tree, styled as [Text.rich] styles it.
  const SelectableText.rich(
    TextSpan this.textSpan, {
    super.key,
    this.focusNode,
    this.style,
    this.textAlign,
    this.showCursor = false,
    this.autofocus = false,
    this.minLines,
    this.maxLines,
    this.enableInteractiveSelection = true,
    this.onTap,
    this.onSelectionChanged,
    this.semanticsLabel,
  }) : data = null;

  /// The text, for the plain constructor; null for [SelectableText.rich].
  final String? data;

  /// The spans, for [SelectableText.rich]; null for the plain constructor.
  final TextSpan? textSpan;

  /// Takes the keyboard when the text is clicked. Null: one of its own.
  final FocusNode? focusNode;

  /// Over the ambient text style, as for [Text].
  final TextStyle? style;

  /// How the lines sit across the width. Null is the start.
  final paragraph.TextAlign? textAlign;

  /// Whether a caret is drawn while focused with nothing selected.
  final bool showCursor;

  /// Whether to take focus when first shown.
  final bool autofocus;

  /// Accepted for Flutter's signature; the text is as tall as its lines.
  final int? minLines;

  /// The most lines shown; the rest is cut.
  final int? maxLines;

  /// False makes the text unselectable - a plain [Text] that can take focus.
  final bool enableInteractiveSelection;

  /// Called on a primary click that does not extend a selection.
  final void Function()? onTap;

  /// Called whenever the selection changes, with what changed it.
  final void Function(TextSelection selection, SelectionChangedCause? cause)?
      onSelectionChanged;

  /// What a screen reader reads, when not the text itself.
  final String? semanticsLabel;

  @override
  State<SelectableText> createState() => _SelectableTextState();
}

final class _SelectableTextState extends State<SelectableText> {
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownFocusNode ??= FocusNode(debugLabel: 'SelectableText'));

  @override
  void dispose() {
    _ownFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? data = widget.data;
    final Widget text = data != null
        ? Text(
            data,
            style: widget.style,
            softWrap: true,
            maxLines: widget.maxLines,
            textAlign: widget.textAlign ?? paragraph.TextAlign.start,
          )
        : Text.rich(
            widget.textSpan!,
            style: widget.style,
            softWrap: true,
            maxLines: widget.maxLines,
            textAlign: widget.textAlign ?? paragraph.TextAlign.start,
          );
    return FocusAttachment(
      node: _focusNode,
      autofocus: widget.autofocus,
      child: _SelectableTextRender(
        theme: Theme.of(context),
        focusNode: _focusNode,
        clipboard: ClipboardScope.of(context),
        contextMenu: ContextMenuScope.maybeOf(context),
        selectable: widget.enableInteractiveSelection,
        showCursor: widget.showCursor,
        onTap: widget.onTap,
        onSelectionChanged: widget.onSelectionChanged,
        semanticsLabel: widget.semanticsLabel,
        child: text,
      ),
    );
  }
}

final class _SelectableTextRender extends SingleChildRenderObjectWidget {
  const _SelectableTextRender({
    required this.theme,
    required this.focusNode,
    required this.clipboard,
    required this.contextMenu,
    required this.selectable,
    required this.showCursor,
    required this.onTap,
    required this.onSelectionChanged,
    required this.semanticsLabel,
    super.child,
  });

  final ThemeData theme;
  final FocusNode focusNode;
  final Clipboard clipboard;
  final ContextMenuController? contextMenu;
  final bool selectable;
  final bool showCursor;
  final void Function()? onTap;
  final void Function(TextSelection, SelectionChangedCause?)?
      onSelectionChanged;
  final String? semanticsLabel;

  @override
  RenderSelectableText createRenderObject(BuildContext context) =>
      RenderSelectableText()
        ..theme = theme
        ..focusNode = focusNode
        ..clipboard = clipboard
        ..contextMenu = contextMenu
        ..selectable = selectable
        ..showCursor = showCursor
        ..onTap = onTap
        ..onSelectionChanged = onSelectionChanged
        ..semanticsLabel = semanticsLabel;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSelectableText renderObject,
  ) {
    renderObject
      ..theme = theme
      ..focusNode = focusNode
      ..clipboard = clipboard
      ..contextMenu = contextMenu
      ..selectable = selectable
      ..showCursor = showCursor
      ..onTap = onTap
      ..onSelectionChanged = onSelectionChanged
      ..semanticsLabel = semanticsLabel;
  }
}

/// The selection over a [RenderText] child: hit testing, painting and the
/// commands. Public for tests that drive it directly.
final class RenderSelectableText extends RenderProxyBox
    with ControlBehavior
    implements MouseCursorTarget {
  RenderSelectableText();

  /// Where Ctrl+C goes.
  Clipboard clipboard = const UnavailableClipboard();

  /// Where a secondary click opens its menu; null opens none.
  ContextMenuController? contextMenu;

  /// See [SelectableText.onTap].
  void Function()? onTap;

  /// See [SelectableText.onSelectionChanged].
  void Function(TextSelection, SelectionChangedCause?)? onSelectionChanged;

  /// See [SelectableText.semanticsLabel].
  String? semanticsLabel;

  bool _selectable = true;
  set selectable(bool value) {
    if (value == _selectable) return;
    _selectable = value;
    if (!value) _select(const TextSelection.collapsed(0), null);
  }

  bool _showCursor = false;
  set showCursor(bool value) {
    if (value == _showCursor) return;
    _showCursor = value;
    markNeedsPaint();
  }

  TextSelection _selection = const TextSelection.collapsed(0);

  /// The current selection, in offsets into [text].
  TextSelection get selection => _selection;

  bool _dragging = false;
  bool _menuOpen = false;
  int _clicks = 0;
  Duration _lastClickAt = Duration.zero;
  Offset _lastClickAt2 = Offset.zero;
  Set<KeyModifier> _modifiers = const <KeyModifier>{};
  Future<void> _clipboardWork = Future<void>.value();

  /// Why the last copy did not happen, or null.
  ClipboardException? lastClipboardError;

  /// Completes when every copy started so far has finished.
  Future<void> get clipboardSettled => _clipboardWork;

  RenderText? get _text {
    final RenderBox? child = this.child;
    return child is RenderText ? child : null;
  }

  /// The text that is selected over: the string, or the spans' plain text.
  String get text => _text?.text ?? '';

  /// The selected text.
  String get selectedText {
    final String all = text;
    final int start = _selection.start.clamp(0, all.length);
    final int end = _selection.end.clamp(0, all.length);
    return all.substring(start, end);
  }

  paragraph.Paragraph? get _paragraph => _text?.laidOutParagraph;

  /// Places the selection, snapped onto grapheme clusters, and tells the
  /// listener.
  void select(TextSelection selection) =>
      _select(selection, SelectionChangedCause.keyboard);

  void _select(TextSelection next, SelectionChangedCause? cause) {
    final String all = text;
    final TextSelection snapped = TextSelection(
      baseOffset: TextMotion.snapDown(all, next.baseOffset),
      extentOffset: TextMotion.snapDown(all, next.extentOffset),
      affinity: next.affinity,
    );
    if (snapped == _selection) return;
    _selection = snapped;
    markNeedsPaint();
    onSelectionChanged?.call(snapped, cause);
  }

  @override
  void performLayout() {
    super.performLayout();
    // A shorter text leaves no selection past its end.
    final int length = text.length;
    if (_selection.end > length) {
      _selection = TextSelection.collapsed(length);
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  SystemCursor? cursorFor(PointerEvent event) =>
      _selectable ? SystemCursor.text : null;

  /// The text position under a point in root coordinates.
  TextPosition _positionAt(Offset global) {
    final paragraph.Paragraph? laid = _paragraph;
    if (laid == null) return const TextPosition(0);
    final RenderBox child = this.child!;
    final Offset local = globalToLocal(global) - child.offsetFromParent;
    return laid.getPositionForOffset(local);
  }

  int _countClick(PointerDownEvent event) {
    final Duration since = event.timestamp - _lastClickAt;
    final Offset moved = event.logicalPosition - _lastClickAt2;
    final bool continues = event.clickCount > 1 ||
        (since >= Duration.zero &&
            since <= const Duration(milliseconds: 500) &&
            moved.dx.abs() <= 4 &&
            moved.dy.abs() <= 4);
    _clicks = continues ? _clicks % 3 + 1 : 1;
    _lastClickAt = event.timestamp;
    _lastClickAt2 = event.logicalPosition;
    return _clicks;
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(event);
    if (!enabled || !_selectable) {
      if (event is PointerUpEvent && event.button == PointerButton.primary) {
        onTap?.call();
      }
      return;
    }
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        final TextPosition at = _positionAt(event.logicalPosition);
        switch (_countClick(event)) {
          case 1:
            if (_modifiers.contains(KeyModifier.shift)) {
              _select(
                TextSelection(
                  baseOffset: _selection.baseOffset,
                  extentOffset: at.offset,
                  affinity: at.affinity,
                ),
                SelectionChangedCause.tap,
              );
            } else {
              _select(
                  TextSelection.fromPosition(at), SelectionChangedCause.tap);
              onTap?.call();
            }
            _dragging = true;
          case 2:
            final TextRange word = TextMotion.wordAt(text, at.offset);
            _select(
              TextSelection(baseOffset: word.start, extentOffset: word.end),
              SelectionChangedCause.doubleTap,
            );
            _dragging = false;
          default:
            _select(
              TextSelection(baseOffset: 0, extentOffset: text.length),
              SelectionChangedCause.tap,
            );
            _dragging = false;
        }
      case PointerDownEvent(button: PointerButton.secondary):
        if (focusOnPointerDown) {
          focusNode?.requestFocus(FocusChangeReason.pointer);
        }
        final TextPosition at = _positionAt(event.logicalPosition);
        final bool inside = !_selection.isCollapsed &&
            at.offset >= _selection.start &&
            at.offset <= _selection.end;
        if (!inside) {
          _select(TextSelection.fromPosition(at), SelectionChangedCause.tap);
        }
        openContextMenu(event.logicalPosition);
      case PointerMoveEvent() when _dragging:
        final TextPosition at = _positionAt(event.logicalPosition);
        _select(
          TextSelection(
            baseOffset: _selection.baseOffset,
            extentOffset: at.offset,
            affinity: at.affinity,
          ),
          SelectionChangedCause.drag,
        );
      case PointerUpEvent(button: PointerButton.primary):
      case PointerCancelEvent():
        _dragging = false;
      default:
        break;
    }
  }

  /// Opens Copy and Select all at [globalPosition], when there is a menu
  /// scope.
  void openContextMenu(Offset globalPosition) {
    final ContextMenuController? menu = contextMenu;
    if (menu == null || !enabled || !_selectable) return;
    _menuOpen = true;
    markNeedsPaint();
    menu.open(
      globalPosition: globalPosition,
      itemsBuilder: buildContextMenuItems,
      theme: theme,
      onClosed: () {
        _menuOpen = false;
        markNeedsPaint();
      },
    );
  }

  /// The menu's commands, enabled for the selection as it is now.
  List<MenuItem> buildContextMenuItems() => <MenuItem>[
        MenuItem(
          label: 'Copy',
          shortcut: 'Ctrl+C',
          enabled: !_selection.isCollapsed,
          disabledReason: 'nothing is selected',
          onSelected: copySelection,
        ),
        MenuItem(
          label: 'Select all',
          shortcut: 'Ctrl+A',
          enabled: text.isNotEmpty,
          disabledReason: 'there is no text',
          onSelected: () => _select(
            TextSelection(baseOffset: 0, extentOffset: text.length),
            SelectionChangedCause.toolbar,
          ),
        ),
      ];

  /// Puts the selected text on the clipboard. An empty selection copies
  /// nothing and leaves the clipboard as it was.
  void copySelection() {
    final String selected = selectedText;
    if (selected.isEmpty) {
      lastClipboardError = const ClipboardException(
        operation: 'copy',
        reason: 'the selection is empty; the clipboard was left as it was',
      );
      return;
    }
    _clipboardWork = _clipboardWork.then((void _) async {
      try {
        await clipboard.writeText(selected);
        lastClipboardError = null;
      } on ClipboardException catch (error) {
        lastClipboardError = error;
      } on UnsupportedCapabilityError catch (error) {
        lastClipboardError =
            ClipboardException(operation: 'copy', reason: error.toString());
      } on Object catch (error) {
        lastClipboardError = ClipboardException(
          operation: 'copy',
          reason: 'the copy failed with an unexpected error: $error',
        );
      }
    });
    unawaited(_clipboardWork);
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    _modifiers = event.modifiers;
    if (!enabled || !_selectable || event is! KeyDownEvent) return false;
    final EditingConvention convention = platformEditingConvention;
    final bool mac = convention == EditingConvention.mac;
    final bool shift = event.modifiers.contains(KeyModifier.shift);
    final bool command = event.modifiers.contains(convention.commandModifier);
    final bool word =
        event.modifiers.contains(convention.wordModifier) || (!mac && command);
    final String all = text;

    void extendTo(int offset) => _select(
          shift
              ? TextSelection(
                  baseOffset: _selection.baseOffset, extentOffset: offset)
              : TextSelection.collapsed(offset),
          SelectionChangedCause.keyboard,
        );

    switch (event.logicalKey) {
      case 0x41 when command: // Ctrl+A
        _select(TextSelection(baseOffset: 0, extentOffset: all.length),
            SelectionChangedCause.keyboard);
        return true;
      case 0x43 when command: // Ctrl+C
        copySelection();
        return true;
      case 0x2D when command: // Ctrl+Insert
        copySelection();
        return true;
      case logicalKeyArrowLeft:
        if (!shift && !_selection.isCollapsed) {
          extendTo(_selection.start);
        } else if (mac && command) {
          extendTo(0);
        } else {
          extendTo(word
              ? TextMotion.previousWord(all, _selection.extentOffset)
              : TextMotion.previousCluster(all, _selection.extentOffset));
        }
        return true;
      case logicalKeyArrowRight:
        if (!shift && !_selection.isCollapsed) {
          extendTo(_selection.end);
        } else if (mac && command) {
          extendTo(all.length);
        } else {
          extendTo(word
              ? TextMotion.nextWord(all, _selection.extentOffset)
              : TextMotion.nextCluster(all, _selection.extentOffset));
        }
        return true;
      case logicalKeyHome:
        extendTo(0);
        return true;
      case logicalKeyEnd:
        extendTo(all.length);
        return true;
      case logicalKeyContextMenu:
        openContextMenu(localToGlobal(Offset(0, size.height)));
        return true;
      case logicalKeyF10 when shift:
        openContextMenu(localToGlobal(Offset(0, size.height)));
        return true;
    }
    return false;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    final paragraph.Paragraph? laid = _paragraph;
    final Offset origin = offset + child.offsetFromParent;
    final bool focused = hasFocus || _menuOpen;
    if (laid != null && !_selection.isCollapsed) {
      final Color color = focused ? theme.selection : _dimmed(theme);
      final int paint = list.addPaint(colorArgb: color.value, antiAlias: false);
      for (final paragraph.TextBox box
          in laid.getBoxesForSelection(_selection.start, _selection.end)) {
        list.drawRectangle(box.rect.shift(origin), paint);
      }
    }
    paintChild(list, child, offset);
    if (laid != null && focused && _showCursor && _selection.isCollapsed) {
      final Rect caret = laid.getCaretRect(_selection.extent);
      list.drawRectangle(
        Rect.fromLTWH(
            origin.dx + caret.left, origin.dy + caret.top, 1, caret.height),
        list.addPaint(colorArgb: theme.foreground.value, antiAlias: false),
      );
    }
  }

  /// The selection colour half-way to the surface, as an unfocused text
  /// field draws its own.
  static Color _dimmed(ThemeData theme) {
    final Color s = theme.selection;
    final Color b = theme.surfaceBase;
    int mix(int a, int c) => (a + c) ~/ 2;
    return Color.fromARGB(
        s.alpha, mix(s.red, b.red), mix(s.green, b.green), mix(s.blue, b.blue));
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.text,
        label: semanticsLabel ?? text,
        states: <SemanticsState>{
          SemanticsState.readOnly,
          if (hasFocus) SemanticsState.focused,
        },
        actions: enabled
            ? const <SemanticsAction>{SemanticsAction.focus}
            : const <SemanticsAction>{},
      );
}
