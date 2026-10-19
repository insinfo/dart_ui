# Name column filter — 2026-10-19

The Name header in the file explorer's Details view now has a separate dropdown
for initial-name ranges. Clicking the title continues to sort; clicking the
arrow opens a multi-choice filter. Resize grips retain their existing behavior.

The ranges are 0–9, A–H, I–P, Q–Z and Other. Only ranges represented in the
unfiltered listing or currently selected appear. Choices combine with OR, update
the listing immediately and leave the popup open. Clear filter restores all
entries allowed by the existing hidden/system-file settings. Escape and outside
click dismiss the popup. A filtered header uses the accent color.

Filtering belongs to the current tab and location, survives refresh/sort, and
resets on navigation. It does not alter files or the source listing. Selections
hidden by a filter are removed. The Details header remains available even when
no files match, so the user can recover without navigating away. Latin accents
are grouped with their base letter; other scripts and punctuation have an
explicit Other range. These are Name filters, not additional sort directions or
filters for the other metadata columns.

`DataGridColumn.filterable` and `filtered`, together with
`DataGrid.onColumnFilter`, expose the affordance without coupling the shared grid
to file-system predicates. The callback receives the column header's rectangle
in owner-window coordinates, including RTL layout and horizontal scrolling.

## Validation

On macOS, Windows 11 ARM64 and Ubuntu 24.04 ARM64:

- Framework DataGrid, popup-host and architecture regression: 71 passed.
- File explorer suite: 77 passed, 1 platform-specific skip.
- Analyzer: no issues in framework sources/tests/tools and the example.
- AOT builds completed and the canonical applications were reopened.

Tests dispatch pointer events through the widget tree to open the Name popup,
choose a checkbox, clear the filter and dismiss it with Escape. They also cover
OR membership, refresh, navigation reset, retained choices, an empty result,
accented names, RTL geometry and release-outside cancellation. This is automated
widget validation; live mouse interaction could not be verified because the
computer-use service timed out selecting the application.
