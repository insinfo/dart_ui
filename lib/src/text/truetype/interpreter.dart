import 'dart:math' as math;
import 'dart:typed_data';

import 'graphics_state.dart';

/// A Call Frame for function execution.
class _CallFrame {
  _CallFrame(
      this.callerPc, this.callerStream, this.functionStartPc, this.loopCount);
  final int callerPc;
  final Uint8List callerStream;
  final int functionStartPc;
  int loopCount;
}

/// Exceptions thrown during bytecode execution.
final class InstructionException implements Exception {
  const InstructionException(this.message);
  final String message;

  @override
  String toString() => 'InstructionException: $message';
}

/// A representation of a TrueType Function or Instruction Definition.
final class DefRecord {
  DefRecord(this.stream, this.startPc, this.endPc);
  final Uint8List stream;
  final int startPc;
  final int endPc;
}

/// The TrueType Bytecode Interpreter.
final class TrueTypeInterpreter {
  TrueTypeInterpreter({
    required int maxStackElements,
    required int maxStorage,
    required int maxTwilightPoints,
  })  : _stack = Int32List(maxStackElements),
        _storage = Int32List(maxStorage),
        _twilightZone = Zone(maxPoints: maxTwilightPoints),
        _gs = GraphicsState();

  final Int32List _stack;
  int _top = 0;

  final Int32List _storage;
  final Zone _twilightZone;
  final GraphicsState _gs;

  Int16List? _cvt;
  Zone? _glyphZone;
  double _ppem = 0.0;

  /// Control Flow state
  int _pc = 0;
  int _step = 1;
  Uint8List _instructions = Uint8List(0);

  /// Function and Instruction definitions (FDEF, IDEF)
  final Map<int, DefRecord> _functions = <int, DefRecord>{};
  final Map<int, DefRecord> _instructionsDefs = <int, DefRecord>{};

  final List<_CallFrame> _callStack = [];

  void setCvt(Int16List cvt) {
    _cvt = cvt;
  }

  void setGlyphZone(Zone glyphZone) {
    _glyphZone = glyphZone;
  }

  void _push(int value) {
    if (_top >= _stack.length) {
      throw const InstructionException('Stack overflow');
    }
    _stack[_top++] = value;
  }

  int _pop() {
    if (_top <= 0) {
      throw const InstructionException('Stack underflow');
    }
    return _stack[--_top];
  }

  void _movePoint(Zone zone, int point, double dx, double dy) {
    zone.curX[point] += dx;
    zone.curY[point] += dy;
    zone.tags[point] |= 0x10; // Touched flag
  }

  /// Projects a vector based on the current projection vector.
  double _project(double dx, double dy) {
    return dx * _gs.projectionVector.x + dy * _gs.projectionVector.y;
  }

  double _dualProject(double dx, double dy) {
    return dx * _gs.dualProjectionVector.x + dy * _gs.dualProjectionVector.y;
  }

  /// Arredonda a distância de acordo com o roundState da VM
  double _round(double distance) {
    switch (_gs.roundState) {
      case 1: // Round to Grid (RTG)
        return ((distance + 32).truncate() & ~63).toDouble();
      case 2: // Round to Half Grid (RTHG)
        return ((distance).truncate() & ~63).toDouble() + 32.0;
      case 3: // Round to Double Grid (RTDG)
        return ((distance + 16).truncate() & ~31).toDouble();
      case 4: // Round Down to Grid (RDTG)
        return (distance.truncate() & ~63).toDouble();
      case 5: // Round Up to Grid (RUTG)
        return ((distance + 63).truncate() & ~63).toDouble();
      case 0:
      default:
        // Super Rounding simplificado ou sem arredondamento
        return distance;
    }
  }

  /// Move um ponto ao longo do Free Vector dada uma distância projetada
  void _movePointAlongFreeVector(Zone zone, int point, double distance) {
    // Calculamos o deslocamento real nos eixos X e Y
    final double dx = distance * _gs.freeVector.x;
    final double dy = distance * _gs.freeVector.y;
    _movePoint(zone, point, dx, dy);
  }

  void _interpolateUntouchedPoints(Zone zone, bool isX) {
    int firstPoint = 0;
    for (final int endPoint in zone.contourEnds) {
      if (endPoint >= zone.curX.length) break;
      _interpolateContour(zone, firstPoint, endPoint, isX);
      firstPoint = endPoint + 1;
    }
  }

