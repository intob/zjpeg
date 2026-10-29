# zjpeg

A JPEG decoder in pure Zig (0.17), no libc: byte-identical to libjpeg-turbo's default decompression; faster than
libjpeg-turbo's SIMD build on an M2 Pro overall (0.97x its time), slower on a Raspberry Pi 5 (1.14x). An encoder, and WebP in a sibling library, are next: see [PLAN.md](PLAN.md).

```zig
const zjpeg = @import("zjpeg");

var img = try zjpeg.decode(gpa, jpeg_bytes, .{});        // grey or RGB, 8 bits
defer img.deinit(gpa);

const info = try zjpeg.readInfo(jpeg_bytes);              // or decode into your own buffer
const pixels = try gpa.alloc(u8, info.len());
_ = try zjpeg.decodeInto(gpa, jpeg_bytes, pixels, .{ .max_pixels = 1 << 26 });
```

Supported: baseline, extended (8-bit, 16-bit quantisation tables) and progressive Huffman JPEG; greyscale, YCbCr and RGB;
restart intervals; any whole-ratio chroma subsampling; files without Huffman tables (Motion-JPEG). Not yet: arithmetic coding,
CMYK/YCCK, 12-bit, lossless, and libjpeg's block smoothing for truncated progressive files.

## Exact

Output matches libjpeg-turbo 3.2 (`tj3Decompress8`, default settings) byte for byte: its islow IDCT, its "fancy" upsampling,
its fixed-point YCbCr->RGB, its range limit, and what it does when data runs out (the rest of the MCUs up to the next restart
are mid grey) or a Huffman code is invalid (17 bits read, symbol 0). Checked on 345 files from libjpeg-turbo's cjpeg (1x1 to
333x221 synthetic images and five photos: quality 5 to 100, every subsampling, progressive, optimised tables, restarts by
block and by row, grey, RGB) and 80 real-world JPEGs.

On damaged files libjpeg-turbo disagrees with itself: its C IDCT works in 64 bits, its NEON and AVX2 ones in 32 and 16, so
coefficients no 8-bit image produces give different pixels depending on the build. zjpeg follows the C build exactly: its
vector IDCT is used only where it provably gives the 64-bit result (every input of a pass within 35079; see `safe_input`),
and a 64-bit scalar port of jidctint.c takes the rest. On every valid file, all of them agree.

```
scripts/make_corpus.sh PHOTO.jpg ...    # corpus/ (needs Pillow and libjpeg-turbo's cjpeg)
zig build check -- corpus/*.jpg         # 345 identical, 0 differ or fail
```

The vector code stays exact: the IDCT is jidctint.c's arithmetic on eight lanes (its zero-column and zero-row shortcuts give
what the full computation gives), the upsampler's special first and last columns are the general formula with the edge sample
repeated, and the colour tables' entries are computed in 16-bit lanes with each constant split so it fits
(91881 x = 65536 x + 26345 x).

## Speed

`zig build bench -- FILE...`: best of several rounds, each decoder writing into a buffer it reuses, libjpeg-turbo 3.2 from
Homebrew (NEON). M2 Pro, macOS, one core. Time is zjpeg's divided by libjpeg-turbo's: below 1 is faster.

| image | pixels | zjpeg ms | libjpeg-turbo ms | ratio |
|---|---|---|---|---|
| photo, q85 4:2:0 progressive | 16.7 M | 80.9 | 89.2 | 0.91 |
| photo, q85 4:2:0 progressive | 12.2 M | 89.7 | 96.3 | 0.93 |
| photo, q85 4:2:0 progressive | 8.3 M | 29.0 | 34.0 | 0.85 |
| photo, q85 4:2:0 | 16.7 M | 32.5 | 30.4 | 1.07 |
| photo, q85 4:2:0 | 12.2 M | 36.1 | 33.7 | 1.07 |
| photo, q85 4:2:0 | 8.3 M | 13.2 | 11.0 | 1.20 |
| photo, q92 4:4:4 | 16.7 M | 39.0 | 43.7 | 0.89 |
| photo, q92 4:4:4 | 12.2 M | 56.7 | 51.3 | 1.11 |
| photo, q92 4:4:4 | 8.3 M | 20.5 | 18.5 | 1.11 |
| **all nine** | | **398** | **408** | **0.97** |

At 640 px across five photos (baseline 4:2:0, progressive 4:4:4, grey) plus two 256 px tiles: 22.6 ms against 24.9 ms (0.91).
A 256 px 4:2:0 tile alone: 0.10 ms against 0.075 ms (1.33): per-image setup weighs there. Progressive is consistently
faster; baseline 4:2:0 is 1.07-1.20x, the gap the next round of entropy-decoding work is for.

