const std = @import("std");
const parser = @import("../parser.zig");
const otlayout = @import("otlayout.zig");

pub const GsubTable = struct {
    data: []const u8,
    script_list_offset: u16,
    feature_list_offset: u16,
    lookup_list_offset: u16,

    pub fn applyFeatures(
        self: GsubTable,
        allocator: std.mem.Allocator,
        script_tag: [4]u8,
        lang_tag: ?[4]u8,
        feature_tags: []const [4]u8,
        glyphs: []const u16,
    ) ![]u16 {
        const lang_sys_offset = otlayout.findLangSysOffset(
            self.data, self.script_list_offset, script_tag, lang_tag,
        ) orelse {
            const result = try allocator.alloc(u16, glyphs.len);
            @memcpy(result, glyphs);
            return result;
        };

        const lookup_indices = try otlayout.collectLookupIndices(
            allocator, self.data, self.feature_list_offset, lang_sys_offset, feature_tags,
        );
        defer allocator.free(lookup_indices);

        var buf = std.ArrayListUnmanaged(u16).empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, glyphs);

        for (lookup_indices) |lookup_idx| {
            self.applyLookup(lookup_idx, &buf);
        }

        return buf.toOwnedSlice(allocator);
    }

    fn applyLookup(self: GsubTable, lookup_index: u16, glyphs: *std.ArrayListUnmanaged(u16)) void {
        const info = otlayout.getLookupInfo(self.data, self.lookup_list_offset, lookup_index) orelse return;

        var si: usize = 0;
        while (si < info.subtable_count) : (si += 1) {
            const sub_abs = otlayout.getSubtableOffset(self.data, info.base_offset, si) orelse break;

            var effective_type = info.lookup_type;
            var effective_offset = sub_abs;

            if (info.lookup_type == 7) {
                const ext = otlayout.parseExtensionSubtable(self.data, sub_abs) orelse continue;
                effective_type = ext.effective_type;
                effective_offset = ext.effective_offset;
            }

            switch (effective_type) {
                1 => applySingleSubst(self.data, effective_offset, glyphs),
                4 => applyLigatureSubst(self.data, effective_offset, glyphs),
                else => {},
            }
        }
    }
};

fn applySingleSubst(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16)) void {
    if (subtable_offset + 6 > data.len) return;
    const format = parser.readU16(data, subtable_offset) catch return;
    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return;

    switch (format) {
        1 => {
            const delta_raw = parser.readI16(data, subtable_offset + 4) catch return;
            const delta: i32 = delta_raw;
            for (glyphs.items) |*g| {
                if (coverage.getCoverageIndex(g.*) != null) {
                    const new_id = @as(i32, g.*) + delta;
                    g.* = @intCast(@as(u32, @bitCast(new_id)) & 0xFFFF);
                }
            }
        },
        2 => {
            const glyph_count = parser.readU16(data, subtable_offset + 4) catch return;
            for (glyphs.items) |*g| {
                const cov_idx = coverage.getCoverageIndex(g.*) orelse continue;
                if (cov_idx >= glyph_count) continue;
                const sub_offset = subtable_offset + 6 + @as(usize, cov_idx) * 2;
                const substitute = parser.readU16(data, sub_offset) catch continue;
                g.* = substitute;
            }
        },
        else => {},
    }
}

