const std = @import("std");
const parser = @import("../parser.zig");

/// OS/2 table fields. `version`/`us_weight_class`/`s_typo_ascender`/
/// `s_typo_descender`/`sx_height`/`s_cap_height` are the original core subset
/// (used internally for auto-hinting blue-zone inference); the remaining
/// fields were added to unify this with what used to be a second, separate
/// `Os2Table` implementation in cappan_embed (for PDF metadata) and raw
/// per-field byte-offset reads duplicated in cappan_metrics -- both now use
/// this same type instead. The added fields default to 0 so existing code
/// that builds a partial `Os2Table{...}` literal (e.g. in tests) keeps
/// compiling unchanged.
pub const Os2Table = struct {
    version: u16,
    us_weight_class: u16,
    s_typo_ascender: i16,
    s_typo_descender: i16,
    sx_height: i16,
    s_cap_height: i16,
    avg_char_width: i16 = 0,
    width_class: u16 = 0,
    fs_type: u16 = 0,
    s_typo_line_gap: i16 = 0,
    us_win_ascent: u16 = 0,
    us_win_descent: u16 = 0,
    fs_selection: u16 = 0,

    pub fn isItalic(self: Os2Table) bool {
        return self.fs_selection & 1 != 0;
    }

    pub fn isBold(self: Os2Table) bool {
        return self.fs_selection & (1 << 5) != 0;
    }
};

/// Reads just `xAvgCharWidth` (offset 2, 2 bytes) without requiring the rest
/// of a full OS/2 table (`parse`'s `len >= 78` guard). xAvgCharWidth has been
/// present at this fixed offset since the very first OS/2 version (v0), whose
/// minimum legal size is only 68 bytes (some older/Apple-oriented fonts still
/// ship exactly that) -- routing a "just need the average width" caller
/// through `parse` would reject those perfectly valid, if minimal, tables
/// outright. Returns null if `data` is too short even for this one field.
pub fn readAvgCharWidth(data: []const u8) ?i16 {
    return parser.readI16(data, 2) catch null;
}

pub fn parse(data: []const u8) !Os2Table {
    if (data.len < 78) return error.UnexpectedEof;
    const version = try parser.readU16(data, 0);
    return .{
        .version = version,
        .avg_char_width = try parser.readI16(data, 2),
        .us_weight_class = try parser.readU16(data, 4),
        .width_class = try parser.readU16(data, 6),
        .fs_type = try parser.readU16(data, 8),
        .fs_selection = try parser.readU16(data, 62),
        .s_typo_ascender = try parser.readI16(data, 68),
        .s_typo_descender = try parser.readI16(data, 70),
        .s_typo_line_gap = try parser.readI16(data, 72),
        .us_win_ascent = try parser.readU16(data, 74),
        .us_win_descent = try parser.readU16(data, 76),
        // NOTE: the differing 90/92 length thresholds here are preserved
        // verbatim from this table's pre-unification behavior (not a typo) --
        // changing them would be a behavior change outside this pass's scope.
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
    try std.testing.expectEqual(@as(u16, 400), os2.us_weight_class);
    // DejaVuSans has positive ascender
    try std.testing.expect(os2.s_typo_ascender > 0);
    // DejaVuSans fixture is OS/2 version 1
    try std.testing.expect(os2.version >= 1);
    if (os2.version >= 2) {
        try std.testing.expect(os2.s_cap_height > 0);
    } else {
        try std.testing.expectEqual(@as(i16, 0), os2.s_cap_height);
    }
    try std.testing.expect(!os2.isItalic());
    try std.testing.expect(!os2.isBold());
}

test "readAvgCharWidth: reads xAvgCharWidth from a minimal 68-byte v0 OS/2 table (I9)" {
    // OS/2 v0's minimum legal size is 68 bytes -- too short for `parse`
    // (which requires 78), but xAvgCharWidth at offset 2 is present all the
    // same.
    var data = [_]u8{0} ** 68;
    std.mem.writeInt(u16, data[0..2], 0, .big); // version
    std.mem.writeInt(i16, data[2..4], 543, .big); // xAvgCharWidth

    // The full parse should reject this table as too short...
    try std.testing.expectError(error.UnexpectedEof, parse(&data));
    // ...but the lightweight accessor should still read the field.
    try std.testing.expectEqual(@as(?i16, 543), readAvgCharWidth(&data));
}

test "readAvgCharWidth: too short even for the one field returns null" {
    var data = [_]u8{0} ** 3;
    try std.testing.expectEqual(@as(?i16, null), readAvgCharWidth(&data));
}

test "readAvgCharWidth: unaffected on a normal (78+ byte) table" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const record = parser.findTable(offset_table, "OS/2".*) orelse return error.TableNotFound;
    const table_data = try parser.getTableData(font_data, record);
    const os2 = try parse(table_data);

    try std.testing.expectEqual(@as(?i16, os2.avg_char_width), readAvgCharWidth(table_data));
}
