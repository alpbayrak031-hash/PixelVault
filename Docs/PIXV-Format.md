# The `.pixv` image format, version 1.0

`.pixv` is PixelVault's lossy image format. It stores an image as a small **dictionary of
4×4 patterns** plus, for every block, **which pattern to use and how strongly to apply it**
(gain–shape vector quantisation). The image is coded as a **resolution pyramid**, so smooth
regions are carried by a few coarse blocks and only detailed regions spend bits on fine ones.

This document is enough to write an independent decoder. Sections 2–7 are normative;
section 8 describes what PixelVault's encoder does and is informative.

- Extension: `.pixv` · Uniform Type Identifier: `com.pixelvault.pixv` · MIME: `image/x-pixv`
- Reference implementation: `PixelVaultKit` (`Bitstream/` parses, `Codec/` reconstructs)

## 1. Overview

```
            ┌──────────────┐  upsample ×2   ┌────────────┐  upsample ×2   ┌────────────┐
 base layer │ 1/8 size     │ ─────────────▶ │ level 2    │ ─────────────▶ │ level 1    │ ─▶ level 0 = plane
 (lossless  │ DPCM + rANS  │   + patterns   │ 16 px      │   + patterns   │ 8 px       │   + patterns (4 px blocks)
  predictor)└──────────────┘                │ blocks     │                │ blocks     │
                                            └────────────┘                └────────────┘
```

Decoding a plane starts from a small **base layer** and repeats one step per **level**:
upsample the picture so far by 2, then add patterns to the 4×4 blocks that have any. Each
block carries a **mode** — the number of patterns stacked on it, possibly zero. A block's
footprint in the final image is 4 px at level 0, 8 px at level 1, 16 px at level 2, and so on.

A colour image has three planes: luma (Y′) at full size, and two chroma planes (Cb, Cr) at
half size in each direction. An optional alpha plane is full size.

### Conventions

- All multi-byte integers are **little-endian**.
- `u8`, `u16`, `u32` are unsigned integers of that many bits.
- `varint` is an unsigned LEB128 integer: 7 value bits per byte, least significant group
  first, high bit set on every byte except the last. Values above 2³¹−1 are invalid.
- `>>` is an arithmetic right shift. `/` on integers truncates.
- "Raster order" means row by row, top to bottom, left to right.

## 2. File layout

```
┌────────────────────────┐
│ Header        24 bytes │
├────────────────────────┤
│ Section "CBKS"         │  pattern dictionaries
├────────────────────────┤
│ Section "PLNE"         │  luma plane
│ Section "PLNE"         │  chroma Cb     (colour images only)
│ Section "PLNE"         │  chroma Cr     (colour images only)
│ Section "PLNE"         │  alpha         (if flagged)
└────────────────────────┘
```

### 2.1 Header

| Offset | Type    | Field         | Meaning |
|-------:|---------|---------------|---------|
| 0      | `u8[4]` | signature     | `50 49 58 56` — ASCII `PIXV` |
| 4      | `u8`    | version major | `1`. A reader must reject any other value. |
| 5      | `u8`    | version minor | `0`. A reader accepts any value; minor versions only add skippable sections. |
| 6      | `u16`   | flags         | bit 0: an alpha plane is present. Other bits are zero. |
| 8      | `u32`   | width         | image width in pixels, 1…32768 |
| 12     | `u32`   | height        | image height in pixels, 1…32768; `width × height ≤ 2²⁷` |
| 16     | `u8`    | colour model  | `0` grayscale (luma only) · `1` Y′CbCr 4:2:0 |
| 17     | `u8`    | luma levels   | `L`, the number of pattern-coded levels in the luma plane, 0…6 |
| 18     | `u8`    | block shift   | `2` (blocks are 4×4) |
| 19     | `u8`    | quality       | the encoder's quality setting, 1…100; informational |
| 20     | `u32`   | checksum      | CRC-32 of every byte after the header |

The checksum is the IEEE 802.3 CRC-32 (reflected, polynomial `0xEDB88320`, initial value and
final XOR `0xFFFFFFFF`) — the same one PNG and zip use.

### 2.2 Sections

After the header the file is a sequence of sections until end of file:

| Type    | Field   | Meaning |
|---------|---------|---------|
| `u8[4]` | tag     | ASCII section name |
| `u32`   | length  | payload size in bytes |
| …       | payload | |

A reader skips sections whose tag it does not know. Version 1.0 defines `CBKS` (exactly one,
before any plane) and `PLNE` (one per plane, in the order luma, Cb, Cr, alpha).

### 2.3 Geometry

Everything below follows from the header:

```
chromaLevels = max(0, L − 1)
alignment    = max(L ≥ 1 ? 2^(L+1) : 1,   chromaLevels ≥ 1 ? 2^(chromaLevels+2) : 2)
paddedWidth  = ceil(width  / alignment) × alignment        (likewise paddedHeight)
```

| Plane       | Size in samples                | Levels (`n`)   |
|-------------|--------------------------------|----------------|
| luma, alpha | `paddedWidth × paddedHeight`   | `L`            |
| Cb, Cr      | half of that in each direction | `chromaLevels` |

For a plane of size `W × H` with `n` levels:

- level `ℓ` (`0 ≤ ℓ < n`) is `(W >> ℓ) × (H >> ℓ)` samples, i.e. `(W >> ℓ)/4 × (H >> ℓ)/4` blocks;
- the base layer is `(W >> n) × (H >> n)` samples.

With `L = 0` there are no levels or dictionaries at all: each plane *is* its base layer.
Encoders use this for images too small to fill a dictionary.

## 3. Entropy coding

Every stream of symbols is coded with static **range ANS** (rANS): a 32-bit state with
byte-wise renormalisation and probabilities expressed in units of `2^-n`, where `n` is the
stream's *scale* — **12** for small alphabets, **15** for pattern indices.

### 3.1 Frequency tables

A table assigns each symbol `s` of an alphabet of size `A` a frequency `freq[s] ≥ 0`. The
frequencies sum to exactly `2^n`, or to zero for a table that is never used.
`start[s]` is the sum of the frequencies of all symbols below `s`.

Serialised form:

```
varint used                    number of leading symbols described (≤ A); the rest are zero
repeat until `used` symbols are described:
    varint f                   frequency of the next symbol
    if f == 0:
        varint extra           `extra` further symbols also have frequency zero
```

### 3.2 Decoding

A stream that codes zero symbols is zero bytes long. Otherwise:

```
x = first 4 bytes of the stream, as a u32                  # initial state
for each symbol, in order:
    slot = x & (2^n − 1)
    s    = the symbol with start[s] ≤ slot < start[s] + freq[s]
    x    = freq[s] × (x >> n) + slot − start[s]
    while x < 2^23:
        x = (x << 8) | next byte of the stream
```

A stream is valid only if, after its last symbol, every byte has been consumed and `x == 2^23`.
(An encoder starts from state `2^23`, codes the symbols in reverse order writing bytes back to
front, and finally writes the state.)

**Raw bits.** Some streams embed a `k`-bit unsigned value `v` as a uniformly distributed
symbol: `freq = 2^(n−k)`, `start = v × freq`. Decode it as `v = (x & (2^n − 1)) >> (n − k)`,
then advance the state as above.

### 3.3 Stream framing

Wherever this document says **stream**, the file contains

```
varint length
u8[length] payload
```

Every stream is self-contained, so a decoder may decode streams concurrently.

## 4. Dictionary section (`CBKS`)

```
u8 count                               number of dictionaries, ≤ 16
repeat count times:
    u8      id                         unique within the file
    u8      role                       0 = luma (also used by alpha), 1 = chroma
    u8      stage                      which stacking stage this dictionary serves, from 0
    varint  K                          number of patterns, ≤ 4096
    if K > 0:
        frequency table                scale 15, alphabet K: how often each pattern is used
        stream PATTERNS:
            frequency table            scale 12, alphabet 256
            rANS data                  K × 16 symbols
```

`PATTERNS` holds the patterns one after another, each as 16 samples in raster order, each
sample a signed value `−127…127` coded as the symbol `value + 128`.

The **usage table** is the probability model for every index stream that references the
dictionary (§5.4). PixelVault stores patterns most-used first; readers must not rely on it.

**Normalisation.** Before use, each stored pattern `e[0…15]` becomes a unit-length vector in
IEEE 754 single precision:

```
norm = sqrt(e[0]² + e[1]² + … + e[15]²)        # the sum is an exact integer
p[i] = e[i] / norm                              # an all-zero pattern stays all zero
```

## 5. Plane section (`PLNE`)

```
u8 kind                                0 = luma, 1 = Cb, 2 = Cr, 3 = alpha
u8 n                                   levels; must equal the value from §2.3
u8 S                                   stages: the most patterns a block may stack, ≤ 8
u8 baseStep                            base-layer quantiser step, ≥ 1
u8 gainStepHalves                      gain step Δ = gainStepHalves / 2, ≥ 1
u8 dictionary[S]                       id of the dictionary used by each stage

stream BASE                            §5.1
for ℓ = n − 1 down to 0:               coarsest level first
    stream MODES                       §5.2
    for stage = 0 … S − 1:
        varint count                   blocks of this level with mode > stage
        if count > 0:
            stream INDICES             §5.4
            stream GAINS               §5.4
```

