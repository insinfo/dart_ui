/// The vocabulary a drag and drop is described in, with no platform in it.
///
/// Split from `drag_drop.dart` for the reason `file_picker_types.dart` is split
/// from `file_picker.dart`: the *types* travel everywhere - into widgets, into
/// tests, into the three backends - while the *port* is only interesting to the
/// application shell and to whoever implements a backend. A widget that wants
/// to say "I take files" should not have to import the interface that registers
/// a window with the OLE runtime.
///
/// ## Formats are MIME types, on all three platforms
///
/// The three protocols name what is being dragged in three different ways:
///
///  * **Wayland** and **XDND** both use MIME types on the wire -
///    `text/uri-list`, `text/plain;charset=utf-8` - so there is nothing to
///    translate.
///  * **Win32** uses numeric clipboard formats: `CF_UNICODETEXT` (13) and
///    `CF_HDROP` (15), plus registered formats obtained from
///    `RegisterClipboardFormat`. Those are integers with no MIME spelling at
///    all.
///
/// Two of three agree, so this contract speaks MIME and the Win32 backend keeps
/// the translation table - the alternative was inventing a fourth vocabulary
/// that no protocol uses and every backend has to translate out of. The names
/// worth agreeing on are in [DragFormats].
///
/// ## Why the payload is read asynchronously, everywhere
///
/// This is the same argument `clipboard.dart` makes, and it is not defensive:
///
///  * **Wayland** hands the destination a pipe. `wl_data_offer.receive` gives
///    it a file descriptor and the source writes the bytes into it *later*,
///    from another process, possibly in several chunks and possibly never.
///  * **XDND** is worse: the destination calls `XConvertSelection` on
///    `XdndSelection` and waits for a `SelectionNotify` to come back through
///    its own event loop, and a payload larger than the server's maximum
///    request size arrives as an `INCR` transfer, one `PropertyNotify` at a
///    time.
///  * **Win32 is genuinely synchronous.** `IDataObject::GetData` returns the
///    `STGMEDIUM` on the spot, while `IDropTarget::Drop` is still on the stack.
///
/// A synchronous contract would therefore be a lie on two platforms out of
/// three, and the only way to satisfy it there is a nested event loop inside a
/// drop handler - which reenters the widget tree during a modal drag, the
/// classic X11 drag-and-drop hang. So [DragData.readBytes] is a `Future`, and
/// the Win32 implementation simply completes it already resolved.
///
/// ## Why the *negotiation* is synchronous, everywhere
///
/// The opposite asymmetry applies to enter/over/leave, and pretending otherwise
/// would break Win32 rather than merely slow it down:
///
///  * `IDropTarget::DragOver` is called by the OLE drag loop and **must return
///    an effect before it returns**. There is no later: the value it writes
///    into `*pdwEffect` is what paints the cursor on that very frame, and the
///    isolate is parked inside `DoDragDrop` in another process, so no Dart
///    microtask can run to answer afterwards.
///  * Wayland is only nominally freer: `wl_data_offer.accept` must have been
///    sent before `drop` arrives or the transfer cannot happen, and `drop` can
///    follow `motion` immediately.
///  * XDND is the same shape - `XdndStatus` answers `XdndPosition`, and a
///    source is entitled to send `XdndDrop` as soon as it has a status.
///
/// So [DropTargetHandler.onDragEnter] and [DropTargetHandler.onDragOver] return
/// a [DropResponse] directly, and only the transfer that follows a drop is a
/// future. The contract is async where the data is and synchronous where the
/// answer is, which is what each protocol actually requires.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../geometry/offset.dart';
import 'input_events.dart';
import 'window_events.dart';

/// The MIME types worth agreeing on, spelled the way the wire spells them.
///
/// Not an enum: a format is an open set - an application may drag its own
/// `application/x-my-thing` and this contract must carry it untouched - and an
/// enum would force every private format through an `other(String)` case that
/// callers would then have to unwrap. These are the names that recur.
abstract final class DragFormats {
  /// UTF-8 text. The `charset` parameter is part of the name on Wayland and
  /// XDND, and both also answer to the bare `text/plain`, so a target that
  /// wants text should offer [text] *and* [plainText] to
  /// [DragData.preferredFormat].
  static const String text = 'text/plain;charset=utf-8';

  /// `text/plain` with no charset, which is what older X11 sources offer.
  static const String plainText = 'text/plain';

