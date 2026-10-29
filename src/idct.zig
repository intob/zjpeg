//! The inverse DCT: libjpeg-turbo's default "islow" (jidctint.c, the Loeffler-Ligtenberg-Moschytz factorisation in 13-bit fixed
//! point), ported so the output matches it bit for bit. Its SIMD versions (NEON, AVX2) give the same results as its C code.
const std = @import("std");

const CONST_BITS = 13;
const PASS1_BITS = 2;
const FIX_0_298631336 = 2446;
const FIX_0_390180644 = 3196;
const FIX_0_541196100 = 4433;
const FIX_0_765366865 = 6270;
const FIX_0_899976223 = 7373;
const FIX_1_175875602 = 9633;
const FIX_1_501321110 = 12299;
const FIX_1_847759065 = 15137;
const FIX_1_961570560 = 16069;
const FIX_2_053119869 = 16819;
const FIX_2_562915447 = 20995;
const FIX_3_072711026 = 25172;

/// libjpeg's post-IDCT range limit (jdmaster.c prepare_range_limit_table, indexed by x & 1023): x + 128 clamped to 0..255 for
/// -512 <= x < 512; values further out wrap, as they do there.
pub const range_limit: [1024]u8 = blk: {
    @setEvalBranchQuota(5000);
    var t: [1024]u8 = undefined;
    for (0..1024) |i| t[i] = if (i < 128) i + 128 else if (i < 512) 255 else if (i < 896) 0 else i - 896;
    break :blk t;
};

const V = @Vector(8, i32);

inline fn sp(v: i32) V {
    return @splat(v);
}

/// One 8-point pass of jidctint.c over eight lanes at once: x[k] holds input k of each lane; the outputs are descaled by n.
inline fn pass(x: [8]V, comptime n: u5) [8]V {
    const z1 = (x[2] +% x[6]) *% sp(FIX_0_541196100);
    const tmp2e = z1 +% x[6] *% sp(-FIX_1_847759065);
    const tmp3e = z1 +% x[2] *% sp(FIX_0_765366865);
    const tmp0e = (x[0] +% x[4]) *% sp(1 << CONST_BITS);
    const tmp1e = (x[0] -% x[4]) *% sp(1 << CONST_BITS);
    const tmp10 = tmp0e +% tmp3e;
    const tmp13 = tmp0e -% tmp3e;
    const tmp11 = tmp1e +% tmp2e;
    const tmp12 = tmp1e -% tmp2e;
    var tmp0 = x[7];
    var tmp1 = x[5];
    var tmp2 = x[3];
    var tmp3 = x[1];
    const za = tmp0 +% tmp3;
    const zb = tmp1 +% tmp2;
    var zc = tmp0 +% tmp2;
    var zd = tmp1 +% tmp3;
    const z5 = (zc +% zd) *% sp(FIX_1_175875602);
    tmp0 *%= sp(FIX_0_298631336);
    tmp1 *%= sp(FIX_2_053119869);
    tmp2 *%= sp(FIX_3_072711026);
    tmp3 *%= sp(FIX_1_501321110);
    const z1o = za *% sp(-FIX_0_899976223);
    const z2o = zb *% sp(-FIX_2_562915447);
    zc = zc *% sp(-FIX_1_961570560) +% z5;
    zd = zd *% sp(-FIX_0_390180644) +% z5;
    tmp0 +%= z1o +% zc;
    tmp1 +%= z2o +% zd;
    tmp2 +%= z2o +% zc;
    tmp3 +%= z1o +% zd;
    const r = sp(1 << (n - 1));
    const sh: @Vector(8, u5) = @splat(n);
    return .{
        (tmp10 +% tmp3 +% r) >> sh, (tmp11 +% tmp2 +% r) >> sh, (tmp12 +% tmp1 +% r) >> sh, (tmp13 +% tmp0 +% r) >> sh,
        (tmp13 -% tmp0 +% r) >> sh, (tmp12 -% tmp1 +% r) >> sh, (tmp11 -% tmp2 +% r) >> sh, (tmp10 -% tmp3 +% r) >> sh,
    };
}

