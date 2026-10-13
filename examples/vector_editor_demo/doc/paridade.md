# Paridade com o CorelDRAW

> Gerado por `dart run tool/parity.dart` a partir do registro de comandos do editor. Não edite à mão.
> Referência: `doc/vector_editor_catalogo_coreldraw.md` (só documentação pública). Uma funcionalidade conta quando todos os comandos dela estão registrados ou quando um teste comprova o comportamento; "parcial" diz o que falta.

## Resumo

| | feitas | parciais | faltam | total | cobertura |
|---|---|---|---|---|---|
| P0 | 54 | 9 | 0 | 63 | 93% |
| P1 | 7 | 2 | 35 | 44 | 18% |
| P2 | 1 | 0 | 67 | 68 | 1% |
| **todas** | 62 | 11 | 102 | 175 | 39% |

Cobertura = (feitas + metade das parciais) / total.

Menus do editor: 82 de 97 linhas têm comando registrado; as outras aparecem desabilitadas.

Comandos registrados: 117.

## Por área

| área | feitas | parciais | faltam | total | cobertura |
|---|---|---|---|---|---|
| Caixa de ferramentas | 10 | 3 | 47 | 60 | 19% |
| Interações no canvas | 9 | 1 | 3 | 13 | 73% |
| Barra de propriedades | 5 | 2 | 9 | 16 | 38% |
| Dockers | 4 | 0 | 11 | 15 | 27% |
| Operações de objeto | 10 | 2 | 10 | 22 | 50% |
| Alinhar e distribuir (teclas) | 5 | 1 | 2 | 8 | 69% |
| Menus | 3 | 1 | 4 | 8 | 44% |
| Edição de nós | 10 | 0 | 4 | 14 | 71% |
| Encaixe, guias, réguas e grade | 3 | 1 | 3 | 7 | 50% |
| Página e documento | 3 | 0 | 5 | 8 | 38% |
| Formatos de arquivo | 0 | 0 | 4 | 4 | 0% |

### Caixa de ferramentas

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Pick | P0 | `tool.select` |  |
| ❌ | Freehand pick | P2 |  | tudo |
| ❌ | Free transform | P2 |  | tudo |
| ✅ | Shape (F10) | P0 | `tool.shape` |  |
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
| ✅ | Freehand (F5) | P0 | `tool.freehand` |  |
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
| 🟡 | Outline pen (F12) | P0 | `panel.fillStroke`, `object.outline`, `object.outlineWidth`, `object.outlineStyle` | no arrowheads or calligraphic pen |
| 🟡 | Fill (F11) | P0 | `panel.fillStroke`, `object.fill` | uniform colour; no fountain, pattern or texture fills |

### Interações no canvas

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Click selects | P0 | teste: "clicking a text selects it" |  |
| ✅ | Drag on empty space: marquee | P0 | teste: "a drag in empty space selects everything it encloses" |  |
| ❌ | Ctrl+click: inside a group | P1 |  | tudo |
| ✅ | Alt+click: the object below | P1 | teste: "a plain click takes the top object, Alt+click the one below it" |  |
| ❌ | Tab / Shift+Tab: next object | P2 |  | tudo |
| ✅ | Esc: deselect | P0 | `edit.deselect`, teste: "Esc drops the selection" |  |
| ✅ | Handles: scale, then rotate and skew | P0 | teste: "clicking a selected object toggles the frame, and again toggles back" |  |
| ❌ | Right-drag: copy here | P1 |  | tudo |
| 🟡 | Numpad +: duplicate in place | P1 | `edit.duplicate` | Ctrl+D duplicates; the numpad key is not bound |
| ✅ | Arrows: nudge | P0 | `object.nudge` |  |
| ✅ | Ctrl while dragging: constrain | P0 | teste: "Ctrl keeps a move on one axis" |  |
| ✅ | Shift while resizing | P0 | teste: "Shift keeps the aspect ratio while resizing" |  |
| ✅ | Delete | P0 | `edit.delete` |  |

