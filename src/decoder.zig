//! The JPEG decoder: baseline, extended (8-bit) and progressive Huffman-coded JPEG, greyscale or three components. Output
//! matches libjpeg-turbo's default decompression (islow IDCT, fancy upsampling) byte for byte. Not supported: arithmetic
//! coding, 12-bit, lossless and hierarchical JPEG, four-component (CMYK/YCCK) images, and the block smoothing libjpeg applies to
//! progressive images whose coefficients never arrived (a truncated progressive file).
const std = @import("std");
const Allocator = std.mem.Allocator;
const huffman = @import("huffman.zig");
const idct = @import("idct.zig");
const color = @import("color.zig");
const BitReader = huffman.BitReader;

pub const Error = error{ InvalidJpeg, Unsupported, TooLarge, OutOfMemory, BufferTooSmall };

pub const Options = struct {
    /// Images with more pixels are refused before anything is allocated for them.
    max_pixels: u64 = 1 << 28,
};

pub const Image = struct {
    width: u32,
    height: u32,
    channels: u8, // 1 (grey) or 3 (RGB)
    pixels: []u8, // rows top to bottom, width * channels bytes each
    /// libjpeg would block-smooth this image (progressive, with some of the first coefficients never fully sent: a
    /// truncated file, usually) and zjpeg does not yet, so its pixels differ from libjpeg's.
    unsmoothed: bool = false,

    pub fn deinit(img: *Image, gpa: Allocator) void {
        gpa.free(img.pixels);
        img.* = undefined;
    }
};

/// The natural (row-major) position of the k-th coefficient in zigzag order; 16 more entries so a run past 63 in a damaged
/// file lands on 63, as in libjpeg.
pub const natural: [80]u8 = .{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
} ++ @as([16]u8, @splat(63));

/// The tables of JPEG's Annex K, which libjpeg-turbo puts in any of slots 0 and 1 a file leaves empty (Motion-JPEG frames).
const std_tables = struct {
    const dc_bits = [2][16]u8{ .{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 } };
    const dc_vals = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    const ac_bits = [2][16]u8{ .{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d }, .{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 } };
    const ac_vals = [2][162]u8{ .{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81,
        0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99,
        0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5,
        0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
    }, .{
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08,
        0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25,
        0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47,
        0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74,
        0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
        0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba,
        0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe2, 0xe3, 0xe4,
        0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
    } };
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    width: usize, // samples (libjpeg's downsampled_width)
    height: usize,
    bw: usize, // blocks holding samples
    bh: usize,
    bw_pad: usize, // blocks to the edge of the last MCU
    bh_pad: usize,
    plane: []u8 = &.{}, // bw_pad * 8 wide; every block row, or in strip mode a ring of three groups
    ring_blocks: usize = 0, // strip mode: block rows per group (the ring holds three); 0: the whole plane
    coefs: []i16 = &.{}, // progressive: every block's coefficients, natural order
    quant: [64]i16 = undefined, // latched at the component's first scan
    latched: bool = false,
    coef_bits: [10]i8 = @splat(-1), // progressive: the Al of the last scan of each of the first coefficients (libjpeg's)
    pred: i32 = 0,
    dc: *const huffman.Table = undefined,
    ac: *const huffman.Table = undefined,

    fn block(c: *Component, bx: usize, by: usize) *[64]i16 {
        return c.coefs[(by * c.bw_pad + bx) * 64 ..][0..64];
    }

    fn samples(c: *Component, bx: usize, by: usize) [*]u8 {
        const row = if (c.ring_blocks == 0) by else (by / c.ring_blocks % 3) * c.ring_blocks + by % c.ring_blocks;
        return c.plane[row * 8 * c.bw_pad * 8 + bx * 8 ..].ptr;
    }
};

const Mode = enum { sequential, dc_first, dc_refine, ac_first, ac_refine };

