const std = @import("std");
const cappan_core = @import("cappan_core");

pub const GlyphInfo = struct {
    glyph_id: u16,
    codepoint: ?u32,
    advance_width: u16,
    lsb: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    contour_count: u16,
    point_count: u16,
    is_compound: bool,
    has_outline: bool,
};

pub fn getGlyphInfo(allocator: std.mem.Allocator, font: cappan_core.font.Font, glyph_id: u16, codepoint: ?u32) !GlyphInfo {
    // Get horizontal metrics
    const HMetrics = cappan_core.font.table.hmtx.HMetrics;
    const metrics: HMetrics = font.getHMetrics(glyph_id) catch .{ .advance_width = 0, .lsb = 0 };

    var is_compound = false;
    var raw_x_min: i16 = 0;
    var raw_y_min: i16 = 0;
    var raw_x_max: i16 = 0;
    var raw_y_max: i16 = 0;
    var has_outline = false;

    if (font.glyf) |glyf| {
        if (font.loca) |loca| {
            const header = glyf.getGlyphHeader(glyph_id, loca);
            has_outline = header.has_outline;
            is_compound = header.number_of_contours < 0;
            raw_x_min = header.x_min;
            raw_y_min = header.y_min;
            raw_x_max = header.x_max;
            raw_y_max = header.y_max;
        }
    }

    var contour_count: u16 = 0;
    var point_count: u16 = 0;
    if (font.getGlyphOutline(allocator, glyph_id)) |outline_opt| {
        if (outline_opt) |outline_val| {
            var outline = outline_val;
            defer outline.deinit();
            contour_count = @intCast(outline.contours.len);
            for (outline.contours) |contour| {
                point_count += @intCast(contour.points.len);
            }
            if (!has_outline) {
                raw_x_min = outline.x_min;
                raw_y_min = outline.y_min;
                raw_x_max = outline.x_max;
                raw_y_max = outline.y_max;
                has_outline = true;
            }
        }
    } else |_| {}

    return GlyphInfo{
        .glyph_id = glyph_id,
        .codepoint = codepoint,
        .advance_width = metrics.advance_width,
        .lsb = metrics.lsb,
        .x_min = raw_x_min,
        .y_min = raw_y_min,
        .x_max = raw_x_max,
        .y_max = raw_y_max,
        .contour_count = contour_count,
        .point_count = point_count,
        .is_compound = is_compound,
        .has_outline = has_outline,
    };
}

test "getGlyphInfo for ASCII A" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId(0x0041); // 'A'
    const info = try getGlyphInfo(std.testing.allocator, font, glyph_id, 0x0041);

    try std.testing.expect(info.glyph_id == glyph_id);
    try std.testing.expect(info.codepoint.? == 0x0041);
    try std.testing.expect(info.advance_width > 0);
    try std.testing.expect(info.has_outline);
    try std.testing.expect(info.contour_count > 0);
    try std.testing.expect(info.point_count > 0);
    try std.testing.expect(!info.is_compound);
}
