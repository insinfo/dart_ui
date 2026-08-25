/// A well-formedness-checking XML 1.0 reader, in Dart.
///
/// ## Why this file exists at all
///
/// The framework ships no third-party packages, and an SVG file is XML, so an
/// SVG reader in pure Dart needs an XML reader in pure Dart. This is the whole
/// dependency, and it is small because SVG needs a reader and not an XML
/// toolchain: there is no writer, no XPath, no schema validation, no namespace
/// URI resolution, and no DTD processing beyond skipping a `DOCTYPE` that a
/// drawing tool left behind.
///
/// ## What it accepts
///
/// The document grammar of XML 1.0: an optional prolog of processing
/// instructions, comments and a `DOCTYPE`; exactly one root element; elements
/// with attributes, nested elements, character data, `CDATA` sections, and the
/// five predefined entities plus numeric character references. Anything else is
/// a [XmlParserException] rather than a silently accepted guess - a reader that
/// repairs malformed markup turns a corrupt file into a wrong drawing, which is
/// the failure that is hard to notice.
///
/// Namespaces are parsed as syntax, not resolved: `<svg:rect>` gives an
/// [XmlName] with prefix `svg` and local `rect`, and `xmlns` declarations are
/// ordinary attributes. That is what a drawing reader needs, since it dispatches
/// on the local name.
library;

/// Thrown when the source is not well-formed XML.
class XmlParserException implements Exception {
  const XmlParserException(this.message, this.offset, this.line, this.column);

  /// What was wrong, without position - callers usually add their own context.
  final String message;

  /// Offset into the source where the parser gave up.
  final int offset;

  /// 1-based line of [offset].
  final int line;

  /// 1-based column of [offset].
  final int column;

  @override
  String toString() =>
      'XmlParserException: $message (line $line, column $column)';
}

/// A qualified XML name. `svg:rect` has prefix `svg` and local name `rect`.
class XmlName {
  const XmlName(this.local, [this.prefix]);

  /// The part after the colon, or the whole name when there is no prefix.
  final String local;

  /// The part before the colon, or null.
  final String? prefix;

  /// The name as it was written.
  String get qualified => prefix == null ? local : '$prefix:$local';

  @override
  String toString() => qualified;
}

/// One `name="value"` pair on an element.
class XmlAttribute {
  const XmlAttribute(this.name, this.value);

  final XmlName name;

  /// The value with references expanded and literal newlines and tabs
  /// normalised to spaces, per XML 1.0 section 3.3.3.
  final String value;

  @override
  String toString() => '${name.qualified}="$value"';
}

/// Base of everything a document is made of.
sealed class XmlNode {
  const XmlNode();

  /// Child nodes, in document order. Empty for text.
  List<XmlNode> get children;

  /// The concatenated character data of this node and its descendants.
  String get innerText;
}

/// Character data: text between tags, or the body of a `CDATA` section.
final class XmlText extends XmlNode {
  const XmlText(this.value);

  final String value;

  @override
  List<XmlNode> get children => const <XmlNode>[];

  @override
  String get innerText => value;

  @override
  String toString() => value;
}

/// An element, its attributes and its children.
final class XmlElement extends XmlNode {
  XmlElement(this.name, this.attributes, this.children);

  final XmlName name;
  final List<XmlAttribute> attributes;

  @override
  final List<XmlNode> children;

  /// The value of the attribute written exactly as [name], or null.
  ///
  /// Matches the qualified name, so `getAttribute('href')` does not find
  /// `xlink:href` - asking for the prefixed form is how you get the prefixed
  /// attribute.
  String? getAttribute(String name) {
    for (final XmlAttribute attribute in attributes) {
      if (attribute.name.qualified == name) return attribute.value;
    }
    return null;
  }

  /// The child nodes that are elements, in document order.
  Iterable<XmlElement> get childElements => children.whereType<XmlElement>();

  /// Direct child elements whose qualified name is [name].
  Iterable<XmlElement> findElements(String name) =>
      childElements.where((XmlElement e) => e.name.qualified == name);

  @override
  String get innerText {
    final StringBuffer buffer = StringBuffer();
    _writeText(this, buffer);
    return buffer.toString();
  }

  @override
  String toString() => '<${name.qualified}>';
}