const Decoder = struct {
    gpa: Allocator,
    data: []const u8,
    pos: usize = 2,
    opts: Options,
    quant: [4]?[64]u16 = @splat(null), // natural order
    dc_tables: [4]?huffman.Table = @splat(null),
    ac_tables: [4]?huffman.Table = @splat(null),
    std_dc: [2]huffman.Table = undefined,
    std_ac: [2]huffman.Table = undefined,
    restart_interval: u16 = 0,
    frame: bool = false,
    progressive: bool = false,
    width: usize = 0,
    height: usize = 0,
    comps: [4]Component = undefined,
    ncomp: usize = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcux: usize = 0,
    mcuy: usize = 0,
    saw_jfif: bool = false,
    adobe_transform: ?u8 = null,
    scans: usize = 0,
    eobrun: u32 = 0,
    // output
    out: []u8 = &.{}, // the caller's buffer, or (own_out) one allocated at the frame header
    own_out: bool = false,
    strip: bool = false, // a single sequential scan: rows go out as its MCU rows are decoded
    group_rows: usize = 0, // strip mode: output rows per MCU row
    emitted: usize = 0, // output rows written
    planes: [3]color.Plane = undefined,
    rows: [3][]u8 = .{ &.{}, &.{}, &.{} },
    scratch: []u16 = &.{},
    rgb: bool = false,

    fn deinit(d: *Decoder) void {
        for (d.comps[0..d.ncomp]) |c| {
            d.gpa.free(c.plane);
            d.gpa.free(c.coefs);
        }
        for (d.rows) |r| d.gpa.free(r);
        d.gpa.free(d.scratch);
        if (d.own_out) d.gpa.free(d.out);
    }

    fn be16(s: []const u8, i: usize) u16 {
        return std.mem.readInt(u16, s[i..][0..2], .big);
    }

    /// The payload of the segment at pos (after its length).
    fn segment(d: *Decoder) Error![]const u8 {
        if (d.data.len - d.pos < 2) return error.InvalidJpeg;
        const len = be16(d.data, d.pos);
        if (len < 2 or len > d.data.len - d.pos) return error.InvalidJpeg;
        defer d.pos += len;
        return d.data[d.pos + 2 .. d.pos + len];
    }

    /// The next marker's code, skipping anything that is not one (libjpeg warns about such garbage); null at the end of data.
    fn nextMarker(d: *Decoder) ?u8 {
        while (d.pos < d.data.len) {
            if (d.data[d.pos] != 0xFF) {
                d.pos += 1;
                continue;
            }
            var j = d.pos + 1;
            while (j < d.data.len and d.data[j] == 0xFF) j += 1;
            if (j >= d.data.len) break;
            d.pos = j + 1;
            if (d.data[j] != 0) return d.data[j];
        }
        d.pos = d.data.len;
        return null;
    }

    fn run(d: *Decoder) Error!void {
        if (d.data.len < 2 or d.data[0] != 0xFF or d.data[1] != 0xD8) return error.InvalidJpeg;
        for (0..2) |i| {
            d.std_dc[i] = huffman.Table.init(&std_tables.dc_bits[i], &std_tables.dc_vals, .dc) catch unreachable;
            d.std_ac[i] = huffman.Table.init(&std_tables.ac_bits[i], &std_tables.ac_vals[i], .ac) catch unreachable;
        }
        while (d.nextMarker()) |m| switch (m) {
            0xD8 => return error.InvalidJpeg,
            0xD9 => break,
            0xC0, 0xC1, 0xC2 => try d.frameHeader(try d.segment(), m == 0xC2),
            0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported,
            0xC4 => try d.huffmanTables(try d.segment()),
            0xDB => try d.quantTables(try d.segment()),
            0xDD => {
                const s = try d.segment();
                if (s.len != 2) return error.InvalidJpeg;
                d.restart_interval = be16(s, 0);
            },
            0xDA => try d.scan(try d.segment()),
            0xE0 => {
                const s = try d.segment();
                if (s.len >= 14 and std.mem.eql(u8, s[0..5], "JFIF\x00")) d.saw_jfif = true;
            },
            0xEE => {
                const s = try d.segment();
                if (s.len >= 12 and std.mem.eql(u8, s[0..5], "Adobe")) d.adobe_transform = s[11];
            },
            0xD0...0xD7, 0x01 => {}, // a stray RST, TEM: no payload
            0xC8, 0xCC, 0xDC, 0xDE, 0xDF, 0xE1...0xED, 0xEF...0xFE => _ = try d.segment(),
            else => return error.InvalidJpeg,
        };
        if (d.scans == 0) return error.InvalidJpeg;
    }

    fn quantTables(d: *Decoder, seg: []const u8) Error!void {
        var s = seg;
        while (s.len > 0) {
            const pq = s[0] >> 4;
            const tq = s[0] & 15;
            const n: usize = if (pq == 0) 64 else 128;
            if (tq > 3 or s.len < 1 + n) return error.InvalidJpeg; // libjpeg reads any precision but 0 as 16-bit
            var t: [64]u16 = undefined;
            for (0..64) |k| t[natural[k]] = if (pq == 0) s[1 + k] else be16(s, 1 + 2 * k);
            d.quant[tq] = t;
            s = s[1 + n ..];
        }
    }

    fn huffmanTables(d: *Decoder, seg: []const u8) Error!void {
        var s = seg;
        while (s.len > 0) {
            const tc = s[0] >> 4;
            const th = s[0] & 15;
            if (tc > 1 or th > 3 or s.len < 17) return error.InvalidJpeg;
            const counts = s[1..17];
            var total: usize = 0;
            for (counts) |c| total += c;
            if (total > 256 or s.len < 17 + total) return error.InvalidJpeg;
            const t = try huffman.Table.init(counts, s[17..][0..total], if (tc == 0) .dc else .ac);
            if (tc == 0) d.dc_tables[th] = t else d.ac_tables[th] = t;
            s = s[17 + total ..];
        }
    }

    fn frameHeader(d: *Decoder, s: []const u8, progressive: bool) Error!void {
        if (d.frame) return error.InvalidJpeg;
        if (s.len < 6) return error.InvalidJpeg;
        if (s[0] != 8) return error.Unsupported;
        const height = be16(s, 1);
        const width = be16(s, 3);
        const nf = s[5];
        if (width == 0 or nf == 0 or s.len < 6 + 3 * @as(usize, nf)) return error.InvalidJpeg;
        if (height == 0) return error.Unsupported; // the height comes in a DNL marker
        if (nf != 1 and nf != 3) return error.Unsupported;
        if (@as(u64, width) * height > d.opts.max_pixels) return error.TooLarge;
        d.width = width;
        d.height = height;
        d.progressive = progressive;
        for (0..nf) |i| {
            const p = s[6 + 3 * i ..][0..3];
            const h = p[1] >> 4;
            const v = p[1] & 15;
            if (h < 1 or h > 4 or v < 1 or v > 4 or p[2] > 3) return error.InvalidJpeg;
            for (d.comps[0..i]) |c| if (c.id == p[0]) return error.InvalidJpeg;
            d.comps[i] = .{ .id = p[0], .h = h, .v = v, .tq = p[2], .width = 0, .height = 0, .bw = 0, .bh = 0, .bw_pad = 0, .bh_pad = 0 };
            d.hmax = @max(d.hmax, h);
            d.vmax = @max(d.vmax, v);
        }
        d.mcux = std.math.divCeil(usize, width, 8 * @as(usize, d.hmax)) catch unreachable;
        d.mcuy = std.math.divCeil(usize, height, 8 * @as(usize, d.vmax)) catch unreachable;
        for (d.comps[0..nf]) |*c| {
            if (d.hmax % c.h != 0 or d.vmax % c.v != 0) return error.Unsupported; // fractional sampling
            c.width = std.math.divCeil(usize, @as(usize, width) * c.h, d.hmax) catch unreachable;
            c.height = std.math.divCeil(usize, @as(usize, height) * c.v, d.vmax) catch unreachable;
            c.bw = std.math.divCeil(usize, c.width, 8) catch unreachable;
            c.bh = std.math.divCeil(usize, c.height, 8) catch unreachable;
            c.bw_pad = d.mcux * c.h;
            c.bh_pad = d.mcuy * c.v;
        }
        d.frame = true;
        d.ncomp = nf; // from here deinit frees what is allocated
        const len = d.info().len();
        if (d.own_out) {
            d.out = try d.gpa.alloc(u8, len);
        } else if (d.out.len < len) return error.BufferTooSmall;
    }

    /// At the first scan: the planes (whole, or in strip mode a ring of three MCU rows), the coefficients of a progressive
    /// image, and the output's row buffers.
    fn allocate(d: *Decoder, strip: bool, single: bool) Error!void {
        d.strip = strip;
        d.group_rows = if (single) 8 else 8 * @as(usize, d.vmax);
        for (d.comps[0..d.ncomp], 0..) |*c, i| {
            c.ring_blocks = if (!strip) 0 else if (single) 1 else c.v;
            const block_rows = if (strip) 3 * c.ring_blocks else c.bh_pad;
            c.plane = try d.gpa.alloc(u8, c.bw_pad * block_rows * 64);
            if (!strip) @memset(c.plane, 128); // a block never decoded has zero coefficients
            if (d.progressive) {
                c.coefs = try d.gpa.alloc(i16, c.bw_pad * c.bh_pad * 64);
                @memset(c.coefs, 0);
            }
            d.planes[i] = .{ .samples = c.plane, .stride = c.bw_pad * 8, .width = c.width, .height = c.height, .rh = d.hmax / c.h, .rv = d.vmax / c.v, .ring_rows = c.ring_blocks * 8 };
            d.rows[i] = try d.gpa.alloc(u8, c.width * d.planes[i].rh + 2);
        }
        d.scratch = try d.gpa.alloc(u16, d.width + 2);
        d.rgb = d.ncomp == 3 and if (d.saw_jfif) false else if (d.adobe_transform) |t| t == 0 else (d.comps[0].id == 'R' and d.comps[1].id == 'G' and d.comps[2].id == 'B');
    }

    fn scan(d: *Decoder, s: []const u8) Error!void {
        if (!d.frame or s.len < 1) return error.InvalidJpeg;
        const ns = s[0];
        if (ns < 1 or ns > 4 or s.len != 4 + 2 * @as(usize, ns)) return error.InvalidJpeg;
        var idx: [4]usize = undefined;
        for (0..ns) |i| {
            const id = s[1 + 2 * i];
            idx[i] = for (d.comps[0..d.ncomp], 0..) |c, ci| {
                if (c.id == id) break ci;
            } else return error.InvalidJpeg;
            for (idx[0..i]) |o| if (o == idx[i]) return error.InvalidJpeg;
        }
        const ss = s[1 + 2 * ns];
        const se = s[2 + 2 * ns];
        const ah = s[3 + 2 * ns] >> 4;
        const al: u4 = @intCast(s[3 + 2 * ns] & 15);
        const mode: Mode = if (!d.progressive) .sequential else if (ss == 0) (if (ah == 0) .dc_first else .dc_refine) else if (ah == 0) .ac_first else .ac_refine;
        if (d.progressive) { // jdphuff.c start_pass_phuff_decoder's checks
            if (ss == 0 and se != 0) return error.InvalidJpeg;
            if (ss != 0 and (se < ss or se > 63 or ns != 1)) return error.InvalidJpeg;
            if ((ah != 0 and al != ah - 1) or al > 13) return error.InvalidJpeg;
        }
        if (ns > 1) {
            var blocks: usize = 0;
            for (idx[0..ns]) |ci| blocks += @as(usize, d.comps[ci].h) * d.comps[ci].v;
            if (blocks > 10) return error.InvalidJpeg;
        }
        for (idx[0..ns], 0..) |ci, i| {
            const c = &d.comps[ci];
            const t = s[2 + 2 * i];
            const td = t >> 4;
            const ta = t & 15;
            // a selector is checked only where the scan uses it, as libjpeg does (start_pass of its entropy decoders)
            if (mode == .sequential or mode == .dc_first) {
                c.dc = d.table(.dc, td) orelse return error.InvalidJpeg;
                for (c.dc.values[0..c.dc.count]) |v| if (v > 15) return error.InvalidJpeg;
            }
            if (mode == .sequential or mode == .ac_first or mode == .ac_refine) c.ac = d.table(.ac, ta) orelse return error.InvalidJpeg;
            if (!c.latched) {
                const q = d.quant[c.tq] orelse return error.InvalidJpeg;
                for (&c.quant, q) |*o, v| o.* = @bitCast(v); // libjpeg keeps islow multipliers as shorts
                c.latched = true;
            }
            c.pred = 0;
        }
        d.eobrun = 0;
        if (d.progressive) for (idx[0..ns]) |ci| {
            var k: usize = ss;
            while (k <= se and k < 10) : (k += 1) d.comps[ci].coef_bits[k] = al;
        };
        if (d.scans == 0) {
            try d.allocate(!d.progressive and ns == d.ncomp, ns == 1);
        } else if (d.strip) {
            return; // libjpeg decodes a frame whose first scan has every component in one pass; later scans go unread
        }
        d.scans += 1;

        d.pos = switch (mode) {
            inline else => |m| d.scanBlocks(m, idx[0..ns], ss, se, al),
        };
    }

    /// One scan's blocks; one copy per mode, so the bit reader stays in registers (nothing it is passed to is out of line).
    fn scanBlocks(d: *Decoder, comptime mode: Mode, idx: []const usize, ss: u8, se: u8, al: u4) usize {
        var br: BitReader = .init(d.data, d.pos);
        var todo = d.restart_interval;
        if (idx.len == 1) {
            const c = &d.comps[idx[0]];
            for (0..c.bh) |by| {
                for (0..c.bw) |bx| {
                    d.restartIfDue(&br, &todo, idx);
                    br.checkInsufficient();
                    if (br.insufficient) {
                        if (d.strip) grey(c, bx, by);
                        continue;
                    }
                    d.decodeBlock(&br, mode, c, bx, by, ss, se, al);
                }
                if (d.strip and by > 0) d.emit(by - 1);
            }
        } else {
            for (0..d.mcuy) |my| {
                for (0..d.mcux) |mx| {
                    d.restartIfDue(&br, &todo, idx);
                    br.checkInsufficient();
                    for (idx) |ci| {
                        const c = &d.comps[ci];
                        for (0..c.v) |v| for (0..c.h) |h| {
                            if (br.insufficient) {
                                if (d.strip) grey(c, mx * c.h + h, my * c.v + v);
                            } else d.decodeBlock(&br, mode, c, mx * c.h + h, my * c.v + v, ss, se, al);
                        };
                    }
                }
                if (d.strip and my > 0) d.emit(my - 1);
            }
        }
        if (d.strip) d.emit(d.emitted / d.group_rows); // the last MCU row: nothing below it to wait for
        return br.pos;
    }

    /// A block left out (data ran out): zero coefficients, so mid grey, as libjpeg gives.
    fn grey(c: *Component, bx: usize, by: usize) void {
        const p = c.samples(bx, by);
        for (0..8) |r| @memset(p[r * c.bw_pad * 8 ..][0..8], 128);
    }

    /// Strip mode: the output rows of MCU row g (its upsampling reads one row of g + 1, decoded by now).
    fn emit(d: *Decoder, g: usize) void {
        const y1 = @min((g + 1) * d.group_rows, d.height);
        d.emitRows(d.emitted, y1);
    }

    fn emitRows(d: *Decoder, y0: usize, y1: usize) void {
        const w = d.width;
        const ch: usize = if (d.ncomp == 1) 1 else 3;
        for (y0..y1) |y| {
            const out = d.out[y * w * ch ..][0 .. w * ch];
            if (ch == 1) {
                @memcpy(out, d.planes[0].upsampledRow(y, d.rows[0], d.scratch)[0..w]);
                continue;
            }
            const a = d.planes[0].upsampledRow(y, d.rows[0], d.scratch);
            const b = d.planes[1].upsampledRow(y, d.rows[1], d.scratch);
            const c = d.planes[2].upsampledRow(y, d.rows[2], d.scratch);
            if (d.rgb) color.interleave3(a, b, c, out) else color.yccToRgb(a, b, c, out);
        }
        d.emitted = @max(d.emitted, y1);
    }

    fn table(d: *Decoder, comptime kind: enum { dc, ac }, i: u8) ?*const huffman.Table {
        if (i > 3) return null;
        const slot = if (kind == .dc) &d.dc_tables[i] else &d.ac_tables[i];
        if (slot.*) |*t| return t;
        if (i < 2) return if (kind == .dc) &d.std_dc[i] else &d.std_ac[i];
        return null;
    }

    inline fn restartIfDue(d: *Decoder, br: *BitReader, todo: *u16, idx: []const usize) void {
        if (d.restart_interval == 0) return;
        if (todo.* == 0) {
            br.restart();
            for (idx) |ci| d.comps[ci].pred = 0;
            d.eobrun = 0;
            todo.* = d.restart_interval;
        }
        todo.* -= 1;
    }

    inline fn decodeBlock(d: *Decoder, br: *BitReader, comptime mode: Mode, c: *Component, bx: usize, by: usize, ss: u8, se: u8, al: u4) void {
        switch (mode) {
            .sequential => {
                var blk: [64]i16 = @splat(0);
                sequentialBlock(br, c, &blk);
                idct.islow(&blk, &c.quant, c.samples(bx, by), c.bw_pad * 8);
            },
            .dc_first => {
                c.pred +%= dcDiff(br, c.dc);
                c.block(bx, by)[0] = @truncate(c.pred *% (@as(i32, 1) << al));
            },
            .dc_refine => if (br.bit()) {
                c.block(bx, by)[0] |= @as(i16, 1) << al;
            },
            .ac_first => d.acFirst(br, c.ac, c.block(bx, by), ss, se, al),
            .ac_refine => d.acRefine(br, c.ac, c.block(bx, by), ss, se, al),
        }
    }

    inline fn dcDiff(br: *BitReader, t: *const huffman.Table) i32 {
        br.ensure(32);
        const f = t.fast[br.peek(9)];
        if (f != 0) {
            br.skip(@as(u8, @truncate(@as(u32, @bitCast(f)))));
            return f >> 16;
        }
        const s = t.decode(br);
        return if (s != 0) br.receiveExtend(s) else 0;
    }

    inline fn sequentialBlock(br: *BitReader, c: *Component, blk: *[64]i16) void {
        c.pred +%= dcDiff(br, c.dc);
        blk[0] = @truncate(c.pred);
        var k: usize = 1;
        const ac = c.ac;
        while (k < 64) {
            br.ensure(32); // a code and its value
            const f = ac.fast[br.peek(9)];
            if (f != 0) {
                const u: u32 = @bitCast(f);
                br.skip(@as(u8, @truncate(u)));
                const zr: u8 = @truncate(u >> 8);
                if (zr == huffman.Table.eob) break;
                k += zr;
                blk[natural[k]] = @truncate(f >> 16); // a ZRL writes 0 where nothing was yet
                k += 1;
                continue;
            }
            const rs = ac.decode(br);
            const r = rs >> 4;
            const sz = rs & 15;
            if (sz != 0) {
                k += r;
                blk[natural[k]] = @truncate(br.receiveExtend(sz));
                k += 1;
            } else {
                if (r != 15) break;
                k += 16;
            }
        }
    }

    fn acFirst(d: *Decoder, br: *BitReader, t: *const huffman.Table, blk: *[64]i16, ss: u8, se: u8, al: u4) void {
        if (d.eobrun > 0) {
            d.eobrun -= 1;
            return;
        }
        var k: usize = ss;
        while (k <= se) : (k += 1) {
            const rs = t.decode(br);
            const r = rs >> 4;
            const s = rs & 15;
            if (s != 0) {
                k += r;
                blk[natural[k]] = @truncate(br.receiveExtend(s) *% (@as(i32, 1) << al));
            } else if (r == 15) {
                k += 15;
            } else {
                d.eobrun = @as(u32, 1) << @intCast(r);
                if (r != 0) d.eobrun += br.bits(r);
                d.eobrun -= 1;
                break;
            }
        }
    }

    fn acRefine(d: *Decoder, br: *BitReader, t: *const huffman.Table, blk: *[64]i16, ss: u8, se: u8, al: u4) void {
        const p1: i16 = @as(i16, 1) << al;
        const m1: i16 = @as(i16, -1) << al;
        const correct = struct {
            inline fn f(r: *BitReader, coef: *i16, plus: i16, minus: i16) void {
                if (r.bit() and coef.* & plus == 0) coef.* +%= if (coef.* >= 0) plus else minus;
            }
        }.f;
        var k: usize = ss;
        if (d.eobrun == 0) {
            while (k <= se) : (k += 1) {
                const rs = t.decode(br);
                var r: i32 = rs >> 4;
                const s = rs & 15;
                var v: i16 = 0;
                if (s != 0) {
                    v = if (br.bit()) p1 else m1; // s should be 1; libjpeg only warns
                } else if (r != 15) {
                    d.eobrun = @as(u32, 1) << @intCast(r);
                    if (r != 0) d.eobrun += br.bits(@intCast(r));
                    break;
                }
                // over the already-nonzero coefficients (each gets a correction bit) and r zero ones
                while (k <= se) : (k += 1) {
                    const coef = &blk[natural[k]];
                    if (coef.* != 0) {
                        correct(br, coef, p1, m1);
                    } else {
                        r -= 1;
                        if (r < 0) break;
                    }
                }
                if (v != 0) blk[natural[k]] = v;
            }
        }
        if (d.eobrun > 0) {
            while (k <= se) : (k += 1) {
                const coef = &blk[natural[k]];
                if (coef.* != 0) correct(br, coef, p1, m1);
            }
            d.eobrun -= 1;
        }
    }

    /// The rows not written during the scans: all of them, unless in strip mode.
    fn output(d: *Decoder) void {
        if (d.progressive) {
            for (d.comps[0..d.ncomp]) |*c| {
                if (!c.latched) continue; // never in a scan: libjpeg's multipliers stay zero, the plane grey
                for (0..c.bh) |by| for (0..c.bw) |bx| idct.islow(c.block(bx, by), &c.quant, c.samples(bx, by), c.bw_pad * 8);
            }
        }
        d.emitRows(d.emitted, d.height);
    }

    fn info(d: *const Decoder) Info {
        return .{ .width = @intCast(d.width), .height = @intCast(d.height), .channels = if (d.ncomp == 1) 1 else 3, .progressive = d.progressive, .unsmoothed = d.wouldSmooth() };
    }

    /// jdcoefct.c smoothing_ok, at the end of the file.
    fn wouldSmooth(d: *const Decoder) bool {
        if (!d.progressive) return false;
        var useful = false;
        for (d.comps[0..d.ncomp]) |c| {
            if (!c.latched) return false;
            for ([_]u8{ 0, 1, 8, 16, 9, 2, 3, 10, 17, 24 }) |pos| if (c.quant[pos] == 0) return false;
            if (c.coef_bits[0] < 0) return false;
            for (c.coef_bits[1..]) |b| useful = useful or b != 0;
        }
        return useful;
    }
};

