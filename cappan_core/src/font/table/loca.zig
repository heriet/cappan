const std = @import("std");
const parser = @import("../parser.zig");

pub const LocaTable = struct {
    data: []const u8,
    index_to_loc_format: i16,
    num_glyphs: u16,

    pub const GlyphLocation = struct {
        offset: u32,
        length: u32,
    };

    pub fn getGlyphLocation(self: LocaTable, glyph_id: u16) !GlyphLocation {
        if (glyph_id >= self.num_glyphs) return error.InvalidGlyphId;

        if (self.index_to_loc_format == 0) {
            // Short format: u16 values, multiply by 2
            const offset1 = @as(u32, try parser.readU16(self.data, @as(usize, glyph_id) * 2)) * 2;
            const offset2 = @as(u32, try parser.readU16(self.data, @as(usize, glyph_id + 1) * 2)) * 2;
            if (offset2 < offset1) return error.InvalidLocaOffset;
            return .{ .offset = offset1, .length = offset2 - offset1 };
        } else {
            // Long format: u32 values
            const offset1 = try parser.readU32(self.data, @as(usize, glyph_id) * 4);
            const offset2 = try parser.readU32(self.data, @as(usize, glyph_id + 1) * 4);
            if (offset2 < offset1) return error.InvalidLocaOffset;
            return .{ .offset = offset1, .length = offset2 - offset1 };
        }
    }
};

pub fn parse(data: []const u8, index_to_loc_format: i16, num_glyphs: u16) LocaTable {
    return .{
        .data = data,
        .index_to_loc_format = index_to_loc_format,
        .num_glyphs = num_glyphs,
    };
}

test "parse loca table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const head_record = parser.findTable(offset_table, "head".*) orelse return error.TableNotFound;
    const head_data = try parser.getTableData(font_data, head_record);
    const head_mod = @import("head.zig");
    const head = try head_mod.parse(head_data);

    const maxp_record = parser.findTable(offset_table, "maxp".*) orelse return error.TableNotFound;
    const maxp_data = try parser.getTableData(font_data, maxp_record);
    const maxp_mod = @import("maxp.zig");
    const maxp = try maxp_mod.parse(maxp_data);

    const loca_record = parser.findTable(offset_table, "loca".*) orelse return error.TableNotFound;
    const loca_data = try parser.getTableData(font_data, loca_record);
    const loca = parse(loca_data, head.index_to_loc_format, maxp.num_glyphs);

    // Glyph 0 (.notdef) should have non-zero length
    const loc0 = try loca.getGlyphLocation(0);
    try std.testing.expect(loc0.length > 0);
}