  void _interpolateContour(Zone zone, int start, int end, bool isX) {
    final Float64List cur = isX ? zone.curX : zone.curY;
    final Float64List org = isX ? zone.orgX : zone.orgY;

    // Procura o primeiro ponto tocado
    int firstTouched = -1;
    for (int i = start; i <= end; i++) {
      if ((zone.tags[i] & 0x10) != 0) {
        firstTouched = i;
        break;
      }
    }

    // Se nenhum ponto foi tocado, não há nada a fazer
    if (firstTouched == -1) return;

    // Procura o último ponto tocado no contorno
    int lastTouched = firstTouched;
    for (int i = end; i >= start; i--) {
      if ((zone.tags[i] & 0x10) != 0) {
        lastTouched = i;
        break;
      }
    }

    // Interpola entre pontos tocados consecutivos
    int p1 = firstTouched;
    while (true) {
      int p2 = -1;
      for (int i = p1 + 1; i <= lastTouched; i++) {
        if ((zone.tags[i] & 0x10) != 0) {
          p2 = i;
          break;
        }
      }
      if (p2 == -1) break;

      _interpolateRange(cur, org, p1, p2, p1 + 1, p2 - 1);
      p1 = p2;
    }

    // Trata pontos antes do primeiro tocado e depois do último tocado (wrap-around)
    if (firstTouched > start || lastTouched < end) {
      _interpolateRange(
          cur, org, lastTouched, firstTouched, lastTouched + 1, end);
      _interpolateRange(
          cur, org, lastTouched, firstTouched, start, firstTouched - 1);
    }
  }

  void _interpolateRange(Float64List cur, Float64List org, int ref1, int ref2,
      int start, int end) {
    if (start > end) return;

    double org1 = org[ref1];
    double org2 = org[ref2];
    double cur1 = cur[ref1];
    double cur2 = cur[ref2];

    if (org1 > org2) {
      double t = org1;
      org1 = org2;
      org2 = t;
      t = cur1;
      cur1 = cur2;
      cur2 = t;
    }

    final double scale = (org1 == org2) ? 0.0 : (cur2 - cur1) / (org2 - org1);

    for (int i = start; i <= end; i++) {
      final double orgMid = org[i];
      if (orgMid <= org1) {
        cur[i] = orgMid + (cur1 - org1);
      } else if (orgMid >= org2) {
        cur[i] = orgMid + (cur2 - org2);
      } else {
        cur[i] = cur1 + (orgMid - org1) * scale;
      }
    }
  }

  void _normalize(double x, double y, TTVector target) {
    final double len = math.sqrt(x * x + y * y);
    if (len > 0.0) {
      target.x = x / len;
      target.y = y / len;
    } else {
      target.x = 1.0;
      target.y = 0.0;
    }
  }

  void run(Uint8List instructions, [double ppem = 0.0]) {
    _instructions = instructions;
    _ppem = ppem;
    _pc = 0;
    while (_pc < _instructions.length) {
      final int opcode = _instructions[_pc];
      _step = 1;

      final int loopCount = _gs.loop;
      _gs.loop = 1;

      for (int i = 0; i < loopCount; i++) {
        _executeOpcode(opcode);
        if (_pc >= _instructions.length) break;
      }

      _pc += _step;
    }
  }