### 5.1 Base layer

The base layer is a plane of quantised samples `q`, each in `0…maxLevel` with
`maxLevel = (255 + baseStep/2) / baseStep`. Its reconstruction is `min(255, q × baseStep)`.

`BASE` is `6` frequency tables (scale 12, alphabet 64), one per context, followed by rANS data.
Samples are coded in raster order. For each sample, with `a` the sample to the left, `b` the
one above and `c` the one above-left:

| Position            | `a`, `b`, `c` |
|---------------------|---------------|
| interior            | as defined |
| first row, `x > 0`  | `b = c = a` |
| first column, `y > 0` | `a = c = b` |
| top-left sample     | `a = b = c = (128 + baseStep/2) / baseStep` |

```
prediction = min(a, b)      if c ≥ max(a, b)
             max(a, b)      if c ≤ min(a, b)
             a + b − c      otherwise
context    = min(5, floor(log2(|a − c| + |b − c| + 1)))
```

Decode one symbol `t` using the table for `context`. If `t == 63`, read 9 raw bits as `u`;
otherwise `u = t`. Then

```
error = u / 2            if u is even
        −(u + 1) / 2     if u is odd
q     = prediction + error
```

A `q` outside `0…maxLevel` makes the file invalid.

### 5.2 Block modes

`MODES` codes one mode per block of the level, in raster order: `18` frequency tables
(scale 12, alphabet `S + 1`), then rANS data. The table for a block is chosen by

```
left    = mode of the block to the left, or 0 in the first column
up      = mode of the block above, or 0 in the first row
parent  = mode of block (x >> 1, y >> 1) of level ℓ + 1, or 0 for the coarsest level
context = 3 × min(left, 2) + min(up, 2) + (parent > 0 ? 9 : 0)
```

### 5.3 Meaning of a mode

A block with mode `m` stacks patterns from stages `0 … m − 1`. Mode `0` leaves the block
exactly as the level above predicts it.

### 5.4 Pattern indices and gains

For each stage, the blocks with `mode > stage` are listed in raster order. `INDICES` and
`GAINS` each carry one symbol per listed block.

- `INDICES` is rANS data only (no table of its own), decoded with the **usage table** of
  `dictionary[stage]`. Each symbol is a pattern index. A non-zero `count` for a dictionary with
  `K = 0` makes the file invalid.
- `GAINS` is a frequency table (scale 12, alphabet 256) followed by rANS data. Symbol `t`
  is the signed gain

  ```
  magnitude = (t >> 1) + 1            # 1 … 128
  gain      = (t & 1) ? −magnitude : magnitude
  ```

## 6. Reconstruction

### 6.1 Upsampling

`upsample` doubles a plane with Catmull-Rom interpolation at quarter-sample offsets, in
integer arithmetic. With `S` the source plane and indices clamped to its edges:

```
lower(a, b, c, d) = −3a + 29b + 111c −  9d         # sample at i − ¼ from i−2 … i+1
upper(b, c, d, e) = −9b + 111c +  29d −  3e         # sample at i + ¼ from i−1 … i+2

H[y][2x]     = (lower(S[y][x−2], S[y][x−1], S[y][x], S[y][x+1]) + 4) >> 3
H[y][2x + 1] = (upper(S[y][x−1], S[y][x], S[y][x+1], S[y][x+2]) + 4) >> 3

O[2y][X]     = clamp((lower(H[y−2][X], H[y−1][X], H[y][X], H[y+1][X]) + 1024) >> 11, 0, 255)
O[2y + 1][X] = clamp((upper(H[y−1][X], H[y][X], H[y+1][X], H[y+2][X]) + 1024) >> 11, 0, 255)
```

This must be reproduced exactly: every level's patterns are corrections to its output.

### 6.2 A plane

```
R = reconstructed base layer                                   # §5.1
for ℓ = n − 1 down to 0:
    P = upsample(R)
    for each block of level ℓ with mode m > 0:
        v[0…15] = the block's 16 samples of P, as single-precision floats
        for stage = 0 … m − 1:
            v[i] = v[i] + (gain × Δ) × p[i]                    # p from §4, one multiply, one add
        block[i] = floor(clamp(v[i], 0, 255) + 0.5)
    R = P with those blocks replaced
```

### 6.3 The image

1. Reconstruct every plane.
2. `upsample` each chroma plane once more, to luma size.
3. Discard the padding: keep the top-left `width × height` samples of each plane.
4. Convert to sRGB with the BT.601 full-range matrix. The reference decoder uses these
   2¹⁴-scaled coefficients, with `cb = Cb − 128` and `cr = Cr − 128`:

   ```
   R = clamp((16384·Y            + 22970·cr + 8192) / 16384, 0, 255)
   G = clamp((16384·Y −  5638·cb − 11700·cr + 8192) / 16384, 0, 255)
   B = clamp((16384·Y + 29032·cb            + 8192) / 16384, 0, 255)
   ```

   For a grayscale file, `R = G = B = Y`.