/// A parsed document: the root element plus whatever surrounded it.
final class XmlDocument extends XmlNode {
  XmlDocument._(this.children, this._root);

  /// Parses [source], throwing [XmlParserException] if it is not well-formed.
  static XmlDocument parse(String source) => _XmlParser(source).parseDocument();

  @override
  final List<XmlNode> children;

  final XmlElement _root;

  /// The single outermost element.
  XmlElement get rootElement => _root;

  /// Top-level elements whose qualified name is [name]. Since a document has
  /// exactly one root, this is either empty or just the root.
  Iterable<XmlElement> findElements(String name) =>
      children.whereType<XmlElement>().where(
            (XmlElement e) => e.name.qualified == name,
          );

  @override
  String get innerText => _root.innerText;

  @override
  String toString() => '<?xml?><${_root.name.qualified}>';
}

/// Walks with an explicit stack rather than recursion: [maxNestingDepth] keeps
/// a parsed tree shallow, but nothing stops a caller from building a deep one
/// by hand, and a stack overflow is an `Error` that callers cannot catch.
void _writeText(XmlNode node, StringBuffer buffer) {
  final List<XmlNode> pending = <XmlNode>[node];
  while (pending.isNotEmpty) {
    final XmlNode current = pending.removeLast();
    if (current is XmlText) {
      buffer.write(current.value);
      continue;
    }
    final List<XmlNode> children = current.children;
    for (int i = children.length - 1; i >= 0; i--) {
      pending.add(children[i]);
    }
  }
}

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

const int _tab = 0x09;
const int _newline = 0x0A;
const int _carriageReturn = 0x0D;
const int _space = 0x20;
const int _quote = 0x22;
const int _hash = 0x23;
const int _apostrophe = 0x27;
const int _hyphen = 0x2D;
const int _period = 0x2E;
const int _colon = 0x3A;
const int _lessThan = 0x3C;
const int _equals = 0x3D;
const int _greaterThan = 0x3E;
const int _ampersand = 0x26;
const int _openBracket = 0x5B;
const int _underscore = 0x5F;
const int _zero = 0x30;
const int _nine = 0x39;
const int _upperA = 0x41;
const int _upperF = 0x46;
const int _upperZ = 0x5A;
const int _lowerA = 0x61;
const int _lowerF = 0x66;
const int _lowerX = 0x78;
const int _lowerZ = 0x7A;

/// How deep [XmlDocument.parse] will let elements nest.
///
/// The parser itself no longer needs a limit - it uses an explicit stack - but
/// everything that reads the result walks it recursively, this library's own
/// `innerText` included, and so does the SVG reader above it. One check here is
/// what keeps a hostile file from reaching those walkers, and it reports as an
/// ordinary [XmlParserException] instead of an uncatchable stack overflow.
/// Real documents are nowhere near it: SVG exported by drawing tools nests a
/// few dozen levels.
const int maxNestingDepth = 512;

/// An element whose start tag has been read while its children still have not.
class _OpenElement {
  _OpenElement(this.name, this.attributes, this.tagStart,
      {required this.selfClosing});

  final XmlName name;
  final List<XmlAttribute> attributes;

  /// Offset of this element's `<`, so an unterminated element can point at it.
  final int tagStart;

  final bool selfClosing;

  final List<XmlNode> children = <XmlNode>[];

  /// Character data seen since the last child element, comment or PI.
  final StringBuffer text = StringBuffer();

  void flushText() {
    if (text.isNotEmpty) {
      children.add(XmlText(text.toString()));
      text.clear();
    }
  }
}

/// Recursive-descent reader over the raw source string.
///
/// Everything is driven off `codeUnitAt` and substring slices rather than a
/// token list: an SVG is read once and thrown away, so an intermediate token
/// stream would be pure allocation.
class _XmlParser {
  _XmlParser(this._source);

  final String _source;
  int _index = 0;

  int get _length => _source.length;

  XmlDocument parseDocument() {
    final List<XmlNode> children = <XmlNode>[];
    XmlElement? root;

    while (_index < _length) {
      _skipWhitespace();
      if (_index >= _length) break;

      if (!_startsWith('<')) {
        _fail('character data is not allowed outside the root element');
      }
      if (_startsWith('<!--')) {
        _skipComment();
        continue;
      }
      if (_startsWith('<?')) {
        _skipProcessingInstruction();
        continue;
      }
      if (_startsWith('<!DOCTYPE')) {
        _skipDoctype();
        continue;
      }
      if (_startsWith('</')) {
        _fail('end tag without a matching start tag');
      }
      if (root != null) {
        _fail('a document may only have one root element');
      }
      root = _parseElementTree();
      children.add(root);
    }

    if (root == null) {
      _fail('document has no root element');
    }
    return XmlDocument._(children, root);
  }