pub const Info = struct {
    width: u32,
    height: u32,
    channels: u8, // what the decoder gives: 1 (grey) or 3 (RGB)
    progressive: bool,
    unsmoothed: bool = false, // see Image.unsmoothed (known only after decoding)

    pub fn len(i: Info) usize {
        return @as(usize, i.width) * i.height * i.channels;
    }
};

/// The image's size and channels from its headers, without decoding it (nor checking the rest of the file).
pub fn readInfo(data: []const u8) Error!Info {
    var d: Decoder = .{ .gpa = undefined, .data = data, .opts = .{} }; // allocates nothing
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) return error.InvalidJpeg;
    while (d.nextMarker()) |m| switch (m) {
        0xC0, 0xC1, 0xC2 => {
            const s = try d.segment();
            if (s.len < 6) return error.InvalidJpeg;
            if (s[0] != 8 or (s[5] != 1 and s[5] != 3)) return error.Unsupported;
            const h = Decoder.be16(s, 1);
            const w = Decoder.be16(s, 3);
            if (w == 0) return error.InvalidJpeg;
            if (h == 0) return error.Unsupported;
            return .{ .width = w, .height = h, .channels = if (s[5] == 1) 1 else 3, .progressive = m == 0xC2 };
        },
        0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported,
        0xD8, 0xD9, 0xDA => return error.InvalidJpeg,
        0xD0...0xD7, 0x01 => {},
        else => _ = try d.segment(),
    };
    return error.InvalidJpeg;
}

