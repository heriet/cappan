const std = @import("std");
const cappan_core = @import("cappan_core");
const parser = cappan_core.font.parser;

pub const Os2Table = struct {
    version: u16,
    avg_char_width: i16,
    weight_class: u16,
    width_class: u16,
    fs_type: u16,
    s_typo_ascender: i16,
    s_typo_descender: i16,
    s_typo_line_gap: i16,
    us_win_ascent: u16,
    us_win_descent: u16,
    s_x_height: i16,
    s_cap_height: i16,
    fs_selection: u16,

    pub fn isItalic(self: Os2Table) bool {
        return self.fs_selection & 1 != 0;
    }

    pub fn isBold(self: Os2Table) bool {
        return self.fs_selection & (1 << 5) != 0;
    }
};

pub fn parse(data: []const u8) !Os2Table {
    if (data.len < 78) return error.UnexpectedEof;
    const version = try parser.readU16(data, 0);
    return .{
        .version = version,
        .avg_char_width = try parser.readI16(data, 2),
        .weight_class = try parser.readU16(data, 4),
        .width_class = try parser.readU16(data, 6),
        .fs_type = try parser.readU16(data, 8),
        .s_typo_ascender = try parser.readI16(data, 68),
        .s_typo_descender = try parser.readI16(data, 70),
        .s_typo_line_gap = try parser.readI16(data, 72),
        .us_win_ascent = try parser.readU16(data, 74),
        .us_win_descent = try parser.readU16(data, 76),
        .s_x_height = if (version >= 2 and data.len >= 90) parser.readI16(data, 86) catch 0 else 0,
        .s_cap_height = if (version >= 2 and data.len >= 90) parser.readI16(data, 88) catch 0 else 0,
        .fs_selection = try parser.readU16(data, 62),
    };
}

test "parse OS/2 table from DejaVuSans" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    const p = cappan_core.font.parser;
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const record = p.findTable(offset_table, "OS/2".*) orelse return error.TableNotFound;
    const table_data = try p.getTableData(font_data, record);
    const os2 = try parse(table_data);

    try std.testing.expectEqual(@as(u16, 400), os2.weight_class);
    try std.testing.expect(os2.version >= 1);
    if (os2.version >= 2) {
        try std.testing.expect(os2.s_cap_height > 0);
    } else {
        try std.testing.expectEqual(@as(i16, 0), os2.s_cap_height);
    }
    try std.testing.expect(!os2.isItalic());
    try std.testing.expect(!os2.isBold());
}
