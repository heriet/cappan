const std = @import("std");
const parser = @import("../parser.zig");

pub const CmapTable = struct {
    data: []const u8,
    format4_offset: ?u32,
    format12_offset: ?u32,

    pub fn charToGlyphId(self: CmapTable, codepoint: u32) !u16 {
        // Try format 12 first (supports full Unicode range)
        if (self.format12_offset) |f12_off| {
            const subtable = self.data[f12_off..];
            // format12 header: format(u16) reserved(u16) length(u32) language(u32) numGroups(u32)
            // numGroups is at offset 12
            const num_groups = try parser.readU32(subtable, 12);

            // Binary search on endCharCode
            var lo: usize = 0;
            var hi: usize = num_groups;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const end_char_code = try parser.readU32(subtable, 16 + mid * 12 + 4);
                if (end_char_code < codepoint) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }

            if (lo < num_groups) {
                const start_char_code = try parser.readU32(subtable, 16 + lo * 12);
                const end_char_code = try parser.readU32(subtable, 16 + lo * 12 + 4);
                if (start_char_code <= codepoint and codepoint <= end_char_code) {
                    const start_glyph_id = try parser.readU32(subtable, 16 + lo * 12 + 8);
                    const glyph_id = std.math.add(u32, start_glyph_id, codepoint - start_char_code) catch return 0;
                    return @intCast(glyph_id & 0xFFFF);
                }
            }

            // Not found in format 12; fall through to format 4 if codepoint fits
        }

        // Try format 4 (BMP only, codepoints <= 0xFFFF)
        if (self.format4_offset) |f4_off| {
            if (codepoint > 0xFFFF) return 0;
            const cp16: u16 = @intCast(codepoint);
            const subtable = self.data[f4_off..];

            const seg_count_x2 = try parser.readU16(subtable, 6);
            const seg_count = seg_count_x2 / 2;

            const end_code_offset: usize = 14;
            const start_code_offset: usize = 14 + @as(usize, seg_count) * 2 + 2; // +2 for reservedPad
            const id_delta_offset: usize = start_code_offset + @as(usize, seg_count) * 2;
            const id_range_offset_base: usize = id_delta_offset + @as(usize, seg_count) * 2;

            // Binary search for segment
            var lo: usize = 0;
            var hi: usize = seg_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const end_code = try parser.readU16(subtable, end_code_offset + mid * 2);
                if (end_code < cp16) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }

            if (lo >= seg_count) return 0;

            const seg = lo;
            const end_code = try parser.readU16(subtable, end_code_offset + seg * 2);
            const start_code = try parser.readU16(subtable, start_code_offset + seg * 2);
            _ = end_code;

            if (cp16 < start_code) return 0;

            const id_delta = try parser.readI16(subtable, id_delta_offset + seg * 2);

            // Verify id_range_offset_addr is within subtable before reading
            const id_range_offset_addr = id_range_offset_base + seg * 2;
            if (id_range_offset_addr + 2 > subtable.len) return 0;
            const id_range_offset = try parser.readU16(subtable, id_range_offset_addr);

            if (id_range_offset == 0) {
                const result = @as(i32, cp16) + @as(i32, id_delta);
                return @intCast(@as(u32, @bitCast(result)) & 0xFFFF);
            } else {
                // Guard against integer overflow when computing glyph_index_offset
                const base = std.math.add(usize, id_range_offset_addr, @as(usize, id_range_offset)) catch return 0;
                const delta = (@as(usize, cp16) - @as(usize, start_code)) * 2;
                const glyph_index_offset = std.math.add(usize, base, delta) catch return 0;
                if (glyph_index_offset + 2 > subtable.len) return 0;
                const glyph_id = try parser.readU16(subtable, glyph_index_offset);
                if (glyph_id == 0) return 0;
                const result = @as(i32, glyph_id) + @as(i32, id_delta);
                return @intCast(@as(u32, @bitCast(result)) & 0xFFFF);
            }
        }

        return 0;
    }
};

pub fn parse(data: []const u8) !CmapTable {
    if (data.len < 4) return error.UnexpectedEof;

    const num_tables = try parser.readU16(data, 2);
    var offset: usize = 4;

    var format4_offset: ?u32 = null;
    var format12_offset: ?u32 = null;

    for (0..num_tables) |_| {
        if (offset + 8 > data.len) return error.UnexpectedEof;
        const platform_id = try parser.readU16(data, offset);
        const encoding_id = try parser.readU16(data, offset + 2);
        const subtable_offset = try parser.readU32(data, offset + 4);
        offset += 8;

        // Unicode BMP: platformID=0 or (platformID=3, encodingID=1)
        const is_bmp = (platform_id == 0) or (platform_id == 3 and encoding_id == 1);
        // Unicode full repertoire: platformID=0 encodingID=3|4, or platformID=3 encodingID=10
        const is_full = (platform_id == 0 and (encoding_id == 3 or encoding_id == 4)) or
            (platform_id == 3 and encoding_id == 10);

        if (is_bmp or is_full) {
            if (subtable_offset + 2 > data.len) continue;
            const format = try parser.readU16(data, subtable_offset);
            if (format == 4 and format4_offset == null) {
                format4_offset = subtable_offset;
            } else if (format == 12 and format12_offset == null) {
                format12_offset = subtable_offset;
            }
        }
    }

    if (format4_offset == null and format12_offset == null) {
        return error.TableNotFound;
    }

    return .{
        .data = data,
        .format4_offset = format4_offset,
        .format12_offset = format12_offset,
    };
}

test "parse cmap and lookup ASCII characters" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const offset_table = try parser.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const record = parser.findTable(offset_table, "cmap".*) orelse return error.TableNotFound;
    const table_data = try parser.getTableData(font_data, record);
    const cmap = try parse(table_data);

    // 'A' (U+0041) should map to a non-zero glyph ID
    const glyph_a = try cmap.charToGlyphId(0x0041);
    try std.testing.expect(glyph_a > 0);

    // ' ' (U+0020) should also have a glyph
    const glyph_space = try cmap.charToGlyphId(0x0020);
    try std.testing.expect(glyph_space > 0);

    // Different characters should (likely) have different glyph IDs
    const glyph_b = try cmap.charToGlyphId(0x0042);
    try std.testing.expect(glyph_b > 0);
    try std.testing.expect(glyph_a != glyph_b);
}