/// 8x8 transpose in three rounds of pairwise interleaves (zip/uzp on NEON).
inline fn transpose(m: [8]V) [8]V {
    const lo1 = [8]i32{ 0, ~@as(i32, 0), 2, ~@as(i32, 2), 4, ~@as(i32, 4), 6, ~@as(i32, 6) };
    const hi1 = [8]i32{ 1, ~@as(i32, 1), 3, ~@as(i32, 3), 5, ~@as(i32, 5), 7, ~@as(i32, 7) };
    const lo2 = [8]i32{ 0, 1, ~@as(i32, 0), ~@as(i32, 1), 4, 5, ~@as(i32, 4), ~@as(i32, 5) };
    const hi2 = [8]i32{ 2, 3, ~@as(i32, 2), ~@as(i32, 3), 6, 7, ~@as(i32, 6), ~@as(i32, 7) };
    const lo4 = [8]i32{ 0, 1, 2, 3, ~@as(i32, 0), ~@as(i32, 1), ~@as(i32, 2), ~@as(i32, 3) };
    const hi4 = [8]i32{ 4, 5, 6, 7, ~@as(i32, 4), ~@as(i32, 5), ~@as(i32, 6), ~@as(i32, 7) };
    var a: [8]V = undefined;
    inline for (0..4) |i| {
        a[2 * i] = @shuffle(i32, m[2 * i], m[2 * i + 1], lo1);
        a[2 * i + 1] = @shuffle(i32, m[2 * i], m[2 * i + 1], hi1);
    }
    var b: [8]V = undefined;
    inline for (0..2) |h| {
        const o = 4 * h;
        b[o + 0] = @shuffle(i32, a[o + 0], a[o + 2], lo2);
        b[o + 2] = @shuffle(i32, a[o + 0], a[o + 2], hi2);
        b[o + 1] = @shuffle(i32, a[o + 1], a[o + 3], lo2);
        b[o + 3] = @shuffle(i32, a[o + 1], a[o + 3], hi2);
    }
    var c: [8]V = undefined;
    inline for (0..4) |i| {
        c[i] = @shuffle(i32, b[i], b[i + 4], lo4);
        c[i + 4] = @shuffle(i32, b[i], b[i + 4], hi4);
    }
    return c;
}

test "transpose" {
    var m: [8]V = undefined;
    inline for (0..8) |i| inline for (0..8) |j| {
        m[i][j] = i * 8 + j;
    };
    const t = transpose(m);
    inline for (0..8) |i| inline for (0..8) |j| try std.testing.expectEqual(@as(i32, j * 8 + i), t[i][j]);
}

/// range_limit, eight at a time.
inline fn limit(x: V) @Vector(8, u8) {
    const v = @as(@Vector(8, u32), @bitCast(x)) & @as(@Vector(8, u32), @splat(1023));
    const u = struct {
        inline fn f(c: u32) @Vector(8, u32) {
            return @splat(c);
        }
    }.f;
    return @intCast(@select(u32, v < u(128), v + u(128), @select(u32, v < u(512), u(255), @select(u32, v < u(896), u(0), v -% u(896)))));
}

/// A pass of the vector code equals jidctint.c's 64-bit arithmetic when no input exceeds this: every intermediate is a sum
/// of the inputs with weights adding up to at most 61214, so it stays within 32 bits (with the rounding constant).
const safe_input = 35079;

inline fn fits(x: [8]V) bool {
    var m: @Vector(8, u32) = @abs(x[0]);
    inline for (1..8) |i| m = @max(m, @abs(x[i]));
    return @reduce(.Max, m) <= safe_input;
}

/// Dequantises `coef` (natural order) with `quant` and writes the 8x8 block of samples to `out` (row stride `stride`): the
/// numbers libjpeg-turbo's C build gives (jidctint.c, whose shortcuts for zero columns and rows give what the full
/// computation gives). Blocks with coefficients no 8-bit image produces take the 64-bit scalar path, `islowWide`; on those
/// libjpeg-turbo's own SIMD builds, 32 and 16 bits wide, give other numbers again.
pub fn islow(coef: *const [64]i16, quant: *const [64]i16, out: [*]u8, stride: usize) void {
    const all: @Vector(64, i16) = coef.*;
    var ac = all;
    ac[0] = 0;
    if (@reduce(.Or, ac != @as(@Vector(64, i16), @splat(0)))) {
        var x: [8]V = undefined;
        inline for (0..8) |r| {
            const c: @Vector(8, i16) = coef[r * 8 ..][0..8].*;
            const q: @Vector(8, i16) = quant[r * 8 ..][0..8].*;
            x[r] = @as(V, c) *% @as(V, q);
        }
        if (!fits(x)) return islowWide(coef, quant, out, stride);
        const w = transpose(pass(x, CONST_BITS - PASS1_BITS));
        if (!fits(w)) return islowWide(coef, quant, out, stride);
        const rows = transpose(pass(w, CONST_BITS + PASS1_BITS + 3));
        inline for (0..8) |r| out[r * stride ..][0..8].* = limit(rows[r]);
        return;
    }
    // DC only: one value for the whole block. Pass 1 shifts in 32 bits, pass 2 rounds in 64, as jidctint.c does.
    const dc: i32 = @bitCast(@as(u32, @bitCast(@as(i32, coef[0]) *% quant[0])) << PASS1_BITS);
    const v = range_limit[@as(u64, @bitCast((@as(i64, dc) + (1 << (PASS1_BITS + 2))) >> (PASS1_BITS + 3))) & 1023];
    inline for (0..8) |r| @memset(out[r * stride ..][0..8], v);
}

