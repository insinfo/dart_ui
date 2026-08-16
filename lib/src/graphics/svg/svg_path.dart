/// SVG path-data parsing, including conversion of elliptical arcs to cubics.
library;

import 'dart:math' as math;

import '../../geometry/path.dart';

final class SvgParseException implements FormatException {
  const SvgParseException(this.message, {this.source, this.offset});

  @override
  final String message;
  @override
  final String? source;
  @override
  final int? offset;

  @override
  String toString() => 'SvgParseException: $message'
      '${offset == null ? '' : ' at offset $offset'}';
}

/// Parses the complete SVG 1.1/Tiny path command set (`MZLHVCSQTA`).
Path parseSvgPathData(String data) => _SvgPathParser(data).parse();

final class _SvgPathParser {
  _SvgPathParser(this.data);

  final String data;
  final PathBuilder _path = PathBuilder();
  int _offset = 0;
  double _x = 0;
  double _y = 0;
  double _startX = 0;
  double _startY = 0;
  double _lastCubicX = 0;
  double _lastCubicY = 0;
  double _lastQuadraticX = 0;
  double _lastQuadraticY = 0;
  String? _previousCommand;

  static final RegExp _number = RegExp(
    r'[+-]?(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+-]?\d+)?',
  );

  Path parse() {
    String? command;
    while (true) {
      _skipSeparators();
      if (_offset >= data.length) break;
      final int code = data.codeUnitAt(_offset);
      if (_isCommand(code)) {
        command = data[_offset++];
      } else if (command == null || command.toUpperCase() == 'Z') {
        _fail('expected a path command');
      }

      final bool relative = command == command.toLowerCase();
      switch (command.toUpperCase()) {
        case 'M':
          _move(relative);
          final String lineCommand = relative ? 'l' : 'L';
          while (_hasNumber) {
            _line(relative);
            _previousCommand = lineCommand;
          }
          command = lineCommand;
          break;
        case 'L':
          _repeat(2, command, () => _line(relative));
          break;
        case 'H':
          _repeat(1, command, () {
            _x = _coordinate(_readNumber(), _x, relative);
            _path.lineTo(_x, _y);
          });
          break;
        case 'V':
          _repeat(1, command, () {
            _y = _coordinate(_readNumber(), _y, relative);
            _path.lineTo(_x, _y);
          });
          break;
        case 'C':
          _repeat(6, command, () => _cubic(relative));
          break;
        case 'S':
          _repeat(4, command, () => _smoothCubic(relative));
          break;
        case 'Q':
          _repeat(4, command, () => _quadratic(relative));
          break;
        case 'T':
          _repeat(2, command, () => _smoothQuadratic(relative));
          break;
        case 'A':
          _repeat(7, command, () => _arc(relative));
          break;
        case 'Z':
          _path.close();
          _x = _startX;
          _y = _startY;
          _previousCommand = command;
          break;
        default:
          _fail('unsupported path command $command');
      }
    }
    return _path.build();
  }

  void _move(bool relative) {
    if (!_hasNumber) _fail('move command needs a coordinate pair');
    final double x = _coordinate(_readNumber(), _x, relative);
    final double y = _coordinate(_readNumber(), _y, relative);
    _path.moveTo(x, y);
    _x = _startX = x;
    _y = _startY = y;
    _previousCommand = relative ? 'm' : 'M';
  }

  void _line(bool relative) {
    _x = _coordinate(_readNumber(), _x, relative);
    _y = _coordinate(_readNumber(), _y, relative);
    _path.lineTo(_x, _y);
  }

  void _cubic(bool relative) {
    final double x1 = _coordinate(_readNumber(), _x, relative);
    final double y1 = _coordinate(_readNumber(), _y, relative);
    final double x2 = _coordinate(_readNumber(), _x, relative);
    final double y2 = _coordinate(_readNumber(), _y, relative);
    final double x = _coordinate(_readNumber(), _x, relative);
    final double y = _coordinate(_readNumber(), _y, relative);
    _path.cubicTo(x1, y1, x2, y2, x, y);
    _lastCubicX = x2;
    _lastCubicY = y2;
    _x = x;
    _y = y;
  }

