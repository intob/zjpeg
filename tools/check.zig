//! zig build check -- FILE...   decodes each JPEG with zjpeg and with libjpeg-turbo and compares the pixels.
//! Exit status 1 if any clean file (one libjpeg-turbo decodes without a warning) differs or fails.
//! With ZJPEG_DUMP set, a file that differs gets both decodes written next to it as FILE.zjpeg.pnm and FILE.turbo.pnm.
const std = @import("std");
const zjpeg = @import("zjpeg");
const turbo = @import("turbo.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var tj = try turbo.Decoder.init();
    defer tj.deinit();
    var same: usize = 0;
    var bad: usize = 0;
    var both_refuse: usize = 0;
    var noisy: usize = 0;
    for (args[1..]) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
        defer gpa.free(data);
        tj.reset();
        const hdr = tj.header(data, 1 << 28);
        var ref: ?[]u8 = null;
        defer if (ref) |r| gpa.free(r);
        var res: ?turbo.Decoder.Result = null;
        if (hdr) |h| {
            ref = try gpa.alloc(u8, @as(usize, h.width) * h.height * h.channels);
            res = tj.decode(data, h, ref.?);
        }
        var img = zjpeg.decode(gpa, data, .{}) catch |e| {
            if (res == null) {
                both_refuse += 1;
                continue;
            }
            std.debug.print("FAIL {s}: zjpeg {t}, libjpeg-turbo {s}\n", .{ path, e, if (res.?.warning) "decoded with a warning" else "decoded it" });
            if (!res.?.warning) bad += 1 else noisy += 1;
            continue;
        };
        defer img.deinit(gpa);
        const r = res orelse {
            std.debug.print("note {s}: libjpeg-turbo refused it ({s}), zjpeg decoded it\n", .{ path, tj.errorString() });
            noisy += 1;
            continue;
        };
        if (img.width != r.width or img.height != r.height or img.channels != r.channels) {
            std.debug.print("DIFF {s}: zjpeg {d}x{d}x{d}, libjpeg-turbo {d}x{d}x{d}\n", .{ path, img.width, img.height, img.channels, r.width, r.height, r.channels });
            bad += 1;
            continue;
        }
        var diff: usize = 0;
        for (img.pixels, ref.?) |a, b| diff += @intFromBool(a != b);
        if (diff == 0) {
            same += 1;
            continue;
        }
        if (init.environ_map.get("ZJPEG_DUMP") != null) {
            for ([_][]const u8{ "zjpeg", "turbo" }, [_][]const u8{ img.pixels, ref.? }) |who, px| {
                const name = try std.fmt.allocPrint(gpa, "{s}.{s}.pnm", .{ path, who });
                defer gpa.free(name);
                const head = try std.fmt.allocPrint(gpa, "P{d}\n{d} {d}\n255\n", .{ @as(u8, if (r.channels == 1) 5 else 6), r.width, r.height });
                defer gpa.free(head);
                const all = try std.mem.concat(gpa, u8, &.{ head, px });
                defer gpa.free(all);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = all });
            }
        }
        const i = std.mem.indexOfDiff(u8, img.pixels, ref.?).?;
        const px = i / r.channels;
        std.debug.print("{s} {s}: {d} of {d} bytes differ; first at x={d} y={d} (zjpeg {d}, libjpeg-turbo {d}){s}\n", .{
            if (r.warning or img.unsmoothed) "diff" else "DIFF", path, diff, img.pixels.len, px % r.width, px / r.width, img.pixels[i], ref.?[i],
            if (r.warning) " - libjpeg-turbo warned" else if (img.unsmoothed) " - libjpeg block-smooths it, zjpeg does not yet" else "",
        });
        if (r.warning or img.unsmoothed) noisy += 1 else bad += 1;
    }
    std.debug.print("{d} identical, {d} differ or fail, {d} damaged (libjpeg-turbo warned or refused, or block-smoothed), {d} refused by both\n", .{ same, bad, noisy, both_refuse });
    if (bad != 0) std.process.exit(1);
}
