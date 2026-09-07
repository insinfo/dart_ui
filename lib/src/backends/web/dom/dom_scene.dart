/// The display list, expressed as a DOM tree that is *edited* rather than
/// rebuilt.
///
/// ## The one decision the whole file turns on
///
/// A `present` that rebuilt the tree would be correct and useless. Replacing a
/// DOM node destroys everything the browser was holding for it: the focus ring,
/// the text selection, the caret, the scroll offset of any ancestor that
/// scrolls, an IME composition in progress, and the accessibility node a screen
/// reader's cursor is parked on. All of those are exactly the things a DOM
/// backend exists to provide, so a rebuild-per-frame backend would be a slower
/// canvas that also flickers.
///
/// So the tree is retained across frames and reconciled, in the shape jaspr
/// arrived at and for the same stated reasons:
///
///   * **an element is never swapped under a slot.** A slot binds to one
///     `web.Element` for its whole life; when the command at that position
///     changes *kind*, the slot is replaced outright rather than mutated into
///     something else, and only then does a node die;
///   * **nothing is written to the DOM unless the value changed.** Every slot
///     caches the exact style string, text and attribute values it last wrote,
///     and a write is skipped on a compare. This is not a micro-optimisation:
///     assigning `style` re-runs layout, and re-inserting a node blurs it in
///     some engines;
///   * **children are matched by position, not by key.** A display list has no
///     keys - it is a flat command stream - but it is also produced by the same
///     widget tree every frame, so position is a very good identity. The cost
///     of being wrong is a subtree rebuilt, and the cost of the alternative is
///     a key mechanism the display list cannot feed.
///
/// ## Why this walks the list itself instead of using `DisplayListPlayer`
///
/// `DisplayListPlayer` is the shared interpreter and it is the right tool for
/// every consumer that rasterises: it composes the transform stack, intersects
/// clips, culls, and hands `RasterSink` device-space primitives with the matrix
/// already applied. That flattening is what a DOM backend must not accept.
///
/// A clip in the player is a rectangle carried alongside each primitive; in the
/// DOM it is an ancestor with `overflow: hidden`, and only the ancestor form
/// clips the *text selection* and the scroll behaviour too. A transform in the
/// player is a matrix folded into every coordinate, and under rotation the
/// player's own documentation says a rectangle degrades to its bounding box -
/// while CSS `transform: matrix(...)` is exact for the whole affine family.
/// Walking the stream here keeps the nesting, so a clip becomes nesting and a
/// rotation becomes a rotation.
///
/// ## Device pixels are deliberately not applied
///
/// [SurfacePresenter.present] carries a `deviceTransform` that scales logical
/// units to physical pixels, and this backend ignores it. A CSS pixel already
/// *is* a logical unit: the browser multiplies by `devicePixelRatio` on the way
/// to the display, and a backend that pre-multiplied would draw everything
/// twice the size on a retina screen. The consequence worth naming is a good
/// one - text and borders are resolution-independent here, because the browser
/// rasterises them at whatever the display is, not at whatever the framework
/// guessed.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_opcodes.dart';
import '../../../graphics/display_list_reader.dart';
import '../../../rendering/framebuffer.dart';
import '../../../text/typeface.dart';
import 'dom_text.dart';

/// What a slot holds, so a reconciliation can tell "the same box moved" from
/// "a different thing is here now".
enum DomSlotKind {
  /// A filled or stroked axis-aligned box.
  box,

  /// A run of text.
  text,

  /// A raster image.
  image,

  /// A group that exists only to carry a CSS transform.
  transform,

  /// The outer half of a clip: a box with `overflow: hidden`.
  clip,

  /// A group that exists only to carry a `saveLayer`'s opacity.
  layer,
}

/// How the DOM layer treats the pointer, which is a genuine conflict rather
/// than a preference.
///
/// The framework's input path runs through the `<canvas>` this backend draws
/// *over*: `WebWindow` installs its listeners there, `dom_input_translation.dart`
/// turns them into framework events, and hit testing happens in the render
/// tree. A DOM element that accepts a pointer event takes it out of that path.
///
/// A user selecting text with the mouse and a user pressing a button are the
/// same gesture up to the moment the mouse moves, so no policy can serve both.
/// The choice is therefore the caller's and is named rather than guessed.
enum DomPointerPolicy {
  /// Every DOM element is `pointer-events: none`, so every press, drag and
  /// wheel reaches the canvas and the framework behaves exactly as it does on
  /// the GPU paths.
  ///
  /// Text remains findable with Ctrl+F, remains selectable through
  /// `window.getSelection()` and Select All, and remains readable by a screen
  /// reader. What it loses is mouse drag-selection.
  passThrough,

