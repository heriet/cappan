const std = @import("std");
const parser = @import("../parser.zig");

pub const AvarTable = struct {
    data: []const u8,
    axis_count: u16,

    pub fn mapNormalizedCoord(self: AvarTable, axis_index: u16, value: f32) !f32 {
        // Header is 8 bytes: majorVersion(2) + minorVersion(2) + reserved(2) + axisCount(2)
        var offset: usize = 8;

        // Walk through axes 0..axis_index-1 to skip their segment maps
        for (0..axis_index) |_| {
            if (offset + 2 > self.data.len) return error.UnexpectedEof;
            const position_map_count = try parser.readU16(self.data, offset);
            const segment_size = @as(usize, position_map_count) * 4;
            if (segment_size > self.data.len -| (offset + 2)) return error.UnexpectedEof;
            offset += 2 + segment_size;
        }

        // Now read this axis's segment map
        if (offset + 2 > self.data.len) return error.UnexpectedEof;
        const position_map_count = try parser.readU16(self.data, offset);
        offset += 2;

        if (position_map_count < 2) {
            // Not enough entries to interpolate; return value as-is
            return value;
        }

        // Read first entry
        var from1 = try parser.readF2Dot14(self.data, offset);
        var to1 = try parser.readF2Dot14(self.data, offset + 2);

        // If value is at or below the first entry, clamp
        if (value <= from1) return to1;

        for (1..position_map_count) |i| {
            const entry_offset = offset + i * 4;
            const from2 = try parser.readF2Dot14(self.data, entry_offset);
            const to2 = try parser.readF2Dot14(self.data, entry_offset + 2);

            if (value == from2) return to2;

            if (value < from2) {
                // Linearly interpolate between (from1, to1) and (from2, to2)
                if (from2 == from1) return to1;
                return to1 + (value - from1) * (to2 - to1) / (from2 - from1);
            }

            from1 = from2;
            to1 = to2;
        }

        // Value is at or beyond the last entry
        return to1;
    }

    pub fn mapNormalizedCoords(self: AvarTable, coords: []f32) !void {
        const count = @min(coords.len, self.axis_count);
        for (0..count) |i| {
            coords[i] = try self.mapNormalizedCoord(@intCast(i), coords[i]);
        }
    }
};

pub fn parse(data: []const u8) !AvarTable {
    if (data.len < 8) return error.UnexpectedEof;
    return .{
        .data = data,
        .axis_count = try parser.readU16(data, 6),
    };
}

test "parse avar from SourceSans3VF-Subset" {
    const font_data = @embedFile("../../fixture/SourceSans3VF-Subset.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const avar_record = parser.findTable(offset_table, "avar".*);
    // avar may or may not exist in the subset; if it does, verify basic parsing
    if (avar_record) |rec| {
        const avar_data = try parser.getTableData(font_data, rec);
        const avar = try parse(avar_data);
        try std.testing.expect(avar.axis_count > 0);

        // Identity mapping: 0.0 should map to 0.0
        const mapped = try avar.mapNormalizedCoord(0, 0.0);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), mapped, 0.001);
    }
}