/// Decodes a JPEG file into `pixels` (at least `readInfo(data).len()` bytes, rows top to bottom), so a caller can reuse one
/// buffer. `gpa` holds the decoder's working memory for the call.
pub fn decodeInto(gpa: Allocator, data: []const u8, pixels: []u8, opts: Options) Error!Info {
    var d: Decoder = .{ .gpa = gpa, .data = data, .opts = opts, .out = pixels };
    defer d.deinit();
    try d.run();
    d.output();
    return d.info();
}

/// Decodes a JPEG file into 8-bit grey or RGB pixels; free them with `Image.deinit`.
pub fn decode(gpa: Allocator, data: []const u8, opts: Options) Error!Image {
    var d: Decoder = .{ .gpa = gpa, .data = data, .opts = opts, .own_out = true };
    defer d.deinit();
    try d.run();
    d.output();
    const i = d.info();
    const pixels = d.out;
    d.own_out = false; // the caller's now
    return .{ .width = i.width, .height = i.height, .channels = i.channels, .pixels = pixels, .unsmoothed = i.unsmoothed };
}

test "the Annex K tables are what a DHT segment would give" {
    for (0..2) |i| {
        _ = try huffman.Table.init(&std_tables.dc_bits[i], &std_tables.dc_vals, .dc);
        _ = try huffman.Table.init(&std_tables.ac_bits[i], &std_tables.ac_vals[i], .ac);
    }
}