  /// Text runs accept the pointer, everything else does not.
  ///
  /// Mouse drag-selection of text works. The cost, and it is not small: a press
  /// that lands on a glyph never reaches the framework, so a button whose label
  /// covers most of it stops responding to clicks on the label. Choose this for
  /// a document, never for an application.
  selectableText,
}

/// Something the DOM cannot express, with the reason, counted.
///
/// Counted rather than thrown because a frame is not the place to fail: one
/// unsupported command in a thousand should degrade one widget, not blank the
/// page. Counted rather than ignored because a backend that silently drops a
/// tenth of the interface is a bug generator - which is the whole reason this
/// type exists at all.
typedef DomRefusal = ({String what, String why});

/// The retained DOM tree for one surface, and the walk that reconciles it.
final class DomScene {
  DomScene(this.root, {this.pointerPolicy = DomPointerPolicy.passThrough})
      : _rootSlot = _DomSlot(root, DomSlotKind.transform, root);

  /// The element every visual node lives under. Owned by the caller.
  final web.Element root;

  final DomPointerPolicy pointerPolicy;

  final _DomSlot _rootSlot;

  final List<_Frame> _frames = <_Frame>[];
  final List<int> _saveDepths = <int>[];

  /// Refusal reason to how many commands it swallowed, since construction.
  ///
  /// Cumulative rather than per frame, because the question a human asks is
  /// "does this interface contain anything this backend cannot draw", and that
  /// is answered by the total.
  final Map<String, int> refusals = <String, int>{};

  /// Called the first time each distinct refusal reason is seen. A page wires
  /// it to the console; a test collects it.
  void Function(DomRefusal refusal)? onRefusal;

  /// Glyphs that could not be turned back into characters. See `dom_text.dart`
  /// - this is the count of the display list's single largest omission.
  int unresolvedGlyphs = 0;

  /// How many elements were created, and how many were reused, on the last
  /// reconciliation.
  ///
  /// The observable proof that the diff works. A steady-state frame must
  /// create zero: if it does not, focus and selection are being destroyed every
  /// frame and no amount of visual correctness makes up for it.
  int lastCreated = 0;
  int lastReused = 0;
  int lastRemoved = 0;

  /// Rasterised images, keyed by the identity of the resource the display list
  /// interned.
  ///
  /// Identity because that is the equality `DisplayList.addImage` uses: a
  /// `Framebuffer` defines no `==`, so two draws share an id only when they
  /// share the object, and this table has to agree or it would re-upload the
  /// same pixels under a second key every frame.
  /// The value is a `data:` URL and not the canvas, because building one costs
  /// a PNG encode: a cache that held the element would re-encode on every
  /// frame, which is the single most expensive thing this backend could
  /// accidentally do per frame.
  final Map<Object, String> _imageUrls = Map<Object, String>.identity();

  /// Reconciles the tree against [list].
  void update(DisplayList list) {
    lastCreated = 0;
    lastReused = 0;
    lastRemoved = 0;
    unresolvedGlyphs = 0;

    _frames
      ..clear()
      ..add(_Frame(_rootSlot));
    _saveDepths.clear();

    final DisplayListReader reader = DisplayListReader(list);
    while (reader.moveNext()) {
      switch (reader.opcode) {
        case opSave:
          _saveDepths.add(_frames.length);
        case opRestore:
          _restore();
        case opSaveLayer:
          _saveLayer(reader, list);
        case opTransform:
          _transform(reader);
        case opClipRect:
          _clipRect(reader);
        case opClipPath:
          _refuse(
            'clipPath',
            'a clip in the DOM is an ancestor with overflow:hidden or a '
                'clip-path, and neither can take an arbitrary path from the '
                'display list without first flattening it to an SVG path '
                'string - which is a path backend, not a clip',
          );
        case opDrawRect:
          _drawRect(reader, list);
        case opDrawRRect:
          _drawRRect(reader, list);
        case opDrawPath:
          _refuse(
            'drawPath',
            'the display list stores a path as an opaque Object with no '
                'segment accessor a backend outside rendering/ may read, so '
                'there is nothing here to turn into an SVG "d" attribute',
          );
        case opDrawImage:
          _drawImage(reader, list);
        case opDrawGlyphRun:
          _drawGlyphRun(reader, list);
      }
    }

    // Anything the frame did not reach is gone. Trimming from the innermost
    // outward, because trimming a parent first would detach children whose
    // slots are still being read.
    while (_frames.length > 1) {
      _finishFrame(_frames.removeLast());
    }
    _finishFrame(_frames.first);
  }