test "avar identity mapping" {
    // Construct a minimal avar table with 1 axis and identity mapping: -1->-1, 0->0, 1->1
    // Header: majorVersion=1, minorVersion=0, reserved=0, axisCount=1
    // Segment map: positionMapCount=3, then 3 entries
    var data: [8 + 2 + 3 * 4]u8 = undefined;
    // majorVersion = 1
    data[0] = 0;
    data[1] = 1;
    // minorVersion = 0
    data[2] = 0;
    data[3] = 0;
    // reserved = 0
    data[4] = 0;
    data[5] = 0;
    // axisCount = 1
    data[6] = 0;
    data[7] = 1;
    // positionMapCount = 3
    data[8] = 0;
    data[9] = 3;
    // Entry 0: from=-1.0 (F2Dot14 = 0xC000), to=-1.0
    data[10] = 0xC0;
    data[11] = 0x00;
    data[12] = 0xC0;
    data[13] = 0x00;
    // Entry 1: from=0.0 (F2Dot14 = 0x0000), to=0.0
    data[14] = 0x00;
    data[15] = 0x00;
    data[16] = 0x00;
    data[17] = 0x00;
    // Entry 2: from=1.0 (F2Dot14 = 0x4000), to=1.0
    data[18] = 0x40;
    data[19] = 0x00;
    data[20] = 0x40;
    data[21] = 0x00;

    const avar = try parse(&data);
    try std.testing.expectEqual(@as(u16, 1), avar.axis_count);

    // Test exact matches
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), try avar.mapNormalizedCoord(0, -1.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), try avar.mapNormalizedCoord(0, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), try avar.mapNormalizedCoord(0, 1.0), 0.001);

    // Test interpolation: 0.5 should map to 0.5 for identity
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), try avar.mapNormalizedCoord(0, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), try avar.mapNormalizedCoord(0, -0.5), 0.001);
}

test "avar non-linear mapping" {
    // 1 axis with non-linear mapping: -1->-1, 0->0, 0.5->0.75, 1->1
    var data: [8 + 2 + 4 * 4]u8 = undefined;
    // Header
    data[0] = 0;
    data[1] = 1;
    data[2] = 0;
    data[3] = 0;
    data[4] = 0;
    data[5] = 0;
    data[6] = 0;
    data[7] = 1;
    // positionMapCount = 4
    data[8] = 0;
    data[9] = 4;
    // Entry 0: -1.0 -> -1.0 (0xC000)
    data[10] = 0xC0;
    data[11] = 0x00;
    data[12] = 0xC0;
    data[13] = 0x00;
    // Entry 1: 0.0 -> 0.0 (0x0000)
    data[14] = 0x00;
    data[15] = 0x00;
    data[16] = 0x00;
    data[17] = 0x00;
    // Entry 2: 0.5 -> 0.75 (from=0x2000, to=0x3000)
    data[18] = 0x20;
    data[19] = 0x00;
    data[20] = 0x30;
    data[21] = 0x00;
    // Entry 3: 1.0 -> 1.0 (0x4000)
    data[22] = 0x40;
    data[23] = 0x00;
    data[24] = 0x40;
    data[25] = 0x00;

    const avar = try parse(&data);

    // 0.5 should map to 0.75
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), try avar.mapNormalizedCoord(0, 0.5), 0.001);

    // 0.25 should interpolate between (0.0, 0.0) and (0.5, 0.75) => 0.375
    try std.testing.expectApproxEqAbs(@as(f32, 0.375), try avar.mapNormalizedCoord(0, 0.25), 0.001);

    // 0.75 should interpolate between (0.5, 0.75) and (1.0, 1.0) => 0.875
    try std.testing.expectApproxEqAbs(@as(f32, 0.875), try avar.mapNormalizedCoord(0, 0.75), 0.001);
}

test "avar mapNormalizedCoords in-place" {
    // 1 axis with identity mapping
    var data: [8 + 2 + 3 * 4]u8 = undefined;
    data[0] = 0;
    data[1] = 1;
    data[2] = 0;
    data[3] = 0;
    data[4] = 0;
    data[5] = 0;
    data[6] = 0;
    data[7] = 1;
    data[8] = 0;
    data[9] = 3;
    data[10] = 0xC0;
    data[11] = 0x00;
    data[12] = 0xC0;
    data[13] = 0x00;
    data[14] = 0x00;
    data[15] = 0x00;
    data[16] = 0x00;
    data[17] = 0x00;
    data[18] = 0x40;
    data[19] = 0x00;
    data[20] = 0x40;
    data[21] = 0x00;

    const avar = try parse(&data);
    var coords = [_]f32{0.5};
    try avar.mapNormalizedCoords(&coords);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), coords[0], 0.001);
}
