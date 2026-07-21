const std = @import("std");
const cappan_core = @import("cappan_core");
const parser = cappan_core.font.parser;
const os2_mod = cappan_core.font.table.os2;

pub const FontComparison = struct {
    /// x-height ratio (font_b.x_height / font_a.x_height)
    x_height_ratio: f32,
    /// average char width ratio (font_b.avg_width / font_a.avg_width)
    avg_width_ratio: f32,
    /// Recommended size-adjust value (%): CSS size-adjust to match font_b to font_a
    /// = (font_a.avg_width / font_b.avg_width) * 100
    size_adjust: f32,

    // Individual metrics (for debugging/display)
    font_a_x_height: f32,
    font_b_x_height: f32,
    font_a_avg_width: f32,
    font_b_avg_width: f32,
};

/// Get x-height normalized by unitsPerEm (returns 0.0-1.0 range approximately)
fn getXHeight(allocator: std.mem.Allocator, font: cappan_core.font.Font) f32 {
    const units_per_em = @as(f32, @floatFromInt(font.head.units_per_em));

    // Try OS/2 sXHeight
    if (parser.findTable(font.offset_table, "OS/2".*)) |record| {
        if (parser.getTableData(font.data, record)) |data| {
            if (os2_mod.parse(data)) |os2| {
                if (os2.sx_height != 0) {
                    return @as(f32, @floatFromInt(os2.sx_height)) / units_per_em;
                }
            } else |_| {}
        } else |_| {}
    }

    // Try to get 'x' (U+0078) glyph outline
    if (font.getGlyphId(0x0078)) |glyph_id| {
        if (font.getGlyphOutline(allocator, glyph_id)) |maybe_outline| {
            if (maybe_outline) |outline| {
                var mut_outline = outline;
                defer mut_outline.deinit();
                const y_max = @as(f32, @floatFromInt(outline.y_max));
                return y_max / units_per_em;
            }
        } else |_| {}
    } else |_| {}

    // Fallback: estimate as ascender * 0.5
    const ascender = @as(f32, @floatFromInt(font.hhea.ascender));
    return (ascender * 0.5) / units_per_em;
}

/// Get average character width normalized by unitsPerEm
fn getAvgWidth(font: cappan_core.font.Font) f32 {
    const units_per_em = @as(f32, @floatFromInt(font.head.units_per_em));

    // Try OS/2 xAvgCharWidth
    if (parser.findTable(font.offset_table, "OS/2".*)) |record| {
        if (parser.getTableData(font.data, record)) |data| {
            if (os2_mod.parse(data)) |os2| {
                if (os2.avg_char_width != 0) {
                    return @as(f32, @floatFromInt(os2.avg_char_width)) / units_per_em;
                }
            } else |_| {}
        } else |_| {}
    }

    // Fallback: average advance width of 'a'-'z'
    var total: f32 = 0.0;
    var count: u32 = 0;
    var cp: u32 = 'a';
    while (cp <= 'z') : (cp += 1) {
        const glyph_id = font.getGlyphId(cp) catch continue;
        const hmetrics = font.getHMetrics(glyph_id) catch continue;
        total += @as(f32, @floatFromInt(hmetrics.advance_width));
        count += 1;
    }

    if (count == 0) {
        // Ultimate fallback: use ascender as proxy
        return @as(f32, @floatFromInt(font.hhea.ascender)) / units_per_em * 0.5;
    }

    return (total / @as(f32, @floatFromInt(count))) / units_per_em;
}

/// Compare metrics of two fonts to calculate size-adjust for font substitution.
/// font_a: reference font (the desired font)
/// font_b: fallback font (the actually used font)
pub fn compareFonts(allocator: std.mem.Allocator, font_a: cappan_core.font.Font, font_b: cappan_core.font.Font) FontComparison {
    const a_x_height = getXHeight(allocator, font_a);
    const b_x_height = getXHeight(allocator, font_b);
    const a_avg_width = getAvgWidth(font_a);
    const b_avg_width = getAvgWidth(font_b);

    const x_height_ratio = if (a_x_height != 0.0) b_x_height / a_x_height else 1.0;
    const avg_width_ratio = if (a_avg_width != 0.0) b_avg_width / a_avg_width else 1.0;
    const size_adjust = if (b_avg_width != 0.0) (a_avg_width / b_avg_width) * 100.0 else 100.0;

    return .{
        .x_height_ratio = x_height_ratio,
        .avg_width_ratio = avg_width_ratio,
        .size_adjust = size_adjust,
        .font_a_x_height = a_x_height,
        .font_b_x_height = b_x_height,
        .font_a_avg_width = a_avg_width,
        .font_b_avg_width = b_avg_width,
    };
}

test "compareFonts same font" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font_a = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font_a.deinit();
    var font_b = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font_b.deinit();

    const cmp = compareFonts(std.testing.allocator, font_a, font_b);

    // Same font should have ratio ~1.0 and size_adjust ~100.0
    try std.testing.expect(cmp.x_height_ratio > 0.99);
    try std.testing.expect(cmp.x_height_ratio < 1.01);
    try std.testing.expect(cmp.avg_width_ratio > 0.99);
    try std.testing.expect(cmp.avg_width_ratio < 1.01);
    try std.testing.expect(cmp.size_adjust > 99.0);
    try std.testing.expect(cmp.size_adjust < 101.0);
}