  /// Drops every element and forgets every cached image.
  void clear() {
    _rootSlot.removeChildrenFrom(0);
    _imageUrls.clear();
    _frames.clear();
    _saveDepths.clear();
  }

  // -----------------------------------------------------------------------
  // Structure
  // -----------------------------------------------------------------------

  _Frame get _frame => _frames.last;

  void _restore() {
    if (_saveDepths.isEmpty) {
      // A restore with no save is a producer bug, and swallowing it is the
      // right answer here rather than throwing: the alternative is a page that
      // goes blank on a malformed frame, and every other consumer of this list
      // would have drawn it.
      _refuse('restore', 'a restore arrived with no matching save');
      return;
    }
    final int depth = _saveDepths.removeLast();
    while (_frames.length > depth) {
      _finishFrame(_frames.removeLast());
    }
  }

  void _finishFrame(_Frame frame) {
    lastRemoved += frame.slot.removeChildrenFrom(frame.index);
  }

  /// The slot at the current position, reused when its kind matches.
  _DomSlot _slotFor(DomSlotKind kind, String tag) {
    final _Frame frame = _frame;
    final _DomSlot parent = frame.slot;
    final int index = frame.index++;
    if (index < parent.children.length) {
      final _DomSlot existing = parent.children[index];
      if (existing.kind == kind && existing.tag == tag) {
        lastReused++;
        return existing;
      }
      final _DomSlot replacement = _create(kind, tag);
      parent.content.replaceChild(replacement.element, existing.element);
      parent.children[index] = replacement;
      lastCreated++;
      lastRemoved++;
      return replacement;
    }
    final _DomSlot created = _create(kind, tag);
    parent.content.append(created.element);
    parent.children.add(created);
    lastCreated++;
    return created;
  }

  _DomSlot _create(DomSlotKind kind, String tag) {
    final web.Element element = web.document.createElement(tag);
    if (kind == DomSlotKind.clip) {
      // Two elements, and the inner one is not decoration. The outer box is
      // positioned at the clip rectangle so that `overflow: hidden` cuts at the
      // right place; the inner one is offset by the negative of that, which
      // puts its children back into the coordinate system every other command
      // in the stream is written in. Without it, every coordinate inside a
      // clip would have to be rewritten relative to the clip - which is the
      // flattening this backend exists to avoid.
      final web.Element content = web.document.createElement('div');
      element.append(content);
      return _DomSlot(element, kind, content, tag: tag);
    }
    return _DomSlot(element, kind, element, tag: tag);
  }

  void _pushFrame(_DomSlot slot) => _frames.add(_Frame(slot));

  // -----------------------------------------------------------------------
  // Commands
  // -----------------------------------------------------------------------

  void _transform(DisplayListReader reader) {
    final double a = reader.floatAt(0);
    final double b = reader.floatAt(1);
    final double c = reader.floatAt(2);
    final double d = reader.floatAt(3);
    final double tx = reader.floatAt(4);
    final double ty = reader.floatAt(5);
    final _DomSlot slot = _slotFor(DomSlotKind.transform, 'div');
    // `transform-origin: 0 0` because the display list's matrix is about the
    // origin of the coordinate system, and CSS defaults to the centre of the
    // border box. Leaving the default in place makes every rotation orbit the
    // element's middle, which looks like a wrong matrix and is a wrong origin.
    slot.setStyle(
      'position:absolute;left:0;top:0;transform-origin:0 0;'
      'transform:matrix(${_n(a)},${_n(b)},${_n(c)},${_n(d)},'
      '${_n(tx)},${_n(ty)})',
    );
    _pushFrame(slot);
  }