  void _executeOpcode(int opcode) {
    switch (opcode) {
      // ----------------------------------------------------
      // VECTOR SETUP
      // ----------------------------------------------------
      case 0x00: // SVTCA[0] y-axis
      case 0x01: // SVTCA[1] x-axis
        final bool isX = (opcode & 1) != 0;
        _gs.projectionVector.x = isX ? 1.0 : 0.0;
        _gs.projectionVector.y = isX ? 0.0 : 1.0;
        _gs.freeVector.setFrom(_gs.projectionVector);
        _gs.dualProjectionVector.setFrom(_gs.projectionVector);
        break;

      case 0x02: // SPVTCA[0] y-axis
      case 0x03: // SPVTCA[1] x-axis
        final bool isX = (opcode & 1) != 0;
        _gs.projectionVector.x = isX ? 1.0 : 0.0;
        _gs.projectionVector.y = isX ? 0.0 : 1.0;
        _gs.dualProjectionVector.setFrom(_gs.projectionVector);
        break;

      case 0x04: // SFVTCA[0] y-axis
      case 0x05: // SFVTCA[1] x-axis
        final bool isX = (opcode & 1) != 0;
        _gs.freeVector.x = isX ? 1.0 : 0.0;
        _gs.freeVector.y = isX ? 0.0 : 1.0;
        break;

      case 0x06: // SPVTL[0]
      case 0x07: // SPVTL[1]
      case 0x08: // SFVTL[0]
      case 0x09: // SFVTL[1]
        final int p2 = _pop();
        final int p1 = _pop();
        final bool orthogonal = (opcode & 1) != 0;
        final bool isFree = opcode >= 0x08;

        final Zone z1 = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
        final Zone z2 = _gs.zp2 == 0 ? _twilightZone : _glyphZone!;
        double dx = z1.curX[p2] - z2.curX[p1];
        double dy = z1.curY[p2] - z2.curY[p1];
        if (dx == 0 && dy == 0) {
          dx = 1.0;
          dy = 0.0;
        } else if (orthogonal) {
          final double t = dy;
          dy = dx;
          dx = -t;
        }
        if (isFree) {
          _normalize(dx, dy, _gs.freeVector);
        } else {
          _normalize(dx, dy, _gs.projectionVector);
          _gs.dualProjectionVector.setFrom(_gs.projectionVector);
        }
        break;

      case 0x0A: // SPVFS
        final int y = _pop();
        final int x = _pop();
        _normalize(x.toDouble(), y.toDouble(), _gs.projectionVector);
        _gs.dualProjectionVector.setFrom(_gs.projectionVector);
        break;

      case 0x0B: // SFVFS
        final int y = _pop();
        final int x = _pop();
        _normalize(x.toDouble(), y.toDouble(), _gs.freeVector);
        break;

      case 0x0C: // GPV
        _push((_gs.projectionVector.x * 0x4000).round());
        _push((_gs.projectionVector.y * 0x4000).round());
        break;
      case 0x0D: // GFV
        _push((_gs.freeVector.x * 0x4000).round());
        _push((_gs.freeVector.y * 0x4000).round());
        break;

      case 0x0E: // SFVTPV
        _gs.freeVector.setFrom(_gs.projectionVector);
        break;

      case 0x0F: // ISECT
        _pop();
        _pop();
        _pop();
        _pop();
        _pop();
        break;

      // ----------------------------------------------------
      // GRAPHICS STATE
      // ----------------------------------------------------
      case 0x10: // SRP0
        _gs.rp0 = _pop();
        break;
      case 0x11: // SRP1
        _gs.rp1 = _pop();
        break;
      case 0x12: // SRP2
        _gs.rp2 = _pop();
        break;
      case 0x13: // SZP0
        _gs.zp0 = _pop();
        break;
      case 0x14: // SZP1
        _gs.zp1 = _pop();
        break;
      case 0x15: // SZP2
        _gs.zp2 = _pop();
        break;
      case 0x16: // SZPS
        final int z = _pop();
        _gs.zp0 = z;
        _gs.zp1 = z;
        _gs.zp2 = z;
        break;
      case 0x17: // SLOOP
        _gs.loop = _pop();
        break;
      case 0x18: // RTG
        _gs.roundState = 1;
        break;
      case 0x19: // RTHG
        _gs.roundState = 2;
        break;
      case 0x1A: // SMD
        _gs.minimumDistance = _pop() / 64.0;
        break;
      case 0x1D: // SCVTCI
        _gs.controlValueCutIn = _pop() / 64.0;
        break;
      case 0x1E: // SSWCI
        _gs.singleWidthCutIn = _pop() / 64.0;
        break;
      case 0x1F: // SSW
        _gs.singleWidthValue = _pop() / 64.0;
        break;
      case 0x4B: // MPPEM
        _push(_ppem.round());
        break;
      case 0x4C: // MPS
        _push((_ppem * 64.0).round());
        break;
      case 0x4D: // FLIPON
        _gs.autoFlip = true;
        break;
      case 0x4E: // FLIPOFF
        _gs.autoFlip = false;
        break;
      case 0x4F: // DEBUG
        _pop();
        break;

      // ----------------------------------------------------
      // STACK
      // ----------------------------------------------------
      case 0x20: // DUP
        final int val = _pop();
        _push(val);
        _push(val);
        break;
      case 0x21: // POP
        _pop();
        break;
      case 0x22: // CLEAR
        _top = 0;
        break;
      case 0x23: // SWAP
        final int v1 = _pop();
        final int v2 = _pop();
        _push(v1);
        _push(v2);
        break;
      case 0x24: // DEPTH
        _push(_top);
        break;
      case 0x25: // CINDEX
        final int index = _pop();
        _push(_stack[_top - index]);
        break;
      case 0x26: // MINDEX
        final int mindex = _pop();
        final int mval = _stack[_top - mindex];
        for (int i = _top - mindex; i < _top - 1; i++) {
          _stack[i] = _stack[i + 1];
        }
        _stack[_top - 1] = mval;
        break;
      case 0x8A: // ROLL
        final int rollC = _pop();
        final int rollB = _pop();
        final int rollA = _pop();
        _push(rollC);
        _push(rollA);
        _push(rollB);
        break;

      // ----------------------------------------------------
      // STORAGE AND CVT
      // ----------------------------------------------------
      case 0x42: // WS
        final int valW = _pop();
        final int idxW = _pop();
        if (idxW >= 0 && idxW < _storage.length) _storage[idxW] = valW;
        break;
      case 0x43: // RS
        final int idxR = _pop();
        _push((idxR >= 0 && idxR < _storage.length) ? _storage[idxR] : 0);
        break;
      case 0x44: // WCVTP
        final int cvtVal = _pop();
        final int cvtIdx = _pop();
        if (_cvt != null && cvtIdx >= 0 && cvtIdx < _cvt!.length)
          _cvt![cvtIdx] = cvtVal;
        break;
      case 0x45: // RCVT
        final int cIdx = _pop();
        _push((_cvt != null && cIdx >= 0 && cIdx < _cvt!.length)
            ? _cvt![cIdx]
            : 0);
        break;
      case 0x70: // WCVTF
        final int cvtValF = _pop();
        final int cvtIdxF = _pop();
        if (_cvt != null && cvtIdxF >= 0 && cvtIdxF < _cvt!.length)
          _cvt![cvtIdxF] = cvtValF;
        break;

      // ----------------------------------------------------
      // MATH AND LOGIC
      // ----------------------------------------------------
      case 0x50: // LT
        final int lt2 = _pop();
        final int lt1 = _pop();
        _push(lt1 < lt2 ? 1 : 0);
        break;
      case 0x51: // LTEQ
        final int lte2 = _pop();
        final int lte1 = _pop();
        _push(lte1 <= lte2 ? 1 : 0);
        break;
      case 0x52: // GT
        final int gt2 = _pop();
        final int gt1 = _pop();
        _push(gt1 > gt2 ? 1 : 0);
        break;
      case 0x53: // GTEQ
        final int gte2 = _pop();
        final int gte1 = _pop();
        _push(gte1 >= gte2 ? 1 : 0);
        break;
      case 0x54: // EQ
        _push(_pop() == _pop() ? 1 : 0);
        break;
      case 0x55: // NEQ
        _push(_pop() != _pop() ? 1 : 0);
        break;
      case 0x56: // ODD
        _push((_pop() % 64) != 0 ? 1 : 0);
        break;
      case 0x57: // EVEN
        _push((_pop() % 64) == 0 ? 1 : 0);
        break;
      case 0x5A: // AND
        final int a1 = _pop();
        final int a2 = _pop();
        _push((a1 != 0 && a2 != 0) ? 1 : 0);
        break;
      case 0x5B: // OR
        final int o1 = _pop();
        final int o2 = _pop();
        _push((o1 != 0 || o2 != 0) ? 1 : 0);
        break;
      case 0x5C: // NOT
        _push(_pop() == 0 ? 1 : 0);
        break;
      case 0x60: // ADD
        _push(_pop() + _pop());
        break;
      case 0x61: // SUB
        final int s2 = _pop();
        final int s1 = _pop();
        _push(s1 - s2);
        break;
      case 0x62: // DIV
        final int d2 = _pop();
        final int d1 = _pop();
        if (d2 == 0) throw const InstructionException('Division by zero');
        _push((d1 * 64) ~/ d2);
        break;
      case 0x63: // MUL
        _push((_pop() * _pop()) ~/ 64);
        break;
      case 0x64: // ABS
        final int v = _pop();
        _push(v < 0 ? -v : v);
        break;
      case 0x65: // NEG
        _push(-_pop());
        break;
      case 0x66: // FLOOR
        _push(_pop() & ~63);
        break;
      case 0x67: // CEILING
        _push((_pop() + 63) & ~63);
        break;
      case 0x68: // ROUND
      case 0x69:
      case 0x6A:
      case 0x6B:
        _push(_round(_pop().toDouble()).toInt());
        break;
      case 0x6C: // NROUND
      case 0x6D:
      case 0x6E:
      case 0x6F:
        _push(_pop());
        break;
      case 0x8B: // MAX
        final int maxB = _pop();
        final int maxA = _pop();
        _push(maxA > maxB ? maxA : maxB);
        break;
      case 0x8C: // MIN
        final int minB = _pop();
        final int minA = _pop();
        _push(minA < minB ? minA : minB);
        break;

      // ----------------------------------------------------
      // CONTROL FLOW
      // ----------------------------------------------------
      case 0x1C: // JMPR
        final int offset = _pop();
        _pc += offset - 1;
        _step = 1;
        break;
      case 0x78: // JROT
        final int o = _pop();
        if (_pop() != 0) {
          _pc += o - 1;
          _step = 1;
        }
        break;
      case 0x79: // JROF
        final int off = _pop();
        if (_pop() == 0) {
          _pc += off - 1;
          _step = 1;
        }
        break;
      case 0x1B: // ELSE
        int nesting = 1;
        while (nesting > 0) {
          _pc++;
          if (_pc >= _instructions.length) break;
          final int op = _instructions[_pc];
          if (op == 0x58) nesting++; // IF
          if (op == 0x59) nesting--; // EIF
        }
        _step = 0;
        break;
      case 0x58: // IF
        final int cond = _pop();
        if (cond == 0) {
          // falso, pular para ELSE ou EIF
          int nesting = 1;
          while (nesting > 0) {
            _pc++;
            if (_pc >= _instructions.length) break;
            final int op = _instructions[_pc];
            if (op == 0x58) nesting++; // IF
            if (op == 0x1B && nesting == 1) break; // ELSE
            if (op == 0x59) nesting--; // EIF
          }
          _step = 0;
        }
        break;
      case 0x59: // EIF
        break;

      case 0x2B: // CALL
        final int funcId = _pop();
        final DefRecord? rec = _functions[funcId];
        if (rec != null) {
          _callStack.add(_CallFrame(_pc + 1, _instructions, rec.startPc, 1));
          _instructions = rec.stream;
          _pc = rec.startPc;
          _step = 0;
        }
        break;
      case 0x2A: // LOOPCALL
        final int funcIdL = _pop();
        final int loops = _pop();
        if (loops > 0) {
          final DefRecord? rec = _functions[funcIdL];
          if (rec != null) {
            _callStack
                .add(_CallFrame(_pc + 1, _instructions, rec.startPc, loops));
            _instructions = rec.stream;
            _pc = rec.startPc;
            _step = 0;
          }
        }
        break;
      case 0x2C: // FDEF
        final int fId = _pop();
        final int startPc = _pc + 1;
        int fnesting = 1;
        while (fnesting > 0) {
          _pc++;
          if (_pc >= _instructions.length) break;
          final int op = _instructions[_pc];
          if (op == 0x2C) fnesting++;
          if (op == 0x2D) fnesting--;
        }
        _functions[fId] = DefRecord(_instructions, startPc, _pc);
        _step = 1;
        break;
      case 0x2D: // ENDF
        if (_callStack.isNotEmpty) {
          final _CallFrame frame = _callStack.last;
          frame.loopCount--;
          if (frame.loopCount > 0) {
            _pc = frame.functionStartPc;
            _step = 0;
          } else {
            _callStack.removeLast();
            _pc = frame.callerPc;
            _instructions = frame.callerStream;
            _step = 0;
          }
        }
        break;
      case 0x89: // IDEF
        final int iId = _pop();
        final int startPc = _pc + 1;
        int inesting = 1;
        while (inesting > 0) {
          _pc++;
          if (_pc >= _instructions.length) break;
          final int op = _instructions[_pc];
          if (op == 0x89 || op == 0x2C) inesting++;
          if (op == 0x2D) inesting--;
        }
        _instructionsDefs[iId] = DefRecord(_instructions, startPc, _pc);
        _step = 1;
        break;

      // ----------------------------------------------------
      // PUSH CONSTANTS
      // ----------------------------------------------------
      case 0x40: // NPUSHB
        final int countB = _instructions[_pc + 1];
        for (int i = 0; i < countB; i++) {
          _push(_instructions[_pc + 2 + i]);
        }
        _step = 2 + countB;
        break;
      case 0x41: // NPUSHW
        final int countW = _instructions[_pc + 1];
        for (int i = 0; i < countW; i++) {
          final int val = (_instructions[_pc + 2 + i * 2] << 8) |
              _instructions[_pc + 2 + i * 2 + 1];
          _push(val.toSigned(16));
        }
        _step = 2 + countW * 2;
        break;

      // ----------------------------------------------------
      // POINT MOVEMENT (Hinting)
      // ----------------------------------------------------
      case 0x27: // ALIGNPTS
        final int p1 = _pop();
        final int p2 = _pop();
        final Zone z0 = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
        final Zone z1 = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
        final double dist =
            _project(z0.curX[p2] - z1.curX[p1], z0.curY[p2] - z1.curY[p1]) /
                2.0;
        _movePointAlongFreeVector(z1, p1, dist);
        _movePointAlongFreeVector(z0, p2, -dist);
        break;

      case 0x29: // UTP
        final int p = _pop();
        final Zone z = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
        if (p >= 0 && p < z.tags.length) {
          z.tags[p] &= ~0x10;
        }
        break;

      case 0x2E: // MDAP[0]
      case 0x2F: // MDAP[1]
        final int p = _pop();
        final bool round = (opcode & 1) != 0;
        final Zone z = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
        double curDist = _project(z.curX[p], z.curY[p]);
        if (round) curDist = _round(curDist);
        _movePointAlongFreeVector(
            z, p, curDist - _project(z.curX[p], z.curY[p]));
        _gs.rp0 = p;
        _gs.rp1 = p;
        break;

      case 0x3E: // MIAP[0]
      case 0x3F: // MIAP[1]
        final int cvtIdx = _pop();
        final int p = _pop();
        final bool round = (opcode & 1) != 0;
        final Zone z = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
        double dist = _cvt != null ? _cvt![cvtIdx].toDouble() : 0.0;
        if (round) {
          double orgDist = _project(z.orgX[p], z.orgY[p]);
          if ((dist - orgDist).abs() > _gs.controlValueCutIn) dist = orgDist;
          dist = _round(dist);
        }
        _movePointAlongFreeVector(z, p, dist - _project(z.curX[p], z.curY[p]));
        _gs.rp0 = p;
        _gs.rp1 = p;
        break;

      case 0x3A: // MSIRP[0]
      case 0x3B: // MSIRP[1]
        _pop();
        final int p = _pop();
        _gs.rp1 = _gs.rp0;
        _gs.rp2 = p;
        final Zone z = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
        z.tags[p] |= 0x10;
        break;

      case 0x3C: // ALIGNRP
        final Zone z0 = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
        final Zone z1 = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
        for (int i = 0; i < _gs.loop; i++) {
          final int p = _pop();
          final double dist = _project(
              z1.curX[p] - z0.curX[_gs.rp0], z1.curY[p] - z0.curY[_gs.rp0]);
          _movePointAlongFreeVector(z1, p, -dist);
        }
        _gs.loop = 1;
        break;

      case 0x3D: // RTDG
        _gs.roundState = 3;
        break;

      case 0x32: // SHP[0]
      case 0x33: // SHP[1]
        final Zone refZ = (opcode & 1) != 0
            ? (_gs.zp0 == 0 ? _twilightZone : _glyphZone!)
            : (_gs.zp1 == 0 ? _twilightZone : _glyphZone!);
        final int refP = (opcode & 1) != 0 ? _gs.rp1 : _gs.rp2;
        final Zone targetZ = _gs.zp2 == 0 ? _twilightZone : _glyphZone!;
        final double shift = _project(refZ.curX[refP] - refZ.orgX[refP],
            refZ.curY[refP] - refZ.orgY[refP]);
        for (int i = 0; i < _gs.loop; i++) {
          final int p = _pop();
          _movePointAlongFreeVector(targetZ, p, shift);
        }
        _gs.loop = 1;
        break;

      case 0x34: // SHC[0]
      case 0x35: // SHC[1]
        final int contour = _pop();
        final Zone refZ = (opcode & 1) != 0
            ? (_gs.zp0 == 0 ? _twilightZone : _glyphZone!)
            : (_gs.zp1 == 0 ? _twilightZone : _glyphZone!);
        final int refP = (opcode & 1) != 0 ? _gs.rp1 : _gs.rp2;
        final Zone targetZ = _gs.zp2 == 0 ? _twilightZone : _glyphZone!;
        final double shift = _project(refZ.curX[refP] - refZ.orgX[refP],
            refZ.curY[refP] - refZ.orgY[refP]);
        if (_gs.zp2 == 0) {
          for (int i = 0; i < targetZ.curX.length; i++) {
            if (i != refP || refZ != targetZ)
              _movePointAlongFreeVector(targetZ, i, shift);
          }
        } else if (contour >= 0 && contour < targetZ.contourEnds.length) {
          final int start =
              contour == 0 ? 0 : targetZ.contourEnds[contour - 1] + 1;
          final int end = targetZ.contourEnds[contour];
          for (int i = start; i <= end; i++) {
            if (i != refP || refZ != targetZ)
              _movePointAlongFreeVector(targetZ, i, shift);
          }
        }
        break;

      case 0x36: // SHZ[0]
      case 0x37: // SHZ[1]
        final int z = _pop();
        final Zone refZ = (opcode & 1) != 0
            ? (_gs.zp0 == 0 ? _twilightZone : _glyphZone!)
            : (_gs.zp1 == 0 ? _twilightZone : _glyphZone!);
        final int refP = (opcode & 1) != 0 ? _gs.rp1 : _gs.rp2;
        final double shift = _project(refZ.curX[refP] - refZ.orgX[refP],
            refZ.curY[refP] - refZ.orgY[refP]);
        final Zone targetZ = z == 0 ? _twilightZone : _glyphZone!;
        final int limit = z == 0
            ? _twilightZone.curX.length
            : (_glyphZone != null
                ? math.max(0, _glyphZone!.curX.length - 4)
                : 0);
        for (int i = 0; i < limit; i++) {
          _movePointAlongFreeVector(targetZ, i, shift);
        }
        break;

      case 0x38: // SHPIX
        final double disp = _cvt != null ? _cvt![_pop()].toDouble() : 0.0;
        double shift = disp / 64.0;
        for (int i = 0; i < _gs.loop; i++) {
          final int p = _pop();
          final Zone z = _gs.zp2 == 0 ? _twilightZone : _glyphZone!;
          _movePointAlongFreeVector(z, p, shift);
        }
        _gs.loop = 1;
        break;

      case 0x30: // IUP[0]
      case 0x31: // IUP[1]
        if (_glyphZone != null) {
          final bool isX = (opcode & 1) == 0;
          _interpolateUntouchedPoints(_glyphZone!, isX);
        }
        _gs.loop = 1;
        break;
      case 0x39: // IP
        final Zone z0 = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
        final Zone z1 = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
        final Zone z2 = _gs.zp2 == 0 ? _twilightZone : _glyphZone!;

        double oldRange = _dualProject(z1.orgX[_gs.rp2] - z0.orgX[_gs.rp1],
            z1.orgY[_gs.rp2] - z0.orgY[_gs.rp1]);
        double curRange = _project(z1.curX[_gs.rp2] - z0.curX[_gs.rp1],
            z1.curY[_gs.rp2] - z0.curY[_gs.rp1]);

        for (int i = 0; i < _gs.loop; i++) {
          final int p = _pop();
          double orgDist = _dualProject(
              z2.orgX[p] - z0.orgX[_gs.rp1], z2.orgY[p] - z0.orgY[_gs.rp1]);
          double curDist = _project(
              z2.curX[p] - z0.curX[_gs.rp1], z2.curY[p] - z0.curY[_gs.rp1]);

          double newDist = 0.0;
          if (orgDist != 0) {
            if (oldRange != 0) {
              newDist = (orgDist * curRange) / oldRange;
            } else {
              newDist = orgDist;
            }
          }
          _movePointAlongFreeVector(z2, p, newDist - curDist);
        }
        _gs.loop = 1;
        break;

      case 0x46: // GC[0]
      case 0x47: // GC[1]
        final int p = _pop();
        final Zone z = _gs.zp2 == 0 ? _twilightZone : _glyphZone!;
        final double val = (opcode & 1) != 0
            ? _dualProject(z.orgX[p], z.orgY[p])
            : _project(z.curX[p], z.curY[p]);
        _push((val * 64.0).round());
        break;

      case 0x48: // SCFS
        final int value = _pop();
        final int p = _pop();
        final Zone z = _gs.zp2 == 0 ? _twilightZone : _glyphZone!;
        final double cur = _project(z.curX[p], z.curY[p]);
        _movePointAlongFreeVector(z, p, (value / 64.0) - cur);
        if (_gs.zp2 == 0) {
          z.orgX[p] = z.curX[p];
          z.orgY[p] = z.curY[p];
        }
        break;

      case 0x49: // MD[0]
      case 0x4A: // MD[1]
        final int p2 = _pop();
        final int p1 = _pop();
        final Zone z0 = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
        final Zone z1 = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
        final double d = (opcode & 1) != 0
            ? _project(z0.curX[p1] - z1.curX[p2], z0.curY[p1] - z1.curY[p2])
            : _dualProject(
                z0.orgX[p1] - z1.orgX[p2], z0.orgY[p1] - z1.orgY[p2]);
        _push((d * 64.0).round());
        break;

      case 0x5D: // DELTAP1
      case 0x71: // DELTAP2
      case 0x72: // DELTAP3
        final int nump = _pop();
        final int pShift = opcode == 0x5D ? 0 : (opcode == 0x71 ? 16 : 32);
        final int pDelta = (_ppem.round() - _gs.deltaBase) - pShift;
        final int factor = 1 << (6 - _gs.deltaShift);
        final Zone z = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
        for (int i = 0; i < nump; i++) {
          final int argB = _pop();
          final int ptA = _pop();
          if (pDelta >= 0 && pDelta <= 15 && ((argB & 0xF0) >> 4) == pDelta) {
            int bMag = (argB & 0x0F) - 8;
            if (bMag >= 0) bMag++;
            final double shift = (bMag * factor) / 64.0;
            _movePointAlongFreeVector(z, ptA, shift);
          }
        }
        break;

      case 0x5E: // SDB
        _gs.deltaBase = _pop();
        break;
      case 0x5F: // SDS
        _gs.deltaShift = _pop();
        break;

      case 0x73: // DELTAC1
      case 0x74: // DELTAC2
      case 0x75: // DELTAC3
        final int numc = _pop();
        final int cShift = opcode == 0x73 ? 0 : (opcode == 0x74 ? 16 : 32);
        final int cDelta = (_ppem.round() - _gs.deltaBase) - cShift;
        final int factor = 1 << (6 - _gs.deltaShift);
        for (int i = 0; i < numc; i++) {
          final int argB = _pop();
          final int cvtA = _pop();
          if (cDelta >= 0 && cDelta <= 15 && ((argB & 0xF0) >> 4) == cDelta) {
            int bMag = (argB & 0x0F) - 8;
            if (bMag >= 0) bMag++;
            if (_cvt != null && cvtA >= 0 && cvtA < _cvt!.length) {
              _cvt![cvtA] += bMag * factor;
            }
          }
        }
        break;

      case 0x76: // SROUND
      case 0x77: // S45ROUND
      case 0x7A: // ROFF
        _pop(); // pop selector / threshold
        _gs.roundState = 0;
        break;
      case 0x7C: // RUTG
        _gs.roundState = 5;
        break;
      case 0x7D: // RDTG
        _gs.roundState = 4;
        break;

      case 0x80: // FLIPPT
        if (_glyphZone != null) {
          for (int i = 0; i < _gs.loop; i++) {
            final int p = _pop();
            _glyphZone!.tags[p] ^= 0x01;
          }
        }
        _gs.loop = 1;
        break;
      case 0x81: // FLIPRGON
        if (_glyphZone != null) {
          final int l = _pop();
          final int k = _pop();
          for (int i = k; i <= l; i++) {
            _glyphZone!.tags[i] |= 0x01;
          }
        }
        break;
      case 0x82: // FLIPRGOFF
        if (_glyphZone != null) {
          final int l = _pop();
          final int k = _pop();
          for (int i = k; i <= l; i++) {
            _glyphZone!.tags[i] &= ~0x01;
          }
        }
        break;

      case 0x85: // SCANCTRL
      case 0x8D: // SCANTYPE
        _pop();
        break;
      case 0x8E: // INSTCTRL
        _pop();
        _pop();
        break;

      case 0x86: // SDPVTL[0]
      case 0x87: // SDPVTL[1]
        final int p2 = _pop();
        final int p1 = _pop();
        final bool orthogonal = (opcode & 1) != 0;
        final Zone z1 = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
        final Zone z2 = _gs.zp2 == 0 ? _twilightZone : _glyphZone!;
        // Dual vector from org
        double dxOrg = z1.orgX[p2] - z2.orgX[p1];
        double dyOrg = z1.orgY[p2] - z2.orgY[p1];
        if (dxOrg == 0 && dyOrg == 0) {
          dxOrg = 1.0;
          dyOrg = 0.0;
        } else if (orthogonal) {
          final double t = dyOrg;
          dyOrg = dxOrg;
          dxOrg = -t;
        }
        _normalize(dxOrg, dyOrg, _gs.dualProjectionVector);

        // Proj vector from cur
        double dxCur = z1.curX[p2] - z2.curX[p1];
        double dyCur = z1.curY[p2] - z2.curY[p1];
        if (dxCur == 0 && dyCur == 0) {
          dxCur = 1.0;
          dyCur = 0.0;
        } else if (orthogonal) {
          final double t = dyCur;
          dyCur = dxCur;
          dxCur = -t;
        }
        _normalize(dxCur, dyCur, _gs.projectionVector);
        break;

      case 0x88: // GETINFO
        final int sel = _pop();
        int res = 0;
        if ((sel & 1) != 0) res |= 35;
        if ((sel & 32) != 0) res |= (1 << 12);
        if ((sel & 64) != 0) res |= (1 << 13);
        _push(res);
        break;

      default:
        // PUSHB / PUSHW check
        if (opcode >= 0xB0 && opcode <= 0xB7) {
          // PUSHB[abc]
          final int count = opcode - 0xB0 + 1;
          for (int i = 0; i < count; i++) {
            _push(_instructions[_pc + 1 + i]);
          }
          _step = 1 + count;
        } else if (opcode >= 0xB8 && opcode <= 0xBF) {
          // PUSHW[abc]
          final int count = opcode - 0xB8 + 1;
          for (int i = 0; i < count; i++) {
            final int val = (_instructions[_pc + 1 + i * 2] << 8) |
                _instructions[_pc + 1 + i * 2 + 1];
            _push(val.toSigned(16));
          }
          _step = 1 + count * 2;
        } else if (opcode >= 0xC0 && opcode <= 0xDF) {
          // MDRP
          final int p = _pop();
          final bool setRp0 = (opcode & 0x10) != 0;
          final bool minDistance = (opcode & 0x08) != 0;
          final bool round = (opcode & 0x04) != 0;
          final Zone z1 = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
          final Zone z2 = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
          final double orgDist = _dualProject(
              z2.orgX[p] - z1.orgX[_gs.rp0], z2.orgY[p] - z1.orgY[_gs.rp0]);
          final double curDist = _project(
              z2.curX[p] - z1.curX[_gs.rp0], z2.curY[p] - z1.curY[_gs.rp0]);
          double dist = orgDist;

          if (round) dist = _round(dist); // + compensation futuramente

          if (minDistance) {
            if (orgDist >= 0) {
              if (dist < _gs.minimumDistance) dist = _gs.minimumDistance;
            } else {
              if (dist > -_gs.minimumDistance) dist = -_gs.minimumDistance;
            }
          }

          _movePointAlongFreeVector(z2, p, dist - curDist);
          _gs.rp1 = _gs.rp0;
          _gs.rp2 = p;
          if (setRp0) _gs.rp0 = p;
        } else if (opcode >= 0xE0 && opcode <= 0xFF) {
          // MIRP
          final int cvtIdx = _pop();
          final int p = _pop();
          final bool setRp0 = (opcode & 0x10) != 0;
          final bool minDistance = (opcode & 0x08) != 0;
          final bool round = (opcode & 0x04) != 0;
          final Zone z1 = _gs.zp0 == 0 ? _twilightZone : _glyphZone!;
          final Zone z2 = _gs.zp1 == 0 ? _twilightZone : _glyphZone!;
          final double cvtDist = _cvt != null ? _cvt![cvtIdx].toDouble() : 0.0;
          final double orgDist = _dualProject(
              z2.orgX[p] - z1.orgX[_gs.rp0], z2.orgY[p] - z1.orgY[_gs.rp0]);
          final double curDist = _project(
              z2.curX[p] - z1.curX[_gs.rp0], z2.curY[p] - z1.curY[_gs.rp0]);
          double dist = cvtDist;

          if (round) {
            if ((dist - orgDist).abs() > _gs.controlValueCutIn) dist = orgDist;
            dist = _round(dist);
          }

          if (minDistance) {
            if (orgDist >= 0) {
              if (dist < _gs.minimumDistance) dist = _gs.minimumDistance;
            } else {
              if (dist > -_gs.minimumDistance) dist = -_gs.minimumDistance;
            }
          }

          _movePointAlongFreeVector(z2, p, dist - curDist);
          _gs.rp1 = _gs.rp0;
          _gs.rp2 = p;
          if (setRp0) _gs.rp0 = p;
        } else {
          // Opcode nulo ou não suportado, avançar.
        }
        break;
    }
  }
}