  void _smoothCubic(bool relative) {
    final bool reflects = _previousCommand?.toUpperCase() == 'C' ||
        _previousCommand?.toUpperCase() == 'S';
    final double x1 = reflects ? 2 * _x - _lastCubicX : _x;
    final double y1 = reflects ? 2 * _y - _lastCubicY : _y;
    final double x2 = _coordinate(_readNumber(), _x, relative);
    final double y2 = _coordinate(_readNumber(), _y, relative);
    final double x = _coordinate(_readNumber(), _x, relative);
    final double y = _coordinate(_readNumber(), _y, relative);
    _path.cubicTo(x1, y1, x2, y2, x, y);
    _lastCubicX = x2;
    _lastCubicY = y2;
    _x = x;
    _y = y;
  }

  void _quadratic(bool relative) {
    final double x1 = _coordinate(_readNumber(), _x, relative);
    final double y1 = _coordinate(_readNumber(), _y, relative);
    final double x = _coordinate(_readNumber(), _x, relative);
    final double y = _coordinate(_readNumber(), _y, relative);
    _path.quadraticBezierTo(x1, y1, x, y);
    _lastQuadraticX = x1;
    _lastQuadraticY = y1;
    _x = x;
    _y = y;
  }

  void _smoothQuadratic(bool relative) {
    final bool reflects = _previousCommand?.toUpperCase() == 'Q' ||
        _previousCommand?.toUpperCase() == 'T';
    final double x1 = reflects ? 2 * _x - _lastQuadraticX : _x;
    final double y1 = reflects ? 2 * _y - _lastQuadraticY : _y;
    final double x = _coordinate(_readNumber(), _x, relative);
    final double y = _coordinate(_readNumber(), _y, relative);
    _path.quadraticBezierTo(x1, y1, x, y);
    _lastQuadraticX = x1;
    _lastQuadraticY = y1;
    _x = x;
    _y = y;
  }

  void _arc(bool relative) {
    final double rx = _readNumber().abs();
    final double ry = _readNumber().abs();
    final double rotation = _readNumber();
    final bool largeArc = _readFlag();
    final bool sweep = _readFlag();
    final double x = _coordinate(_readNumber(), _x, relative);
    final double y = _coordinate(_readNumber(), _y, relative);
    _appendArc(_path, _x, _y, rx, ry, rotation, largeArc, sweep, x, y);
    _x = x;
    _y = y;
  }

  void _repeat(int arity, String command, void Function() read) {
    var count = 0;
    while (_hasNumber) {
      read();
      count++;
      _previousCommand = command;
    }
    if (count == 0) _fail('command needs $arity numeric arguments');
  }

  bool get _hasNumber {
    _skipSeparators();
    if (_offset >= data.length) return false;
    final int code = data.codeUnitAt(_offset);
    return code == 0x2B || code == 0x2D || code == 0x2E || _isDigit(code);
  }

  double _readNumber() {
    _skipSeparators();
    final Match? match = _number.matchAsPrefix(data, _offset);
    if (match == null) _fail('expected a number');
    _offset = match.end;
    final double? value = double.tryParse(match.group(0)!);
    if (value == null || !value.isFinite) _fail('number must be finite');
    return value;
  }

  bool _readFlag() {
    _skipSeparators();
    if (_offset >= data.length ||
        (data.codeUnitAt(_offset) != 0x30 &&
            data.codeUnitAt(_offset) != 0x31)) {
      _fail('arc flag must be 0 or 1');
    }
    return data.codeUnitAt(_offset++) == 0x31;
  }

  void _skipSeparators() {
    while (_offset < data.length) {
      final int code = data.codeUnitAt(_offset);
      if (code == 0x2C ||
          code == 0x20 ||
          code == 0x09 ||
          code == 0x0A ||
          code == 0x0D) {
        _offset++;
      } else {
        break;
      }
    }
  }

