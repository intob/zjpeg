# zjpeg / zwebp plan

Goal: JPEG and WebP decoding and encoding in pure Zig, for the soaring map server's move to Peregrine (aerial tiles: JPEG in,
WebP out), each library at least as fast as the C reference, matched against it, fuzzed.

The method for each codec:
- **Exact first.** Match the reference implementation's output byte for byte where its algorithm is fixed (libjpeg-turbo's
  decoder; libwebp's decoders), so the reference is a perfect oracle for differential testing and fuzzing. Encoders can't
  match byte for byte without copying every heuristic; they are judged on size and quality (SSIMULACRA2 / Butteraugli /
  PSNR) at a given speed, and their output must decode identically in the reference decoder and ours.
- **Then fast**, with `@Vector` code that stays exact, measured against the reference's SIMD build on the same machine.
- **Fuzz** every parser: the mutation fuzzer here (`zig build fuzz`, any OS, the reference as oracle) and std's
  coverage-guided fuzzer (`zig build test --fuzz`, Linux). Every input that found a bug stays in `src/testdata/`.

## M1. JPEG decoder ✅

- [x] Baseline, extended 8-bit (SOF1, 16-bit quantisation tables) and progressive Huffman JPEG; greyscale, YCbCr, RGB
      (Adobe transform 0, 'R','G','B' ids); restart intervals; any whole-ratio subsampling (4:4:4, 4:2:2, 4:2:0, 4:4:0, 4:1:1,
      mixed); Annex K tables for files without DHT (Motion-JPEG)
- [x] Byte-identical to libjpeg-turbo 3.2's default decompression (islow IDCT, fancy upsampling, its ycc->rgb tables, its
      range limit, its handling of running out of data): 345 generated files and 80 real-world ones
- [x] Errors where libjpeg-turbo errors: bad Huffman tables (including its reserved all-ones codes), bad progression
      parameters, duplicate components, MCUs over 10 blocks, missing tables
- [x] Faster than libjpeg-turbo (SIMD build) overall on an M2 Pro (0.97x); not yet on a Pi 5 (1.14x); see readme.md
- [x] Strip decoding for single-scan images: three MCU rows of planes, pixels written as each row is decoded
- [x] `decode`, `decodeInto` (caller's buffer), `readInfo`
- [x] Fuzzed: mutation fuzzer with libjpeg-turbo's C build as oracle; found two crashes (an overfull DHT overran the 9-bit
      lookup table; 4x vertical sampling of a 65535-row image overflowed 16 bits) and four differences on damaged data (17
      bits for an invalid Huffman code; the 64-bit IDCT, now used wherever 32 bits could overflow; table selectors checked
      only where used; any nonzero DQT precision is 16-bit); see readme.md for what is counted apart (FF FF fill bytes, block smoothing)
- [ ] Fuzz on Linux with `zig build test --fuzz` (coverage-guided) on the box

Open:
- [ ] Block smoothing (libjpeg's `do_block_smoothing`, jdcoefct.c decompress_smooth_data) for progressive files missing
      coefficient bands (truncated): today those differ from libjpeg-turbo; `unsmoothed` flags them
- [ ] CMYK / YCCK (4 components), arithmetic coding, 12-bit, DNL
- [ ] Scaled decoding (1/2, 1/4, 1/8 in the DCT domain, libjpeg's reduced IDCTs): thumbnails without a full decode
- [ ] Faster baseline 4:2:0 on small images (a 256 px tile is 1.1-1.3x libjpeg-turbo's time: per-image setup)
- [ ] Faster entropy decoding: it is now ~40% of a baseline decode; ideas: two symbols per lookup, a branchless EOB path
- [ ] Cortex-A76 (Pi 5): 1.14x libjpeg-turbo overall, 1.5x on a 256 px tile. Profile there (perf); likely wins: 16-bit
      lanes for IDCT pass 1 when the inputs allow it (the same guard idea as the 64-bit fallback), `st3`-style RGB stores
      instead of `tbl`, and less per-image setup (tables, allocations) for small images
- [ ] x86_64 numbers (AVX2 libjpeg-turbo) on the box

## M2. JPEG encoder

- [ ] Baseline 4:2:0 / 4:4:4 / grey, standard and optimised Huffman tables, restart intervals, libjpeg quality scaling
- [ ] Forward DCT matching libjpeg-turbo's islow FDCT and its quantisation, so at equal settings the coefficients (and so
      the file, with the same tables) match cjpeg byte for byte: an exact oracle again
- [ ] Progressive (libjpeg's default scan script), then trellis quantisation (mozjpeg's) as an option
- [ ] Bench against libjpeg-turbo's cjpeg path (tj3Compress8)

## M3. WebP decoder (zwebp)

- [ ] RIFF container, VP8L (lossless) with all transforms and colour cache, VP8 (lossy) with its loop filter, alpha (ALPH),
      animation frames as a later step
- [ ] Byte-identical to libwebp 1.6's decoder (VP8's integer IDCT and filter are fully specified; its YUV->RGB is
      libwebp's own fixed point)
- [ ] Bench against libwebp (dwebp's path, WebPDecodeRGBA), fuzz with libwebp as oracle

## M4. WebP encoder (zwebp)

- [ ] VP8L encoder first (simpler, exact round-trip testable), then VP8 lossy at roughly libwebp's `-m 4`: the aerial
      tiles need lossy with alpha (VP8 + ALPH)
- [ ] Judge on size vs SSIMULACRA2 against cwebp at equal speed

## M5. In the soaring server

- [ ] The aerial path in Zig: decode the upstream JPEG (zjpeg), mask (zig/src/tiles.zig), encode WebP (zwebp), behind the
      same C ABI ctypes uses today, then inside the Peregrine server
