/// Locates the Unicode conformance suites the bidi, line-breaking and
/// grapheme tests run against.
///
/// These four files are the reason those algorithms can be trusted: they are
/// written by Unicode, not by us, and they enumerate close to the entire input
/// space for short strings. A hand-written test suite for UAX #9 tells you
/// that the cases you thought of pass; `BidiTest.txt` tells you that 490,846
/// cases pass, including the ones you would never have thought of.
///
/// So they are committed rather than fetched. Stored gzipped because the raw
/// text is 18 MB and compresses to 1.9 MB, which is worth the four lines of
/// decompression below - a suite that is only green on the machine that
/// downloaded the data is not a suite, it is a memory.
///
/// The files are redistributed under the Unicode License v3; see `LICENSE.md`
/// in this directory for the notice and for the exact version and refresh
/// commands.
library;

import 'dart:convert';
import 'dart:io';

/// Where the committed copies live, relative to the package root.
const String ucdDataDirectory = 'test/data/unicode';

/// The lines of one conformance file, decompressed on demand.
///
/// [name] is the plain UCD filename, e.g. `BidiTest.txt`; the `.gz` suffix is
/// added here so callers name the file the way Unicode does.
///
/// Returns null when the file is absent, which lets a suite report itself as
/// skipped instead of passing vacuously. That should not happen in a normal
/// checkout - it exists so a shallow or filtered clone degrades honestly.
List<String>? ucdConformanceLines(String name) {
  final File file = File('$ucdDataDirectory/$name.gz');
  if (!file.existsSync()) return null;
  return const LineSplitter()
      .convert(utf8.decode(gzip.decode(file.readAsBytesSync())));
}