test "rejects what is not a JPEG" {
    try std.testing.expectError(error.InvalidJpeg, decode(std.testing.allocator, "", .{}));
    try std.testing.expectError(error.InvalidJpeg, decode(std.testing.allocator, "\xFF\xD8\xFF\xD9", .{}));
    try std.testing.expectError(error.InvalidJpeg, decode(std.testing.allocator, "GIF89a", .{}));
}

const seeds = [_]struct { name: []const u8, width: u32, height: u32, channels: u8, crc: u32 }{
    // CRC-32 of libjpeg-turbo 3.2's djpeg output for each file
    .{ .name = "syn16x16-q85-420.jpg", .width = 16, .height = 16, .channels = 3, .crc = 0x1f380c88 },
    .{ .name = "syn17x31-rst1b.jpg", .width = 17, .height = 31, .channels = 3, .crc = 0x09464e04 },
    .{ .name = "syn17x31-s1x1-prog.jpg", .width = 17, .height = 31, .channels = 3, .crc = 0x72447b85 },
    .{ .name = "syn3x2-rgb.jpg", .width = 3, .height = 2, .channels = 3, .crc = 0x14dff9e9 },
    .{ .name = "syn63x65-s2x2_1x2_2x1.jpg", .width = 63, .height = 65, .channels = 3, .crc = 0x77a40686 },
    .{ .name = "syn7x9-grey-prog.jpg", .width = 7, .height = 9, .channels = 1, .crc = 0xeaef4f12 },
};