  void _clipRect(DisplayListReader reader) {
    if (reader.clipOp != clipOpIntersect) {
      _refuse(
        'clipRect(difference)',
        'CSS clips by containment; subtracting a rectangle would need a '
            'clip-path polygon wound the other way, and the display list can '
            'nest difference clips arbitrarily',
      );
      return;
    }
    final double left = reader.floatAt(0);
    final double top = reader.floatAt(1);
    final double right = reader.floatAt(2);
    final double bottom = reader.floatAt(3);
    final _DomSlot slot = _slotFor(DomSlotKind.clip, 'div');
    slot.setStyle(
      'position:absolute;overflow:hidden;'
      'left:${_px(left)};top:${_px(top)};'
      'width:${_px(right - left)};height:${_px(bottom - top)}',
    );
    slot.setContentStyle(
      'position:absolute;left:${_px(-left)};top:${_px(-top)}',
    );
    _pushFrame(slot);
  }

  void _saveLayer(DisplayListReader reader, DisplayList list) {
    _saveDepths.add(_frames.length);
    final int paintId = reader.paintId;
    final int blend = list.paintBlendMode(paintId);
    if (blend != blendModeSrcOver) {
      _refuse(
        'saveLayer(blendMode)',
        'only source-over composites the same way in CSS; the display list\'s '
            'other blend modes have no `mix-blend-mode` that matches them '
            'exactly on a non-isolated stacking context',
      );
    }
    final int alpha = (list.paintColor(paintId) >> 24) & 0xFF;
    final _DomSlot slot = _slotFor(DomSlotKind.layer, 'div');
    // `isolation: isolate` makes this a stacking context, which is what turns
    // the opacity into a group opacity rather than a per-element one. Without
    // it two overlapping children at 50% show each other through, which is
    // exactly the artefact `saveLayer` exists to prevent.
    slot.setStyle(
      'position:absolute;left:0;top:0;isolation:isolate;'
      'opacity:${_n(alpha / 255)}',
    );
    _pushFrame(slot);
  }

  void _drawRect(DisplayListReader reader, DisplayList list) {
    _emitBox(
      list,
      reader.paintId,
      reader.floatAt(0),
      reader.floatAt(1),
      reader.floatAt(2),
      reader.floatAt(3),
      null,
    );
  }

  void _drawRRect(DisplayListReader reader, DisplayList list) {
    // Eight radii in the encoder's order: top-left x/y, top-right, bottom-
    // right, bottom-left. CSS takes them as four horizontal then four vertical,
    // which is the same set in the same corner order and a different grouping.
    final String radii = 'border-radius:'
        '${_px(reader.floatAt(4))} ${_px(reader.floatAt(6))} '
        '${_px(reader.floatAt(8))} ${_px(reader.floatAt(10))} / '
        '${_px(reader.floatAt(5))} ${_px(reader.floatAt(7))} '
        '${_px(reader.floatAt(9))} ${_px(reader.floatAt(11))}';
    _emitBox(
      list,
      reader.paintId,
      reader.floatAt(0),
      reader.floatAt(1),
      reader.floatAt(2),
      reader.floatAt(3),
      radii,
    );
  }

  void _emitBox(
    DisplayList list,
    int paintId,
    double left,
    double top,
    double right,
    double bottom,
    String? radii,
  ) {
    if (list.paintGradient(paintId) != null) {
      _refuse(
        'gradient fill',
        'a CSS gradient is defined along a line across the element box while '
            'the display list defines one by two points in the current '
            'coordinate system with its own spread mode; the two agree only '
            'for the axis-aligned unclamped case, so mapping them would be '
            'right most of the time, which is the worst kind of right',
      );
      return;
    }
    final int blend = list.paintBlendMode(paintId);
    if (blend != blendModeSrcOver) {
      _refuse(
        'blend mode',
        'only source-over is expressible without a stacking context whose '
            'backdrop is exactly the display list\'s',
      );
      return;
    }

    final int style = list.paintStyle(paintId);
    final String color = _cssColor(list.paintColor(paintId));
    final double stroke = list.paintStrokeWidth(paintId);
    final _DomSlot slot = _slotFor(DomSlotKind.box, 'div');

    final StringBuffer css = StringBuffer('position:absolute;');
    if (style == paintStyleFill) {
      css
        ..write('left:${_px(left)};top:${_px(top)};')
        ..write('width:${_px(right - left)};height:${_px(bottom - top)};')
        ..write('background-color:$color;');
    } else {
      // A stroke is centred on the geometric edge, so the element has to grow
      // by half the width on every side and the border has to be inside it.
      // Getting this wrong by using the geometric rectangle draws a border that
      // is entirely inside the shape, which is a visibly thinner outline that
      // no test comparing colours would catch.
      final double half = stroke / 2;
      css
        ..write('box-sizing:border-box;')
        ..write('left:${_px(left - half)};top:${_px(top - half)};')
        ..write('width:${_px(right - left + stroke)};')
        ..write('height:${_px(bottom - top + stroke)};')
        ..write('border:${_px(stroke)} solid $color;');
      if (style == paintStyleFillAndStroke) {
        // `border-box` clip, which is the default, so the fill runs under the
        // border exactly as the filled shape would.
        css.write('background-color:$color;');
      }
    }
    if (radii != null) css.write('$radii;');
    // Never the pointer, under either policy: a box is decoration, and the one
    // thing that may legitimately take the pointer away from the framework is
    // text - see [DomPointerPolicy].
    css.write('pointer-events:none;');
    slot.setStyle(css.toString());
  }

