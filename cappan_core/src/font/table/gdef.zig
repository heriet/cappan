const std = @import("std");
const parser = @import("../parser.zig");
const otlayout = @import("otlayout.zig");

pub const GlyphClass = enum(u16) {
    unclassified = 0,
    base = 1,
    ligature = 2,
    mark = 3,
    component = 4,
};

pub const GdefTable = struct {
    data: []const u8,
    glyph_class_def_offset: u16,
    mark_attach_class_def_offset: u16,
    mark_glyph_sets_offset: u16,

    pub fn getGlyphClass(self: GdefTable, glyph_id: u16) GlyphClass {
        if (self.glyph_class_def_offset == 0) return .unclassified;
        const class_def = otlayout.parseClassDef(self.data, @as(usize, self.glyph_class_def_offset)) catch return .unclassified;
        const class_val = class_def.getClass(glyph_id);
        return switch (class_val) {
            1 => .base,
            2 => .ligature,
            3 => .mark,
            4 => .component,
            else => .unclassified,
        };
    }

    pub fn getMarkAttachClass(self: GdefTable, glyph_id: u16) u16 {
        if (self.mark_attach_class_def_offset == 0) return 0;
        const class_def = otlayout.parseClassDef(self.data, @as(usize, self.mark_attach_class_def_offset)) catch return 0;
        return class_def.getClass(glyph_id);
    }

    pub fn isMarkInGlyphSet(self: GdefTable, glyph_id: u16, set_index: u16) bool {
        if (self.mark_glyph_sets_offset == 0) return false;
        const base = @as(usize, self.mark_glyph_sets_offset);
        // MarkGlyphSetsTable: format(u16) + markGlyphSetCount(u16) + offsets[](u32)
        if (base + 4 > self.data.len) return false;
        const set_count = parser.readU16(self.data, base + 2) catch return false;
        if (set_index >= set_count) return false;
        const offset_pos = base + 4 + @as(usize, set_index) * 4;
        if (offset_pos + 4 > self.data.len) return false;
        const cov_offset = parser.readU32(self.data, offset_pos) catch return false;
        const coverage = otlayout.parseCoverage(self.data, base + @as(usize, cov_offset)) catch return false;
        return coverage.getCoverageIndex(glyph_id) != null;
    }

    /// Check if a glyph should be skipped according to the given LookupFlag.
    /// LookupFlag bits:
    ///   bit 1 (0x0002): ignoreBaseGlyphs
    ///   bit 2 (0x0004): ignoreLigatures
    ///   bit 3 (0x0008): ignoreMarks
    ///   bits 8-15 (0xFF00): markAttachmentType (only process marks of this class)
    ///   bit 4 (0x0010): useMarkFilteringSet (markGlyphSetsIndex follows at end of lookup table)
    pub fn shouldSkipGlyph(self: GdefTable, glyph_id: u16, lookup_flag: u16, mark_filtering_set: ?u16) bool {
        if (lookup_flag & 0x000E == 0 and lookup_flag & 0xFF00 == 0 and lookup_flag & 0x0010 == 0) return false;

        const glyph_class = self.getGlyphClass(glyph_id);

        if (lookup_flag & 0x0002 != 0 and glyph_class == .base) return true;
        if (lookup_flag & 0x0004 != 0 and glyph_class == .ligature) return true;
        if (lookup_flag & 0x0008 != 0) {
            if (glyph_class == .mark) {
                const mark_attach_type = (lookup_flag >> 8) & 0xFF;
                if (mark_attach_type != 0) {
                    return self.getMarkAttachClass(glyph_id) != @as(u16, @intCast(mark_attach_type));
                }
                return true;
            }
        } else {
            // ignoreMarks not set, but markAttachmentType may still filter marks
            const mark_attach_type = (lookup_flag >> 8) & 0xFF;
            if (mark_attach_type != 0 and glyph_class == .mark) {
                return self.getMarkAttachClass(glyph_id) != @as(u16, @intCast(mark_attach_type));
            }
        }

        if (lookup_flag & 0x0010 != 0) {
            if (glyph_class == .mark) {
                if (mark_filtering_set) |set_idx| {
                    return !self.isMarkInGlyphSet(glyph_id, set_idx);
                }
            }
        }

        return false;
    }
};

