const std = @import("std");
const parser = @import("../parser.zig");
const ivs = @import("item_variation_store.zig");

pub const VvarTable = struct {
    data: []const u8,
    item_variation_store_offset: u32,
    advance_height_mapping_offset: u32,
    tsb_mapping_offset: u32,

    pub fn getAdvanceHeightDelta(self: VvarTable, glyph_id: u16, normalized_coords: []const f32) !i32 {
        var outer: u16 = 0;
        var inner: u16 = glyph_id;

        if (self.advance_height_mapping_offset != 0) {
            const mapping = try ivs.readDeltaSetIndexMap(self.data, self.advance_height_mapping_offset);
            if (glyph_id < mapping.map_count) {
                const entry = try ivs.readMapEntry(self.data, mapping, glyph_id);
                outer = entry.outer;
                inner = entry.inner;
            }
        }

        return ivs.getItemDelta(self.data, @as(usize, self.item_variation_store_offset), outer, inner, normalized_coords);
    }

    pub fn getTsbDelta(self: VvarTable, glyph_id: u16, normalized_coords: []const f32) !i32 {
        if (self.tsb_mapping_offset == 0) return 0;

        const mapping = try ivs.readDeltaSetIndexMap(self.data, self.tsb_mapping_offset);
        if (glyph_id >= mapping.map_count) return 0;

        const entry = try ivs.readMapEntry(self.data, mapping, glyph_id);
        return ivs.getItemDelta(self.data, @as(usize, self.item_variation_store_offset), entry.outer, entry.inner, normalized_coords);
    }
};

pub fn parse(data: []const u8) !VvarTable {
    if (data.len < 24) return error.UnexpectedEof;
    return .{
        .data = data,
        .item_variation_store_offset = try parser.readU32(data, 4),
        .advance_height_mapping_offset = try parser.readU32(data, 8),
        .tsb_mapping_offset = try parser.readU32(data, 12),
    };
}

test "parse VVAR from SourceSans3VF-Subset" {
    const font_data = @embedFile("../../fixture/SourceSans3VF-Subset.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const vvar_record = p.findTable(offset_table, "VVAR".*);
    if (vvar_record) |rec| {
        const vvar_data = try p.getTableData(font_data, rec);
        const vvar = try parse(vvar_data);

        const zero_coords = [_]f32{0.0};
        const delta = try vvar.getAdvanceHeightDelta(0, &zero_coords);
        try std.testing.expectEqual(@as(i32, 0), delta);
    }
}
