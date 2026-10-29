//! zig build fuzz -- [-n ITERATIONS] [-s SEED] FILE...   a mutation fuzzer that runs anywhere (std's coverage-guided fuzzer,
//! `zig build test --fuzz`, needs Linux). Mutates the given JPEGs (bit flips, bytes, inserts, deletes, truncation, spliced
//! chunks, header-heavy), decodes each with zjpeg in ReleaseSafe with a leak-checking allocator, and compares with
//! libjpeg-turbo whenever it decodes the input without a warning. A panic writes the input to fuzz-crash.jpg first; a
//! difference is kept as fuzz-diff-N.jpg. `-r FILE` replays one input as it is.
const std = @import("std");
const zjpeg = @import("zjpeg");
const turbo = @import("turbo.zig");

var current: []const u8 = &.{};

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, ra: ?usize) noreturn {
    const f = std.c.fopen("fuzz-crash.jpg", "wb");
    if (f != null) {
        _ = std.c.fwrite(current.ptr, 1, current.len, f.?);
        _ = std.c.fclose(f.?);
        std.debug.print("\ninput written to fuzz-crash.jpg ({d} bytes)\n", .{current.len});
    }
    std.debug.defaultPanic(msg, ra);
}

/// FF FF inside entropy-coded data (fill bytes where no marker follows). Invalid, and libjpeg-turbo disagrees with itself
/// on it: its fast Huffman path, which decodes most of a file held in memory, takes FF FF for a marker, decodes the rest of
/// the MCU from zero bits and hands the MCU to its slow path, which reads the fill bytes correctly but does not clear the
/// coefficients the fast attempt left. Its slow path (djpeg on a file) gives what zjpeg gives. Such differences are counted
/// apart (ff_fill_diffs).
fn fillInScan(data: []const u8) bool {
    const sos = std.mem.indexOf(u8, data, "\xFF\xDA") orelse return false;
    var i = sos + 2;
    while (i + 2 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0xFF) return true;
    }
    return false;
}

fn mutate(rand: std.Random, buf: *std.ArrayList(u8), gpa: std.mem.Allocator, corpus: []const []const u8) !void {
    const n = 1 + rand.uintLessThan(u8, 4);
    for (0..n) |_| {
        if (buf.items.len < 4) return;
        // half the time aim at the headers, where a byte changes the most
        const lim = if (rand.boolean()) @min(buf.items.len, 700) else buf.items.len;
        const at = rand.uintLessThan(usize, lim);
        switch (rand.uintLessThan(u8, 9)) {
            0, 1 => buf.items[at] ^= @as(u8, 1) << rand.int(u3),
            2 => buf.items[at] = rand.int(u8),
            3 => buf.items[at] = switch (rand.uintLessThan(u8, 6)) {
                0 => 0xFF,
                1 => 0,
                2 => 1,
                3 => 0x7F,
                4 => 0x80,
                else => buf.items[at] +% 1,
            },
            4 => try buf.insert(gpa, at, rand.int(u8)),
            5 => _ = buf.orderedRemove(at),
            6 => if (at + 2 < buf.items.len) buf.shrinkRetainingCapacity(at + 2),
            7 => { // splice a chunk of another corpus file
                const other = corpus[rand.uintLessThan(usize, corpus.len)];
                const from = rand.uintLessThan(usize, other.len);
                const len = @min(other.len - from, 1 + rand.uintLessThan(usize, 64));
                try buf.insertSlice(gpa, at, other[from..][0..len]);
            },
            else => { // 16-bit field set to an edge value
                if (at + 2 > buf.items.len) continue;
                const v: u16 = switch (rand.uintLessThan(u8, 4)) {
                    0 => 0,
                    1 => 0xFFFF,
                    2 => 1,
                    else => rand.int(u16),
                };
                std.mem.writeInt(u16, buf.items[at..][0..2], v, .big);
            },
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var iterations: u64 = 100_000;
    var seed: u64 = 1;
    var corpus: std.ArrayList([]const u8) = .empty;
    var replay = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-r")) {
            replay = true;
        } else if (std.mem.eql(u8, args[i], "-n")) {
            i += 1;
            iterations = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "-s")) {
            i += 1;
            seed = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            const data = try std.Io.Dir.cwd().readFileAlloc(io, args[i], arena, .limited(1 << 26));
            if (replay or data.len <= 256 * 1024) try corpus.append(arena, data); // big files fuzz slowly
        }
    }
    if (corpus.items.len == 0) return error.NoCorpus;
    if (replay) iterations = corpus.items.len;
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    // libjpeg-turbo's SIMD IDCTs (16 and 32 bits wide) and its C one (64-bit) disagree on coefficients no 8-bit image
    // has; zjpeg follows the C one, so the oracle runs without SIMD. Set before the first call: it is read once.
    _ = setenv("JSIMD_FORCENONE", "1", 1);
    var tj = try turbo.Decoder.init();
    defer tj.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var ref: std.ArrayList(u8) = .empty;
    defer ref.deinit(gpa);
    var stats = struct { ok: u64 = 0, refused: u64 = 0, compared: u64 = 0, diffs: u64 = 0, warned_diffs: u64 = 0, ff_fill_diffs: u64 = 0, unsmoothed_diffs: u64 = 0, ours_only: u64 = 0, theirs_only: u64 = 0 }{};
    const max_pixels = 1 << 22;
    for (0..iterations) |it| {
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, corpus.items[if (replay) it % corpus.items.len else rand.uintLessThan(usize, corpus.items.len)]);
        if (!replay) try mutate(rand, &buf, gpa, corpus.items);
        current = buf.items;
        var res: ?turbo.Decoder.Result = null;
        tj.reset();
        if (tj.header(buf.items, max_pixels)) |h| {
            try ref.resize(gpa, @as(usize, h.width) * h.height * h.channels);
            res = tj.decode(buf.items, h, ref.items);
        }
        if (zjpeg.decode(gpa, buf.items, .{ .max_pixels = max_pixels })) |img| {
            var im = img;
            defer im.deinit(gpa);
            stats.ok += 1;
            if (res) |r| {
                const same = im.width == r.width and im.height == r.height and im.channels == r.channels and
                    std.mem.eql(u8, im.pixels, ref.items);
                if (!r.warning) {
                    stats.compared += 1;
                    if (!same and fillInScan(buf.items)) {
                        stats.ff_fill_diffs += 1;
                    } else if (!same and im.unsmoothed) {
                        stats.unsmoothed_diffs += 1; // libjpeg's block smoothing, not implemented yet
                    } else if (!same) {
                        stats.diffs += 1;
                        const name = try std.fmt.allocPrint(arena, "fuzz-diff-{d}.jpg", .{stats.diffs});
                        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = buf.items });
                        std.debug.print("difference on a clean decode: {s}\n", .{name});
                    }
                } else if (!same) stats.warned_diffs += 1;
            } else stats.ours_only += 1;
        } else |_| {
            stats.refused += 1;
            if (res != null and !res.?.warning) {
                stats.theirs_only += 1;
                if (stats.theirs_only <= 20) {
                    const name = try std.fmt.allocPrint(arena, "fuzz-refused-{d}.jpg", .{stats.theirs_only});
                    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = buf.items });
                }
            }
        }
        if ((it + 1) % 20000 == 0) std.debug.print("{d}: {any}\n", .{ it + 1, stats });
    }
    std.debug.print("done: {any}\n", .{stats});
    if (stats.diffs != 0) std.process.exit(1);
}
