const std = @import("std");
const parser = @import("../parser.zig");

pub const HeadTable = struct {
    units_per_em: u16,
    index_to_loc_format: i16, // 0 = short, 1 = long
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

pub fn parse(data: []const u8) !HeadTable {
    if (data.len < 54) return error.UnexpectedEof;
    return .{
        .units_per_em = try parser.readU16(data, 18),
        .x_min = try parser.readI16(data, 36),
        .y_min = try parser.readI16(data, 38),
        .x_max = try parser.readI16(data, 40),
        .y_max = try parser.readI16(data, 42),
        .index_to_loc_format = try parser.readI16(data, 50),
    };
}

test "parse head table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const record = parser.findTable(offset_table, "head".*) orelse return error.TableNotFound;
    const table_data = try parser.getTableData(font_data, record);
    const head = try parse(table_data);

    try std.testing.expect(head.units_per_em == 2048);
    try std.testing.expect(head.index_to_loc_format == 1); // long format for DejaVu
}