  void _drawImage(DisplayListReader reader, DisplayList list) {
    final Object resource = list.imageAt(reader.imageId);
    if (resource is! Framebuffer) {
      _refuse(
        'drawImage',
        'the display list interns an image as an opaque Object; this backend '
            'can upload a Framebuffer and nothing else, and got '
            '${resource.runtimeType}',
      );
      return;
    }
    final String? bitmap = _bitmapFor(resource);
    if (bitmap == null) return;

    final double dstLeft = reader.floatAt(4);
    final double dstTop = reader.floatAt(5);
    final double dstRight = reader.floatAt(6);
    final double dstBottom = reader.floatAt(7);
    final double srcLeft = reader.floatAt(0);
    final double srcTop = reader.floatAt(1);
    final double srcRight = reader.floatAt(2);
    final double srcBottom = reader.floatAt(3);

    final _DomSlot slot = _slotFor(DomSlotKind.image, 'div');
    // A `<div>` with a background rather than an `<img>`, because the source
    // rectangle is a crop and `<img>` has no crop: expressing one would need a
    // wrapper with overflow hidden and a negatively positioned child, which is
    // two elements to say what `background-position` says in one. The
    // accessible name is supplied by the semantics layer, so nothing is lost by
    // not being an `<img>` - and `role="img"` keeps it a graphic to a screen
    // reader.
    final double scaleX = (dstRight - dstLeft) / (srcRight - srcLeft);
    final double scaleY = (dstBottom - dstTop) / (srcBottom - srcTop);
    slot
      ..setStyle(
        'position:absolute;pointer-events:none;'
        'left:${_px(dstLeft)};top:${_px(dstTop)};'
        'width:${_px(dstRight - dstLeft)};height:${_px(dstBottom - dstTop)};'
        'background-image:url($bitmap);'
        'background-repeat:no-repeat;'
        'background-size:${_px(resource.width * scaleX)} '
        '${_px(resource.height * scaleY)};'
        'background-position:${_px(-srcLeft * scaleX)} '
        '${_px(-srcTop * scaleY)}',
      )
      ..setAttribute('role', 'img');
  }

  String? _bitmapFor(Framebuffer framebuffer) {
    final String? cached = _imageUrls[framebuffer];
    if (cached != null) return cached;
    final web.HTMLCanvasElement canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    canvas
      ..width = framebuffer.width
      ..height = framebuffer.height;
    final web.CanvasRenderingContext2D? context =
        canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    if (context == null) {
      _refuse(
        'drawImage',
        'the browser refused a 2d context, so there is nowhere to put the '
            'pixels of a Framebuffer',
      );
      return null;
    }
    context.putImageData(_imageDataOf(framebuffer), 0, 0);
    final String url = canvas.toDataUrl('image/png');
    _imageUrls[framebuffer] = url;
    return url;
  }

