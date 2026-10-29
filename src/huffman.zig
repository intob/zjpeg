//! Entropy-coded data: the bit reader (0xFF00 stuffing, stopping at markers) and Huffman tables.
const std = @import("std");

/// Reads the bits of a scan, most significant first. At a marker or the end of the data it feeds zero bits, as libjpeg does;
/// `insufficient` says a read went past the real data (libjpeg's insufficient_data: the rest of the scan, up to the next restart,
/// is then left out). The padding only ever sits at the bottom of buf, so that is the case exactly when fewer bits are left than
/// padding was added; `checkInsufficient` looks once per MCU, where libjpeg acts on it, and reads stay free of bookkeeping.
pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    buf: u64 = 0, // left-aligned
    n: u32 = 0, // bits in buf
    zeros: u32 = 0, // padding bits added (past a marker or the end)
    at_marker: bool = false,
    insufficient: bool = false,

    pub fn init(data: []const u8, pos: usize) BitReader {
        return .{ .data = data, .pos = pos };
    }

    /// Fills buf to at least 57 bits.
    inline fn refill(r: *BitReader) void {
        // Fast path: eight bytes with no 0xFF among them.
        if (!r.at_marker and r.data.len - r.pos >= 8) {
            const w = std.mem.readInt(u64, r.data[r.pos..][0..8], .big);
            const x = ~w; // a 0xFF byte in w is a zero byte in x
            if ((x -% 0x0101010101010101) & ~x & 0x8080808080808080 == 0) {
                const k = (64 - r.n) / 8;
                const total = r.n + k * 8;
                var add = w >> @intCast(r.n);
                if (total < 64) add &= ~((@as(u64, 1) << @intCast(64 - total)) - 1);
                r.buf |= add;
                r.n = total;
                r.pos += k;
                return;
            }
        }
        while (r.n <= 56) {
            var byte: u8 = 0;
            if (!r.at_marker) {
                if (r.pos >= r.data.len) {
                    r.at_marker = true;
                } else if (r.data[r.pos] != 0xFF) {
                    byte = r.data[r.pos];
                    r.pos += 1;
                } else {
                    var j = r.pos + 1; // FF FF ... 00 is a stuffed FF; FF FF ... xx a marker at the last FF
                    while (j < r.data.len and r.data[j] == 0xFF) j += 1;
                    if (j < r.data.len and r.data[j] == 0) {
                        byte = 0xFF;
                        r.pos = j + 1;
                    } else {
                        r.pos = j - 1;
                        r.at_marker = true;
                    }
                }
            }
            if (r.at_marker) r.zeros += 8;
            r.buf |= @as(u64, byte) << @intCast(56 - r.n);
            r.n += 8;
        }
    }

    pub inline fn ensure(r: *BitReader, k: u32) void {
        if (r.n < k) r.refill();
    }

    pub inline fn peek(r: *const BitReader, comptime k: u5) u32 {
        return @intCast(r.buf >> (64 - @as(u7, k)));
    }

    /// Consumes k bits (at most 32; a caller ensured them).
    pub inline fn skip(r: *BitReader, k: u32) void {
        r.buf <<= @intCast(k);
        r.n -= k;
    }

    pub inline fn checkInsufficient(r: *BitReader) void {
        if (r.n < r.zeros) r.insufficient = true;
    }

    /// `k` (1-16) bits as an unsigned number.
    pub inline fn bits(r: *BitReader, k: u32) u32 {
        r.ensure(k);
        const v: u32 = @intCast(r.buf >> @intCast(64 - k));
        r.skip(k);
        return v;
    }

    pub inline fn bit(r: *BitReader) bool {
        return r.bits(1) != 0;
    }

    /// `s` bits (1-15) as a signed coefficient (JPEG's EXTEND).
    pub inline fn receiveExtend(r: *BitReader, s: u32) i32 {
        const v: i32 = @intCast(r.bits(s));
        return if (v < (@as(i32, 1) << @intCast(s - 1))) v - (@as(i32, 1) << @intCast(s)) + 1 else v;
    }

    /// At a restart: drops the bits left and consumes the RSTn marker if it is next (any n: resynchronising is libjpeg's
    /// business only in damaged files); another marker is left for the marker reader, and the reader keeps feeding zeros.
    pub inline fn restart(r: *BitReader) void {
        r.buf = 0;
        r.n = 0;
        r.zeros = 0;
        var p = r.pos;
        while (p + 1 < r.data.len) : (p += 1) {
            if (r.data[p] != 0xFF) continue;
            var j = p + 1;
            while (j < r.data.len and r.data[j] == 0xFF) j += 1;
            if (j >= r.data.len) break;
            if (r.data[j] == 0) {
                p = j;
                continue;
            }
            if (r.data[j] >= 0xD0 and r.data[j] <= 0xD7) {
                r.pos = j + 1;
                r.at_marker = false;
                r.insufficient = false;
            } else {
                r.pos = j - 1;
                r.at_marker = true;
            }
            return;
        }
        r.pos = r.data.len;
        r.at_marker = true;
    }
};

