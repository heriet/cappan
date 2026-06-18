const std = @import("std");
const writer = @import("../writer.zig");

pub fn buildPost(allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, 32);
    @memset(buf, 0);
    writer.writeU32BE(buf, 0, 0x00030000);
    return buf;
}