test "islow matches jidctint.c's 64-bit arithmetic, garbage coefficients included" {
    var prng = std.Random.DefaultPrng.init(12);
    const rand = prng.random();
    var coef: [64]i16 = undefined;
    var q: [64]i16 = undefined;
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    for (0..20000) |i| {
        for (&coef, &q) |*c, *qq| {
            c.* = if (rand.boolean()) rand.int(i16) else 0;
            qq.* = if (i % 2 == 0) rand.int(i16) else rand.intRangeAtMost(i16, 1, 255);
        }
        islow(&coef, &q, &a, 8);
        islowWide(&coef, &q, &b, 8);
        try std.testing.expectEqualSlices(u8, &b, &a);
    }
}

test "a DC-only block is flat; the range limit clamps" {
    var coef: [64]i16 = @splat(0);
    var q: [64]i16 = @splat(1);
    var out: [64]u8 = undefined;
    coef[0] = 80; // 80 / 8 = +10
    islow(&coef, &q, &out, 8);
    for (out) |v| try std.testing.expectEqual(138, v);
    coef[0] = -2000;
    islow(&coef, &q, &out, 8);
    for (out) |v| try std.testing.expectEqual(0, v);
    q[0] = 16;
    coef[0] = 200;
    islow(&coef, &q, &out, 8);
    for (out) |v| try std.testing.expectEqual(255, v);
}

