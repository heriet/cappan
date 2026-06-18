const std = @import("std");
const parser = @import("../parser.zig");

pub const HheaTable = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    number_of_h_metrics: u16,
};

pub fn parse(data: []const u8) !HheaTable {
    if (data.len < 36) return error.UnexpectedEof;
    return .{
        .ascender = try parser.readI16(data, 4),
        .descender = try parser.readI16(data, 6),
        .line_gap = try parser.readI16(data, 8),
        .number_of_h_metrics = try parser.readU16(data, 34),
    };
}

test "parse hhea table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const record = parser.findTable(offset_table, "hhea".*) orelse return error.TableNotFound;
    const table_data = try parser.getTableData(font_data, record);
    const hhea = try parse(table_data);

    try std.testing.expect(hhea.ascender > 0);
    try std.testing.expect(hhea.descender < 0);
    try std.testing.expect(hhea.number_of_h_metrics > 0);
}