pub const Table = struct {
    /// (length << 8) | symbol for codes of 9 bits or fewer, indexed by the next 9 bits; 0 for longer codes.
    lut: [512]u16,
    /// The symbol and its extra bits in one lookup, when both fit in the next 9 bits: (value << 16) | (run << 8) | bits used,
    /// value already sign-extended. For AC tables, run 0xFF is end of block; a ZRL is run 15 with value 0. 0: not in the table.
    fast: [512]i32,
    maxcode: [17]i32, // largest code of each length, -1 for none
    valoff: [17]i32, // symbol index of a code of that length: code + valoff
    values: [256]u8,
    count: u16,

    /// From a DHT segment's 16 counts and its symbols. Rejects tables libjpeg rejects (jdhuff.c jpeg_make_d_derived_tbl).
    pub const eob = 0xFF;

    pub fn init(counts: *const [16]u8, values: []const u8, class: enum { dc, ac }) error{InvalidJpeg}!Table {
        var t: Table = .{ .lut = @splat(0), .fast = @splat(0), .maxcode = @splat(-1), .valoff = @splat(0), .values = @splat(0), .count = @intCast(values.len) };
        @memcpy(t.values[0..values.len], values);
        var last: usize = 0;
        for (counts, 1..) |c, l| if (c != 0) {
            last = l;
        };
        var code: u32 = 0;
        var k: u32 = 0;
        for (1..last + 1) |l| {
            t.valoff[l] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
            // libjpeg's check, made before the codes are placed: the all-ones code of each length stays unused
            if (code + counts[l - 1] >= @as(u32, 1) << @intCast(l)) return error.InvalidJpeg;
            for (0..counts[l - 1]) |_| {
                if (l <= 9) {
                    const shift: u5 = @intCast(9 - l);
                    const e: u16 = @intCast((l << 8) | values[k]);
                    @memset(t.lut[code << shift ..][0 .. @as(u32, 1) << shift], e);
                }
                code += 1;
                k += 1;
            }
            if (counts[l - 1] != 0) t.maxcode[l] = @as(i32, @intCast(code)) - 1;
            code <<= 1;
        }
        for (&t.fast, 0..) |*f, look| {
            const e = t.lut[look];
            const len = e >> 8;
            const rs: u8 = @truncate(e);
            if (e == 0) continue;
            const size = if (class == .dc) rs else rs & 15;
            var run: i32 = if (class == .dc) 0 else rs >> 4;
            if (size == 0) {
                if (class == .ac and run != 15) run = eob;
                f.* = (run << 8) | @as(i32, len);
                continue;
            }
            if (size > 15 or len + size > 9) continue;
            const raw: i32 = @intCast((look >> @intCast(9 - len - size)) & ((@as(u32, 1) << @intCast(size)) - 1));
            const v = if (raw < (@as(i32, 1) << @intCast(size - 1))) raw - (@as(i32, 1) << @intCast(size)) + 1 else raw;
            f.* = (v << 16) | (run << 8) | @as(i32, len + size);
        }
        return t;
    }

    pub inline fn decode(t: *const Table, r: *BitReader) u8 {
        r.ensure(16);
        const e = t.lut[r.peek(9)];
        if (e != 0) {
            r.skip(e >> 8);
            return @truncate(e);
        }
        const b16 = r.peek(16);
        var l: u32 = 10;
        while (l <= 16) : (l += 1) {
            const code: i32 = @intCast(b16 >> @intCast(16 - l));
            if (code <= t.maxcode[l]) {
                r.skip(l);
                return t.values[@intCast(code + t.valoff[l])];
            }
        }
        // Not a code: libjpeg reads a 17th bit before it gives up, then takes it as 0 (its slow path warns; the fast one,
        // decode_mcu_fast, which decodes most of a file held in memory, does not)
        r.ensure(17);
        r.skip(17);
        return 0;
    }
};

test "bit reader: stuffing, a marker, zero fill" {
    const data = [_]u8{ 0b1010_0000, 0xFF, 0x00, 0x12, 0xFF, 0xD9 };
    var r: BitReader = .init(&data, 0);
    try std.testing.expectEqual(0b101, r.bits(3));
    try std.testing.expectEqual(0, r.bits(5));
    try std.testing.expectEqual(0xFF, r.bits(8));
    try std.testing.expectEqual(0x12, r.bits(8));
    r.checkInsufficient();
    try std.testing.expect(!r.insufficient);
    try std.testing.expectEqual(0, r.bits(16));
    r.checkInsufficient();
    try std.testing.expect(r.insufficient);
    try std.testing.expectEqual(4, r.pos); // left at the marker
}

test "huffman: an overfull table is refused before it is built" {
    var counts: [16]u8 = @splat(0);
    counts[0] = 5; // five 1-bit codes: more than the code space (found by the fuzzer: it overran the lookup table)
    try std.testing.expectError(error.InvalidJpeg, Table.init(&counts, "abcde", .ac));
    counts[0] = 2; // 0 and 1: libjpeg keeps each length's all-ones code unused
    try std.testing.expectError(error.InvalidJpeg, Table.init(&counts, "ab", .ac));
    counts[0] = 1;
    _ = try Table.init(&counts, "a", .ac);
}

test "huffman: a small canonical table" {
    // lengths: 2 codes of 2 bits (00 -> 'a', 01 -> 'b'), 1 of 3 bits (100 -> 'c'), 1 of 11 bits
    var counts: [16]u8 = @splat(0);
    counts[1] = 2;
    counts[2] = 1;
    counts[10] = 1;
    const t = try Table.init(&counts, "abcd", .ac);
    // 01 100 00 then 101 0000 0000 (code 'd' = 10100000000) padded
    const data = [_]u8{ 0b0110_0001, 0b0100_0000, 0b0000_0000 };
    var r: BitReader = .init(&data, 0);
    try std.testing.expectEqual('b', t.decode(&r));
    try std.testing.expectEqual('c', t.decode(&r));
    try std.testing.expectEqual('a', t.decode(&r));
    try std.testing.expectEqual('d', t.decode(&r));
}