  /// Reads one element and everything under it.
  ///
  /// Iterative on purpose. The obvious shape here is mutual recursion between
  /// "read an element" and "read its content", and it costs one Dart frame per
  /// level of nesting: `<g>` repeated ten thousand times - 30 KB of source -
  /// was enough to raise [StackOverflowError], which is an `Error` and so blows
  /// straight past the `on XmlParserException` that callers wrap this in. An
  /// explicit stack turns depth into heap, where [maxNestingDepth] can refuse
  /// it as a normal parse error.
  XmlElement _parseElementTree() {
    final List<_OpenElement> stack = <_OpenElement>[];

    final _OpenElement first = _readStartTag();
    if (first.selfClosing) {
      return XmlElement(first.name, first.attributes, <XmlNode>[]);
    }
    stack.add(first);

    while (true) {
      final _OpenElement current = stack.last;

      if (_index >= _length) {
        _index = current.tagStart;
        _fail("unterminated element '<${current.name.qualified}>'");
      }

      final int c = _source.codeUnitAt(_index);

      if (c == _lessThan) {
        if (_startsWith('</')) {
          current.flushText();
          final int closeStart = _index;
          _index += 2;
          final XmlName closeName = _parseName();
          _skipWhitespace();
          if (_index >= _length || _source.codeUnitAt(_index) != _greaterThan) {
            _fail("expected '>' to close '</${closeName.qualified}'");
          }
          _index++;
          if (closeName.qualified != current.name.qualified) {
            _index = closeStart;
            _fail("'</${closeName.qualified}>' does not close "
                "'<${current.name.qualified}>'");
          }

          final XmlElement element =
              XmlElement(current.name, current.attributes, current.children);
          stack.removeLast();
          if (stack.isEmpty) return element;
          // The parent's text buffer was flushed before this child was pushed
          // and could not grow while the child was on top, so appending the
          // element here keeps document order.
          stack.last.children.add(element);
          continue;
        }
        if (_startsWith('<!--')) {
          current.flushText();
          _skipComment();
          continue;
        }
        if (_startsWith('<![CDATA[')) {
          _index += 9;
          final int end = _source.indexOf(']]>', _index);
          if (end < 0) _fail('unterminated CDATA section');
          current.text
              .write(_normalizeLineEndings(_source.substring(_index, end)));
          _index = end + 3;
          continue;
        }
        if (_startsWith('<?')) {
          current.flushText();
          _skipProcessingInstruction();
          continue;
        }
        if (_startsWith('<!')) {
          _fail('a declaration is not allowed inside an element');
        }

        current.flushText();
        final _OpenElement child = _readStartTag();
        if (child.selfClosing) {
          current.children
              .add(XmlElement(child.name, child.attributes, <XmlNode>[]));
          continue;
        }
        if (stack.length >= maxNestingDepth) {
          _index = child.tagStart;
          _fail('element nesting deeper than $maxNestingDepth levels');
        }
        stack.add(child);
        continue;
      }

      if (c == _ampersand) {
        current.text.write(_parseReference());
        continue;
      }

      // XML 1.0 section 2.11: a CRLF pair and a lone carriage return are both
      // read as a single newline, so a file saved on Windows and the same file
      // saved on Unix parse to the same text.
      if (c == _carriageReturn) {
        current.text.writeCharCode(_newline);
        _index++;
        if (_index < _length && _source.codeUnitAt(_index) == _newline) {
          _index++;
        }
        continue;
      }

      // Plain run of character data: copy it in one slice.
      final int runStart = _index;
      while (_index < _length) {
        final int t = _source.codeUnitAt(_index);
        if (t == _lessThan || t == _ampersand || t == _carriageReturn) break;
        _index++;
      }
      current.text.write(_source.substring(runStart, _index));
    }
  }

