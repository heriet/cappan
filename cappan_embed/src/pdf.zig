const std = @import("std");
const cappan_core = @import("cappan_core");
const os2_mod = cappan_core.font.table.os2;

pub const PdfFontInfo = struct {
    postscript_name: []const u8,
    flags: u32,
    bbox: [4]i16,
    italic_angle: i16,
    ascent: i16,
    descent: i16,
    cap_height: i16,
    stem_v: i16,
    units_per_em: u16,
    is_italic: bool,
    is_bold: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PdfFontInfo) void {
        self.allocator.free(self.postscript_name);
    }
};

pub const GlyphWidth = struct {
    codepoint: u21,
    glyph_id: u16,
    width: u16,
};

pub fn getPdfFontInfo(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
) !PdfFontInfo {
    const name_table = font.name orelse return error.NoNameTable;
    const ps_name_raw = try name_table.getName(allocator, .postscript_name);
    const ps_name = ps_name_raw orelse try allocator.dupe(u8, "Unknown");

    const os2_record = cappan_core.font.parser.findTable(font.offset_table, "OS/2".*);
    var os2: ?os2_mod.Os2Table = null;
    if (os2_record) |rec| {
        const os2_data = try cappan_core.font.parser.getTableData(font.data, rec);
        os2 = os2_mod.parse(os2_data) catch null;
    }

    const post_record = cappan_core.font.parser.findTable(font.offset_table, "post".*);
    var italic_angle: i16 = 0;
    var is_fixed_pitch = false;
    if (post_record) |rec| {
        const post_data = try cappan_core.font.parser.getTableData(font.data, rec);
        if (post_data.len >= 32) {
            const angle_fixed = cappan_core.font.parser.readI32(post_data, 4) catch 0;
            italic_angle = @intCast(@divTrunc(angle_fixed, 65536));
            const fixed_pitch = cappan_core.font.parser.readU32(post_data, 12) catch 0;
            is_fixed_pitch = fixed_pitch != 0;
        }
    }

    const is_italic = (if (os2) |o| o.isItalic() else false) or (italic_angle != 0);

    var flags: u32 = 32;
    if (is_fixed_pitch) flags |= 1;
    if (is_italic) flags |= 64;

    const bbox = [4]i16{ font.head.x_min, font.head.y_min, font.head.x_max, font.head.y_max };

    var ascent: i16 = font.hhea.ascender;
    var descent: i16 = font.hhea.descender;
    if (os2) |o| {
        if (o.s_typo_ascender != 0) ascent = o.s_typo_ascender;
        if (o.s_typo_descender != 0) descent = o.s_typo_descender;
    }

    var cap_height: i16 = 0;
    if (os2) |o| {
        if (o.s_cap_height != 0) {
            cap_height = o.s_cap_height;
        }
    }
    if (cap_height == 0) {
        cap_height = @intCast(@divTrunc(@as(i32, ascent) * 7, 10));
    }

    var stem_v: i16 = 80;
    if (os2) |o| {
        const w: i32 = @intCast(o.us_weight_class);
        stem_v = @intCast(50 + @divTrunc(w, 65) * @divTrunc(w, 65));
    }

    const is_bold = if (os2) |o| o.isBold() else false;

    return .{
        .postscript_name = ps_name,
        .flags = flags,
        .bbox = bbox,
        .italic_angle = italic_angle,
        .ascent = ascent,
        .descent = descent,
        .cap_height = cap_height,
        .stem_v = stem_v,
        .units_per_em = font.getUnitsPerEm(),
        .is_italic = is_italic,
        .is_bold = is_bold,
        .allocator = allocator,
    };
}

/// Scales a glyph's font-unit advance width to PDF's fixed 1000-unit glyph
/// space (`advance_width * 1000 / unitsPerEm`), guarding two ways a
/// malformed/untrusted font can otherwise crash this (I10):
/// - `upm == 0` would divide by zero -- treated as an unscalable glyph (0)
///   rather than panicking.
/// - A small-but-nonzero upm combined with a large advance_width can produce
///   a scaled value that overflows u16 (max advance_width 65535 * 1000 /
///   minimum legal upm 16 ≈ 4.1M) -- clamped to u16's range instead of
///   truncating (which would otherwise panic on the `@intCast`).
fn scaleAdvanceToPdfWidth(advance_width: u16, upm: u16) u16 {
    if (upm == 0) return 0;
    const scaled: u32 = @as(u32, advance_width) * 1000 / @as(u32, upm);
    return @intCast(@min(scaled, std.math.maxInt(u16)));
}

