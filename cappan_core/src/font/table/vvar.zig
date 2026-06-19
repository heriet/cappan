const std = @import("std");
const parser = @import("../parser.zig");

pub const VvarTable = struct {
    data: []const u8,
    item_variation_store_offset: u32,
    advance_height_mapping_offset: u32,
    tsb_mapping_offset: u32,

    pub fn getAdvanceHeightDelta(self: VvarTable, glyph_id: u16, normalized_coords: []const f32) !i32 {
        var outer: u16 = 0;
        var inner: u16 = glyph_id;

        if (self.advance_height_mapping_offset != 0) {
            const mapping = try self.readDeltaSetIndexMap(self.advance_height_mapping_offset);
            if (glyph_id < mapping.map_count) {
                const entry = try self.readMapEntry(mapping, glyph_id);
                outer = entry.outer;
                inner = entry.inner;
            }
        }

        return self.getItemDelta(outer, inner, normalized_coords);
    }

    pub fn getTsbDelta(self: VvarTable, glyph_id: u16, normalized_coords: []const f32) !i32 {
        if (self.tsb_mapping_offset == 0) return 0;

        const mapping = try self.readDeltaSetIndexMap(self.tsb_mapping_offset);
        if (glyph_id >= mapping.map_count) return 0;

        const entry = try self.readMapEntry(mapping, glyph_id);
        return self.getItemDelta(entry.outer, entry.inner, normalized_coords);
    }

    const DeltaSetIndexMap = struct {
        offset: usize,
        format: u8,
        entry_format: u8,
        map_count: u32,
        data_offset: usize,
    };

    const MapEntry = struct {
        outer: u16,
        inner: u16,
    };

    fn readDeltaSetIndexMap(self: VvarTable, map_offset: u32) !DeltaSetIndexMap {
        const off = @as(usize, map_offset);
        const format = try parser.readU8(self.data, off);
        const entry_format = try parser.readU8(self.data, off + 1);
        var map_count: u32 = undefined;
        var data_offset: usize = undefined;
        if (format == 0) {
            map_count = @as(u32, try parser.readU16(self.data, off + 2));
            data_offset = off + 4;
        } else {
            map_count = try parser.readU32(self.data, off + 2);
            data_offset = off + 6;
        }
        return .{
            .offset = off,
            .format = format,
            .entry_format = entry_format,
            .map_count = map_count,
            .data_offset = data_offset,
        };
    }

    fn readMapEntry(self: VvarTable, mapping: DeltaSetIndexMap, index: u16) !MapEntry {
        const entry_size: usize = @as(usize, (mapping.entry_format >> 4) & 3) + 1;
        const inner_bit_count: u5 = @intCast((mapping.entry_format & 0x0F) + 1);
        const pos = mapping.data_offset + @as(usize, index) * entry_size;

        var entry_value: u32 = 0;
        for (0..entry_size) |i| {
            entry_value = (entry_value << 8) | @as(u32, try parser.readU8(self.data, pos + i));
        }

        const inner_mask: u32 = (@as(u32, 1) << inner_bit_count) - 1;
        return .{
            .outer = @intCast(entry_value >> inner_bit_count),
            .inner = @intCast(entry_value & inner_mask),
        };
    }

    fn getItemDelta(self: VvarTable, outer_index: u16, inner_index: u16, normalized_coords: []const f32) !i32 {
        const store_offset = @as(usize, self.item_variation_store_offset);
        // ItemVariationStore header
        // format: u16 at store_offset
        const region_list_offset_raw = try parser.readU32(self.data, store_offset + 2);
        const region_list_offset = store_offset + @as(usize, region_list_offset_raw);
        const item_data_count = try parser.readU16(self.data, store_offset + 6);

        if (outer_index >= item_data_count) return 0;

        // Get ItemVariationData offset
        const item_data_offset_raw = try parser.readU32(self.data, store_offset + 8 + @as(usize, outer_index) * 4);
        const item_data_offset = store_offset + @as(usize, item_data_offset_raw);

        // Parse ItemVariationData
        const item_count = try parser.readU16(self.data, item_data_offset);
        if (inner_index >= item_count) return 0;

        const word_delta_count_raw = try parser.readU16(self.data, item_data_offset + 2);
        const long_words = (word_delta_count_raw & 0x8000) != 0;
        const word_delta_count: u16 = word_delta_count_raw & 0x7FFF;
        const region_index_count = try parser.readU16(self.data, item_data_offset + 4);

        // Read region indices
        const region_indices_offset = item_data_offset + 6;

        // Calculate delta row offset
        const long_size: usize = if (long_words) 4 else 2;
        const short_size: usize = if (long_words) 2 else 1;
        const row_size = @as(usize, word_delta_count) * long_size + @as(usize, region_index_count -| word_delta_count) * short_size;
        const delta_sets_offset = region_indices_offset + @as(usize, region_index_count) * 2;
        const row_offset = delta_sets_offset + @as(usize, inner_index) * row_size;

        // Read VariationRegionList
        const axis_count = try parser.readU16(self.data, region_list_offset);

        // Compute delta
        var delta: f32 = 0.0;
        var col_offset = row_offset;
        for (0..region_index_count) |col| {
            // Read delta value
            var delta_value: i32 = undefined;
            if (col < word_delta_count) {
                if (long_words) {
                    delta_value = try parser.readI32(self.data, col_offset);
                    col_offset += 4;
                } else {
                    delta_value = @as(i32, try parser.readI16(self.data, col_offset));
                    col_offset += 2;
                }
            } else {
                if (long_words) {
                    delta_value = @as(i32, try parser.readI16(self.data, col_offset));
                    col_offset += 2;
                } else {
                    delta_value = @as(i32, try parser.readI8(self.data, col_offset));
                    col_offset += 1;
                }
            }

            if (delta_value == 0) continue;

            // Get region index
            const region_idx = try parser.readU16(self.data, region_indices_offset + col * 2);

            // Compute region scalar
            var scalar: f32 = 1.0;
            const region_offset = region_list_offset + 4 + @as(usize, region_idx) * @as(usize, axis_count) * 6;
            for (0..@as(usize, axis_count)) |axis| {
                const axis_offset = region_offset + axis * 6;
                const start = try parser.readF2Dot14(self.data, axis_offset);
                const peak = try parser.readF2Dot14(self.data, axis_offset + 2);
                const end_val = try parser.readF2Dot14(self.data, axis_offset + 4);

                if (peak == 0.0) continue;

                const coord = if (axis < normalized_coords.len) normalized_coords[axis] else 0.0;

                if (coord == peak) continue;

                if (coord <= start or coord >= end_val) {
                    scalar = 0.0;
                    break;
                }

                if (coord < peak) {
                    if (peak == start) {
                        scalar = 0.0;
                        break;
                    }
                    scalar *= (coord - start) / (peak - start);
                } else {
                    if (peak == end_val) {
                        scalar = 0.0;
                        break;
                    }
                    scalar *= (end_val - coord) / (end_val - peak);
                }
            }

            delta += @as(f32, @floatFromInt(delta_value)) * scalar;
        }

        return @as(i32, @intFromFloat(@round(delta)));
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
