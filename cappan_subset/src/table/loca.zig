const std = @import("std");
const writer = @import("../writer.zig");

pub fn buildLoca(
    allocator: std.mem.Allocator,
    offsets: []const u32,
    use_short: bool,
) ![]u8 {
    if (use_short) {
        const buf = try allocator.alloc(u8, offsets.len * 2);
        for (offsets, 0..) |off, i| {
            writer.writeU16BE(buf, i * 2, @intCast(off / 2));
        }
        return buf;
    } else {
        const buf = try allocator.alloc(u8, offsets.len * 4);
        for (offsets, 0..) |off, i| {
            writer.writeU32BE(buf, i * 4, off);
        }
        return buf;
    }
}
