const std = @import("std");
const parser = @import("../parser.zig");
const ivs = @import("item_variation_store.zig");

pub const MvarTable = struct {
    data: []const u8,
    item_variation_store_offset: u16,
    value_record_count: u16,
    value_records_offset: usize,

    pub fn getMetricDelta(self: MvarTable, tag: [4]u8, normalized_coords: []const f32) !i32 {
        // Binary search through sorted value records for the tag
        var low: u16 = 0;
        var high: u16 = self.value_record_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const rec_offset = self.value_records_offset + @as(usize, mid) * 8;
            if (rec_offset + 8 > self.data.len) return error.UnexpectedEof;
            const rec_tag = [4]u8{
                try parser.readU8(self.data, rec_offset),
                try parser.readU8(self.data, rec_offset + 1),
                try parser.readU8(self.data, rec_offset + 2),
                try parser.readU8(self.data, rec_offset + 3),
            };
            const order = std.mem.order(u8, &rec_tag, &tag);
            if (order == .eq) {
                const outer = try parser.readU16(self.data, rec_offset + 4);
                const inner = try parser.readU16(self.data, rec_offset + 6);
                return ivs.getItemDelta(self.data, @as(usize, self.item_variation_store_offset), outer, inner, normalized_coords);
            } else if (order == .lt) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return 0; // Tag not found -- no variation for this metric
    }
};

pub fn parse(data: []const u8) !MvarTable {
    if (data.len < 12) return error.UnexpectedEof;
    return .{
        .data = data,
        .item_variation_store_offset = try parser.readU16(data, 10),
        .value_record_count = try parser.readU16(data, 8),
        .value_records_offset = 12,
    };
}

test "parse MVAR from SourceSans3VF-Subset" {
    const font_data = @embedFile("../../fixture/SourceSans3VF-Subset.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const mvar_record = p.findTable(offset_table, "MVAR".*);
    if (mvar_record) |rec| {
        const mvar_data = try p.getTableData(font_data, rec);
        const mvar = try parse(mvar_data);

        // At zero coords, all deltas should be 0
        const zero_coords = [_]f32{0.0};
        const hasc_delta = try mvar.getMetricDelta("hasc".*, &zero_coords);
        try std.testing.expectEqual(@as(i32, 0), hasc_delta);
    }
}

test "MVAR binary search with synthetic data" {
    // Build a minimal MVAR table with 2 value records and a trivial ItemVariationStore
    // Header: 12 bytes
    // ValueRecords: 2 * 8 = 16 bytes  (at offset 12)
    // ItemVariationStore starts at offset 28
    //
    // Layout:
    //   IVS at 28, header 8 bytes (format + regionListOffset + itemDataCount) = 28..35
    //   IVD offsets: 1 * 4 bytes = 36..39
    //   VariationRegionList at offset 40 (relative 12 from IVS start)
    //     axisCount=1, regionCount=1, region(6 bytes) = 10 bytes total -> 40..49
    //   ItemVariationData[0] at offset 50 (relative 22 from IVS start)
    //     itemCount=1, wordDeltaCount=1, regionIndexCount=1, regionIndex=0, delta=42

    var data: [100]u8 = .{0} ** 100;
    // majorVersion = 1
    data[0] = 0x00;
    data[1] = 0x01;
    // minorVersion = 0
    data[2] = 0x00;
    data[3] = 0x00;
    // reserved = 0
    data[4] = 0x00;
    data[5] = 0x00;
    // valueRecordSize = 8
    data[6] = 0x00;
    data[7] = 0x08;
    // valueRecordCount = 2
    data[8] = 0x00;
    data[9] = 0x02;
    // itemVariationStoreOffset = 28
    data[10] = 0x00;
    data[11] = 0x1C;

    // ValueRecord[0]: tag "hasc", outer=0, inner=0
    data[12] = 'h';
    data[13] = 'a';
    data[14] = 's';
    data[15] = 'c';
    data[16] = 0x00;
    data[17] = 0x00; // outer
    data[18] = 0x00;
    data[19] = 0x00; // inner

    // ValueRecord[1]: tag "hdsc", outer=0, inner=0
    data[20] = 'h';
    data[21] = 'd';
    data[22] = 's';
    data[23] = 'c';
    data[24] = 0x00;
    data[25] = 0x00; // outer
    data[26] = 0x00;
    data[27] = 0x00; // inner

    // ItemVariationStore at offset 28:
    // format = 1
    data[28] = 0x00;
    data[29] = 0x01;
    // variationRegionListOffset = 12 (relative to IVS start=28, so absolute=40)
    data[30] = 0x00;
    data[31] = 0x00;
    data[32] = 0x00;
    data[33] = 0x0C;
    // itemVariationDataCount = 1
    data[34] = 0x00;
    data[35] = 0x01;
    // IVD offset[0] = 22 (relative to IVS start=28, so absolute=50)
    data[36] = 0x00;
    data[37] = 0x00;
    data[38] = 0x00;
    data[39] = 0x16;

    // VariationRegionList at absolute 40:
    data[40] = 0x00;
    data[41] = 0x01; // axisCount = 1
    data[42] = 0x00;
    data[43] = 0x01; // regionCount = 1
    data[44] = 0x00;
    data[45] = 0x00; // start = 0.0
    data[46] = 0x40;
    data[47] = 0x00; // peak = 1.0
    data[48] = 0x40;
    data[49] = 0x00; // end = 1.0

    // ItemVariationData[0] at absolute 50:
    data[50] = 0x00;
    data[51] = 0x01; // itemCount = 1
    data[52] = 0x00;
    data[53] = 0x01; // wordDeltaCount = 1 (short words, not long)
    data[54] = 0x00;
    data[55] = 0x01; // regionIndexCount = 1
    data[56] = 0x00;
    data[57] = 0x00; // regionIndex[0] = 0
    // delta for item 0: i16 = 42
    data[58] = 0x00;
    data[59] = 0x2A; // 42

    const mvar = try parse(&data);
    try std.testing.expectEqual(@as(u16, 2), mvar.value_record_count);

    // Test binary search: "hasc" should be found, delta=42 at coords=[1.0]
    const bold_coords = [_]f32{1.0};
    const hasc_delta = try mvar.getMetricDelta("hasc".*, &bold_coords);
    try std.testing.expectEqual(@as(i32, 42), hasc_delta);

    // "hdsc" also outer=0, inner=0, so same delta
    const hdsc_delta = try mvar.getMetricDelta("hdsc".*, &bold_coords);
    try std.testing.expectEqual(@as(i32, 42), hdsc_delta);

    // Missing tag should return 0
    const missing_delta = try mvar.getMetricDelta("zzzz".*, &bold_coords);
    try std.testing.expectEqual(@as(i32, 0), missing_delta);

    // At zero coords, delta should be 0 (scalar=0 because coord=0 != peak=1.0, and coord <= start)
    const zero_coords = [_]f32{0.0};
    const hasc_zero = try mvar.getMetricDelta("hasc".*, &zero_coords);
    try std.testing.expectEqual(@as(i32, 0), hasc_zero);
}
