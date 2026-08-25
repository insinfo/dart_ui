import 'dart:typed_data';

class Mp3ReservoirStream {
  Mp3ReservoirStream(this.resvMax);

  /// Max reservoir bytes the back-pointer field can express (511 for MPEG-1).
  final int resvMax;

  final List<int> _stream = []; // live window; _stream[0] == absolute _head
  int _slotStart = 0; // absolute slot cursor (sum of queued slot_md)
  int _dataPos = 0; // absolute end of produced main data
  int _head = 0; // absolute index of _stream[0]
  final List<_Pending> _pending = [];

  /// Reservoir bytes available to the frame about to be encoded — the value to
  /// write into `main_data_begin`; 8× this is the extra bit budget.
  int mainDataBegin() {
    var mdb = _slotStart - _dataPos;
    if (mdb < 0) mdb = 0;
    if (mdb > resvMax) mdb = resvMax;
    return mdb;
  }

  /// Append one encoded frame: [headerSi] = header(4) + side-info bytes, [md] =
  /// this frame's byte-aligned main data, [slotMd] = main-data bytes the frame's
  /// slot carries (frameSize − headerSi.length). Emits any now-complete frames.
  void addFrame(
    Uint8List headerSi,
    Uint8List md,
    int slotMd,
    BytesBuilder out,
  ) {
    _append(md);
    // Cap the reservoir: keep the gap to the next slot within resvMax so the
    // bounded main_data_begin field can always express it (stuffing lands in a
    // slot tail no frame references, which decoders skip).
    final gap = (_slotStart + slotMd) - _dataPos;
    if (gap > resvMax) _padZeros(gap - resvMax);

    _pending.add(_Pending(headerSi, _slotStart, slotMd));
    _slotStart += slotMd;
    _drain(out, false);
  }

  /// Release all buffered frames at end of stream, padding the final slots.
  void flush(BytesBuilder out) {
    if (_dataPos < _slotStart) _padZeros(_slotStart - _dataPos);
    _drain(out, true);
  }

  void _append(Uint8List p) {
    _stream.addAll(p);
    _dataPos += p.length;
  }

  void _padZeros(int n) {
    for (var i = 0; i < n; i++) {
      _stream.add(0);
    }
    _dataPos += n;
  }

  void _drain(BytesBuilder out, bool isFinal) {
    var i = 0;
    while (i < _pending.length) {
      final p = _pending[i];
      final slotEnd = p.slotStart + p.slotMd;
      if (!isFinal && _dataPos < slotEnd) break; // slot not yet full
      out.add(p.headerSi);
      final off = p.slotStart - _head;
      // Slot bytes (may run past produced data on the final flush → zero pad).
      for (var k = 0; k < p.slotMd; k++) {
        final idx = off + k;
        out.addByte(idx >= 0 && idx < _stream.length ? _stream[idx] : 0);
      }
      // Discard stream bytes now fully emitted.
      final newHeadOff = slotEnd - _head;
      if (newHeadOff > 0) {
        _stream.removeRange(0, newHeadOff.clamp(0, _stream.length));
        _head = slotEnd;
      }
      i++;
    }
    _pending.removeRange(0, i);
  }
}

class _Pending {
  _Pending(this.headerSi, this.slotStart, this.slotMd);
  final Uint8List headerSi;
  final int slotStart;
  final int slotMd;
}
