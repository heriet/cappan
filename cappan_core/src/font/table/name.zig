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
            const result = try allocator.alloc(u8, raw.len);
            @memcpy(result, raw);
            return result;
        }

        return try utf16beToUtf8(allocator, raw);
    }
};

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
