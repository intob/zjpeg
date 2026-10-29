const std = @import("std");

// zig build test                  unit tests (and the coverage-guided fuzz test: zig build test --fuzz, on Linux)
// zig build check -- FILE...      compare with libjpeg-turbo, pixel for pixel
// zig build bench -- FILE...      decode speed against libjpeg-turbo
// zig build fuzz -- FILE...       mutation fuzzer with libjpeg-turbo as the oracle
// The tools link libjpeg-turbo's static TurboJPEG library from -Dturbo=<prefix> (default: Homebrew's).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const turbo = b.option([]const u8, "turbo", "libjpeg-turbo prefix") orelse "/opt/homebrew/opt/jpeg-turbo";
    const checked = b.option(std.builtin.OptimizeMode, "checked-mode", "Mode for check and fuzz (default: safe)") orelse .safe;

    const zjpeg = b.addModule("zjpeg", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });

    const t = b.addTest(.{ .root_module = zjpeg });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(t).step);

    const tools = [_]struct { name: []const u8, desc: []const u8, mode: std.builtin.OptimizeMode }{
        .{ .name = "check", .desc = "Compare with libjpeg-turbo", .mode = checked },
        .{ .name = "bench", .desc = "Benchmark against libjpeg-turbo", .mode = .fast },
        .{ .name = "fuzz", .desc = "Mutation-fuzz against libjpeg-turbo", .mode = checked },
    };
    for (tools) |tool| {
        const lib = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = tool.mode });
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}.zig", .{tool.name})),
            .target = target,
            .optimize = tool.mode,
            .link_libc = true,
            .imports = &.{.{ .name = "zjpeg", .module = lib }},
        });
        mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libturbojpeg.a", .{turbo}) });
        const exe = b.addExecutable(.{ .name = tool.name, .root_module = mod });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(tool.name, tool.desc).dependOn(&run.step);
    }
}
