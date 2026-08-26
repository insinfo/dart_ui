/// IMM32, against a real input context on a real window.
///
/// ## What is real here and what is not
///
/// **Real**, and asserted against Windows itself: imm32 loads and every symbol
/// binds; a real `HWND` has an input context; `ImmAssociateContextEx` really
/// does take it away and give it back, which is the mechanism a password field
/// relies on; `ImmSetCompositionWindow` and `ImmSetCandidateWindow` accept the
/// forms this backend builds; `ImmGetCompositionStringW` answers for a context
/// that is not composing. The `WndProc` arms are driven through the real
/// message handler of a real window.
///
/// **Not testable, and named rather than faked**: a composition string with
/// actual content. `ImmGetCompositionStringW` only answers while an input
/// method is mid-conversion, and an input method only starts converting when a
/// human presses a key with a Japanese, Chinese or Korean IME selected. There
/// is no supported way to inject one - `ImmSetCompositionStringW` requires the
/// *IME's own* context and fails from an application, and posting
/// `WM_IME_COMPOSITION` by hand does not populate the context the message
/// merely announces. So the arithmetic that turns a composition string into an
/// [ImeComposition] - clause runs, the caret inside the preedit, a caret
/// Windows reported past the end - is tested as a pure function over the exact
/// bytes IMM32 would have produced, and the reading of those bytes is exercised
/// only against an empty context.
///
/// What a human would have to do to cover the rest, in one paragraph so it can
/// be done deliberately: install a Japanese IME, run an application with a
/// [TextField], select the IME, type `nihongo`, and check that the preedit
/// appears underlined in the field with the clause under conversion drawn
/// thicker, that the candidate window opens under the caret rather than in the
/// corner, that Escape leaves no text behind, and that Enter commits.
library;

import 'dart:async';
import 'dart:ffi' show nullptr;
import 'dart:io' show Platform;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_ime.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:test/test.dart';

