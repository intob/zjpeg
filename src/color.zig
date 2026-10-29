//! Chroma upsampling and YCbCr -> RGB, as libjpeg-turbo does them by default (jdsample.c "fancy" upsampling, jdcolor.c), so
//! the pixels match its output exactly; 16 samples at a time.
const std = @import("std");

const L = 16;
const V16 = @Vector(L, u16);

/// One component's samples after the IDCT: `width` x `height` real samples in a plane `stride` wide.
pub const Plane = struct {
    samples: []const u8,
    stride: usize,
    width: usize, // libjpeg's downsampled_width
    height: usize,
    rh: u8, // upsampling ratio: max sampling factor / this component's
    rv: u8,
    ring_rows: usize = 0, // the plane holds three groups of this many rows, row y in group y / ring_rows % 3; 0: all rows

    fn row(p: Plane, y: usize) []const u8 {
        const r = @min(y, p.height - 1);
        const i = if (p.ring_rows == 0) r else (r / p.ring_rows % 3) * p.ring_rows + r % p.ring_rows;
        return p.samples[i * p.stride ..][0..p.width];
    }

    /// The component's samples for output row `y`, upsampled (at least the image's width), in `out` (or a slice of the plane
    /// itself when it is full size). `scratch` holds width + 2 values.
    pub fn upsampledRow(p: Plane, y: usize, out: []u8, scratch: []u16) []const u8 {
        if (p.rh == 1 and p.rv == 1) return p.row(y);
        if (p.rh == 2 and p.rv == 1 and p.width > 2) { // h2v1_fancy_upsample
            const cs = scratch[0 .. p.width + 2];
            for (p.row(y), cs[1 .. p.width + 1]) |v, *c| c.* = v;
            pairs(cs, out, 1, 2, 2);
        } else if (p.rh == 2 and p.rv == 2 and p.width > 2) { // h2v2_fancy_upsample
            const iy = y / 2;
            const near = p.row(iy);
            const far = if (y % 2 == 0) p.row(iy -| 1) else p.row(iy + 1); // the row above or below, repeated at the edges
            const cs = scratch[0 .. p.width + 2];
            colsums(near, far, cs[1 .. p.width + 1]);
            pairs(cs, out, 8, 7, 4);
        } else if (p.rh == 1 and p.rv == 2) { // h1v2_fancy_upsample
            const iy = y / 2;
            const near = p.row(iy);
            const far = if (y % 2 == 0) p.row(iy -| 1) else p.row(iy + 1);
            const bias: u16 = if (y % 2 == 0) 1 else 2;
            for (near, far, out[0..near.len]) |a, b, *o| o.* = @intCast((@as(u16, a) * 3 + b + bias) >> 2);
        } else { // any other whole ratio: each sample repeated (int_upsample, h2v1_upsample, h2v2_upsample)
            const src = p.row(y / p.rv);
            var i: usize = 0;
            for (src) |s| {
                @memset(out[i..][0..p.rh], s);
                i += p.rh;
            }
        }
        return out;
    }
};

/// 3 * near + far, the vertical half of h2v2's triangle filter.
fn colsums(near: []const u8, far: []const u8, cs: []u16) void {
    var i: usize = 0;
    while (i + L <= cs.len) : (i += L) {
        const a: @Vector(L, u8) = near[i..][0..L].*;
        const b: @Vector(L, u8) = far[i..][0..L].*;
        cs[i..][0..L].* = @as(V16, a) * @as(V16, @splat(3)) + @as(V16, b);
    }
    while (i < cs.len) : (i += 1) cs[i] = @as(u16, near[i]) * 3 + far[i];
}

/// libjpeg-turbo's fancy upsamplers across a row: from the values cs[1..n+1] (samples, or for h2v2 column sums), each value
/// gives two outputs, 3 parts itself and 1 part its left (even) or right (odd) neighbour, rounded with `even_bias` / `odd_bias`
/// and shifted by `shift`. Its special first and last columns are exactly this with the edge value repeated, which cs[0] and
/// cs[n+1] are set to here.
fn pairs(cs: []u16, out: []u8, comptime even_bias: u16, comptime odd_bias: u16, comptime shift: u4) void {
    const n = cs.len - 2;
    cs[0] = cs[1];
    cs[n + 1] = cs[n];
    const interleave = comptime blk: {
        var m: [2 * L]i32 = undefined;
        for (0..L) |k| {
            m[2 * k] = k;
            m[2 * k + 1] = ~@as(i32, k);
        }
        break :blk m;
    };
    var i: usize = 0;
    while (i + L <= n) : (i += L) {
        const left: V16 = cs[i..][0..L].*;
        const mid: V16 = cs[i + 1 ..][0..L].*;
        const right: V16 = cs[i + 2 ..][0..L].*;
        const m3 = mid * @as(V16, @splat(3));
        const even: @Vector(L, u8) = @intCast((m3 + left + @as(V16, @splat(even_bias))) >> @splat(shift));
        const odd: @Vector(L, u8) = @intCast((m3 + right + @as(V16, @splat(odd_bias))) >> @splat(shift));
        out[2 * i ..][0 .. 2 * L].* = @shuffle(u8, even, odd, interleave);
    }
    while (i < n) : (i += 1) {
        const m3 = cs[i + 1] * 3;
        out[2 * i] = @intCast((m3 + cs[i] + even_bias) >> shift);
        out[2 * i + 1] = @intCast((m3 + cs[i + 2] + odd_bias) >> shift);
    }
}

