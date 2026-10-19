# Secondary-click context replacement — 2026-10-19

An open context menu consumed every outside press. A secondary click on a
different file therefore only dismissed the old menu; a second click was needed
to select the new target and open its menu. This policy was shared by the native
window host and overlay hosts rather than being a macOS renderer limitation.

Secondary presses now close the existing menu chain before targeting the content
at the same pointer position. Primary dismissing presses retain their existing
behavior. The change applies to native popup windows, PopupLayer overlays and the
legacy ContextMenuScope overlay. Closed overlay render children are excluded from
hit testing immediately, before the scheduled rebuild; the old layer cannot
close the replacement menu as the same press bubbles through it. No event is
delivered twice. Hover shielding while a menu is open remains unchanged.

## Regression coverage

- Every explorer view mode: one secondary click switches from one file's open
  menu to another file, from a file to blank folder space, and back to a file.
  Selection and menu contents follow the hit target; only one popup remains.
- Native-window host: closes a menu/submenu chain and dispatches the same press
  once to the owner, which opens the replacement menu.
- Legacy overlay: replacement anchor changes on the first secondary click.
- Existing primary-dismissal, popup hover shielding, pointer capture, menu-bar,
  text-field context-menu and gesture tests continue to pass.

## Validation

- macOS: widgets/gestures/app/architecture suites, **2143 passed**.
- Ubuntu 24.04 ARM64: same suites, **2141 passed, 2 platform skips**.
- Windows 11 ARM64: routing/menu/gesture/app-context/architecture tests,
  **327 passed**. The broader SYSTEM-session run aborted in the unchanged WGL
  startup probe (`ChoosePixelFormat`, access violation in native DLL loading).
  The complete startup test file was then run in the interactive user session:
  **13 passed**, including WGL probing. The broad SYSTEM run is not counted as
  passing; no OpenGL or SDK code was changed for this fix.
- Explorer on all three systems: analyzer clean, **74 passed, 1 platform skip**.
- Root analyzer clean. AOT builds succeeded on all three systems and applications
  were reopened with the corrected runtime.
- `tool/context_menu_retarget_smoke.dart` passed against real native popup
  lifetimes on macOS/AppKit, Windows/Direct3D 11, Wayland/OpenGL and X11/OpenGL.
  This smoke dispatches presses through the application's normal owner input
  route and checks native menu disposal, replacement, selection and app errors;
  it does not synthesize operating-system mouse input.
