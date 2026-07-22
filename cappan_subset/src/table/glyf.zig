const std = @import("std");
const cappan_core = @import("cappan_core");

pub const SubsetGlyfResult = struct {
    data: []u8,
    offsets: []u32,

    pub fn deinit(self: SubsetGlyfResult, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.offsets);
    }
};

pub fn subsetGlyf(
    allocator: std.mem.Allocator,
    glyf_data: []const u8,
    loca: cappan_core.font.table.loca.LocaTable,
    used_glyphs: []const u16,
    mapping: []const u16,
) !SubsetGlyfResult {
    var total_size: usize = 0;
    for (used_glyphs) |glyph_id| {
        const loc = try loca.getGlyphLocation(glyph_id);
        if (loc.length > 0) {
            const aligned_len = std.math.add(usize, @as(usize, loc.length), 3) catch return error.InvalidGlyphData;
            total_size = std.math.add(usize, total_size, aligned_len & ~@as(usize, 3)) catch return error.InvalidGlyphData;
        }
    }

    const data = try allocator.alloc(u8, total_size);
    errdefer allocator.free(data);
    @memset(data, 0);

    const offsets = try allocator.alloc(u32, used_glyphs.len + 1);
    errdefer allocator.free(offsets);

    var write_offset: u32 = 0;
    for (used_glyphs, 0..) |glyph_id, i| {
        offsets[i] = write_offset;
        const loc = try loca.getGlyphLocation(glyph_id);
        if (loc.length == 0) continue;

        const glyph_offset: usize = @intCast(loc.offset);
        const glyph_len: usize = @intCast(loc.length);
        const dest_offset: usize = @intCast(write_offset);
        const glyph_end = std.math.add(usize, glyph_offset, glyph_len) catch return error.InvalidGlyphData;
        if (glyph_end > glyf_data.len) return error.InvalidGlyphData;
        const dest_end = std.math.add(usize, dest_offset, glyph_len) catch return error.InvalidGlyphData;
        if (dest_end > data.len) return error.InvalidGlyphData;
        const glyph_bytes = glyf_data[glyph_offset..glyph_end];
        const dest = data[dest_offset..dest_end];
        @memcpy(dest, glyph_bytes);

        const num_contours = try cappan_core.font.parser.readI16(glyph_bytes, 0);
        if (num_contours < 0) {
            // Remap each component's glyph id in place, one write per
            // component at the offset the shared iterator reports --
            // `dest` is a live copy of these bytes (memcpy'd above), so
            // walking it via the iterator and writing back through
            // `id_field_offset` is exactly the single-write remap the
            // iterator's doc promises.
            var it = cappan_core.font.table.glyf.GlyfTable.ComponentIterator.init(dest);
            while (try it.next()) |item| {
                const new_id = if (item.glyph_id < mapping.len) mapping[item.glyph_id] else 0;
                std.mem.writeInt(u16, dest[item.id_field_offset..][0..2], new_id, .big);
            }
        }

        const aligned_len = (@as(u32, loc.length) + 3) & ~@as(u32, 3);
        write_offset += aligned_len;
    }
    offsets[used_glyphs.len] = write_offset;

    return .{ .data = data, .offsets = offsets };
}