  /// A list of URIs, one per line, CRLF-separated, `#` starting a comment.
  /// This is RFC 2483's `text/uri-list`, and it is how *files* are dragged
  /// everywhere except Win32, where the same thing is `CF_HDROP`.
  static const String uriList = 'text/uri-list';

  /// GNOME's file-manager flavour of [uriList]: the first line is the word
  /// `copy` or `move`, the rest are URIs. Accepted on the read side because
  /// Nautilus and Files send it; never produced.
  static const String gnomeCopiedFiles = 'x-special/gnome-copied-files';

  static const String utf8String = 'UTF8_STRING';

  static const String png = 'image/png';

  static const String html = 'text/html';
}

/// What a drop would *do* with the data, which is not the same question as
/// whether it is allowed.
///
/// The three protocols overlap but do not agree, and this enum is the union
/// rather than the intersection because dropping the difference would silently
/// downgrade behaviour on whichever platform has it:
///
/// | this      | Win32 `DROPEFFECT_` | Wayland `WL_DATA_DEVICE_MANAGER_DND_ACTION_` | XDND atom          |
/// |-----------|---------------------|----------------------------------------------|--------------------|
/// | [none]    | `NONE`              | `NONE`                                       | `XdndActionPrivate`* |
/// | [copy]    | `COPY`              | `COPY`                                       | `XdndActionCopy`   |
/// | [move]    | `MOVE`              | `MOVE`                                       | `XdndActionMove`   |
/// | [link]    | `LINK`              | *(absent)*                                   | `XdndActionLink`   |
/// | [ask]     | *(absent)*          | `ASK`                                        | `XdndActionAsk`    |
///
/// \* a refusal on XDND is spelled by clearing the accept bit of `XdndStatus`,
/// not by an action atom; [none] is how this contract spells it in one word.
///
/// **[link] on Wayland and [ask] on Win32 are not silently remapped.** A
/// backend that is asked for an action its protocol has no word for refuses the
/// drop, because the alternatives are both worse: substituting [copy] for a
/// requested [move] loses the user's file, and substituting [move] for [link]
/// deletes an original the user meant to keep.
enum DragAction {
  /// No drop is possible here. The cursor shows the "not allowed" glyph.
  none,

  /// The destination takes a copy; the source keeps the original.
  copy,

  /// The destination takes it and the source deletes the original **after the
  /// transfer is confirmed**. Confirmation is a real protocol step - Wayland's
  /// `wl_data_offer.finish`, XDND's `XdndFinished` - and skipping it is how a
  /// move loses data.
  move,

  /// The destination stores a reference: a shortcut, a symlink, a URL.
  link,

  /// The destination will ask the user which of the above to do, typically
  /// with a menu at the drop point. Has no Win32 spelling.
  ask;

  /// Whether this action, if performed, destroys the source's copy.
  bool get destroysSource => this == DragAction.move;
}

/// One action chosen out of [allowed], preferring [preferred] and falling back
/// to copy, then move, then link.
///
/// This is the rule every protocol applies when the user is not holding a
/// modifier, written once: a source that offers copy-or-move and a target that
/// takes either must settle on copy, because copy is the choice that cannot
/// lose data if the negotiation was wrong.
DragAction resolveDragAction(
  Set<DragAction> allowed, {
  DragAction preferred = DragAction.copy,
}) {
  if (allowed.contains(preferred) && preferred != DragAction.none) {
    return preferred;
  }
  for (final DragAction candidate in <DragAction>[
    DragAction.copy,
    DragAction.move,
    DragAction.link,
    DragAction.ask,
  ]) {
    if (allowed.contains(candidate)) return candidate;
  }
  return DragAction.none;
}

/// The action a modifier state asks for, or null when the user is not asking.
///
/// The three desktops agree on this one, which is why it is worth having in
/// shared code: Ctrl forces copy, Shift forces move, Ctrl+Shift makes a link.
/// A backend still masks the answer against what the source offers - a forced
/// move that the source cannot perform is a refusal, not a copy.
DragAction? dragActionForModifiers(Set<KeyModifier> modifiers) {
  final bool control = modifiers.contains(KeyModifier.control);
  final bool shift = modifiers.contains(KeyModifier.shift);
  if (control && shift) return DragAction.link;
  if (control) return DragAction.copy;
  if (shift) return DragAction.move;
  return null;
}

