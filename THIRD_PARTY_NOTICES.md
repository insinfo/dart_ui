# Third-party notices

## Inter

Inter is Copyright (c) 2016 The Inter Project Authors and is distributed
under the SIL Open Font License 1.1. The complete license is included at
`assets/fonts/Inter-OFL-1.1.txt`.

## Tabler Icons

Tabler Icons is Copyright (c) 2020-2026 Paweł Kuna and is distributed under
the MIT License. The complete license is included at
`assets/fonts/TablerIcons-MIT.txt`.

## Phosphor Icons

Phosphor Icons is Copyright (c) 2020-2021 Phosphor Icons and is distributed
under the MIT License. The complete license is included at
`assets/fonts/PhosphorIcons-MIT.txt`.

## docking_flutter

The docking layout public model and behavior were adapted for dart_ui from
`docking_flutter`, Copyright (c) 2021 Carlos Eduardo Leite de Andrade, under
the MIT License:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## Vello (referência arquitetural)

O protótipo `SparseStripGenerator` é uma implementação Dart independente do
conceito de sparse strips estudado no projeto Vello, Copyright 2020 the Vello
Authors. Nenhum código Rust foi portado. O material de referência local em
`referencias/vello-main` é oferecido sob Apache-2.0 ou MIT, à escolha; os textos
completos estão em `referencias/vello-main/LICENSE-APACHE` e
`referencias/vello-main/LICENSE-MIT`.

## Vello — sparse strip rasteriser (`vello_common`)

`lib/src/rendering/gpu/vector/native_strip_rasterizer.dart` ports the sparse
strip pipeline from Vello's `vello_common` crate — specifically the tile
generation of `tile.rs` (the per-crossing top-edge winding bit) and the
analytic area accumulation of `strip.rs` (the trapezoidal coverage loop, the
winding carried rightwards, and the sparse-fill handling between strips).

The port is scalar rather than SIMD, omits the off-viewport culling, and emits
into this repository's own `StripBuffer` instead of Vello's packed wire format;
the algorithm is otherwise faithful. Deviations are listed in the file's
library comment.

Vello is licensed Apache-2.0 OR MIT. Copyright 2025 the Vello Authors.