pub fn parse(data: []const u8) !GdefTable {
    if (data.len < 12) return error.UnexpectedEof;
    const major = try parser.readU16(data, 0);
    if (major != 1) return error.InvalidVersion;
    const minor = try parser.readU16(data, 2);

    const mark_glyph_sets_offset: u16 = if (minor >= 2 and data.len >= 14)
        parser.readU16(data, 12) catch 0
    else
        0;

    return .{
        .data = data,
        .glyph_class_def_offset = try parser.readU16(data, 4),
        .mark_attach_class_def_offset = try parser.readU16(data, 10),
        .mark_glyph_sets_offset = mark_glyph_sets_offset,
    };
}

// ============================================================
// Tests
// ============================================================

test "parse GDEF from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const gdef_record = p.findTable(offset_table, "GDEF".*) orelse return;
    const gdef_data = try p.getTableData(font_data, gdef_record);
    const gdef = try parse(gdef_data);

    try std.testing.expect(gdef.glyph_class_def_offset > 0);
}

test "GDEF glyph classification with DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const gdef_record = p.findTable(offset_table, "GDEF".*) orelse return;
    const gdef_data = try p.getTableData(font_data, gdef_record);
    const gdef = try parse(gdef_data);

    const font_mod = @import("../font.zig");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_a = try font.getGlyphId('A');
    const class_a = gdef.getGlyphClass(glyph_a);
    try std.testing.expectEqual(GlyphClass.base, class_a);
}

test "shouldSkipGlyph with ignoreMarks" {
    // Synthetic test: create a minimal ClassDef Format 1 that classifies glyph 10 as mark (3)
    const data = [_]u8{
        // GDEF header (12 bytes)
        0x00, 0x01, // majorVersion = 1
        0x00, 0x00, // minorVersion = 0
        0x00, 0x0C, // glyphClassDefOffset = 12
        0x00, 0x00, // attachListOffset = 0
        0x00, 0x00, // ligCaretListOffset = 0
        0x00, 0x00, // markAttachClassDefOffset = 0
        // ClassDef Format 1 at offset 12
        0x00, 0x01, // format = 1
        0x00, 0x0A, // startGlyphID = 10
        0x00, 0x03, // glyphCount = 3
        0x00, 0x03, // glyph 10 = mark (3)
        0x00, 0x01, // glyph 11 = base (1)
        0x00, 0x02, // glyph 12 = ligature (2)
    };

    const gdef = try parse(&data);

    // ignoreMarks (0x0008): should skip mark glyphs
    try std.testing.expect(gdef.shouldSkipGlyph(10, 0x0008, null)); // mark -> skip
    try std.testing.expect(!gdef.shouldSkipGlyph(11, 0x0008, null)); // base -> don't skip
    try std.testing.expect(!gdef.shouldSkipGlyph(12, 0x0008, null)); // ligature -> don't skip

    // ignoreBaseGlyphs (0x0002): should skip base glyphs
    try std.testing.expect(!gdef.shouldSkipGlyph(10, 0x0002, null)); // mark -> don't skip
    try std.testing.expect(gdef.shouldSkipGlyph(11, 0x0002, null)); // base -> skip

    // ignoreLigatures (0x0004): should skip ligature glyphs
    try std.testing.expect(gdef.shouldSkipGlyph(12, 0x0004, null)); // ligature -> skip
    try std.testing.expect(!gdef.shouldSkipGlyph(11, 0x0004, null)); // base -> don't skip

    // no flags: skip nothing
    try std.testing.expect(!gdef.shouldSkipGlyph(10, 0x0000, null));
}