/// What a drag carries: the list of formats it can produce, and a way to get
/// the bytes of one of them.
///
/// An interface rather than a value because on two platforms out of three the
/// bytes **do not exist yet** when the drag enters the window - they live in
/// another process and are produced on demand, which is exactly what makes a
/// drag cheap when the payload is a hundred megabytes. Materialising it on
/// enter, so that this could be a plain data class, would copy the payload for
/// every window the pointer crosses on its way to the target.
abstract interface class DragData {
  /// Every format the source advertised, in the order it offered them.
  ///
  /// The source's order is a preference, but it is *its* preference, not the
  /// target's; see [preferredFormat].
  List<String> get formats;

  /// The bytes of [format], or null when it could not be transferred.
  ///
  /// Null rather than an exception for "the source went away mid-transfer",
  /// which is routine and not exceptional: the other application is entitled
  /// to exit while the user is dragging out of it. A [DragDropException] is
  /// still what a *protocol* failure raises.
  ///
  /// May be called at most once per drop on Wayland and XDND, because the
  /// underlying transfer consumes the offer; implementations cache so that a
  /// second call answers from memory rather than hanging.
  Future<Uint8List?> readBytes(String format);
}

/// Reading conveniences that are the same arithmetic on every platform, and so
/// live here instead of in each backend.
extension DragDataReading on DragData {
  bool hasFormat(String format) => formats.contains(format);

  /// The first of [preferred] the source actually offers, or null.
  ///
  /// The order is the **caller's** preference and deliberately not the
  /// source's: a file manager wants [DragFormats.uriList] before
  /// [DragFormats.text] when both are offered, a text editor wants the
  /// opposite, and only they know which they are.
  String? preferredFormat(List<String> preferred) {
    for (final String format in preferred) {
      if (formats.contains(format)) return format;
    }
    return null;
  }

  /// Whether this drag carries files, by any of the spellings that mean files.
  bool get hasFiles =>
      hasFormat(DragFormats.uriList) || hasFormat(DragFormats.gnomeCopiedFiles);

  /// Whether this drag carries text, by any of its spellings.
  bool get hasText =>
      hasFormat(DragFormats.text) ||
      hasFormat(DragFormats.plainText) ||
      hasFormat(DragFormats.utf8String);

  /// The dragged text, decoded, or null when none was offered or transferred.
  ///
  /// Malformed UTF-8 is replaced rather than thrown on: the bytes came from
  /// another application and a dropped file name with one bad byte in it should
  /// arrive with one replacement character, not take the drop down.
  Future<String?> readText() async {
    final String? format = preferredFormat(<String>[
      DragFormats.text,
      DragFormats.utf8String,
      DragFormats.plainText,
    ]);
    if (format == null) return null;
    final Uint8List? bytes = await readBytes(format);
    if (bytes == null) return null;
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }

  /// The dragged URIs, or an empty list when none were offered.
  ///
  /// Parses `text/uri-list` per RFC 2483 - CRLF separated, `#` comments - and
  /// tolerates the LF-only files that half the world actually sends, plus
  /// GNOME's leading `copy`/`move` line.
  Future<List<Uri>> readUris() async {
    final String? format = preferredFormat(<String>[
      DragFormats.uriList,
      DragFormats.gnomeCopiedFiles,
    ]);
    if (format == null) return const <Uri>[];
    final Uint8List? bytes = await readBytes(format);
    if (bytes == null) return const <Uri>[];
    return parseUriList(
      const Utf8Decoder(allowMalformed: true).convert(bytes),
    );
  }

  /// The dragged files as local paths, skipping URIs that name no local file.
  ///
  /// A `http://` URI dropped from a browser is a real drag that this target
  /// simply has no file for, so it is skipped rather than turned into a
  /// nonsense path.
  Future<List<String>> readFilePaths() async {
    final List<Uri> uris = await readUris();
    return <String>[
      for (final Uri uri in uris)
        if (uri.scheme == 'file') uri.toFilePath(windows: _isWindowsUri(uri)),
    ];
  }

  static bool _isWindowsUri(Uri uri) {
    // A `file:///C:/x` path is a Windows path wherever it is parsed, and a
    // `/home/x` one never is. Deciding by the URI rather than by the host
    // platform is what lets a headless test on Linux parse a Windows drop.
    final List<String> segments = uri.pathSegments;
    if (segments.isEmpty) return false;
    final String first = segments.first;
    return first.length == 2 && first.endsWith(':');
  }
}

