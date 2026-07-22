const std = @import("std");
const cappan_core = @import("cappan_core");
const writer = cappan_core.font.sfnt_writer;

pub fn buildPost(allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, 32);
    @memset(buf, 0);
    writer.writeU32BE(buf, 0, 0x00030000);
    return buf;
}
