# Unicode Character Database conformance data

The `.txt.gz` files in this directory are verbatim, gzip-compressed copies of
Unicode Character Database files, redistributed under the Unicode License v3.

| File | Version | Cases | Used by |
| --- | --- | --- | --- |
| `BidiTest.txt.gz` | UCD 17.0.0 | 490,846 | `test/text/bidi_test.dart` (UAX #9) |
| `BidiCharacterTest.txt.gz` | UCD 17.0.0 | 91,707 | `test/text/bidi_test.dart` (UAX #9) |
| `LineBreakTest.txt.gz` | UCD 17.0.0 | 19,338 | `test/text/line_break_test.dart` (UAX #14) |
| `GraphemeBreakTest.txt.gz` | UCD 17.0.0 | 766 | `test/text/grapheme_test.dart` (UAX #29) |

## Refreshing

Fetch the raw files and re-compress in place. Nothing else changes unless a
rule changed, in which case the suite will say so.

```sh
for f in BidiTest BidiCharacterTest LineBreakTest GraphemeBreakTest; do
  curl -fsSL "https://www.unicode.org/Public/17.0.0/ucd/auxiliary/$f.txt" \
    | gzip -9 -c > "test/data/unicode/$f.txt.gz"
done
```

`BidiTest.txt` and `BidiCharacterTest.txt` live directly under `ucd/`, not
under `ucd/auxiliary/`; adjust the path for those two.

The character property tables compiled into `lib/src/text/bidi.dart`,
`line_break.dart` and `grapheme.dart` come from `ucd.nounihan.flat.xml` of the
same release, which is 67 MB and is *not* committed. Regenerating them is a
separate step, documented in each of those files.

## Notice

UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2025 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS
INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT
OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.

Unicode and the Unicode Logo are registered trademarks of Unicode, Inc. in
the United States and other countries.