  void _drawGlyphRun(DisplayListReader reader, DisplayList list) {
    final Object resource = list.fontAt(reader.fontId);
    if (resource is! ScaledTypeface) {
      _refuse(
        'drawGlyphRun',
        'the display list interns a font as an opaque Object; this backend '
            'needs a ScaledTypeface to invert the cmap, and got '
            '${resource.runtimeType}',
      );
      return;
    }
    final int paintId = reader.paintId;
    if (list.paintGradient(paintId) != null) {
      _refuse('gradient text', 'see the gradient fill refusal');
      return;
    }

    final int count = reader.glyphCount;
    if (count == 0) return;
    final Int32List glyphs = Int32List(count);
    for (int i = 0; i < count; i++) {
      glyphs[i] = reader.glyphIdAt(i);
    }
    final DomTypeface face =
        DomFontRegistry.instance.faceFor(resource.typeface);
    final ResolvedGlyphText resolved = face.textOf(glyphs, count);
    unresolvedGlyphs += resolved.unresolved;
    if (resolved.unresolved > 0) {
      _refuse(
        'glyph without a code point',
        'the display list carries glyph ids and no text, so a glyph that the '
            'cmap does not map - a ligature, an Arabic positional form, any '
            'contextual substitution - cannot be named. See dom_text.dart for '
            'the side table that would fix this',
      );
    }
    if (resolved.text.isEmpty) return;

    final double pixelSize = resource.pixelSize;
    final String cssFont = '${_n(pixelSize)}px "${face.cssFamily}", sans-serif';
    final DomFontMetrics metrics =
        DomFontRegistry.instance.metricsFor(cssFont, pixelSize);

    // The run origin is a baseline and CSS positions by the top of a line box.
    // Setting `line-height` to exactly the browser's own ascent plus descent
    // makes the half-leading zero, so the baseline is `ascent` below the top -
    // which is the only arrangement in which this arithmetic is exact rather
    // than close.
    final double originX = reader.floatAt(0) + reader.glyphOffsetXAt(0);
    final double originY = reader.floatAt(1) + reader.glyphOffsetYAt(0);
    final double lineHeight = metrics.ascent + metrics.descent;

    final _DomSlot slot = _slotFor(DomSlotKind.text, 'span');
    final String pointerEvents =
        pointerPolicy == DomPointerPolicy.selectableText
            ? 'pointer-events:auto;user-select:text;-webkit-user-select:text;'
            : 'pointer-events:none;user-select:text;-webkit-user-select:text;';
    slot
      ..setStyle(
        'position:absolute;white-space:pre;$pointerEvents'
        'left:${_px(originX)};top:${_px(originY - metrics.ascent)};'
        'font:$cssFont;line-height:${_px(lineHeight)};'
        'color:${_cssColor(list.paintColor(paintId))}',
      )
      ..setText(resolved.text)
      ..setAttribute(
        'data-dartui-unresolved',
        resolved.unresolved == 0 ? null : '${resolved.unresolved}',
      );
  }

  void _refuse(String what, String why) {
    final int seen = refusals[what] ?? 0;
    refusals[what] = seen + 1;
    if (seen == 0) onRefusal?.call((what: what, why: why));
  }
}

/// One position in the retained tree.
///
/// [element] is `final` and never reassigned, which is the invariant the whole
/// file rests on: a slot that survives a frame keeps its DOM node, and a node
/// that keeps its identity keeps its focus, its selection and its scroll
/// offset.
final class _DomSlot {
  _DomSlot(this.element, this.kind, this.content, {this.tag = 'div'});

  final web.Element element;
  final DomSlotKind kind;

  /// Where children go. The same as [element] except for a clip, which needs
  /// an inner element to undo its own offset.
  final web.Element content;

  final String tag;

  final List<_DomSlot> children = <_DomSlot>[];

  String? _style;
  String? _contentStyle;
  String? _text;
  Map<String, String>? _attributes;

  /// Writes [css] only if it differs from what this slot last wrote.
  ///
  /// The compare is against a cached string rather than against
  /// `element.getAttribute('style')`, because nothing else writes these
  /// elements - this backend owns the subtree - so the cache cannot go stale,
  /// and reading back would cost a JS call per element per frame to learn
  /// something already known.
  void setStyle(String css) {
    if (_style == css) return;
    _style = css;
    element.setAttribute('style', css);
  }

  void setContentStyle(String css) {
    if (_contentStyle == css) return;
    _contentStyle = css;
    content.setAttribute('style', css);
  }

  /// Replaces the text, and only when it changed.
  ///
  /// Assigning `textContent` destroys and recreates the text node, which
  /// collapses any selection anchored in it. On a frame where the label did not
  /// change - which is nearly all of them - this must not happen, and the
  /// compare is what stops it.
  void setText(String text) {
    if (_text == text) return;
    _text = text;
    element.textContent = text;
  }

