# Windows caption input and cursor — 2026-10-19

The user reported a missing cursor over the explorer and unresponsive minimize,
maximize and close controls. No previous input tests were running. Read-only
inspection found the explorer enabled, with no native capture, move/size loop or
menu owner active. This was not a retained test mouse grab.

The custom caption painted framework controls and returned native hit codes,
but delegated their presses to DefWindowProc instead of delivering them to the
painted controls. These presses now translate screen coordinates to client
coordinates and enter the framework pointer route. Native mouse capture delivers
the matching client release, including releases outside the control that cancel
activation. Border and title drag messages retain native handling; maximize hit
code HTMAXBUTTON remains for Windows integration. The class now has a real arrow
fallback, and custom caption WM_SETCURSOR explicitly supplies an arrow without
replacing the client's requested text/other cursor.

## Validation

- Native HWND tests: **8 passed**, including caption down/up delivery, coordinate
  conversion, capture release, arrow/text cursor transitions and existing frame
  geometry/fullscreen checks.
- `tool/win32_caption_controls_smoke.dart`, interactive Windows 11 ARM64 with
  Direct3D 11: `CAPTION_CONTROLS=PASS cursor=PASS capture=RELEASED`. Queued messages
  to this test application's own HWND exercised the painted controls through the
  normal backend and widget route: maximize, restore, canceled release outside,
  minimize, restore and close. Cursor handles and capture release were asserted.
  This is an application integration test, not physical mouse automation.
- Shared window-widget/architecture tests on macOS: **34 passed**. Root and
  explorer analyzers clean. Explorer tests on Windows: **74 passed, 1 skip**.
- The broader Win32/widget/architecture sweep had **505 passed, 14 skipped,
  4 failed**. All four failures are Direct2D glyph-transform pixel comparisons
  (maximum differences 67–78, tolerance 64). That offscreen text-rendering code
  is unchanged; the sweep is not reported as fully passing.
- The Windows AOT explorer was rebuilt and reopened. Its former executable was
  stopped before replacement; no periodic agents or input automation were left
  running.

Reference: https://learn.microsoft.com/en-us/windows/win32/dwm/customframe
