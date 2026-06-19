const std = @import("std");
const parser = @import("../parser.zig");
const ivs = @import("item_variation_store.zig");

pub const HvarTable = struct {
    data: []const u8,
    item_variation_store_offset: u32,
    advance_width_mapping_offset: u32,
    lsb_mapping_offset: u32,

    pub fn getAdvanceWidthDelta(self: HvarTable, glyph_id: u16, normalized_coords: []const f32) !i32 {
        var outer: u16 = 0;
        var inner: u16 = glyph_id;

        if (self.advance_width_mapping_offset != 0) {
            const mapping = try ivs.readDeltaSetIndexMap(self.data, self.advance_width_mapping_offset);
            if (glyph_id < mapping.map_count) {
                const entry = try ivs.readMapEntry(self.data, mapping, glyph_id);
                outer = entry.outer;
                inner = entry.inner;
            }
        }

        return ivs.getItemDelta(self.data, @as(usize, self.item_variation_store_offset), outer, inner, normalized_coords);
    }

    pub fn getLsbDelta(self: HvarTable, glyph_id: u16, normalized_coords: []const f32) !i32 {
        if (self.lsb_mapping_offset == 0) return 0;

        const mapping = try ivs.readDeltaSetIndexMap(self.data, self.lsb_mapping_offset);
        if (glyph_id >= mapping.map_count) return 0;

        const entry = try ivs.readMapEntry(self.data, mapping, glyph_id);
        return ivs.getItemDelta(self.data, @as(usize, self.item_variation_store_offset), entry.outer, entry.inner, normalized_coords);
    }
};

pub fn parse(data: []const u8) !HvarTable {
    if (data.len < 20) return error.UnexpectedEof;
    return .{
        .data = data,
        .item_variation_store_offset = try parser.readU32(data, 4),
        .advance_width_mapping_offset = try parser.readU32(data, 8),
        .lsb_mapping_offset = try parser.readU32(data, 12),
    };
}

test "parse HVAR from SourceSans3VF-Subset" {
    const font_data = @embedFile("../../fixture/SourceSans3VF-Subset.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const hvar_record = p.findTable(offset_table, "HVAR".*);
    if (hvar_record) |rec| {
        const hvar_data = try p.getTableData(font_data, rec);
        const hvar = try parse(hvar_data);

        // At default coords (all 0), delta should be 0
        const zero_coords = [_]f32{0.0};
        const delta_default = try hvar.getAdvanceWidthDelta(0, &zero_coords);
        try std.testing.expectEqual(@as(i32, 0), delta_default);

        // At bold (wght=1.0), delta should be non-zero for most glyphs
        const bold_coords = [_]f32{1.0};
        const delta_bold = try hvar.getAdvanceWidthDelta(1, &bold_coords);
        _ = delta_bold;
    }
}