fn applyLigatureSubst(data: []const u8, subtable_offset: usize, glyphs: *std.ArrayListUnmanaged(u16)) void {
    if (subtable_offset + 6 > data.len) return;
    const format = parser.readU16(data, subtable_offset) catch return;
    if (format != 1) return;

    const cov_offset = parser.readU16(data, subtable_offset + 2) catch return;
    const coverage = otlayout.parseCoverage(data, subtable_offset + @as(usize, cov_offset)) catch return;
    const lig_set_count = parser.readU16(data, subtable_offset + 4) catch return;

    var i: usize = 0;
    while (i < glyphs.items.len) {
        const glyph_id = glyphs.items[i];
        const cov_idx = coverage.getCoverageIndex(glyph_id) orelse {
            i += 1;
            continue;
        };
        if (cov_idx >= lig_set_count) {
            i += 1;
            continue;
        }

        const ls_offset_pos = subtable_offset + 6 + @as(usize, cov_idx) * 2;
        if (ls_offset_pos + 2 > data.len) {
            i += 1;
            continue;
        }
        const ls_offset = parser.readU16(data, ls_offset_pos) catch {
            i += 1;
            continue;
        };
        const ls_base = subtable_offset + @as(usize, ls_offset);
        if (ls_base + 2 > data.len) {
            i += 1;
            continue;
        }

        const lig_count = parser.readU16(data, ls_base) catch {
            i += 1;
            continue;
        };

        var matched = false;
        var li: usize = 0;
        while (li < lig_count) : (li += 1) {
            const lig_offset_pos = ls_base + 2 + li * 2;
            if (lig_offset_pos + 2 > data.len) break;
            const lig_offset = parser.readU16(data, lig_offset_pos) catch break;
            const lig_base = ls_base + @as(usize, lig_offset);
            if (lig_base + 4 > data.len) continue;

            const lig_glyph = parser.readU16(data, lig_base) catch continue;
            const comp_count = parser.readU16(data, lig_base + 2) catch continue;
            if (comp_count == 0) continue;

            const components_needed = comp_count - 1;
            if (i + components_needed >= glyphs.items.len) continue;

            var components_match = true;
            var ci: usize = 0;
            while (ci < components_needed) : (ci += 1) {
                const comp_offset = lig_base + 4 + ci * 2;
                if (comp_offset + 2 > data.len) {
                    components_match = false;
                    break;
                }
                const expected = parser.readU16(data, comp_offset) catch {
                    components_match = false;
                    break;
                };
                if (glyphs.items[i + 1 + ci] != expected) {
                    components_match = false;
                    break;
                }
            }

            if (components_match) {
                glyphs.items[i] = lig_glyph;
                var removed: usize = 0;
                while (removed < components_needed) : (removed += 1) {
                    _ = glyphs.orderedRemove(i + 1);
                }
                matched = true;
                break;
            }
        }

        if (!matched) {
            i += 1;
        }
    }
}

pub fn parse(data: []const u8) !GsubTable {
    if (data.len < 10) return error.UnexpectedEof;
    const major_version = try parser.readU16(data, 0);
    if (major_version != 1) return error.InvalidVersion;

    return .{
        .data = data,
        .script_list_offset = try parser.readU16(data, 4),
        .feature_list_offset = try parser.readU16(data, 6),
        .lookup_list_offset = try parser.readU16(data, 8),
    };
}

// ============================================================
// Tests
// ============================================================

test "Single Substitution Format 1: delta" {
    const data = [_]u8{
        0x00, 0x01, // substFormat = 1
        0x00, 0x06, // coverageOffset = 6
        0x00, 0x05, // deltaGlyphID = 5
        0x00, 0x01, // coverage format = 1
        0x00, 0x02, // glyphCount = 2
        0x00, 0x0A, // glyph 10
        0x00, 0x14, // glyph 20
    };

    var glyphs = std.ArrayListUnmanaged(u16).empty;
    defer glyphs.deinit(std.testing.allocator);
    try glyphs.appendSlice(std.testing.allocator, &[_]u16{ 10, 15, 20, 30 });

    applySingleSubst(&data, 0, &glyphs);

    try std.testing.expectEqual(@as(u16, 15), glyphs.items[0]);
    try std.testing.expectEqual(@as(u16, 15), glyphs.items[1]);
    try std.testing.expectEqual(@as(u16, 25), glyphs.items[2]);
    try std.testing.expectEqual(@as(u16, 30), glyphs.items[3]);
}

