const std = @import("std");
const parser = @import("../parser.zig");

pub const VMetrics = struct {
    advance_height: u16,
    tsb: i16,
};

pub const VmtxTable = struct {
    data: []const u8,
    number_of_v_metrics: u16,

    pub fn getMetrics(self: VmtxTable, glyph_id: u16) !VMetrics {
        if (glyph_id < self.number_of_v_metrics) {
            const offset = @as(usize, glyph_id) * 4;
            return .{
                .advance_height = try parser.readU16(self.data, offset),
                .tsb = try parser.readI16(self.data, offset + 2),
            };
        } else {
            // Use last advance height, read tsb from extended array
            const last_ah_offset = (@as(usize, self.number_of_v_metrics) - 1) * 4;
            const advance_height = try parser.readU16(self.data, last_ah_offset);
            const tsb_offset = @as(usize, self.number_of_v_metrics) * 4 + (@as(usize, glyph_id) - @as(usize, self.number_of_v_metrics)) * 2;
            const tsb = try parser.readI16(self.data, tsb_offset);
            return .{
                .advance_height = advance_height,
                .tsb = tsb,
            };
        }
    }
};

pub fn parse(data: []const u8, number_of_v_metrics: u16) VmtxTable {
    return .{
        .data = data,
        .number_of_v_metrics = number_of_v_metrics,
    };
}

test "parse vmtx table with synthetic data" {
    // Build vmtx data with 2 vMetric records + 1 extended tsb entry
    // vMetric[0]: advance_height=1000, tsb=100
    // vMetric[1]: advance_height=900, tsb=80
    // extended tsb[0]: tsb=50
    var data: [12]u8 = undefined;
    // vMetric[0]
    data[0] = 0x03;
    data[1] = 0xE8; // 1000
    data[2] = 0x00;
    data[3] = 0x64; // 100
    // vMetric[1]
    data[4] = 0x03;
    data[5] = 0x84; // 900
    data[6] = 0x00;
    data[7] = 0x50; // 80
    // extended tsb for glyph 2
    data[8] = 0x00;
    data[9] = 0x32; // 50
    // padding
    data[10] = 0x00;
    data[11] = 0x00;

    const vmtx = parse(&data, 2);

    const m0 = try vmtx.getMetrics(0);
    try std.testing.expectEqual(@as(u16, 1000), m0.advance_height);
    try std.testing.expectEqual(@as(i16, 100), m0.tsb);

    const m1 = try vmtx.getMetrics(1);
    try std.testing.expectEqual(@as(u16, 900), m1.advance_height);
    try std.testing.expectEqual(@as(i16, 80), m1.tsb);

    // Glyph 2 uses last advance_height (900) and extended tsb (50)
    const m2 = try vmtx.getMetrics(2);
    try std.testing.expectEqual(@as(u16, 900), m2.advance_height);
    try std.testing.expectEqual(@as(i16, 50), m2.tsb);
}