  void setAttribute(String name, String? value) {
    final Map<String, String> attributes = _attributes ??= <String, String>{};
    if (value == null) {
      if (attributes.remove(name) != null) element.removeAttribute(name);
      return;
    }
    if (attributes[name] == value) return;
    attributes[name] = value;
    element.setAttribute(name, value);
  }

  /// Drops every child from [from] on, returning how many went.
  int removeChildrenFrom(int from) {
    if (children.length <= from) return 0;
    final int removed = children.length - from;
    for (int i = children.length - 1; i >= from; i--) {
      content.removeChild(children[i].element);
    }
    children.removeRange(from, children.length);
    return removed;
  }
}

/// One open group during a walk: where children go and how many have been
/// placed.
final class _Frame {
  _Frame(this.slot);

  final _DomSlot slot;
  int index = 0;
}

/// Straight (non-premultiplied) RGBA for the browser, from whatever the
/// framebuffer holds.
///
/// Both of the framework's formats are **premultiplied** and `ImageData` is
/// not, so the divide is mandatory rather than an optimisation to skip. Leaving
/// it out is invisible on opaque pixels and turns every antialiased edge into a
/// dark fringe, which reads as a bad font rather than as a colour-space bug.
web.ImageData _imageDataOf(Framebuffer framebuffer) {
  final int width = framebuffer.width;
  final int height = framebuffer.height;
  final Uint8ClampedList rgba = Uint8ClampedList(width * height * 4);
  final bool bgra = framebuffer.format == PixelFormat.bgra8888Premultiplied;
  final Uint8List source = framebuffer.pixels;
  int out = 0;
  for (int y = 0; y < height; y++) {
    int index = y * framebuffer.bytesPerRow;
    for (int x = 0; x < width; x++) {
      final int alpha = source[index + 3];
      final int b0 = source[index];
      final int b2 = source[index + 2];
      final int red = bgra ? b2 : b0;
      final int green = source[index + 1];
      final int blue = bgra ? b0 : b2;
      if (alpha == 0) {
        rgba[out] = 0;
        rgba[out + 1] = 0;
        rgba[out + 2] = 0;
        rgba[out + 3] = 0;
      } else if (alpha == 255) {
        rgba[out] = red;
        rgba[out + 1] = green;
        rgba[out + 2] = blue;
        rgba[out + 3] = 255;
      } else {
        rgba[out] = (red * 255) ~/ alpha;
        rgba[out + 1] = (green * 255) ~/ alpha;
        rgba[out + 2] = (blue * 255) ~/ alpha;
        rgba[out + 3] = alpha;
      }
      index += 4;
      out += 4;
    }
  }
  return web.ImageData(rgba.toJS, width, height.toJS);
}

/// `0xAARRGGBB` as a CSS colour.
///
/// `rgba()` rather than `#rrggbbaa`, because the display list's alpha is a byte
/// and CSS's hex alpha is also a byte but its `rgba()` alpha is a fraction -
/// and going through the fraction is what keeps a half-transparent paint
/// half-transparent in every engine, including the ones whose eight-digit hex
/// support arrived late.
String _cssColor(int argb) {
  final int alpha = (argb >> 24) & 0xFF;
  final int red = (argb >> 16) & 0xFF;
  final int green = (argb >> 8) & 0xFF;
  final int blue = argb & 0xFF;
  if (alpha == 255) return 'rgb($red,$green,$blue)';
  return 'rgba($red,$green,$blue,${_n(alpha / 255)})';
}

/// A number with the trailing noise of float32 removed.
///
/// The display list stores coordinates as float32, so `100.0` comes back as
/// `100.0` and `0.1` comes back as `0.10000000149011612`. Writing that into a
/// style string makes every diff compare two long strings and makes the DOM
/// unreadable in an inspector, for precision far below what a browser lays out
/// with.
String _n(double value) {
  if (!value.isFinite) return '0';
  final double rounded = (value * 1000).roundToDouble() / 1000;
  if (rounded == rounded.truncateToDouble() && rounded.abs() < 1e9) {
    return rounded.toInt().toString();
  }
  return rounded.toString();
}

String _px(double value) => '${_n(value)}px';
