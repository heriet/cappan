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

pub const MORE_COMPONENTS: u16 = 0x0020;
pub const ARG_1_AND_2_ARE_WORDS: u16 = 0x0001;
pub const WE_HAVE_A_SCALE: u16 = 0x0008;
pub const WE_HAVE_AN_X_AND_Y_SCALE: u16 = 0x0040;
pub const WE_HAVE_A_TWO_BY_TWO: u16 = 0x0080;

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
            var offset: usize = 10;
            var flags: u16 = MORE_COMPONENTS;
            while (flags & MORE_COMPONENTS != 0) {
                if (offset + 4 > dest.len) break;
                flags = try cappan_core.font.parser.readU16(dest, offset);
                offset += 2;
                const old_id = try cappan_core.font.parser.readU16(dest, offset);
                const new_id = if (old_id < mapping.len) mapping[old_id] else 0;
                std.mem.writeInt(u16, dest[offset..][0..2], new_id, .big);
                offset += 2;

                if (flags & ARG_1_AND_2_ARE_WORDS != 0) {
                    offset += 4;
                } else {
                    offset += 2;
                }
                if (flags & WE_HAVE_A_SCALE != 0) {
                    offset += 2;
                } else if (flags & WE_HAVE_AN_X_AND_Y_SCALE != 0) {
                    offset += 4;
                } else if (flags & WE_HAVE_A_TWO_BY_TWO != 0) {
                    offset += 8;
                }
            }
        }

        const aligned_len = (@as(u32, loc.length) + 3) & ~@as(u32, 3);
        write_offset += aligned_len;
    }
    offsets[used_glyphs.len] = write_offset;

    return .{ .data = data, .offsets = offsets };
}
