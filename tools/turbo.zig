//! libjpeg-turbo's TurboJPEG 3 API, the reference the tools compare against (linked from -Dturbo=<prefix>).
const std = @import("std");

const Handle = ?*anyopaque;
extern fn tj3Init(init_type: c_int) Handle;
extern fn tj3Destroy(h: Handle) void;
extern fn tj3Set(h: Handle, param: c_int, value: c_int) c_int;
extern fn tj3Get(h: Handle, param: c_int) c_int;
extern fn tj3DecompressHeader(h: Handle, buf: [*]const u8, size: usize) c_int;
extern fn tj3Decompress8(h: Handle, buf: [*]const u8, size: usize, dst: [*]u8, pitch: c_int, pf: c_int) c_int;
extern fn tj3GetErrorCode(h: Handle) c_int;
extern fn tj3GetErrorStr(h: Handle) [*:0]const u8;

const TJINIT_DECOMPRESS = 1;
const TJPF_RGB = 0;
const TJPF_GRAY = 6;
const TJPARAM_JPEGWIDTH = 5;
const TJPARAM_JPEGHEIGHT = 6;
const TJPARAM_COLORSPACE = 8;
const TJPARAM_MAXPIXELS = 24;
const TJCS_GRAY = 2;
const TJERR_WARNING = 0;

pub const Decoder = struct {
    h: Handle,
    err: [256]u8 = undefined,
    err_len: usize = 0,

    pub fn init() !Decoder {
        const h = tj3Init(TJINIT_DECOMPRESS) orelse return error.TurboInit;
        return .{ .h = h };
    }

    pub fn deinit(d: Decoder) void {
        tj3Destroy(d.h);
    }

    pub const Result = struct {
        width: u32,
        height: u32,
        channels: u8,
        warning: bool, // libjpeg-turbo decoded it but warned (damaged or truncated data)
    };

    /// After an error or a warning a TurboJPEG handle can be left mid-decompression, refusing every later file
    /// ("Improper call to JPEG library in state ..."), so the tools start over with a new one. A handle also keeps the
    /// quantisation and Huffman tables of earlier files (libjpeg's abbreviated datastreams), so a file missing one would be
    /// decoded with another file's: the tools reset before each file too.
    pub fn reset(d: *Decoder) void {
        const msg = std.mem.span(tj3GetErrorStr(d.h));
        d.err_len = @min(msg.len, d.err.len);
        @memcpy(d.err[0..d.err_len], msg[0..d.err_len]);
        tj3Destroy(d.h);
        d.h = tj3Init(TJINIT_DECOMPRESS) orelse @panic("tj3Init");
    }

    /// Header only: size and channels, or null when libjpeg-turbo refuses the file.
    pub fn header(d: *Decoder, data: []const u8, max_pixels: u32) ?Result {
        _ = tj3Set(d.h, TJPARAM_MAXPIXELS, @intCast(max_pixels));
        if (tj3DecompressHeader(d.h, data.ptr, data.len) != 0) {
            d.reset();
            return null;
        }
        const w = tj3Get(d.h, TJPARAM_JPEGWIDTH);
        const h = tj3Get(d.h, TJPARAM_JPEGHEIGHT);
        if (w <= 0 or h <= 0) return null;
        const ch: u8 = if (tj3Get(d.h, TJPARAM_COLORSPACE) == TJCS_GRAY) 1 else 3;
        return .{ .width = @intCast(w), .height = @intCast(h), .channels = ch, .warning = false };
    }

    /// Decodes into `out` (width * height * channels from `header`); null on an error, a warning flagged in the result.
    pub fn decode(d: *Decoder, data: []const u8, hdr: Result, out: []u8) ?Result {
        const pf: c_int = if (hdr.channels == 1) TJPF_GRAY else TJPF_RGB;
        var r = hdr;
        if (tj3Decompress8(d.h, data.ptr, data.len, out.ptr, @intCast(hdr.width * hdr.channels), pf) != 0) {
            const warning = tj3GetErrorCode(d.h) == TJERR_WARNING;
            d.reset();
            if (!warning) return null;
            r.warning = true;
        }
        return r;
    }

    /// The last error or warning.
    pub fn errorString(d: *const Decoder) []const u8 {
        return d.err[0..d.err_len];
    }
};