/// The lines of an RFC 2483 `text/uri-list` that are actually URIs.
///
/// Public because both the read side (above) and the write side
/// ([MemoryDragData.uris]) need the same rules, and because XDND sources in the
/// wild get the line ending wrong often enough that the tolerance is worth
/// testing directly.
List<Uri> parseUriList(String text) {
  final List<Uri> uris = <Uri>[];
  for (final String rawLine in text.split('\n')) {
    final String line = rawLine.replaceAll('\r', '').trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    // GNOME prefixes the list with the action it intends; it is not a URI.
    if (line == 'copy' || line == 'move' || line == 'link') continue;
    final Uri? uri = Uri.tryParse(line);
    // A line that is not a URI at all is skipped rather than fatal: one bad
    // line in a multi-file drop must not lose the other files.
    if (uri != null && uri.hasScheme) uris.add(uri);
  }
  return uris;
}

/// A drag payload that is already in memory.
///
/// Both the source side (what this application drags out) and every test use
/// it, and so does the Win32 destination, whose `IDataObject` really has handed
/// over the bytes by the time a drop is reported.
final class MemoryDragData implements DragData {
  MemoryDragData(Map<String, Uint8List> data)
      : _data = Map<String, Uint8List>.unmodifiable(data);

  /// A drag carrying [text], offered under every spelling of "text" that the
  /// three protocols use, so that a Windows target, a GTK target and an old
  /// Xt target all find something they know.
  factory MemoryDragData.text(String text) {
    final Uint8List bytes = Uint8List.fromList(utf8.encode(text));
    return MemoryDragData(<String, Uint8List>{
      DragFormats.text: bytes,
      DragFormats.plainText: bytes,
      DragFormats.utf8String: bytes,
    });
  }

  /// A drag carrying files, encoded as `text/uri-list`.
  ///
  /// CRLF, because RFC 2483 says CRLF and the readers that are strict about it
  /// are the ones that cannot be fixed from here.
  factory MemoryDragData.uris(List<Uri> uris) {
    final String list =
        '${uris.map((Uri uri) => uri.toString()).join('\r\n')}\r\n';
    return MemoryDragData(<String, Uint8List>{
      DragFormats.uriList: Uint8List.fromList(utf8.encode(list)),
    });
  }

  /// A drag carrying local files. Paths become `file://` URIs.
  factory MemoryDragData.filePaths(List<String> paths) => MemoryDragData.uris(
        <Uri>[for (final String path in paths) Uri.file(path)],
      );

  final Map<String, Uint8List> _data;

  @override
  List<String> get formats => List<String>.unmodifiable(_data.keys);

  @override
  Future<Uint8List?> readBytes(String format) async => _data[format];

  /// The bytes without the round trip, for a caller that already knows this is
  /// a memory payload - the Win32 source side, which must hand `IDataObject`
  /// its bytes from inside a COM call and cannot await.
  Uint8List? bytesOf(String format) => _data[format];

  @override
  String toString() => 'MemoryDragData(${_data.keys.join(', ')})';
}

/// A drag payload produced on demand.
///
/// The shape a real source wants: nothing is serialised until a destination
/// actually asks for that format, which is the difference between dragging a
/// 200 MB file list and dragging a promise of one.
final class LazyDragData implements DragData {
  LazyDragData(this.formats, this._produce);

  @override
  final List<String> formats;

  final Future<Uint8List?> Function(String format) _produce;

  final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  @override
  Future<Uint8List?> readBytes(String format) async {
    if (!formats.contains(format)) return null;
    if (_cache.containsKey(format)) return _cache[format];
    final Uint8List? bytes = await _produce(format);
    // Cached even when null: on Wayland and XDND the transfer consumed the
    // offer, so asking again would hang rather than fail again.
    _cache[format] = bytes;
    return bytes;
  }

  @override
  String toString() => 'LazyDragData(${formats.join(', ')})';
}

/// Where a drag is, and under what conditions, in terms every backend can fill
/// in.
///
/// One class for enter, over and drop rather than three near-identical ones,
/// because the fields are the same and the *phase* is already named by which
/// method receives it.
final class DragSessionEvent {
  const DragSessionEvent({
    required this.windowId,
    required this.position,
    required this.data,
    required this.allowedActions,
    this.suggestedAction = DragAction.copy,
    this.modifiers = const <KeyModifier>{},
    this.screenPosition,
  });