fn seedData(comptime name: []const u8) []const u8 {
    return @embedFile("testdata/" ++ name);
}

test "the seed files decode to libjpeg-turbo's pixels" {
    inline for (seeds) |sd| {
        var img = try decode(std.testing.allocator, seedData(sd.name), .{});
        defer img.deinit(std.testing.allocator);
        try std.testing.expectEqual(sd.width, img.width);
        try std.testing.expectEqual(sd.height, img.height);
        try std.testing.expectEqual(sd.channels, img.channels);
        try std.testing.expectEqual(sd.crc, std.hash.Crc32.hash(img.pixels));
        const info = try readInfo(seedData(sd.name));
        try std.testing.expectEqual(img.pixels.len, info.len());
    }
}

test "every truncation of a seed fails cleanly or decodes, without leaks" {
    const data = seedData("syn17x31-s1x1-prog.jpg");
    for (0..data.len) |n| {
        var img = decode(std.testing.allocator, data[0..n], .{}) catch continue;
        img.deinit(std.testing.allocator);
    }
}

test "fuzzer finds: a table that overflows its code space; 4x vertical sampling of a 65535-row image" {
    try std.testing.expectError(error.InvalidJpeg, decode(std.testing.allocator, seedData("fuzz-overfull-dht.jpg"), .{}));
    try std.testing.expectError(error.InvalidJpeg, decode(std.testing.allocator, seedData("fuzz-tall-sampling.jpg"), .{})); // it overflowed before
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [16384]u8 = undefined;
    const n = smith.slice(&buf);
    var img = decode(std.testing.allocator, buf[0..n], .{ .max_pixels = 1 << 20 }) catch return;
    img.deinit(std.testing.allocator);
}

test "fuzz: decode" {
    // Coverage-guided with `zig build test --fuzz` (Linux); otherwise the seeds are replayed.
    const corpus = comptime blk: {
        var c: [seeds.len + 2][]const u8 = undefined;
        for (seeds, 0..) |sd, i| c[i] = seedData(sd.name);
        c[seeds.len] = seedData("fuzz-overfull-dht.jpg");
        c[seeds.len + 1] = seedData("fuzz-tall-sampling.jpg");
        break :blk c;
    };
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &corpus });
}