pub fn getGlyphWidths(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
) ![]GlyphWidth {
    var widths: std.ArrayList(GlyphWidth) = .empty;
    defer widths.deinit(allocator);

    const upm = font.getUnitsPerEm();

    for (codepoints) |cp| {
        const glyph_id = font.getGlyphId(@intCast(cp)) catch continue;
        const metrics = font.getHMetrics(glyph_id) catch continue;
        const width_1000: u16 = scaleAdvanceToPdfWidth(metrics.advance_width, upm);
        try widths.append(allocator, .{
            .codepoint = cp,
            .glyph_id = glyph_id,
            .width = width_1000,
        });
    }

    return try widths.toOwnedSlice(allocator);
}

pub fn buildCidToGidMap(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    codepoints: []const u21,
    glyph_mapping: ?[]const u16,
) ![]u8 {
    var max_cp: u21 = 0;
    for (codepoints) |cp| {
        if (cp <= 0xFFFF and cp > max_cp) max_cp = cp;
    }
    const map_size: usize = (@as(usize, max_cp) + 1) * 2;
    const map = try allocator.alloc(u8, map_size);
    @memset(map, 0);

    for (codepoints) |cp| {
        if (cp > 0xFFFF) continue;
        const old_id = font.getGlyphId(@intCast(cp)) catch continue;
        const new_id = if (glyph_mapping) |m| (if (old_id < m.len) m[old_id] else 0) else old_id;
        const offset: usize = @as(usize, cp) * 2;
        std.mem.writeInt(u16, map[offset..][0..2], new_id, .big);
    }

    return map;
}

test "getPdfFontInfo from DejaVuSans" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var info = try getPdfFontInfo(std.testing.allocator, font);
    defer info.deinit();

    try std.testing.expect(info.postscript_name.len > 0);
    try std.testing.expect(info.units_per_em == 2048);
    try std.testing.expect(info.ascent > 0);
    try std.testing.expect(info.descent < 0);
    try std.testing.expect(info.cap_height > 0);
    try std.testing.expect(info.stem_v > 0);
    try std.testing.expect(info.flags & 32 != 0);
}

test "getGlyphWidths" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const codepoints = [_]u21{ 'H', 'e', 'l', 'o' };
    const widths = try getGlyphWidths(std.testing.allocator, font, &codepoints);
    defer std.testing.allocator.free(widths);

    try std.testing.expectEqual(@as(usize, 4), widths.len);
    for (widths) |w| {
        try std.testing.expect(w.width > 0);
        try std.testing.expect(w.glyph_id != 0);
    }
}

test "scaleAdvanceToPdfWidth: upm=0 returns 0 instead of dividing by zero (I10)" {
    try std.testing.expectEqual(@as(u16, 0), scaleAdvanceToPdfWidth(500, 0));
    try std.testing.expectEqual(@as(u16, 0), scaleAdvanceToPdfWidth(65535, 0));
}

test "scaleAdvanceToPdfWidth: large advance + small upm clamps instead of overflowing u16 (I10)" {
    // 65535 * 1000 / 16 ≈ 4,095,937 -- vastly exceeds u16's range.
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), scaleAdvanceToPdfWidth(65535, 16));
}

test "scaleAdvanceToPdfWidth: normal values unchanged by the fix" {
    // 500 * 1000 / 1000 == 500 (unitsPerEm=1000, a common convention).
    try std.testing.expectEqual(@as(u16, 500), scaleAdvanceToPdfWidth(500, 1000));
    // 1024 * 1000 / 2048 == 500 (unitsPerEm=2048, DejaVuSans's convention).
    try std.testing.expectEqual(@as(u16, 500), scaleAdvanceToPdfWidth(1024, 2048));
}

test "buildCidToGidMap" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const codepoints = [_]u21{ 'A', 'B' };
    const map = try buildCidToGidMap(std.testing.allocator, font, &codepoints, null);
    defer std.testing.allocator.free(map);

    const a_gid = std.mem.readInt(u16, map[0x41 * 2 ..][0..2], .big);
    try std.testing.expect(a_gid != 0);
}
