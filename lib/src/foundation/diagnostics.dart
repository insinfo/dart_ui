/// Explicit failure reporting, per section 6.6 of the roadmap.
///
/// The rule that shaped this file: *never catch an exception silently and just
/// pick another backend*. A fallback that leaves no trace is indistinguishable
/// from a backend that was never tried, and the macOS spike showed how
/// expensive that is - a registration call that intermittently returned
/// paramErr looked like a wrong ABI for weeks because nothing recorded which
/// attempt had failed and why.
///
/// So a backend does not answer "did it work?" with a bool. It answers with a
/// report that names the library, the symbol, the device or the permission
/// that was missing.
library;

/// What a backend can do, asked abstractly so that a control never queries
/// Direct3D or Metal directly.
enum Capability {
  /// A window can be created and shown.
  window,

  /// Several windows at once.
  multipleWindows,

  /// A CPU framebuffer can be presented.
  cpuPresentation,

  /// Only the damaged region needs to be presented.
  partialPresent,

  /// Presentation is synchronised with the display refresh.
  vsync,

  keyboardInput,
  pointerInput,
  scrollInput,

  /// Text composition / IME.
  textComposition,

  clipboardText,
  clipboardImage,
  dragAndDrop,

  /// Per-monitor DPI, reported and updated at runtime.
  perMonitorDpi,

  /// The process can shut down without leaking native handles or calling
  /// `_exit`. Not universal: the macOS signal-hijack backend had to prove it.
  orderlyShutdown,

  accessibility,
}

/// Why a probe reached the conclusion it did.
enum DiagnosticKind {
  missingLibrary,
  missingSymbol,
  incompatibleVersion,
  incompatibleDevice,
  surfaceCreationFailed,
  connectionFailed,
  permissionDenied,
  unsupportedPlatform,

  /// The backend works but was rejected by policy - an experimental backend
  /// without an explicit opt-in, for example.
  rejectedByPolicy,

  /// Not a failure. Something the operator should know: a fallback that was
  /// taken, a version that is only partially validated.
  note,
}

/// One fact about a probe. Deliberately not an exception: a diagnostic is
/// evidence, and evidence is collected even from probes that succeeded.
final class BackendDiagnostic {
  const BackendDiagnostic({
    required this.kind,
    required this.message,
    this.detail,
  });

  const BackendDiagnostic.missingLibrary(String library, {String? detail})
      : this(
          kind: DiagnosticKind.missingLibrary,
          message: 'library not loadable: $library',
          detail: detail,
        );

  const BackendDiagnostic.missingSymbol(String symbol, {String? detail})
      : this(
          kind: DiagnosticKind.missingSymbol,
          message: 'symbol not found: $symbol',
          detail: detail,
        );

  const BackendDiagnostic.note(String message, {String? detail})
      : this(kind: DiagnosticKind.note, message: message, detail: detail);

  final DiagnosticKind kind;
  final String message;

  /// The raw evidence: an errno, a `CGError`, an `HRESULT`, a version string.
  /// Kept separate from [message] so logs stay greppable.
  final String? detail;

  bool get isFailure => kind != DiagnosticKind.note;

  @override
  String toString() =>
      detail == null ? '${kind.name}: $message' : '${kind.name}: $message ($detail)';
}

/// The answer a backend gives when asked whether it can run here.
final class BackendProbeResult {
  BackendProbeResult({
    required this.backendName,
    required this.supported,
    Set<Capability> capabilities = const <Capability>{},
    List<BackendDiagnostic> diagnostics = const <BackendDiagnostic>[],
  })  : capabilities = Set<Capability>.unmodifiable(capabilities),
        diagnostics = List<BackendDiagnostic>.unmodifiable(diagnostics);

  /// Convenience for the common shape: unsupported because of exactly one
  /// thing, which is named.
  factory BackendProbeResult.unsupported(
    String backendName,
    BackendDiagnostic reason,
  ) =>
      BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: <BackendDiagnostic>[reason],
      );

  final String backendName;
  final bool supported;
  final Set<Capability> capabilities;
  final List<BackendDiagnostic> diagnostics;

  bool supports(Capability capability) => capabilities.contains(capability);

  Iterable<BackendDiagnostic> get failures =>
      diagnostics.where((d) => d.isFailure);

  /// One line per fact, so a CI log or a bug report carries the whole story.
  String describe() {
    final buffer = StringBuffer()
      ..writeln('backend: $backendName')
      ..writeln('supported: $supported')
      ..writeln('capabilities: '
          '${(capabilities.map((c) => c.name).toList()..sort()).join(', ')}');
    if (diagnostics.isEmpty) {
      buffer.writeln('diagnostics: none');
    } else {
      buffer.writeln('diagnostics:');
      for (final diagnostic in diagnostics) {
        buffer.writeln('  - $diagnostic');
      }
    }
    return buffer.toString();
  }

  @override
  String toString() => 'BackendProbeResult($backendName, '
      'supported: $supported, ${capabilities.length} capabilities, '
      '${failures.length} failures)';
}

/// Raised when selection runs out of candidates. Carries every report so the
/// message can say what was tried and why each one was refused.
final class BackendSelectionError extends Error {
  BackendSelectionError({
    required this.requested,
    required List<BackendProbeResult> attempts,
  }) : attempts = List<BackendProbeResult>.unmodifiable(attempts);

  /// What the application asked for, if it asked for anything specific.
  final String? requested;
  final List<BackendProbeResult> attempts;

  @override
  String toString() {
    final buffer = StringBuffer('BackendSelectionError: no usable backend');
    if (requested != null) buffer.write(' (requested: $requested)');
    buffer.writeln();
    for (final attempt in attempts) {
      buffer.writeln(attempt.describe());
    }
    return buffer.toString();
  }
}

/// Raised when code asks a backend for something it never claimed to do.
///
/// Separate from [BackendSelectionError] because the fix is different: this
/// one is a bug in the caller, not a missing library on the machine.
final class UnsupportedCapabilityError extends Error {
  UnsupportedCapabilityError({
    required this.backendName,
    required this.capability,
    this.detail,
  });

  final String backendName;
  final Capability capability;
  final String? detail;

  @override
  String toString() => 'UnsupportedCapabilityError: $backendName does not '
      'support ${capability.name}${detail == null ? '' : ' ($detail)'}';
}
