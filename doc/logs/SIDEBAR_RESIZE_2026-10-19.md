# Resizable Explorer navigation pane — 2026-10-19

The Explorer previously wrapped its sidebar in a fixed 232-pixel box. It now
uses the framework's existing SplitView with a six-pixel grab strip. The
navigation pane can be dragged in either direction; its minimum is 160 logical
pixels, and the file pane retains at least 320 while the window has room.

The model stores the preferred width separately from folder view settings.
Dragging notifies the existing debounced, atomic PreferencesStore. The width
survives navigation, hiding/reopening the pane and application restarts. A
window resize clamps only the displayed width, retaining the preference for
when the window grows again. Old preference files retain the original 232
pixel default; invalid, non-finite or undersized stored values are ignored.

SplitView's divider now exposes the appropriate horizontal or vertical resize
cursor. Its existing pointer capture, keyboard controls and accessibility
semantics are reused.

Validation:

- Framework and Explorer static analysis clean on macOS, Windows and Ubuntu.
- 35 directed splitter/architecture tests and 67 Explorer tests passed on all
  three platforms. The final selection-preservation assertion also passed in
  the complete local window suite (20 tests).
- The Explorer regression drags through the actual pointer router, verifies
  width changes, selection preservation, minimum clamping, narrow-window
  clamping without overwriting the preference, and hiding/reopening the pane.
- Preferences tests verify real disk round trips and corrupt input handling.
- AOT applications rebuilt for all three systems and reopened. The Windows
  application capture confirms the divider is present in the compiled UI.
