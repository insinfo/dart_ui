# Paridade com o CorelDRAW

> Gerado por `dart run tool/parity.dart` a partir do registro de comandos do editor. Não edite à mão.
> Referência: `doc/vector_editor_catalogo_coreldraw.md` (só documentação pública). Uma funcionalidade conta quando todos os comandos dela estão registrados ou quando um teste comprova o comportamento; "parcial" diz o que falta.

## Resumo

| | feitas | parciais | faltam | total | cobertura |
|---|---|---|---|---|---|
| P0 | 29 | 8 | 26 | 63 | 52% |
| P1 | 5 | 1 | 38 | 44 | 13% |
| P2 | 1 | 0 | 67 | 68 | 1% |
| **todas** | 35 | 9 | 131 | 175 | 23% |

Cobertura = (feitas + metade das parciais) / total.

Menus do editor: 51 de 72 linhas têm comando registrado; as outras aparecem desabilitadas.

Comandos registrados: 74.

## Por área

| área | feitas | parciais | faltam | total | cobertura |
|---|---|---|---|---|---|
| Caixa de ferramentas | 8 | 3 | 49 | 60 | 16% |
| Interações no canvas | 7 | 2 | 4 | 13 | 62% |
| Barra de propriedades | 3 | 0 | 13 | 16 | 19% |
| Dockers | 3 | 0 | 12 | 15 | 20% |
| Operações de objeto | 5 | 2 | 15 | 22 | 27% |
| Alinhar e distribuir (teclas) | 0 | 0 | 8 | 8 | 0% |
| Menus | 3 | 1 | 4 | 8 | 44% |
| Edição de nós | 0 | 0 | 14 | 14 | 0% |
| Encaixe, guias, réguas e grade | 3 | 1 | 3 | 7 | 50% |
| Página e documento | 3 | 0 | 5 | 8 | 38% |
| Formatos de arquivo | 0 | 0 | 4 | 4 | 0% |

### Caixa de ferramentas

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Pick | P0 | `tool.select` |  |
| ❌ | Freehand pick | P2 |  | tudo |
| ❌ | Free transform | P2 |  | tudo |
| ❌ | Shape (F10) | P0 |  | tudo |
| ❌ | Smooth | P2 |  | tudo |
| ❌ | Smear | P2 |  | tudo |
| ❌ | Twirl | P2 |  | tudo |
| ❌ | Attract / Repel | P2 |  | tudo |
| ❌ | Smudge / Roughen | P2 |  | tudo |
| ❌ | Crop | P2 |  | tudo |
| ❌ | Knife | P1 |  | tudo |
| ❌ | Virtual segment delete | P2 |  | tudo |
| ❌ | Eraser (X) | P2 |  | tudo |
| ✅ | Zoom (Z) | P0 | `tool.zoom` |  |
| ✅ | Pan (H) | P0 | `tool.pan` |  |
| ❌ | Freehand (F5) | P0 |  | tudo |
| ❌ | 2-point line | P1 |  | tudo |
| ✅ | Bézier | P0 | `tool.pen` |  |
| ✅ | Pen | P0 | `tool.pen` |  |
| ❌ | B-spline | P2 |  | tudo |
| ❌ | Polyline | P1 |  | tudo |
| ❌ | 3-point curve | P2 |  | tudo |
| ❌ | Smart drawing | P2 |  | tudo |
| ❌ | LiveSketch | P2 |  | tudo |
| ❌ | Artistic media | P2 |  | tudo |
| ✅ | Rectangle (F6) | P0 | `tool.rectangle`, `shape.rectangle` |  |
| ❌ | 3-point rectangle | P2 |  | tudo |
| ✅ | Ellipse (F7) | P0 | `tool.ellipse`, `shape.ellipse` |  |
| ❌ | 3-point ellipse | P2 |  | tudo |
| ✅ | Polygon (Y) | P1 | `tool.polygon`, `shape.polygon` |  |
| ❌ | Star | P1 |  | a polygon with a sharpness, but no Star tool or command |
| ❌ | Complex star | P2 |  | tudo |
| ❌ | Graph paper | P2 |  | tudo |
| ❌ | Spiral | P2 |  | tudo |
| ❌ | Common shapes (arrow, flowchart...) | P2 |  | tudo |
| ❌ | Impact | P2 |  | tudo |
| 🟡 | Text (F8) | P0 | `tool.text`, `shape.text` | artistic text only; no paragraph text |
| ❌ | Table | P2 |  | tudo |
| ❌ | Parallel dimension | P2 |  | tudo |
| ❌ | Horizontal/vertical dimension | P2 |  | tudo |
| ❌ | Angular dimension | P2 |  | tudo |
| ❌ | Segment dimension | P2 |  | tudo |
| ❌ | 3-point callout | P2 |  | tudo |
| ❌ | Connectors | P2 |  | tudo |
| ❌ | Edit anchor | P2 |  | tudo |
| ❌ | Drop shadow | P1 |  | tudo |
| ❌ | Block shadow | P2 |  | tudo |
| ❌ | Contour | P2 |  | tudo |
| ❌ | Blend | P2 |  | tudo |
| ❌ | Distort | P2 |  | tudo |
| ❌ | Envelope | P2 |  | tudo |
| ❌ | Extrude | P2 |  | tudo |
| ❌ | Transparency | P1 |  | tudo |
| ❌ | Color eyedropper | P1 |  | tudo |
| ❌ | Attributes eyedropper | P1 |  | tudo |
| ❌ | Interactive fill (G) | P1 |  | tudo |
| ❌ | Mesh fill | P2 |  | tudo |
| ❌ | Smart fill | P2 |  | tudo |
| 🟡 | Outline pen (F12) | P0 | `panel.fillStroke`, `object.outline` | colour and width; no dashes, caps or joins |
| 🟡 | Fill (F11) | P0 | `panel.fillStroke`, `object.fill` | uniform colour; no fountain, pattern or texture fills |