/// jidctint.c exactly as libjpeg-turbo's C build runs it on a 64-bit system: products and sums in JLONG (64-bit), the
/// workspace between the passes in int (32-bit, so pass 1's results are truncated), shifts of the bits as unsigned.
/// It differs from the 32-bit vector code only when coefficients are far outside what an 8-bit image produces.
pub fn islowWide(coef: *const [64]i16, quant: *const [64]i16, out: [*]u8, stride: usize) void {
    var ws: [64]i32 = undefined;
    const d64 = struct {
        inline fn f(x: i64, comptime n: u6) i64 {
            return (x +% (@as(i64, 1) << (n - 1))) >> n;
        }
    }.f;
    const shl = struct {
        inline fn f(x: i64, comptime n: u6) i64 {
            return @bitCast(@as(u64, @bitCast(x)) << n);
        }
    }.f;
    for (0..8) |c| {
        const in = struct {
            inline fn f(cf: *const [64]i16, q: *const [64]i16, col: usize, row: usize) i32 {
                return @as(i32, cf[row * 8 + col]) *% @as(i32, q[row * 8 + col]); // DEQUANTIZE: int
            }
        }.f;
        if (coef[8 + c] == 0 and coef[16 + c] == 0 and coef[24 + c] == 0 and coef[32 + c] == 0 and coef[40 + c] == 0 and
            coef[48 + c] == 0 and coef[56 + c] == 0)
        {
            const dc: i32 = @bitCast(@as(u32, @bitCast(in(coef, quant, c, 0))) << PASS1_BITS); // LEFT_SHIFT on int
            inline for (0..8) |r| ws[r * 8 + c] = dc;
            continue;
        }
        var z2: i64 = in(coef, quant, c, 2);
        var z3: i64 = in(coef, quant, c, 6);
        const z1 = (z2 +% z3) *% FIX_0_541196100;
        var tmp2 = z1 +% z3 *% -FIX_1_847759065;
        var tmp3 = z1 +% z2 *% FIX_0_765366865;
        z2 = in(coef, quant, c, 0);
        z3 = in(coef, quant, c, 4);
        var tmp0 = shl(z2 +% z3, CONST_BITS);
        var tmp1 = shl(z2 -% z3, CONST_BITS);
        const tmp10 = tmp0 +% tmp3;
        const tmp13 = tmp0 -% tmp3;
        const tmp11 = tmp1 +% tmp2;
        const tmp12 = tmp1 -% tmp2;
        tmp0 = in(coef, quant, c, 7);
        tmp1 = in(coef, quant, c, 5);
        tmp2 = in(coef, quant, c, 3);
        tmp3 = in(coef, quant, c, 1);
        oddWide(&tmp0, &tmp1, &tmp2, &tmp3);
        const n = CONST_BITS - PASS1_BITS;
        ws[0 * 8 + c] = @truncate(d64(tmp10 +% tmp3, n));
        ws[7 * 8 + c] = @truncate(d64(tmp10 -% tmp3, n));
        ws[1 * 8 + c] = @truncate(d64(tmp11 +% tmp2, n));
        ws[6 * 8 + c] = @truncate(d64(tmp11 -% tmp2, n));
        ws[2 * 8 + c] = @truncate(d64(tmp12 +% tmp1, n));
        ws[5 * 8 + c] = @truncate(d64(tmp12 -% tmp1, n));
        ws[3 * 8 + c] = @truncate(d64(tmp13 +% tmp0, n));
        ws[4 * 8 + c] = @truncate(d64(tmp13 -% tmp0, n));
    }
    for (0..8) |r| {
        const w = ws[r * 8 ..][0..8];
        const o = out[r * stride ..][0..8];
        const lim = struct {
            inline fn f(x: i64, comptime n: u6) u8 {
                return range_limit[@as(u64, @bitCast(d64(x, n))) & 1023];
            }
        }.f;
        if (w[1] == 0 and w[2] == 0 and w[3] == 0 and w[4] == 0 and w[5] == 0 and w[6] == 0 and w[7] == 0) {
            @memset(o, lim(w[0], PASS1_BITS + 3));
            continue;
        }
        const z2: i64 = w[2];
        const z3: i64 = w[6];
        const z1 = (z2 +% z3) *% FIX_0_541196100;
        var tmp2 = z1 +% z3 *% -FIX_1_847759065;
        var tmp3 = z1 +% z2 *% FIX_0_765366865;
        var tmp0 = shl(@as(i64, w[0]) +% w[4], CONST_BITS);
        var tmp1 = shl(@as(i64, w[0]) -% w[4], CONST_BITS);
        const tmp10 = tmp0 +% tmp3;
        const tmp13 = tmp0 -% tmp3;
        const tmp11 = tmp1 +% tmp2;
        const tmp12 = tmp1 -% tmp2;
        tmp0 = w[7];
        tmp1 = w[5];
        tmp2 = w[3];
        tmp3 = w[1];
        oddWide(&tmp0, &tmp1, &tmp2, &tmp3);
        const n = CONST_BITS + PASS1_BITS + 3;
        o[0] = lim(tmp10 +% tmp3, n);
        o[7] = lim(tmp10 -% tmp3, n);
        o[1] = lim(tmp11 +% tmp2, n);
        o[6] = lim(tmp11 -% tmp2, n);
        o[2] = lim(tmp12 +% tmp1, n);
        o[5] = lim(tmp12 -% tmp1, n);
        o[3] = lim(tmp13 +% tmp0, n);
        o[4] = lim(tmp13 -% tmp0, n);
    }
}

inline fn oddWide(tmp0: *i64, tmp1: *i64, tmp2: *i64, tmp3: *i64) void {
    var z1 = tmp0.* +% tmp3.*;
    var z2 = tmp1.* +% tmp2.*;
    var z3 = tmp0.* +% tmp2.*;
    var z4 = tmp1.* +% tmp3.*;
    const z5 = (z3 +% z4) *% FIX_1_175875602;
    tmp0.* = tmp0.* *% FIX_0_298631336;
    tmp1.* = tmp1.* *% FIX_2_053119869;
    tmp2.* = tmp2.* *% FIX_3_072711026;
    tmp3.* = tmp3.* *% FIX_1_501321110;
    z1 = z1 *% -FIX_0_899976223;
    z2 = z2 *% -FIX_2_562915447;
    z3 = z3 *% -FIX_1_961570560;
    z4 = z4 *% -FIX_0_390180644;
    z3 +%= z5;
    z4 +%= z5;
    tmp0.* +%= z1 +% z3;
    tmp1.* +%= z2 +% z4;
    tmp2.* +%= z2 +% z3;
    tmp3.* +%= z1 +% z4;
}
