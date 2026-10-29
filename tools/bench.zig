//! zig build bench -- FILE...   decode time per file, zjpeg against libjpeg-turbo (its SIMD build), best of several rounds.
//! zig build bench -- -z N FILE  decodes FILE with zjpeg only, N times (for a profiler).
const std = @import("std");
const zjpeg = @import("zjpeg");
const turbo = @import("turbo.zig");

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var tj = try turbo.Decoder.init();
    defer tj.deinit();
    if (args.len == 4 and std.mem.eql(u8, args[1], "-z")) {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, args[3], gpa, .limited(1 << 30));
        defer gpa.free(data);
        const out = try gpa.alloc(u8, (try zjpeg.readInfo(data)).len());
        defer gpa.free(out);
        for (0..try std.fmt.parseInt(usize, args[2], 10)) |_| _ = try zjpeg.decodeInto(gpa, data, out, .{});
        return;
    }
    std.debug.print("{s:<44} {s:>11} {s:>9} {s:>9} {s:>7}\n", .{ "file", "pixels", "zjpeg ms", "turbo ms", "ratio" });
    var sum_z: f64 = 0;
    var sum_t: f64 = 0;
    for (args[1..]) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
        defer gpa.free(data);
        const hdr = tj.header(data, 1 << 28) orelse continue;
        const out = try gpa.alloc(u8, @as(usize, hdr.width) * hdr.height * hdr.channels);
        defer gpa.free(out);
        const out_z = try gpa.alloc(u8, out.len); // each decoder writes into its own buffer, reused across rounds
        defer gpa.free(out_z);
        const px = @as(usize, hdr.width) * hdr.height;
        // enough rounds for ~0.3 s each, at least 3
        var best_z: i96 = std.math.maxInt(i96);
        var best_t: i96 = std.math.maxInt(i96);
        var rounds: usize = 3;
        var r: usize = 0;
        while (r < rounds) : (r += 1) {
            var t = now(io);
            _ = try zjpeg.decodeInto(gpa, data, out_z, .{});
            const dz = now(io) - t;
            t = now(io);
            _ = tj.decode(data, hdr, out) orelse return error.TurboFailed;
            const dt = now(io) - t;
            best_z = @min(best_z, dz);
            best_t = @min(best_t, dt);
            if (r == 0) rounds = std.math.clamp(@as(usize, @intCast(@divTrunc(300_000_000, @max(dz + dt, 1)))), 3, 200);
        }
        const mz = @as(f64, @floatFromInt(best_z)) / 1e6;
        const mt = @as(f64, @floatFromInt(best_t)) / 1e6;
        sum_z += mz;
        sum_t += mt;
        std.debug.print("{s:<44} {d:>11} {d:>9.3} {d:>9.3} {d:>6.2}x\n", .{ std.fs.path.basename(path), px, mz, mt, mz / mt });
    }
    std.debug.print("{s:<44} {s:>11} {d:>9.3} {d:>9.3} {d:>6.2}x  (zjpeg time / libjpeg-turbo time)\n", .{ "total", "", sum_z, sum_t, sum_z / sum_t });
}
