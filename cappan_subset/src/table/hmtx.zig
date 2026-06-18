const std = @import("std");
const cappan_core = @import("cappan_core");
const writer = @import("../writer.zig");

pub fn subsetHmtx(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    used_glyphs: []const u16,
) ![]u8 {
    const buf = try allocator.alloc(u8, used_glyphs.len * 4);
    errdefer allocator.free(buf);

    for (used_glyphs, 0..) |glyph_id, i| {
        const metrics = try font.getHMetrics(glyph_id);
        const off = i * 4;
        writer.writeU16BE(buf, off, metrics.advance_width);
        writer.writeI16BE(buf, off + 2, metrics.lsb);
    }

    return buf;
}