  /// Reads `<name attr="value" ...` up to and including its `>` or `/>`.
  _OpenElement _readStartTag() {
    final int tagStart = _index;
    _index++; // '<'
    final XmlName name = _parseName();
    final List<XmlAttribute> attributes = <XmlAttribute>[];
    Set<String>? seen;

    while (true) {
      final bool hadWhitespace = _skipWhitespace();
      if (_index >= _length) {
        _index = tagStart;
        _fail("unterminated start tag '<${name.qualified}'");
      }
      if (_startsWith('/>')) {
        _index += 2;
        return _OpenElement(name, attributes, tagStart, selfClosing: true);
      }
      if (_source.codeUnitAt(_index) == _greaterThan) {
        _index++;
        return _OpenElement(name, attributes, tagStart, selfClosing: false);
      }
      if (!hadWhitespace) {
        _fail('expected whitespace before the next attribute');
      }

      final XmlName attributeName = _parseName();
      _skipWhitespace();
      if (_index >= _length || _source.codeUnitAt(_index) != _equals) {
        _fail("expected '=' after attribute '${attributeName.qualified}'");
      }
      _index++;
      _skipWhitespace();
      final String value = _parseAttributeValue();

      // Only pay for the set once an element actually has several attributes.
      if (attributes.isNotEmpty) {
        seen ??= <String>{
          for (final XmlAttribute a in attributes) a.name.qualified,
        };
        if (!seen.add(attributeName.qualified)) {
          _fail("duplicate attribute '${attributeName.qualified}'");
        }
      }
      attributes.add(XmlAttribute(attributeName, value));
    }
  }

  /// Reads a quoted attribute value, expanding references.
  String _parseAttributeValue() {
    if (_index >= _length) _fail('expected an attribute value');
    final int quote = _source.codeUnitAt(_index);
    if (quote != _quote && quote != _apostrophe) {
      _fail('attribute values must be quoted');
    }
    _index++;

    final StringBuffer buffer = StringBuffer();
    while (true) {
      if (_index >= _length) _fail('unterminated attribute value');
      final int c = _source.codeUnitAt(_index);

      if (c == quote) {
        _index++;
        return buffer.toString();
      }
      if (c == _lessThan) {
        _fail("'<' is not allowed in an attribute value");
      }
      if (c == _ampersand) {
        buffer.write(_parseReference());
        continue;
      }
      // XML 1.0 section 3.3.3: a literal tab, newline or carriage return in an
      // attribute value is a space. Multi-line `d="..."` path data depends on
      // this being done before the path grammar sees it.
      if (c == _tab || c == _newline) {
        buffer.writeCharCode(_space);
        _index++;
        continue;
      }
      // Section 2.11 folds a CRLF pair into one newline before 3.3.3 turns it
      // into a space, so a value broken across lines in a file with Windows
      // line endings is one space wide and not two.
      if (c == _carriageReturn) {
        buffer.writeCharCode(_space);
        _index++;
        if (_index < _length && _source.codeUnitAt(_index) == _newline) {
          _index++;
        }
        continue;
      }

      final int runStart = _index;
      while (_index < _length) {
        final int t = _source.codeUnitAt(_index);
        if (t == quote ||
            t == _lessThan ||
            t == _ampersand ||
            t == _tab ||
            t == _newline ||
            t == _carriageReturn) {
          break;
        }
        _index++;
      }
      buffer.write(_source.substring(runStart, _index));
    }
  }

  /// Reads `&amp;`, `&#60;` or `&#x3C;` and returns what it stands for.
  String _parseReference() {
    final int start = _index;
    _index++; // '&'
    final int end = _source.indexOf(';', _index);
    if (end < 0) {
      _index = start;
      _fail('unterminated entity reference');
    }
    final String body = _source.substring(_index, end);
    if (body.isEmpty || body.contains('<') || body.contains(' ')) {
      _index = start;
      _fail('malformed entity reference');
    }
    _index = end + 1;

    if (body.codeUnitAt(0) == _hash) {
      // The `CharRef` production is `&#[0-9]+;` or `&#x[0-9a-fA-F]+;`: no sign,
      // no `&#X`. `int.tryParse` would take a leading `+` or `-`, so the digits
      // are checked before it sees them.
      final bool hex = body.length > 1 && body.codeUnitAt(1) == _lowerX;
      final String digits = hex ? body.substring(2) : body.substring(1);
      final int? value = _areDigits(digits, hex)
          ? int.tryParse(digits, radix: hex ? 16 : 10)
          : null;
      if (value == null || value < 0 || value > 0x10FFFF) {
        _index = start;
        _fail("'&$body;' is not a valid character reference");
      }
      return String.fromCharCode(value);
    }

    // Only the five predefined entities exist without a DTD, and this reader
    // does not process DTDs. Guessing at an undeclared entity is how a corrupt
    // file becomes a wrong drawing.
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    _index = start;
    _fail("undeclared entity '&$body;'");
  }