### Raspberry Pi 5 (Cortex-A76, Linux)

The same comparison on a Pi 5 tells a different story: libjpeg-turbo 3.2.0 cross-built with `zig cc` for aarch64-linux-musl
with its NEON code (`-mcpu=cortex_a76`), zjpeg with `-Dcpu=cortex_a76`, both static, one pinned core, two Pis agreeing to
0.5%. Still byte-identical (347/347 against both the NEON and the C build), but slower:

| set | zjpeg ms | libjpeg-turbo ms | ratio |
|---|---|---|---|
| the nine large photos | 987 | 864 | 1.14 |
| baseline 4:2:0 (large) | 87 / 87 / 39 | 74 / 72 / 29 | 1.17-1.35 |
| progressive 4:2:0 (large) | 203 / 198 / 83 | 184 / 174 / 70 | 1.11-1.19 |
| q92 4:4:4 (large) | 134 / 100 / 57 | 111 / 105 / 46 | 0.95-1.25 |
| 640 px set and two tiles | 59.2 | 52.6 | 1.13 |
| 256 px 4:2:0 tile | 0.34 | 0.225 | 1.51 |

The M2's wide core hides what the A76 does not: 32-bit lanes in the IDCT where libjpeg-turbo's NEON uses 16, `tbl`
shuffles for RGB interleave where it uses `st3`, and per-image setup. That is the next performance work (PLAN.md).

Where the time goes in a baseline decode: entropy decoding ~40%, IDCT ~25%, colour conversion ~15%, upsampling ~5%.
Single-scan images are decoded in strips: three MCU rows of planes, rows of pixels written as each MCU row is done.

## Fuzzing

- `zig build fuzz -- FILE...`: mutation fuzzer for any OS. Bit flips, bytes, inserts, deletes, truncation, spliced chunks,
  16-bit fields, aimed at the headers half the time; ReleaseSafe with a leak-checking allocator; inputs libjpeg-turbo (its C
  build: the fuzzer sets `JSIMD_FORCENONE=1`) decodes without a warning must decode to the same pixels. A crash writes
  `fuzz-crash.jpg`; `-r FILE` replays one. `JSIMD_FORCENONE=1 zig build check -- ...` compares with the C build too.
  `-Dchecked-mode=debug` builds it (and `check`) in Debug for full stack traces.
- `zig build test --fuzz`: std's coverage-guided fuzzer over `decode` (Linux), seeded from `src/testdata/`.

Found so far, and fixed:
- two crashes: an overfull DHT segment overran the 9-bit lookup table before the code-space check; 4x vertical sampling of a
  65535-row image overflowed a 16-bit product (both inputs are in `src/testdata/`, replayed by `zig build test`);
- four differences from libjpeg on damaged files: it reads 17 bits for an invalid Huffman code, not 16 (its fast path, which
  decodes most of an in-memory file, does so without a warning); it computes the IDCT in 64 bits (above); it checks a scan's
  table selectors only where the scan uses them; it reads a quantisation table as 16-bit for any precision nibble but 0;
- three bugs in the harness: a TurboJPEG handle refused every file after its first warning (which had quietly turned the
  oracle off), and kept earlier files' tables for files that lack them (libjpeg's abbreviated datastreams), so both get a
  fresh handle per input now; and a truncation past the end.

Counted apart, not as differences:
- `FF FF` inside entropy-coded data, which no encoder writes: libjpeg-turbo's fast Huffman path takes it for a marker,
  decodes the rest of the MCU from zero bits, then has its slow path decode the MCU again without clearing what the first
  attempt wrote. Its slow path (`djpeg` reading a file) gives what zjpeg gives.
- libjpeg's block smoothing of progressive images whose first coefficients never fully arrived (truncated files): not
  implemented yet. `Image.unsmoothed` / `Info.unsmoothed` says when libjpeg would apply it.

## Layout

| | |
|---|---|
| `src/decoder.zig` | markers, frame and scans, sequential and progressive block decoding, strip output |
| `src/huffman.zig` | bit reader (stuffing, markers, zero fill) and Huffman tables with a one-lookup path for short codes |
| `src/idct.zig` | jidctint.c's islow IDCT, scalar (the tests' reference) and on vectors |
| `src/color.zig` | fancy upsampling and YCbCr->RGB on vectors |
| `tools/` | `check`, `bench`, `fuzz`, linked against libjpeg-turbo's TurboJPEG (`-Dturbo=PREFIX`) |