### Barra de propriedades

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Pick, nothing selected: page and units | P0 | teste: "the property bar changes with the selection" |  |
| ✅ | Pick, selection: position, size, rotation | P0 | teste: "the property bar changes with the selection" |  |
| ✅ | Shape: nodes | P0 | `path.addNode`, `path.deleteNodes`, `path.toLine`, `path.toCurve`, `path.cusp`, `path.smooth`, `path.symmetrical` |  |
| ✅ | Rectangle: corners | P0 | teste: "a single rectangle brings up the rectangle plugin" |  |
| ❌ | Ellipse: arc and pie | P1 |  | tudo |
| ❌ | Polygon / Star: points | P1 |  | corner count only |
| 🟡 | Freehand, Bézier, Pen | P0 | `tool.freehandSmoothing` | Freehand smoothing; no arrowheads or line style on the bar |
| 🟡 | Text: content and size | P0 | `text.content`, `text.size` | content and size; no font, style or alignment |
| ❌ | Interactive fill | P1 |  | tudo |
| ❌ | Transparency | P1 |  | tudo |
| ❌ | Blend | P2 |  | tudo |
| ❌ | Contour | P2 |  | tudo |
| ❌ | Drop shadow | P1 |  | tudo |
| ❌ | Envelope | P2 |  | tudo |
| ❌ | Extrude | P2 |  | tudo |
| ✅ | Zoom | P0 | `view.zoomTo`, `view.zoomIn`, `view.zoomOut`, `view.zoomSelection`, `view.zoomPage`, `view.zoomPageWidth`, `view.zoomPageHeight` |  |

### Dockers

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Objects | P0 | `panel.objects` |  |
| ✅ | Properties (Alt+Enter) | P0 | `panel.properties`, `object.position`, `object.fillRule`, `rectangle.round`, `ellipse.type`, `polygon.corners` |  |
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
| ✅ | Combine (Ctrl+L) | P0 | `object.combine` |  |
| ✅ | Break apart (Ctrl+K) | P0 | `object.breakApart` |  |
| ✅ | Convert to curves (Ctrl+Q) | P0 | `object.toCurves` |  |
| ❌ | Convert outline to object | P1 |  | tudo |
| 🟡 | To front / back of page | P0 | `object.toFront`, `object.toBack` | of the layer; the page has one layer stack per layer |
| ✅ | To front / back of layer | P0 | `object.toFront`, `object.toBack` |  |
| ✅ | Forward one / Back one | P0 | `object.forward`, `object.backward` |  |
| ❌ | In front of / Behind / Reverse order | P2 |  | tudo |
| ❌ | Lock / Unlock objects | P1 |  | layers lock; single objects do not |
| ✅ | Weld | P0 | `object.weld` |  |
| ✅ | Trim | P0 | `object.trim` |  |
| ✅ | Intersect | P0 | `object.intersect` |  |
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
| ✅ | L / R | P0 | `object.alignLeft`, `object.alignRight`, teste: "L lines the selection up on the last object selected" |  |
| ✅ | T / B | P0 | `object.alignTop`, `object.alignBottom`, teste: "B aligns to the bottom with a selection, and is the pen without" |  |
| ✅ | C | P0 | `object.alignCentersVertically` |  |
| ✅ | E | P0 | `object.alignCentersHorizontally` |  |
| ✅ | P | P0 | `object.centerToPage`, teste: "P centres one object on the page" |  |
| 🟡 | Shift+L/R/T/B: distribute | P1 | `object.distribute` | distributes centres from the Align panel and by command; the Shift keys are not bound |
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
| ✅ | Node types (cusp, smooth, symmetrical) | P0 | `path.cusp`, `path.smooth`, `path.symmetrical` |  |
| ✅ | Line ↔ curve | P0 | `path.toLine`, `path.toCurve` |  |
| ✅ | Add node | P0 | `path.addNode` |  |
| ✅ | Delete node | P0 | `path.deleteNodes` |  |
| ✅ | Drag a segment | P0 | teste: "dragging a segment bends it under the pointer" |  |
| ✅ | Nudge nodes | P0 | teste: "the arrows nudge the picked nodes under the Shape tool" |  |
| ✅ | Select all nodes | P1 | `path.selectAllNodes` |  |
| ✅ | Join / Break | P0 | `path.joinNodes`, `path.breakNode` |  |
| ✅ | Reverse direction | P1 | `path.reverse` |  |
| ❌ | Extract subpath | P1 |  | tudo |
| ❌ | Reduce nodes | P1 |  | tudo |
| ❌ | Stretch, rotate, skew, align nodes | P2 |  | tudo |
| ❌ | Elastic mode | P2 |  | tudo |
| ✅ | Parametric shapes: corner handles | P0 | teste: "the Shape tool rounds a rectangle by its corner, in one undo" |  |

### Encaixe, guias, réguas e grade

| | funcionalidade | prio | como | falta |
|---|---|---|---|---|
| ✅ | Snap to grid | P0 | `view.snapGrid`, teste: "a move lands an edge of the box on a grid line" |  |
| ❌ | Snap off (Alt+Q) | P1 |  | tudo |
| ❌ | Dynamic / alignment guides | P1 |  | tudo |
| ✅ | Rulers | P0 | teste: "both rulers are mounted, one per axis" |  |
| 🟡 | Guides | P0 | `view.guides`, `guide.add`, `guide.clear` | dragged out of a ruler; not yet moved or removed by dragging the guide itself |
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