  XmlName _parseName() {
    if (_index >= _length || !_isNameStart(_source.codeUnitAt(_index))) {
      _fail('expected a name');
    }
    final int start = _index;
    _index++;
    while (_index < _length && _isNameChar(_source.codeUnitAt(_index))) {
      _index++;
    }
    final String text = _source.substring(start, _index);
    final int colon = text.indexOf(':');
    if (colon <= 0 || colon == text.length - 1) {
      return XmlName(text);
    }
    return XmlName(text.substring(colon + 1), text.substring(0, colon));
  }

  void _skipComment() {
    _index += 4; // '<!--'
    final int end = _source.indexOf('-->', _index);
    if (end < 0) _fail('unterminated comment');
    _index = end + 3;
  }

  void _skipProcessingInstruction() {
    _index += 2; // '<?'
    final int end = _source.indexOf('?>', _index);
    if (end < 0) _fail('unterminated processing instruction');
    _index = end + 2;
  }

  /// Skips a `DOCTYPE`, including an internal subset in brackets. Nothing in it
  /// is honoured - it is here so a file exported with one still reads.
  void _skipDoctype() {
    _index += 9; // '<!DOCTYPE'
    while (_index < _length) {
      final int c = _source.codeUnitAt(_index);
      if (c == _openBracket) {
        final int end = _source.indexOf(']', _index + 1);
        if (end < 0) _fail('unterminated DOCTYPE internal subset');
        _index = end + 1;
        continue;
      }
      _index++;
      if (c == _greaterThan) return;
    }
    _fail('unterminated DOCTYPE');
  }

  /// Returns whether it consumed anything, which is how a start tag knows an
  /// attribute was separated from what came before it.
  bool _skipWhitespace() {
    final int start = _index;
    while (_index < _length) {
      final int c = _source.codeUnitAt(_index);
      if (c != _space && c != _tab && c != _newline && c != _carriageReturn) {
        break;
      }
      _index++;
    }
    return _index != start;
  }

  bool _startsWith(String token) => _source.startsWith(token, _index);

  Never _fail(String message) {
    int line = 1;
    int column = 1;
    for (int i = 0; i < _index && i < _length; i++) {
      if (_source.codeUnitAt(i) == _newline) {
        line++;
        column = 1;
      } else {
        column++;
      }
    }
    throw XmlParserException(message, _index, line, column);
  }
}

/// Whether [text] is a non-empty run of digits of the radix a character
/// reference asked for.
bool _areDigits(String text, bool hex) {
  if (text.isEmpty) return false;
  for (int i = 0; i < text.length; i++) {
    final int c = text.codeUnitAt(i);
    if (c >= _zero && c <= _nine) continue;
    if (hex &&
        ((c >= _lowerA && c <= _lowerF) || (c >= _upperA && c <= _upperF))) {
      continue;
    }
    return false;
  }
  return true;
}

/// XML 1.0 section 2.11: CRLF and a lone carriage return are both a single
/// newline. Used where a slice is copied wholesale instead of scanned.
String _normalizeLineEndings(String text) {
  if (!text.contains('\r')) return text;
  return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

/// The ASCII part of XML's `NameStartChar`, plus everything above it.
///
/// Names outside ASCII are accepted wholesale rather than checked against the
/// exact code point ranges of the production: the ranges exclude only
/// combining marks and a handful of punctuation blocks, and no drawing tool
/// emits those as element names.
bool _isNameStart(int c) =>
    (c >= _lowerA && c <= _lowerZ) ||
    (c >= _upperA && c <= _upperZ) ||
    c == _underscore ||
    c == _colon ||
    c > 0x7F;

bool _isNameChar(int c) =>
    _isNameStart(c) ||
    (c >= _zero && c <= _nine) ||
    c == _hyphen ||
    c == _period;
