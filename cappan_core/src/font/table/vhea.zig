const std = @import("std");
const parser = @import("../parser.zig");

pub const VheaTable = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    number_of_v_metrics: u16,
};

pub fn parse(data: []const u8) !VheaTable {
    if (data.len < 36) return error.UnexpectedEof;
    return .{
        .ascender = try parser.readI16(data, 4),
        .descender = try parser.readI16(data, 6),
        .line_gap = try parser.readI16(data, 8),
        .number_of_v_metrics = try parser.readU16(data, 34),
    };
}

test "parse vhea table with synthetic data" {
    // Build a minimal 36-byte vhea table
    var data: [36]u8 = .{0} ** 36;
    // version 1.0 at offset 0..3 (not validated by parse, but set for completeness)
    data[0] = 0x00;
    data[1] = 0x01;
    data[2] = 0x00;
    data[3] = 0x00;
    // ascender at offset 4..5: 800 = 0x0320
    data[4] = 0x03;
    data[5] = 0x20;
    // descender at offset 6..7: -200 = 0xFF38
    data[6] = 0xFF;
    data[7] = 0x38;
    // line_gap at offset 8..9: 0
    data[8] = 0x00;
    data[9] = 0x00;
    // number_of_v_metrics at offset 34..35: 10
    data[34] = 0x00;
    data[35] = 0x0A;

    const vhea = try parse(&data);
    try std.testing.expectEqual(@as(i16, 800), vhea.ascender);
    try std.testing.expectEqual(@as(i16, -200), vhea.descender);
    try std.testing.expectEqual(@as(i16, 0), vhea.line_gap);
    try std.testing.expectEqual(@as(u16, 10), vhea.number_of_v_metrics);
}
