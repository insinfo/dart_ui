/// Picking a colour from anywhere on the screen - an eyedropper.
library;

/// A window that can sample a colour from the screen.
///
/// A capability, tested for with a pattern. Only the platform's own sampler
/// is used, never a screenshot this process takes: reading other windows'
/// pixels is something macOS gates behind the Screen Recording permission,
/// and its `NSColorSampler` - the loupe every Mac colour well opens - is the
/// one way that needs none, because the user's click is the consent.
///
/// macOS has it; the other backends do not yet.
abstract interface class ScreenColorSampling {
  /// Shows the platform's sampler and completes with the colour the user
  /// clicked, as 0xAARRGGBB in sRGB, or null when they cancelled - Escape,
  /// or a click that chose nothing. One at a time: a second call while the
  /// sampler is up completes with null at once.
  ///
  /// An integer rather than a `Color` because this layer is below graphics;
  /// `WindowController.sampleScreenColor` is the typed one widgets use.
  Future<int?> sampleScreenColor();
}