void main() {
  group('the composition arithmetic', () {
    test('equal attribute bytes coalesce into one clause', () {
      final List<ImeCompositionClause> clauses = decodeCompositionAttributes(
        <int>[imeAttrInput, imeAttrInput, imeAttrInput],
      );

      expect(clauses, hasLength(1));
      expect(clauses.single.start, 0);
      expect(clauses.single.end, 3);
      expect(clauses.single.style, ImeCompositionStyle.input);
    });

    test('the clause under conversion is its own run', () {
      // What `にほんご` looks like mid-conversion: two clauses already
      // converted, the third the one the candidate window is about.
      final List<ImeCompositionClause> clauses = decodeCompositionAttributes(
        <int>[
          imeAttrConverted,
          imeAttrConverted,
          imeAttrTargetConverted,
          imeAttrTargetConverted,
        ],
      );

      expect(clauses, hasLength(2));
      expect(clauses[0].style, ImeCompositionStyle.converted);
      expect(clauses[0].end, 2);
      expect(clauses[1].style, ImeCompositionStyle.targetConverted);
      expect(clauses[1].start, 2);
      expect(clauses[1].end, 4);
    });

    test('every ATTR_ value has a style, and an unknown one is not converted',
        () {
      expect(
        imeCompositionStyleForAttribute(imeAttrInput),
        ImeCompositionStyle.input,
      );
      expect(
        imeCompositionStyleForAttribute(imeAttrTargetConverted),
        ImeCompositionStyle.targetConverted,
      );
      expect(
        imeCompositionStyleForAttribute(imeAttrConverted),
        ImeCompositionStyle.converted,
      );
      expect(
        imeCompositionStyleForAttribute(imeAttrTargetNotconverted),
        ImeCompositionStyle.targetNotConverted,
      );
      expect(
        imeCompositionStyleForAttribute(imeAttrInputError),
        ImeCompositionStyle.error,
      );
      expect(
        imeCompositionStyleForAttribute(imeAttrFixedconverted),
        ImeCompositionStyle.fixedConverted,
      );
      expect(
        imeCompositionStyleForAttribute(0x7F),
        ImeCompositionStyle.input,
        reason: 'the conservative reading: an unknown state draws as raw, '
            'which never claims a run is converted when it is not',
      );
    });

    test('an empty composition string is the absence of one', () {
      expect(
        buildComposition(text: '', attributes: <int>[], cursorPosition: 0),
        ImeComposition.none,
      );
    });

    test('GCS_CURSORPOS becomes the caret inside the preedit', () {
      final ImeComposition composition = buildComposition(
        text: 'にほんご',
        attributes: <int>[],
        cursorPosition: 2,
      );

      expect(composition.cursorStart, 2);
      expect(composition.cursorEnd, 2);
      expect(composition.hasHiddenCursor, isFalse);
    });

    test('a negative GCS_CURSORPOS is an error, not a hidden caret', () {
      // IMM_ERROR_NODATA is -1, which is also how Wayland spells "hide the
      // caret". Reading one as the other would remove the caret on every
      // failed read.
      final ImeComposition composition = buildComposition(
        text: 'abc',
        attributes: <int>[],
        cursorPosition: immErrorNodata,
      );

      expect(composition.hasHiddenCursor, isFalse);
      expect(
        composition.cursorStart,
        3,
        reason: 'the end of the preedit, which is where every method puts it',
      );
    });

    test('a cursor past the end of the string is clamped, not thrown on', () {
      final ImeComposition composition = buildComposition(
        text: 'ab',
        attributes: <int>[],
        cursorPosition: 99,
      );
      expect(composition.cursorStart, 2);
    });

    test('more attribute bytes than code units are truncated', () {
      // Reachable when an edit races the message: the context still describes
      // the previous, longer string.
      final ImeComposition composition = buildComposition(
        text: 'ab',
        attributes: <int>[imeAttrInput, imeAttrInput, imeAttrTargetConverted],
        cursorPosition: 2,
      );

      expect(composition.clauses, hasLength(1));
      expect(composition.clauses.single.end, 2);
    });
  });

  group('WM_IME_SETCONTEXT', () {
    test('hides the platform composition window and keeps the candidate list',
        () {
      const int all = 0xFFFFFFFF;
      final int forwarded = imeSetContextLParam(all);

      expect(
        forwarded & iscShowUiCompositionWindow,
        0,
        reason: 'the preedit is drawn in the document; leaving this set draws '
            'it twice',
      );
      expect(
        forwarded & iscShowUiCandidateWindow,
        iscShowUiCandidateWindow,
        reason: 'the candidate list is the IME\'s to draw and this framework '
            'has no widget for it',
      );
      expect(
        imeSetContextLParam(0),
        0,
        reason: 'nothing to clear when nothing was asked for',
      );
    });
  });

  group('a real input context', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late TextInputBackend textInput;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      window = await backend.createWindow(
        const WindowOptions(
          title: 'ime',
          size: Size(200, 80),
          visible: false,
        ),
      ) as Win32Window;
      textInput = backend.textInput;
    });

    tearDown(() async {
      window.close();
      await backend.shutdown();
    });

    test('imm32 loads and every required symbol binds', () {
      expect(Imm32Api.load().api, isNotNull);
      expect(textInput.name, 'imm32');
      expect(textInput.supportsComposition, isTrue);
      expect(
        textInput.usesSurroundingText,
        isFalse,
        reason: 'IMM32 pulls context with WM_IME_REQUEST/IMR_DOCUMENTFEED, '
            'which this backend does not answer; reporting true and dropping '
            'what it was given would hide a real gap',
      );
    });

    test('the probe claims textComposition only when imm32 bound', () {
      final BackendProbeResult probe = backend.probe();
      expect(
        probe.capabilities.contains(Capability.textComposition),
        Imm32Api.load().api != null,
      );
    });

    test('attaching installs a handler on the window and detaching removes it',
        () {
      final client = _StubClient();
      final TextInputConnection connection =
          textInput.attach(window: window, client: client);

      expect(window.imeHandler, isNotNull);
      expect(connection.isAttached, isTrue);
      expect(connection.windowId, window.id);

      connection.detach();

      expect(window.imeHandler, isNull);
      expect(connection.isAttached, isFalse);
      expect(
        connection.detach,
        returnsNormally,
        reason: 'a window teardown and an explicit detach race by design',
      );
    });

    test(
        'disable really takes the input context away, and enable gives it '
        'back', () {
      final api = Imm32Api.load().api!;
      final int hwnd = window.handle;
      if (api.immGetContext(hwnd) == 0) {
        // A Windows install with input methods switched off entirely. The
        // mechanism cannot be observed there; nothing is asserted rather than
        // asserting something weaker.
        return;
      }
      api.immReleaseContext(hwnd, api.immGetContext(hwnd));

      final client = _StubClient();
      final TextInputConnection connection =
          textInput.attach(window: window, client: client);
      addTearDown(connection.detach);

      connection.disable();
      expect(
        api.immGetContext(hwnd),
        0,
        reason: 'this is the mechanism a password field relies on: an input '
            'method left associated shows a candidate window full of the '
            'user\'s password and can write it to a user dictionary',
      );

      connection.enable();
      final int restored = api.immGetContext(hwnd);
      expect(restored, isNot(0));
      api.immReleaseContext(hwnd, restored);
      expect(connection.isEnabled, isTrue);
    });

    test('an obscured field is never enabled', () {
      final client = _StubClient()
        ..configuration = TextInputConfiguration.password;
      final TextInputConnection connection =
          textInput.attach(window: window, client: client);
      addTearDown(connection.detach);

      connection.enable();

      expect(connection.isEnabled, isFalse);
    });

    test(
        'the caret rectangle reaches ImmSetCompositionWindow and '
        'ImmSetCandidateWindow', () {
      final api = Imm32Api.load().api!;
      if (api.immGetContext(window.handle) == 0) return;
      api.immReleaseContext(window.handle, api.immGetContext(window.handle));

      final client = _StubClient()..caret = const Rect.fromLTWH(40, 8, 1, 16);
      final connection = textInput.attach(window: window, client: client)
          as Win32TextInputConnection;
      addTearDown(connection.detach);

      connection.enable();
      connection.updateEditingState();

      expect(
        connection.lastError,
        isNull,
        reason: 'both forms were accepted by IMM32 as this backend builds them',
      );
    });

    test(
        'reading a composition string from a context that is not composing '
        'is empty, not a crash', () {
      final api = Imm32Api.load().api!;
      final int himc = api.immGetContext(window.handle);
      if (himc == 0) return;
      try {
        final int bytes = api.immGetCompositionStringW(
          himc,
          gcsCompstr,
          nullptr,
          0,
        );
        expect(
          bytes,
          lessThanOrEqualTo(0),
          reason: 'no method is converting, so there is no string; a positive '
              'length here would mean the read is picking up somebody else\'s '
              'context',
        );
      } finally {
        api.immReleaseContext(window.handle, himc);
      }
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');

  group('the WndProc arms', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late Win32TextInputConnection connection;
    late _StubClient client;

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      window = await backend.createWindow(
        const WindowOptions(
          title: 'ime wndproc',
          size: Size(200, 80),
          visible: false,
        ),
      ) as Win32Window;
      client = _StubClient();
      connection = backend.textInput.attach(window: window, client: client)
          as Win32TextInputConnection;
    });

    tearDown(() async {
      connection.detach();
      window.close();
      await backend.shutdown();
    });

    test('WM_IME_STARTCOMPOSITION is swallowed', () {
      expect(
        window.handleMessage(window.handle, wmImeStartcomposition, 0, 0),
        0,
        reason: 'answering 0 is what stops DefWindowProcW creating its own '
            'composition window on top of the one we draw',
      );
      expect(connection.isComposing, isTrue);
    });

    test('WM_IME_ENDCOMPOSITION ends the composition and is swallowed', () {
      window.handleMessage(window.handle, wmImeStartcomposition, 0, 0);
      client.log.clear();

      expect(
        window.handleMessage(window.handle, wmImeEndcomposition, 0, 0),
        0,
      );
      expect(connection.isComposing, isFalse);
      expect(client.log, <String>['composition:']);
    });

    test('WM_IME_NOTIFY is left to the platform', () {
      // Named rather than left to the default arm: the candidate list is the
      // IME's window, and swallowing this would break the very list the caret
      // rectangle is positioning.
      expect(
        connection.handleImeMessage(window.handle, wmImeNotify, 0, 0),
        isNull,
      );
      expect(
        connection.handleImeMessage(window.handle, wmImeChar, 0x41, 0),
        isNull,
        reason: 'DefWindowProcW turns WM_IME_CHAR into an ordinary WM_CHAR; '
            'handling it here as well would insert every character twice',
      );
      expect(
        connection.handleImeMessage(window.handle, wmImeRequest, 0, 0),
        isNull,
      );
    });

    test('WM_IME_COMPOSITION with no bits set changes nothing', () {
      expect(window.handleMessage(window.handle, wmImeComposition, 0, 0), 0);
      expect(client.log, isEmpty);
    });

    test('a client that throws does not escape into the OS', () {
      final throwing = _StubClient()..throwOnComposition = true;
      final TextInputConnection other =
          backend.textInput.attach(window: window, client: throwing);
      addTearDown(other.detach);

      window.handleMessage(window.handle, wmImeStartcomposition, 0, 0);
      expect(
        () => window.handleMessage(window.handle, wmImeEndcomposition, 0, 0),
        returnsNormally,
        reason: 'the WndProc must return an LRESULT; letting a Dart exception '
            'through would unwind through native frames',
      );
      expect((other as Win32TextInputConnection).lastError, isNotNull);
    });

    test('VK_PROCESSKEY produces no key event at all', () async {
      final events = <PlatformWindowEvent>[];
      final StreamSubscription<PlatformWindowEvent> subscription =
          window.events.listen(events.add);
      addTearDown(subscription.cancel);

      window.handleMessage(window.handle, wmKeydown, vkProcesskey, 0);
      await Future<void>.delayed(Duration.zero);

      expect(
        events.whereType<KeyEvent>(),
        isEmpty,
        reason: 'every key of a Japanese conversion arrives as this one '
            'virtual key; emitting it would fire an application shortcut '
            'bound to a bare letter on every keystroke of the word',
      );

      events.clear();
      window.handleMessage(window.handle, wmKeydown, 0x41, 0);
      await Future<void>.delayed(Duration.zero);
      expect(
        events.whereType<KeyEvent>(),
        hasLength(1),
        reason: 'an ordinary key is unaffected',
      );
    });

    test('a window with no handler hands every IME message to the platform',
        () async {
      connection.detach();
      expect(window.imeHandler, isNull);

      // The behaviour this backend had before IMM32 was wired up: the IME
      // draws its own composition window, which is a working - if
      // duplicated-looking - input method rather than a dead one.
      expect(
        () => window.handleMessage(window.handle, wmImeStartcomposition, 0, 0),
        returnsNormally,
      );
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');
}

/// A [TextInputClient] that records what it was told.
final class _StubClient implements TextInputClient {
  TextInputConfiguration configuration = const TextInputConfiguration();
  Rect caret = const Rect.fromLTWH(0, 0, 1, 16);
  bool throwOnComposition = false;
  final List<String> log = <String>[];

  @override
  TextInputConfiguration get textInputConfiguration => configuration;

  @override
  ImeSurroundingText get surroundingText => ImeSurroundingText.empty;

  @override
  Rect get caretRect => caret;

  @override
  void updateComposition(ImeComposition composition) {
    if (throwOnComposition) throw StateError('the field blew up');
    log.add('composition:${composition.text}');
  }

  @override
  void commitText(String text) => log.add('commit:$text');

  @override
  void deleteSurroundingText({
    required int beforeLength,
    required int afterLength,
  }) =>
      log.add('delete:$beforeLength/$afterLength');
}
