const std = @import("std");
const parser = @import("../parser.zig");

pub const DeltaSetIndexMap = struct {
    offset: usize,
    format: u8,
    entry_format: u8,
    map_count: u32,
    data_offset: usize,
};

pub const MapEntry = struct {
    outer: u16,
    inner: u16,
};

pub fn readDeltaSetIndexMap(data: []const u8, map_offset: u32) !DeltaSetIndexMap {
    const off = @as(usize, map_offset);
    const format = try parser.readU8(data, off);
    const entry_format = try parser.readU8(data, off + 1);
    var map_count: u32 = undefined;
    var data_offset: usize = undefined;
    if (format == 0) {
        map_count = @as(u32, try parser.readU16(data, off + 2));
        data_offset = off + 4;
    } else {
        map_count = try parser.readU32(data, off + 2);
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

pub fn readMapEntry(data: []const u8, mapping: DeltaSetIndexMap, index: u16) !MapEntry {
    const entry_size: usize = @as(usize, (mapping.entry_format >> 4) & 3) + 1;
    const inner_bit_count: u5 = @intCast((mapping.entry_format & 0x0F) + 1);
    const pos = mapping.data_offset + @as(usize, index) * entry_size;
    if (pos + entry_size > data.len) return error.UnexpectedEof;

    var entry_value: u32 = 0;
    for (0..entry_size) |i| {
        entry_value = (entry_value << 8) | @as(u32, try parser.readU8(data, pos + i));
    }

    const inner_mask: u32 = (@as(u32, 1) << inner_bit_count) - 1;
    return .{
        .outer = @intCast(entry_value >> inner_bit_count),
        .inner = @intCast(entry_value & inner_mask),
    };
}

pub fn getItemDelta(data: []const u8, store_offset: usize, outer_index: u16, inner_index: u16, normalized_coords: []const f32) !i32 {
    if (store_offset + 8 > data.len) return error.UnexpectedEof;
    const region_list_offset_raw = try parser.readU32(data, store_offset + 2);
    if (@as(usize, region_list_offset_raw) > data.len -| store_offset) return error.UnexpectedEof;
    const region_list_offset = store_offset + @as(usize, region_list_offset_raw);
    const item_data_count = try parser.readU16(data, store_offset + 6);

    if (outer_index >= item_data_count) return 0;

    const ivd_offset_pos = store_offset + 8 + @as(usize, outer_index) * 4;
    if (ivd_offset_pos + 4 > data.len) return error.UnexpectedEof;
    const item_data_offset_raw = try parser.readU32(data, ivd_offset_pos);
    if (@as(usize, item_data_offset_raw) > data.len -| store_offset) return error.UnexpectedEof;
    const item_data_offset = store_offset + @as(usize, item_data_offset_raw);

    // Parse ItemVariationData
    const item_count = try parser.readU16(data, item_data_offset);
    if (inner_index >= item_count) return 0;

    const word_delta_count_raw = try parser.readU16(data, item_data_offset + 2);
    const long_words = (word_delta_count_raw & 0x8000) != 0;
    const word_delta_count: u16 = word_delta_count_raw & 0x7FFF;
    const region_index_count = try parser.readU16(data, item_data_offset + 4);

    // Read region indices
    const region_indices_offset = item_data_offset + 6;

    const long_size: usize = if (long_words) 4 else 2;
    const short_size: usize = if (long_words) 2 else 1;
    const word_part = @as(usize, word_delta_count) * long_size;
    const short_part = @as(usize, region_index_count -| word_delta_count) * short_size;
    const row_size = word_part + short_part;
    const delta_sets_offset = region_indices_offset + @as(usize, region_index_count) * 2;
    const row_offset = delta_sets_offset + @as(usize, inner_index) * row_size;
    if (row_offset + row_size > data.len) return error.UnexpectedEof;

    if (region_list_offset + 4 > data.len) return error.UnexpectedEof;
    const axis_count = try parser.readU16(data, region_list_offset);

    // Compute delta
    var delta: f32 = 0.0;
    var col_offset = row_offset;
    for (0..region_index_count) |col| {
        // Read delta value
        var delta_value: i32 = undefined;
        if (col < word_delta_count) {
            if (long_words) {
                delta_value = try parser.readI32(data, col_offset);
                col_offset += 4;
            } else {
                delta_value = @as(i32, try parser.readI16(data, col_offset));
                col_offset += 2;
            }
        } else {
            if (long_words) {
                delta_value = @as(i32, try parser.readI16(data, col_offset));
                col_offset += 2;
            } else {
                delta_value = @as(i32, try parser.readI8(data, col_offset));
                col_offset += 1;
            }
        }

        if (delta_value == 0) continue;

        // Get region index
        const region_idx = try parser.readU16(data, region_indices_offset + col * 2);

        // Compute region scalar
        var scalar: f32 = 1.0;
        const region_offset = region_list_offset + 4 + @as(usize, region_idx) * @as(usize, axis_count) * 6;
        if (region_offset + @as(usize, axis_count) * 6 > data.len) return error.UnexpectedEof;
        for (0..@as(usize, axis_count)) |axis| {
            const axis_offset = region_offset + axis * 6;
            const start = try parser.readF2Dot14(data, axis_offset);
            const peak = try parser.readF2Dot14(data, axis_offset + 2);
            const end_val = try parser.readF2Dot14(data, axis_offset + 4);

            if (peak == 0.0) continue;

            const coord = if (axis < normalized_coords.len) normalized_coords[axis] else 0.0;

            if (coord == peak) continue;

            if (coord <= start or coord >= end_val) {
                scalar = 0.0;
                break;
            }

            if (coord < peak) {
                if (@abs(peak - start) < 1e-10) {
                    scalar = 0.0;
                    break;
                }
                scalar *= (coord - start) / (peak - start);
            } else {
                if (@abs(end_val - peak) < 1e-10) {
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