### Interações no canvas

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Click selects | P0 | teste: "clicking a text selects it" |  |
| ✅ | Drag on empty space: marquee | P0 | teste: "a drag in empty space selects everything it encloses" |  |
| ❌ | Ctrl+click: inside a group | P1 |  | tudo |
| ✅ | Alt+click: the object below | P1 | teste: "a plain click takes the top object, Alt+click the one below it" |  |
| ❌ | Tab / Shift+Tab: next object | P2 |  | tudo |
| ❌ | Esc: deselect | P0 |  | tudo |
| ✅ | Handles: scale, then rotate and skew | P0 | teste: "clicking a selected object toggles the frame, and again toggles back" |  |
| ❌ | Right-drag: copy here | P1 |  | tudo |
| 🟡 | Numpad +: duplicate in place | P1 | `edit.duplicate` | Ctrl+D duplicates; the numpad key is not bound |
| ✅ | Arrows: nudge | P0 | `object.nudge` |  |
| 🟡 | Ctrl while dragging: constrain | P0 | teste: "Ctrl draws a circle, Shift grows it from the press point" | constrains creation; moving is not constrained |
| ✅ | Shift while resizing | P0 | teste: "Shift keeps the aspect ratio while resizing" |  |
| ✅ | Delete | P0 | `edit.delete` |  |

### Barra de propriedades

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Pick, nothing selected: page and units | P0 | teste: "the property bar changes with the selection" |  |
| ✅ | Pick, selection: position, size, rotation | P0 | teste: "the property bar changes with the selection" |  |
| ❌ | Shape: nodes | P0 |  | tudo |
| ✅ | Rectangle: corners | P0 | teste: "a single rectangle brings up the rectangle plugin" |  |
| ❌ | Ellipse: arc and pie | P1 |  | tudo |
| ❌ | Polygon / Star: points | P1 |  | corner count only |
| ❌ | Freehand, Bézier, Pen | P0 |  | tudo |
| ❌ | Text: content and size | P0 |  | content and size; no font, style or alignment |
| ❌ | Interactive fill | P1 |  | tudo |
| ❌ | Transparency | P1 |  | tudo |
| ❌ | Blend | P2 |  | tudo |
| ❌ | Contour | P2 |  | tudo |
| ❌ | Drop shadow | P1 |  | tudo |
| ❌ | Envelope | P2 |  | tudo |
| ❌ | Extrude | P2 |  | tudo |
| ❌ | Zoom | P0 |  | tudo |

### Dockers

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Objects | P0 | `panel.objects` |  |
| ❌ | Properties (Alt+Enter) | P0 |  | tudo |
| ✅ | Transform | P1 | `panel.transform` |  |
| ✅ | Align and Distribute | P0 | `panel.align` |  |
| ❌ | Color styles / harmonies | P2 |  | tudo |
| ❌ | Object styles | P2 |  | tudo |
| ❌ | Pages | P1 |  | tudo |
| ❌ | Text (character, paragraph) | P1 |  | tudo |
| ❌ | Glyphs | P2 |  | tudo |
| ❌ | Symbols | P2 |  | tudo |
| ❌ | Contour / Envelope / Lens | P2 |  | tudo |
| ❌ | Undo history | P1 |  | tudo |
| ❌ | Export | P2 |  | tudo |
| ❌ | Effects | P2 |  | tudo |
| ❌ | Hints | P2 |  | tudo |

