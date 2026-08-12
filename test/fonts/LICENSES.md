# Test fonts

Fonts are the one asset where "it was already in the references folder" is not a
license. Every file here is redistributable under a permissive license, and each
one is listed below with its upstream and its terms. **Nothing from
`C:\Windows\Fonts` may ever be added** — Segoe UI, Arial, Calibri and the rest
are proprietary, and a test that needs a system font must discover it at runtime
and skip with a reason when it is absent.

Why these three and not one: each exercises a different branch of the parser, so
a bug that only shows up on one font layout still fails a test.

| File | Upstream | License | What it is here for |
|---|---|---|---|
| `Roboto-Regular.ttf` | Google Fonts / Android, via the Flutter engine's `txt/third_party/fonts` | **Apache License 2.0** | The general-purpose face. 1294 glyphs, `unitsPerEm` 2048, and — the reason it is first — `indexToLocFormat = 0`, the **short** `loca` format, where offsets are stored halved and must be doubled. |
| `DejaVuSans.ttf` | DejaVu Fonts, via Avalonia's Skia unit tests | **Bitstream Vera + Arev**, permissive, **no reserved font name** | The wide-coverage face: 6253 glyphs, every Portuguese accent, composite glyphs, a legacy `kern` table *and* `GSUB`/`GPOS`, and `indexToLocFormat = 1`, the **long** `loca` format. Also the only one here that may be freely subsetted, because it carries no reserved-name clause. |
| `ahem.ttf` | W3C test font, via the Flutter engine | **Public domain** (W3C test suite font, no rights reserved) | Every glyph is a solid em box. Advances are exact integers and coverage is either 0 or 255, so metric and layout assertions can be exact rather than approximate. `unitsPerEm` 1000, no `GSUB`/`GPOS` — it also proves the parser tolerates their absence. |

## Rules for adding a font here

1. It must be redistributable. Record the upstream URL or repository path, the
   version or commit, and the SPDX identifier in the table above.
2. Prefer fonts **without** a reserved font name (SIL OFL's RFN clause). A
   subset is a modification, and under RFN a modification may not keep the
   original name — which turns "make a smaller fixture" into a renaming
   exercise.
3. Commit the license text alongside the file when the license requires it to
   travel with the font.
4. If a test only needs *a* font rather than *this* font, prefer discovering a
   system font at runtime and skipping when it is missing.

## Apache-2.0 obligations for Roboto

Apache-2.0 requires that redistribution carry the license and any NOTICE. The
license text is in `Apache-2.0.txt` in this directory, and the framework's
`NOTICE` file at the repository root records the attribution.