  Never _fail(String message) => throw SvgParseException(
        message,
        source: data,
        offset: _offset,
      );

  static double _coordinate(double value, double current, bool relative) =>
      relative ? current + value : value;

  static bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

  static bool _isCommand(int code) => switch (code | 0x20) {
        0x6D ||
        0x7A ||
        0x6C ||
        0x68 ||
        0x76 ||
        0x63 ||
        0x73 ||
        0x71 ||
        0x74 ||
        0x61 =>
          true,
        _ => false,
      };
}

void _appendArc(
  PathBuilder path,
  double x0,
  double y0,
  double rx,
  double ry,
  double degrees,
  bool largeArc,
  bool sweep,
  double x1,
  double y1,
) {
  if ((x0 == x1 && y0 == y1)) return;
  if (rx == 0 || ry == 0) {
    path.lineTo(x1, y1);
    return;
  }

  final double phi = degrees.remainder(360) * math.pi / 180;
  final double cosPhi = math.cos(phi);
  final double sinPhi = math.sin(phi);
  final double dx = (x0 - x1) / 2;
  final double dy = (y0 - y1) / 2;
  final double xp = cosPhi * dx + sinPhi * dy;
  final double yp = -sinPhi * dx + cosPhi * dy;

  var actualRx = rx;
  var actualRy = ry;
  final double lambda = xp * xp / (rx * rx) + yp * yp / (ry * ry);
  if (lambda > 1) {
    final double scale = math.sqrt(lambda);
    actualRx *= scale;
    actualRy *= scale;
  }

  final double rx2 = actualRx * actualRx;
  final double ry2 = actualRy * actualRy;
  final double numerator = math.max(
    0,
    rx2 * ry2 - rx2 * yp * yp - ry2 * xp * xp,
  );
  final double denominator = rx2 * yp * yp + ry2 * xp * xp;
  final double sign = largeArc == sweep ? -1 : 1;
  final double factor =
      denominator == 0 ? 0 : sign * math.sqrt(numerator / denominator);
  final double cxp = factor * actualRx * yp / actualRy;
  final double cyp = factor * -actualRy * xp / actualRx;
  final double cx = cosPhi * cxp - sinPhi * cyp + (x0 + x1) / 2;
  final double cy = sinPhi * cxp + cosPhi * cyp + (y0 + y1) / 2;

  final double ux = (xp - cxp) / actualRx;
  final double uy = (yp - cyp) / actualRy;
  final double vx = (-xp - cxp) / actualRx;
  final double vy = (-yp - cyp) / actualRy;
  final double start = math.atan2(uy, ux);
  var delta = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
  if (!sweep && delta > 0) delta -= math.pi * 2;
  if (sweep && delta < 0) delta += math.pi * 2;

  final int segments = (delta.abs() / (math.pi / 2)).ceil();
  final double step = delta / segments;
  var angle = start;
  for (var i = 0; i < segments; i++) {
    final double next = angle + step;
    final double alpha = 4 / 3 * math.tan((next - angle) / 4);
    final double cos0 = math.cos(angle);
    final double sin0 = math.sin(angle);
    final double cos1 = math.cos(next);
    final double sin1 = math.sin(next);

    double mapX(double ux, double uy) =>
        cx + actualRx * cosPhi * ux - actualRy * sinPhi * uy;
    double mapY(double ux, double uy) =>
        cy + actualRx * sinPhi * ux + actualRy * cosPhi * uy;

    path.cubicTo(
      mapX(cos0 - alpha * sin0, sin0 + alpha * cos0),
      mapY(cos0 - alpha * sin0, sin0 + alpha * cos0),
      mapX(cos1 + alpha * sin1, sin1 - alpha * cos1),
      mapY(cos1 + alpha * sin1, sin1 - alpha * cos1),
      i == segments - 1 ? x1 : mapX(cos1, sin1),
      i == segments - 1 ? y1 : mapY(cos1, sin1),
    );
    angle = next;
  }
}
