const std = @import("std");
const parser = @import("../parser.zig");

pub const MaxpTable = struct {
    num_glyphs: u16,
};

pub fn parse(data: []const u8) !MaxpTable {
    if (data.len < 6) return error.UnexpectedEof;
    return .{
        .num_glyphs = try parser.readU16(data, 4),
    };
}

test "parse maxp table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const record = parser.findTable(offset_table, "maxp".*) orelse return error.TableNotFound;
    const table_data = try parser.getTableData(font_data, record);
    const maxp = try parse(table_data);

    try std.testing.expect(maxp.num_glyphs > 0);
}
