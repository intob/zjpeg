//! zjpeg: JPEG in pure Zig.
const std = @import("std");

pub const decoder = @import("decoder.zig");
pub const decode = decoder.decode;
pub const decodeInto = decoder.decodeInto;
pub const readInfo = decoder.readInfo;
pub const Info = decoder.Info;
pub const Image = decoder.Image;
pub const Options = decoder.Options;
pub const Error = decoder.Error;

test {
    _ = decoder;
    _ = @import("huffman.zig");
    _ = @import("idct.zig");
    _ = @import("color.zig");
}