const Tables = struct { cr_r: [256]i32, cb_b: [256]i32, cr_g: [256]i32, cb_g: [256]i32 };

/// jdcolor.c build_ycc_rgb_table: 16-bit fixed point.
const tables: Tables = blk: {
    @setEvalBranchQuota(10000);
    var t: Tables = undefined;
    for (0..256) |i| {
        const x: i64 = @as(i64, i) - 128;
        t.cr_r[i] = @intCast((fix_cr_r * x + (1 << 15)) >> 16);
        t.cb_b[i] = @intCast((fix_cb_b * x + (1 << 15)) >> 16);
        t.cr_g[i] = @intCast(-fix_cr_g * x);
        t.cb_g[i] = @intCast(-fix_cb_g * x + (1 << 15));
    }
    break :blk t;
};

fn fix(x: comptime_float) comptime_int {
    return @intFromFloat(@floor(x * 65536.0 + 0.5));
}
const fix_cr_r = fix(1.40200);
const fix_cb_b = fix(1.77200);
const fix_cr_g = fix(0.71414);
const fix_cb_g = fix(0.34414);

inline fn clamp(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// jdcolor.c ycc_rgb_convert. The vector loop computes its tables' entries directly; they are these same products.
pub fn yccToRgb(y: []const u8, cb: []const u8, cr: []const u8, out: []u8) void {
    const n = out.len / 3;
    const VI = @Vector(L, i32);
    const rg_mask = comptime blk: {
        var m: [2 * L]i32 = undefined;
        for (0..L) |k| {
            m[k] = k;
            m[L + k] = ~@as(i32, k);
        }
        break :blk m;
    };
    const rgb_mask = comptime blk: {
        var m: [3 * L]i32 = undefined;
        for (0..L) |k| {
            m[3 * k] = k;
            m[3 * k + 1] = L + k;
            m[3 * k + 2] = ~@as(i32, k);
        }
        break :blk m;
    };
    const sp = struct {
        inline fn f(v: i32) VI {
            return @splat(v);
        }
    }.f;
    // In 16-bit lanes: each product is split so its constant fits a 16-bit multiply, exactly (65536 x is a whole x):
    //   (91881 x + 2^15) >> 16 = x + ((26345 x + 2^15) >> 16)            red
    //   (116130 x + 2^15) >> 16 = 2 x + ((-14942 x + 2^15) >> 16)        blue
    //   (-22554 b - 46802 r + 2^15) >> 16 = -r + ((-22554 b + 18734 r + 2^15) >> 16)   green
    const VS = @Vector(L, i16);
    const hi16 = struct {
        inline fn f(v: VI) VS {
            return @intCast((v + @as(VI, @splat(1 << 15))) >> @splat(16));
        }
    }.f;
    var i: usize = 0;
    while (i + L <= n) : (i += L) {
        const yv: VS = @as(@Vector(L, u8), y[i..][0..L].*);
        const b: VS = @as(VS, @as(@Vector(L, u8), cb[i..][0..L].*)) - @as(VS, @splat(128));
        const r: VS = @as(VS, @as(@Vector(L, u8), cr[i..][0..L].*)) - @as(VS, @splat(128));
        const bw: VI = b;
        const rw: VI = r;
        const rr = yv + r + hi16(rw * sp(fix_cr_r - 65536));
        const gg = yv - r + hi16(bw * sp(-fix_cb_g) + rw * sp(65536 - fix_cr_g));
        const bb = yv + b + b + hi16(bw * sp(fix_cb_b - 131072));
        const z: VS = @splat(0);
        const m: VS = @splat(255);
        const r8: @Vector(L, u8) = @intCast(@min(@max(rr, z), m));
        const g8: @Vector(L, u8) = @intCast(@min(@max(gg, z), m));
        const b8: @Vector(L, u8) = @intCast(@min(@max(bb, z), m));
        out[3 * i ..][0 .. 3 * L].* = @shuffle(u8, @shuffle(u8, r8, g8, rg_mask), b8, rgb_mask);
    }
    while (i < n) : (i += 1) {
        const yy: i32 = y[i];
        out[3 * i] = clamp(yy + tables.cr_r[cr[i]]);
        out[3 * i + 1] = clamp(yy + ((tables.cb_g[cb[i]] + tables.cr_g[cr[i]]) >> 16));
        out[3 * i + 2] = clamp(yy + tables.cb_b[cb[i]]);
    }
}

pub fn interleave3(a: []const u8, b: []const u8, c: []const u8, out: []u8) void {
    for (0..out.len / 3) |i| {
        out[3 * i] = a[i];
        out[3 * i + 1] = b[i];
        out[3 * i + 2] = c[i];
    }
}

test "fancy upsampling matches libjpeg-turbo's loops, edges included" {
    var prng = std.Random.DefaultPrng.init(3);
    const rand = prng.random();
    for ([_]usize{ 3, 4, 17, 40, 63 }) |n| {
        var near: [64]u8 = undefined;
        var far: [64]u8 = undefined;
        rand.bytes(&near);
        rand.bytes(&far);
        var cs: [66]u16 = undefined;
        var got: [128]u8 = undefined;
        var want: [128]u8 = undefined;
        // h2v1_fancy_upsample, as in jdsample.c
        want[0] = near[0];
        want[1] = @intCast((@as(u16, near[0]) * 3 + near[1] + 2) >> 2);
        for (1..n - 1) |i| {
            const v = @as(u16, near[i]) * 3;
            want[2 * i] = @intCast((v + near[i - 1] + 1) >> 2);
            want[2 * i + 1] = @intCast((v + near[i + 1] + 2) >> 2);
        }
        want[2 * n - 2] = @intCast((@as(u16, near[n - 1]) * 3 + near[n - 2] + 1) >> 2);
        want[2 * n - 1] = near[n - 1];
        for (near[0..n], cs[1 .. n + 1]) |v, *c| c.* = v;
        pairs(cs[0 .. n + 2], &got, 1, 2, 2);
        try std.testing.expectEqualSlices(u8, want[0 .. 2 * n], got[0 .. 2 * n]);
        // h2v2_fancy_upsample
        var sums: [64]u16 = undefined;
        for (0..n) |i| sums[i] = @as(u16, near[i]) * 3 + far[i];
        want[0] = @intCast((sums[0] * 4 + 8) >> 4);
        want[1] = @intCast((sums[0] * 3 + sums[1] + 7) >> 4);
        for (1..n - 1) |i| {
            want[2 * i] = @intCast((sums[i] * 3 + sums[i - 1] + 8) >> 4);
            want[2 * i + 1] = @intCast((sums[i] * 3 + sums[i + 1] + 7) >> 4);
        }
        want[2 * n - 2] = @intCast((sums[n - 1] * 3 + sums[n - 2] + 8) >> 4);
        want[2 * n - 1] = @intCast((sums[n - 1] * 4 + 7) >> 4);
        colsums(near[0..n], far[0..n], cs[1 .. n + 1]);
        pairs(cs[0 .. n + 2], &got, 8, 7, 4);
        try std.testing.expectEqualSlices(u8, want[0 .. 2 * n], got[0 .. 2 * n]);
    }
}

test "vector colour conversion matches the tables" {
    var prng = std.Random.DefaultPrng.init(5);
    var y: [4099]u8 = undefined;
    var cb: [4099]u8 = undefined;
    var cr: [4099]u8 = undefined;
    prng.random().bytes(&y);
    prng.random().bytes(&cb);
    prng.random().bytes(&cr);
    var out: [3 * 4099]u8 = undefined;
    yccToRgb(&y, &cb, &cr, &out);
    for (0..4099) |i| {
        const yy: i32 = y[i];
        try std.testing.expectEqual(clamp(yy + tables.cr_r[cr[i]]), out[3 * i]);
        try std.testing.expectEqual(clamp(yy + ((tables.cb_g[cb[i]] + tables.cr_g[cr[i]]) >> 16)), out[3 * i + 1]);
        try std.testing.expectEqual(clamp(yy + tables.cb_b[cb[i]]), out[3 * i + 2]);
    }
}

test "YCbCr grey and primaries" {
    var out: [6]u8 = undefined;
    yccToRgb(&.{ 128, 76 }, &.{ 128, 85 }, &.{ 128, 255 }, &out);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128, 254, 0, 0 }, &out);
}
