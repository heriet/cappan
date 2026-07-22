const std = @import("std");
const parser = @import("../parser.zig");

pub const NameId = enum(u16) {
    copyright = 0,
    font_family = 1,
    font_subfamily = 2,
    unique_id = 3,
    full_name = 4,
    version = 5,
    postscript_name = 6,
    _,
};

pub const NameRecord = struct {
    platform_id: u16,
    encoding_id: u16,
    language_id: u16,
    name_id: u16,
    length: u16,
    string_offset: u16,
};

pub const NameTable = struct {
    data: []const u8,
    count: u16,
    string_storage_offset: u16,

    pub fn getName(self: NameTable, allocator: std.mem.Allocator, name_id: NameId) !?[]u8 {
        var best_record: ?NameRecord = null;
        var best_priority: u8 = 0;

        const target_name_id = @intFromEnum(name_id);

        for (0..self.count) |i| {
            const offset = 6 + i * 12;
            if (offset + 12 > self.data.len) break;

            const rec = NameRecord{
                .platform_id = parser.readU16(self.data, offset) catch break,
                .encoding_id = parser.readU16(self.data, offset + 2) catch break,
                .language_id = parser.readU16(self.data, offset + 4) catch break,
                .name_id = parser.readU16(self.data, offset + 6) catch break,
                .length = parser.readU16(self.data, offset + 8) catch break,
                .string_offset = parser.readU16(self.data, offset + 10) catch break,
            };

            if (rec.name_id != target_name_id) continue;

            var priority: u8 = 0;
            if (rec.platform_id == 3 and rec.encoding_id == 1) {
                if (rec.language_id == 0x0409) {
                    priority = 4;
                } else {
                    priority = 3;
                }
            } else if (rec.platform_id == 0) {
                priority = 2;
            } else if (rec.platform_id == 1 and rec.encoding_id == 0) {
                priority = 1;
            }

            if (priority > best_priority) {
                best_priority = priority;
                best_record = rec;
            }
        }

        if (best_record) |rec| {
            return try self.decodeString(allocator, rec);
        }
        return null;
    }

    fn decodeString(self: NameTable, allocator: std.mem.Allocator, rec: NameRecord) ![]u8 {
        const str_start: usize = @as(usize, self.string_storage_offset) + @as(usize, rec.string_offset);
        const str_end: usize = str_start + @as(usize, rec.length);
        if (str_end > self.data.len) return error.UnexpectedEof;
        const raw = self.data[str_start..str_end];

        if (rec.platform_id == 1 and rec.encoding_id == 0) {
            // Macintosh / Roman (MacRoman): an 8-bit encoding, not UTF-16BE.
            // 0x00-0x7F is ASCII and passes through unchanged; 0x80-0xFF maps
            // to non-ASCII codepoints (accented letters, symbols) via a fixed
            // 128-entry table (I8) -- previously these bytes were copied
            // through raw, producing invalid UTF-8 for any name containing
            // them.
            //
            // Other Mac platform encodings (encoding_id != 0, e.g. Japanese,
            // Korean, ...) are intentionally left as raw bytes for now: they
            // are different 8-bit/multi-byte charsets that would need their
            // own mapping tables, and are rare in practice (platform 3
            // Windows/Unicode dominates real-world fonts).
            return try macRomanToUtf8(allocator, raw);
        }

        return try utf16beToUtf8(allocator, raw);
    }
};

/// Unicode codepoints for MacRoman bytes 0x80-0xFF (index 0 == byte 0x80).
/// 0x00-0x7F is identical to ASCII and needs no table lookup.
const mac_roman_high_table = [128]u21{
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1, // 0x80-0x87
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8, // 0x88-0x8F
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3, // 0x90-0x97
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC, // 0x98-0x9F
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF, // 0xA0-0xA7
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8, // 0xA8-0xAF
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211, // 0xB0-0xB7
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8, // 0xB8-0xBF
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB, // 0xC0-0xC7
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153, // 0xC8-0xCF
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA, // 0xD0-0xD7
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02, // 0xD8-0xDF
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1, // 0xE0-0xE7
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4, // 0xE8-0xEF
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC, // 0xF0-0xF7
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7, // 0xF8-0xFF
};

fn macRomanToUtf8(allocator: std.mem.Allocator, mac_roman: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (mac_roman) |byte| {
        const codepoint: u21 = if (byte < 0x80) byte else mac_roman_high_table[byte - 0x80];
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch continue;
        try result.appendSlice(allocator, buf[0..len]);
    }

    return try result.toOwnedSlice(allocator);
}