### Operações de objeto

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Group / Ungroup | P0 | `object.group`, `object.ungroup` |  |
| ❌ | Combine (Ctrl+L) | P0 |  | tudo |
| ❌ | Break apart (Ctrl+K) | P0 |  | tudo |
| ✅ | Convert to curves (Ctrl+Q) | P0 | `object.toCurves` |  |
| ❌ | Convert outline to object | P1 |  | tudo |
| 🟡 | To front / back of page | P0 | `object.toFront`, `object.toBack` | of the layer; the page has one layer stack per layer |
| ✅ | To front / back of layer | P0 | `object.toFront`, `object.toBack` |  |
| ✅ | Forward one / Back one | P0 | `object.forward`, `object.backward` |  |
| ❌ | In front of / Behind / Reverse order | P2 |  | tudo |
| ❌ | Lock / Unlock objects | P1 |  | layers lock; single objects do not |
| ❌ | Weld | P0 |  | tudo |
| ❌ | Trim | P0 |  | tudo |
| ❌ | Intersect | P0 |  | tudo |
| ❌ | Simplify | P2 |  | tudo |
| ❌ | Front minus back / Back minus front | P1 |  | tudo |
| ❌ | Boundary | P2 |  | tudo |
| ❌ | Join curves / Close path | P1 |  | tudo |
| ❌ | PowerClip | P1 |  | tudo |
| 🟡 | Mirror, rotate | P0 | `object.flip`, `object.rotate` | no Clear transformations |
| ✅ | Align & distribute | P0 | `object.align`, `panel.align` |  |
| ❌ | Barcode, QR code | P2 |  | tudo |
| ❌ | Symmetry | P2 |  | tudo |

### Alinhar e distribuir (teclas)

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ❌ | L / R | P0 |  | tudo |
| ❌ | T / B | P0 |  | tudo |
| ❌ | C | P0 |  | tudo |
| ❌ | E | P0 |  | tudo |
| ❌ | P | P0 |  | tudo |
| ❌ | Shift+L/R/T/B: distribute | P1 |  | tudo |
| ❌ | Shift+C / Shift+E | P1 |  | tudo |
| ❌ | Shift+P / Shift+A | P1 |  | tudo |

### Menus

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| 🟡 | Edit | P0 | `edit.undo`, `edit.cut`, `edit.paste` | no Paste Special, Find and Replace or Select by type |
| ❌ | Layout | P1 |  | the menu is there; every item is still planned |
| ✅ | Object | P0 | `object.group` |  |
| ❌ | Effects | P2 |  | tudo |
| ❌ | Text | P1 |  | the menu is there; every item is still planned |
| ❌ | Table | P2 |  | tudo |
| ✅ | Window | P1 | `panel.objects`, `window.resetWorkspace` |  |
| ✅ | Help | P2 | `help.about` |  |

### Edição de nós

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ❌ | Node types (cusp, smooth, symmetrical) | P0 |  | tudo |
| ❌ | Line ↔ curve | P0 |  | tudo |
| ❌ | Add node | P0 |  | tudo |
| ❌ | Delete node | P0 |  | tudo |
| ❌ | Drag a segment | P0 |  | tudo |
| ❌ | Nudge nodes | P0 |  | tudo |
| ❌ | Select all nodes | P1 |  | tudo |
| ❌ | Join / Break | P0 |  | tudo |
| ❌ | Reverse direction | P1 |  | tudo |
| ❌ | Extract subpath | P1 |  | tudo |
| ❌ | Reduce nodes | P1 |  | tudo |
| ❌ | Stretch, rotate, skew, align nodes | P2 |  | tudo |
| ❌ | Elastic mode | P2 |  | tudo |
| ❌ | Parametric shapes: corner handles | P0 |  | tudo |

### Encaixe, guias, réguas e grade

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Snap to grid | P0 | `view.snapGrid`, teste: "a move lands an edge of the box on a grid line" |  |
| ❌ | Snap off (Alt+Q) | P1 |  | tudo |
| ❌ | Dynamic / alignment guides | P1 |  | tudo |
| ✅ | Rulers | P0 | teste: "both rulers are mounted, one per axis" |  |
| 🟡 | Guides | P0 | `view.guides` | shown; not created by dragging from a ruler |
| ✅ | Grid | P1 | `view.grid` |  |
| ❌ | Master page | P2 |  | tudo |

### Página e documento

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Page size | P0 | teste: "the property bar changes with the selection" |  |
| ✅ | Orientation | P0 | teste: "the property bar changes with the selection" |  |
| ❌ | Rendering resolution | P1 |  | tudo |
| ❌ | Bleed | P2 |  | tudo |
| ❌ | Page background | P1 |  | tudo |
| ❌ | Multiple pages | P1 |  | tudo |
| ❌ | Layout styles | P2 |  | tudo |
| ✅ | Desktop area | P0 | teste: "the canvas still draws its page and its artwork" |  |

### Formatos de arquivo

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ❌ | AI, EPS, PS | P2 |  | tudo |
| ❌ | PSD, CPT, RAW, JP2 | P2 |  | tudo |
| ❌ | WMF / EMF, CGM, WPG, VSD... | P2 |  | tudo |
| ❌ | TTF / PFB | P2 |  | tudo |

