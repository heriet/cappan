const std = @import("std");
const cappan_core = @import("cappan_core");
const parser = cappan_core.font.parser;

pub const MetricsSource = enum {
    os2_typo,
    os2_win,
    hhea,
};

pub const CssFontMetrics = struct {
    /// ascent-override (percentage, e.g. 105.0 means "105%")
    ascent_override: f32,
    /// descent-override (percentage, positive value, e.g. 25.0 means "25%")
    descent_override: f32,
    /// line-gap-override (percentage)
    line_gap_override: f32,
    /// Source of metrics values
    source: MetricsSource,
};

/// CSS @font-face 用の metrics override 値を計算
/// OS/2 テーブルがある場合は OS/2 の値を優先、なければ hhea を使用
/// 値は unitsPerEm に対する百分率（%）
pub fn getCssFontMetrics(font: cappan_core.font.Font) CssFontMetrics {
    const units_per_em = @as(f32, @floatFromInt(font.head.units_per_em));

    // Try to find and parse the OS/2 table
    if (parser.findTable(font.offset_table, "OS/2".*)) |record| {
        if (parser.getTableData(font.data, record)) |data| {
            if (data.len >= 78) {
                const typo_ascender = parser.readI16(data, 68) catch 0;
                const typo_descender = parser.readI16(data, 70) catch 0;
                const typo_line_gap = parser.readI16(data, 72) catch 0;

                if (typo_ascender != 0) {
                    // Use sTypo values
                    return .{
                        .ascent_override = @as(f32, @floatFromInt(typo_ascender)) / units_per_em * 100.0,
                        .descent_override = @abs(@as(f32, @floatFromInt(typo_descender)) / units_per_em * 100.0),
                        .line_gap_override = @as(f32, @floatFromInt(typo_line_gap)) / units_per_em * 100.0,
                        .source = .os2_typo,
                    };
                }

                // sTypoAscender == 0: fallback to usWinAscent/usWinDescent
                const win_ascent = parser.readU16(data, 74) catch 0;
                const win_descent = parser.readU16(data, 76) catch 0;

                return .{
                    .ascent_override = @as(f32, @floatFromInt(win_ascent)) / units_per_em * 100.0,
                    .descent_override = @as(f32, @floatFromInt(win_descent)) / units_per_em * 100.0,
                    .line_gap_override = 0.0,
                    .source = .os2_win,
                };
            }
        } else |_| {}
    }

    // Fallback to hhea values
    const ascender = @as(f32, @floatFromInt(font.hhea.ascender));
    const descender = @as(f32, @floatFromInt(font.hhea.descender));
    const line_gap = @as(f32, @floatFromInt(font.hhea.line_gap));

    return .{
        .ascent_override = ascender / units_per_em * 100.0,
        .descent_override = @abs(descender / units_per_em * 100.0),
        .line_gap_override = line_gap / units_per_em * 100.0,
        .source = .hhea,
    };
}

test "getCssFontMetrics from DejaVuSans" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const metrics = getCssFontMetrics(font);

    // DejaVuSans has OS/2 table with sTypo values
    // sTypoAscender=1556, unitsPerEm=2048 => ~76%
    try std.testing.expect(metrics.ascent_override > 50.0);
    try std.testing.expect(metrics.ascent_override < 120.0);
    try std.testing.expect(metrics.descent_override > 10.0);
    try std.testing.expect(metrics.descent_override < 50.0);
    try std.testing.expect(metrics.line_gap_override >= 0.0);
}