test "Single Substitution Format 2: direct mapping" {
    const data = [_]u8{
        0x00, 0x02, // substFormat = 2
        0x00, 0x0A, // coverageOffset = 10
        0x00, 0x02, // glyphCount = 2
        0x00, 0x64, // substituteGlyphIDs[0] = 100
        0x00, 0xC8, // substituteGlyphIDs[1] = 200
        0x00, 0x01, // coverage format = 1
        0x00, 0x02, // glyphCount = 2
        0x00, 0x0A, // glyph 10
        0x00, 0x14, // glyph 20
    };

    var glyphs = std.ArrayListUnmanaged(u16).empty;
    defer glyphs.deinit(std.testing.allocator);
    try glyphs.appendSlice(std.testing.allocator, &[_]u16{ 10, 15, 20 });

    applySingleSubst(&data, 0, &glyphs);

    try std.testing.expectEqual(@as(u16, 100), glyphs.items[0]);
    try std.testing.expectEqual(@as(u16, 15), glyphs.items[1]);
    try std.testing.expectEqual(@as(u16, 200), glyphs.items[2]);
}

test "Ligature Substitution: f + i -> fi" {
    const data = [_]u8{
        0x00, 0x01, // substFormat = 1
        0x00, 0x08, // coverageOffset = 8
        0x00, 0x01, // ligatureSetCount = 1
        0x00, 0x0E, // ligatureSetOffsets[0] = 14
        0x00, 0x01, // coverage format = 1
        0x00, 0x01, // glyphCount = 1
        0x00, 0x28, // glyph 40
        0x00, 0x01, // ligatureCount = 1
        0x00, 0x04, // ligatureOffsets[0] = 4
        0x00, 0x63, // ligatureGlyph = 99
        0x00, 0x02, // componentCount = 2
        0x00, 0x29, // componentGlyphIDs[0] = 41
    };

    var glyphs = std.ArrayListUnmanaged(u16).empty;
    defer glyphs.deinit(std.testing.allocator);
    try glyphs.appendSlice(std.testing.allocator, &[_]u16{ 40, 41, 42 });

    applyLigatureSubst(&data, 0, &glyphs);

    try std.testing.expectEqual(@as(usize, 2), glyphs.items.len);
    try std.testing.expectEqual(@as(u16, 99), glyphs.items[0]);
    try std.testing.expectEqual(@as(u16, 42), glyphs.items[1]);
}

test "parse GSUB table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const gsub_record = p.findTable(offset_table, "GSUB".*) orelse return;
    const gsub_data = try p.getTableData(font_data, gsub_record);
    const gsub = try parse(gsub_data);

    try std.testing.expect(gsub.script_list_offset > 0);
    try std.testing.expect(gsub.feature_list_offset > 0);
    try std.testing.expect(gsub.lookup_list_offset > 0);
}

test "GSUB liga feature with DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const font_mod = @import("../font.zig");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const gsub = font.getGsubTable() orelse return;

    const glyph_f = try font.getGlyphId('f');
    const glyph_i = try font.getGlyphId('i');
    try std.testing.expect(glyph_f > 0);
    try std.testing.expect(glyph_i > 0);

    const input = [_]u16{ glyph_f, glyph_i };
    const feature_tags = [_][4]u8{"liga".*};

    const result_latn = try gsub.applyFeatures(
        std.testing.allocator,
        "latn".*,
        null,
        &feature_tags,
        &input,
    );
    defer std.testing.allocator.free(result_latn);

    if (result_latn.len < input.len) {
        try std.testing.expect(result_latn.len == 1);
        try std.testing.expect(result_latn[0] != glyph_f);
        try std.testing.expect(result_latn[0] != glyph_i);
        return;
    }

    const result_dflt = try gsub.applyFeatures(
        std.testing.allocator,
        "DFLT".*,
        null,
        &feature_tags,
        &input,
    );
    defer std.testing.allocator.free(result_dflt);

    if (result_dflt.len < input.len) {
        try std.testing.expect(result_dflt.len == 1);
        try std.testing.expect(result_dflt[0] != glyph_f);
        try std.testing.expect(result_dflt[0] != glyph_i);
    }
}