5. Alpha, when present, is the alpha plane's samples; colour is stored unpremultiplied.

Pixels are sRGB. An encoder converts from the source's colour space and bakes in its
orientation, so a `.pixv` carries no profile or orientation metadata.

## 7. Validity

A decoder must reject, without reading out of bounds or allocating without limit, a file that:

- has a bad signature, an unknown major version, or dimensions outside §2.1;
- fails the checksum, or ends inside any header, section, table or stream;
- lacks a plane required by the header, has one out of order, or has a level count that
  disagrees with §2.3;
- contains a frequency table that does not sum to `2^n` (or zero);
- contains a stream that does not end as §3.2 requires;
- codes a `count` that differs from the number of blocks with `mode > stage`;
- references a dictionary id that is not defined, or an empty dictionary.

Pattern indices cannot be out of range, because each is decoded against an alphabet of
exactly `K` symbols.

## 8. The reference encoder (informative)

Nothing here constrains a file; any stream that decodes is valid.

1. **Planes.** Convert to Y′CbCr (BT.601 full range), pad by repeating edge samples,
   box-average chroma to half size, and build each plane's pyramid by repeated 2×2 averaging.
   A neutral image is written as grayscale.
2. **Dictionaries.** Sample blocks from every level and collect their residuals against the
   upsampled coarser level. Train one dictionary per stage with gain–shape k-means: assign
   each residual `x` to the pattern maximising `|x · p|`, then move each pattern to
   `normalise(Σ (x · p) x)`. Later stages train on what earlier ones leave behind. Luma gets
   one family of dictionaries, the two chroma planes share another, and each family is shared
   by all pyramid levels.
3. **Matching.** Code each plane coarsest level first, each level against the upsampled
   *reconstruction* of the one above, so errors never accumulate. A block whose squared error
   is under a quality-dependent threshold gets mode 0. Otherwise stages are added while the
   best pattern removes at least a threshold's worth of error — a rate–distortion test that
   keeps weak matches out of the file. The match for all blocks of a level is one matrix
   product (Accelerate `vDSP_mmul`) followed by `vDSP_maxmgvi` per block.
4. **Entropy coding.** Unused patterns are dropped, the rest sorted by use, and every stream
   coded concurrently.

Levels are chosen from the shorter image side: 3 from 192 px, 2 from 64 px, 1 from 24 px,
otherwise 0. Quality 1…100 sets the error threshold (log-linear, mean squared error 100 → 2),
the stage limit (2–5 luma), the dictionary size limit (512–2048 patterns), and the gain step.

### Measured behaviour

Apple M5, 10 cores, release build, two 3840 × 2160 photographs, best of five runs. PSNR is
over R, G and B against the uncompressed original.

| Image   | Quality | `.pixv` size | Bits/pixel | PSNR    | Encode | Decode |
|---------|--------:|-------------:|-----------:|--------:|-------:|-------:|
| Lake    | 30      | 357 KB       | 0.35       | 35.7 dB | 35 ms  | 17 ms  |
| Lake    | 60      | 679 KB       | 0.66       | 39.1 dB | 60 ms  | 27 ms  |
| Lake    | 85      | 1.2 MB       | 1.14       | 41.8 dB | 150 ms | 36 ms  |
| Hills   | 30      | 514 KB       | 0.50       | 35.2 dB | 46 ms  | 21 ms  |
| Hills   | 60      | 940 KB       | 0.91       | 38.4 dB | 76 ms  | 30 ms  |
| Hills   | 85      | 1.6 MB       | 1.50       | 41.2 dB | 188 ms | 41 ms  |

For scale, the same two images encoded by macOS's own codecs to a similar size:

| Image | JPEG              | HEIC              | `.pixv`           |
|-------|-------------------|-------------------|-------------------|
| Lake  | 697 KB · 39.1 dB  | 617 KB · 40.3 dB  | 679 KB · 39.1 dB  |
| Hills | 896 KB · 38.1 dB  | 884 KB · 40.7 dB  | 940 KB · 38.4 dB  |

So at equal file size `.pixv` is on par with JPEG and about 2 dB behind HEIC. The large
ratios against a *source file* come from re-encoding at a lower quality than the source was
saved at — a 5.6 MB camera-quality JPEG becomes a 679 KB `.pixv` at quality 60 — not from
beating modern codecs at equal fidelity. `.pixv` is lossy: fine texture softens first, and
each re-encode loses a little more.