fn utf16beToUtf8(allocator: std.mem.Allocator, utf16be: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i + 1 < utf16be.len) {
        const code_unit = std.mem.readInt(u16, utf16be[i..][0..2], .big);
        i += 2;

        var codepoint: u21 = undefined;
        if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
            if (i + 1 < utf16be.len) {
                const low = std.mem.readInt(u16, utf16be[i..][0..2], .big);
                i += 2;
                if (low >= 0xDC00 and low <= 0xDFFF) {
                    codepoint = @intCast((@as(u32, code_unit - 0xD800) << 10) + @as(u32, low - 0xDC00) + 0x10000);
                } else {
                    codepoint = 0xFFFD;
                }
            } else {
                codepoint = 0xFFFD;
            }
        } else if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
            codepoint = 0xFFFD;
        } else {
            codepoint = @intCast(code_unit);
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch continue;
        try result.appendSlice(allocator, buf[0..len]);
    }

    return try result.toOwnedSlice(allocator);
}

pub fn parse(data: []const u8) !NameTable {
    if (data.len < 6) return error.UnexpectedEof;
    const count = try parser.readU16(data, 2);
    const string_offset = try parser.readU16(data, 4);

    return NameTable{
        .data = data,
        .count = count,
        .string_storage_offset = string_offset,
    };
}

test "parse name table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const font_parser = @import("../parser.zig");
    const offset_table = try font_parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const name_record = font_parser.findTable(offset_table, "name".*) orelse return error.TableNotFound;
    const name_data = try font_parser.getTableData(font_data, name_record);
    const name_table = try parse(name_data);

    const family = (try name_table.getName(std.testing.allocator, .font_family)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(family);
    try std.testing.expectEqualStrings("DejaVu Sans", family);

    const subfamily = (try name_table.getName(std.testing.allocator, .font_subfamily)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(subfamily);
    try std.testing.expect(subfamily.len > 0);

    const full_name = (try name_table.getName(std.testing.allocator, .full_name)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(full_name);
    try std.testing.expect(full_name.len > 0);
}

/// Builds a minimal synthetic `name` table with a single record, for testing
/// decode behavior without needing a real font fixture (I8).
fn buildSyntheticNameTable(
    allocator: std.mem.Allocator,
    platform_id: u16,
    encoding_id: u16,
    language_id: u16,
    name_id: u16,
    string_bytes: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // header: format(u16)=0, count(u16)=1, stringOffset(u16)=18 (6 header + 12 record bytes)
    try buf.appendSlice(allocator, &[_]u8{ 0, 0, 0, 1, 0, 18 });
    // record: platform, encoding, language, nameID, length, offset(=0, relative to stringOffset)
    const len_u16: u16 = @intCast(string_bytes.len);
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, platform_id)));
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, encoding_id)));
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, language_id)));
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, name_id)));
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, len_u16)));
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @as(u16, 0))));
    // string storage
    try buf.appendSlice(allocator, string_bytes);

    return try buf.toOwnedSlice(allocator);
}

test "MacRoman name decodes non-ASCII bytes to UTF-8 (I8)" {
    // MacRoman "Caf\x8E" == "Café" (0x8E maps to U+00E9 'é').
    const mac_roman_bytes = [_]u8{ 'C', 'a', 'f', 0x8E };
    const table_data = try buildSyntheticNameTable(std.testing.allocator, 1, 0, 0, 6, &mac_roman_bytes);
    defer std.testing.allocator.free(table_data);

    const name_table = try parse(table_data);
    const decoded = (try name_table.getName(std.testing.allocator, .postscript_name)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("Café", decoded);
}

test "MacRoman name with ASCII-only bytes is unaffected by the fix (I8)" {
    const ascii_bytes = "Hello";
    const table_data = try buildSyntheticNameTable(std.testing.allocator, 1, 0, 0, 6, ascii_bytes);
    defer std.testing.allocator.free(table_data);

    const name_table = try parse(table_data);
    const decoded = (try name_table.getName(std.testing.allocator, .postscript_name)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("Hello", decoded);
}

test "Windows (platform 3) name is unaffected by the MacRoman fix (I8)" {
    // UTF-16BE "Hi" == 00 48 00 69
    const utf16be_bytes = [_]u8{ 0x00, 'H', 0x00, 'i' };
    const table_data = try buildSyntheticNameTable(std.testing.allocator, 3, 1, 0x0409, 6, &utf16be_bytes);
    defer std.testing.allocator.free(table_data);

    const name_table = try parse(table_data);
    const decoded = (try name_table.getName(std.testing.allocator, .postscript_name)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("Hi", decoded);
}