  /// The window under the pointer.
  final NativeWindowId windowId;

  /// Where the pointer is, **in logical units inside the client area** - the
  /// same coordinate space [PointerEvent.logicalPosition] uses, so a widget can
  /// hit-test a drop with the code it already hit-tests a click with.
  ///
  /// Getting this wrong is the single most common drag-and-drop bug, because
  /// two of the three protocols report the position in *screen* coordinates
  /// and in *physical* pixels: `IDropTarget::DragOver` takes a `POINTL` on the
  /// desktop, and `XdndPosition` packs root-window coordinates into
  /// `data.l[2]`. Converting is the backend's job precisely so that no widget
  /// ever has to know which protocol it is on.
  final Offset position;

  /// Where the pointer is on the desktop, when the backend knows - which it
  /// always does on Win32 and XDND, and never does on Wayland, where a client
  /// is not told where its own windows are.
  final Offset? screenPosition;

  /// What is being dragged. The same instance for the whole session, so a
  /// target may hold it from enter to drop.
  final DragData data;

  /// What the *source* is prepared to do. A response naming anything outside
  /// this set is a refusal, not a negotiation.
  final Set<DragAction> allowedActions;

  /// What the source, the modifiers or the platform suggest - the action that
  /// happens if the target expresses no preference.
  final DragAction suggestedAction;

  /// The modifier keys held right now, so a target can implement the
  /// Ctrl-copies/Shift-moves convention itself when it wants to override the
  /// platform's answer.
  final Set<KeyModifier> modifiers;

  @override
  String toString() => 'DragSessionEvent(window ${windowId.value}, $position, '
      '${data.formats.length} formats, allowed $allowedActions)';
}

/// How a destination answers "may this be dropped here, and as what?".
///
/// Returned synchronously; see the library comment for why that is not a
/// shortcut but a requirement of `IDropTarget`.
final class DropResponse {
  const DropResponse({
    required this.acceptedFormat,
    this.action = DragAction.copy,
  });

  /// Refuses the drag. The cursor shows "not allowed", no drop can happen, and
  /// - crucially - the source is told, so it stops waiting.
  ///
  /// A target that cannot use the data must say this rather than accept and
  /// then ignore the drop: an accepted drop that produces nothing leaves the
  /// source's `wl_data_source` alive and its `dnd_finished` never sent, which
  /// the user sees as the *other* application hanging.
  const DropResponse.reject()
      : acceptedFormat = null,
        action = DragAction.none;

  /// The format this target will read at drop time, or null to refuse.
  ///
  /// Naming the format up front is not bureaucracy: Wayland's
  /// `wl_data_offer.accept` takes exactly one MIME type and the transfer can
  /// only be for that one, and XDND's `XdndDrop` converts a single target atom.
  /// A target that wants to decide later must name the format it would most
  /// like now, and may still read a different one on Win32 only - which is why
  /// deciding later is not in this contract.
  final String? acceptedFormat;

  final DragAction action;

  bool get isAccepted => acceptedFormat != null && action != DragAction.none;

  @override
  String toString() => isAccepted
      ? 'DropResponse($acceptedFormat, $action)'
      : 'DropResponse.reject()';
}

/// A drag-and-drop operation that did not happen, named.
///
/// The shape of [ClipboardException] and for the same reason: "drag and drop
/// failed" is not actionable, while "RegisterDragDrop failed with
/// DRAGDROP_E_ALREADYREGISTERED" says the window already has a target and the
/// fix is to revoke the old one.
final class DragDropException implements Exception {
  const DragDropException({
    required this.operation,
    required this.reason,
    this.backend,
    this.errorCode,
  });

  /// The call that failed: `RegisterDragDrop`, `XConvertSelection`,
  /// `startDrag`.
  final String operation;

  /// Why, in words that name the cause rather than restate the failure.
  final String reason;

  /// Which implementation reported it, when there is one.
  final String? backend;

  /// The platform's own number - an `HRESULT`, an X11 error code - when there
  /// is one.
  final int? errorCode;

  @override
  String toString() => 'DragDropException: $operation failed'
      '${backend == null ? '' : ' in $backend'}'
      '${errorCode == null ? '' : ' (0x${errorCode!.toRadixString(16)})'}'
      ' - $reason';
}
