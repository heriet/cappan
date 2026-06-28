const std = @import("std");
const parser = @import("../parser.zig");

pub const Os2Table = struct {
    version: u16,
    us_weight_class: u16,
    s_typo_ascender: i16,
    s_typo_descender: i16,
    sx_height: i16,
    s_cap_height: i16,
};

pub fn parse(data: []const u8) !Os2Table {
    if (data.len < 78) return error.UnexpectedEof;
    const version = try parser.readU16(data, 0);
    return .{
        .version = version,
        .us_weight_class = try parser.readU16(data, 4),
        .s_typo_ascender = try parser.readI16(data, 68),
        .s_typo_descender = try parser.readI16(data, 70),
        .sx_height = if (version >= 2 and data.len >= 90) try parser.readI16(data, 86) else 0,
        .s_cap_height = if (version >= 2 and data.len >= 92) try parser.readI16(data, 88) else 0,
    };
}

test "parse OS/2 table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const record = parser.findTable(offset_table, "OS/2".*) orelse return error.TableNotFound;
    const table_data = try parser.getTableData(font_data, record);
    const os2 = try parse(table_data);

    // DejaVuSans is Book weight (400)
    try std.testing.expect(os2.us_weight_class > 0);
    // DejaVuSans has positive ascender
    try std.testing.expect(os2.s_typo_ascender > 0);
    // DejaVuSans fixture is OS/2 version 1
    try std.testing.expect(os2.version >= 1);
}
