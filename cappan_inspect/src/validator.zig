const std = @import("std");
const cappan_core = @import("cappan_core");

const Font = cappan_core.font.Font;
const parser = cappan_core.font.parser;
const err_mod = cappan_core.err;

/// Validate font table consistency. Returns a Diagnostics object.
pub fn validate(allocator: std.mem.Allocator, font: Font) !err_mod.Diagnostics {
    var diag: err_mod.Diagnostics = .{};
    errdefer diag.deinit(allocator);

    // Check 1: head.units_per_em in range [16, 16384]
    const upm = font.head.units_per_em;
    if (upm < 16 or upm > 16384) {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "units_per_em={d} is outside recommended range [16, 16384]", .{upm});
        try diag.addWarning(allocator, .{ .table_tag = "head".* }, msg);
    }

    // Check 2: head.index_to_loc_format is 0 or 1
    const loc_fmt = font.head.index_to_loc_format;
    if (loc_fmt != 0 and loc_fmt != 1) {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "index_to_loc_format={d} is invalid; must be 0 or 1", .{loc_fmt});
        try diag.addError(allocator, .{ .table_tag = "head".* }, msg);
    }

    // Check 3: loca last offset <= glyf table size
    if (font.loca) |loca| {
        if (parser.findTable(font.offset_table, "glyf".*)) |glyf_rec| {
            const glyf_len = glyf_rec.length;
            if (loca.num_glyphs > 0) {
                if (loca.getGlyphLocation(loca.num_glyphs - 1)) |loc| {
                    const last_offset = loc.offset + loc.length;
                    if (last_offset > glyf_len) {
                        var buf: [192]u8 = undefined;
                        const msg = try std.fmt.bufPrint(&buf, "loca last offset={d} exceeds glyf table size={d}", .{ last_offset, glyf_len });
                        try diag.addError(allocator, .{ .table_tag = "loca".* }, msg);
                    }
                } else |_| {}
            }
        }
    }

    // Check 4: hmtx entry count vs hhea.number_of_h_metrics
    {
        const expected = font.hhea.number_of_h_metrics;
        const hmtx_data_len = font.hmtx.data.len;
        const min_needed = @as(usize, expected) * 4;
        if (hmtx_data_len < min_needed) {
            var buf: [192]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "hmtx table too small: need {d} bytes for {d} hMetrics, got {d}", .{ min_needed, expected, hmtx_data_len });
            try diag.addError(allocator, .{ .table_tag = "hmtx".* }, msg);
        }
    }

    // Check 5: cmap returns glyph ID < maxp.num_glyphs for 'A' (U+0041)
    {
        const glyph_id = font.cmap.charToGlyphId(0x0041) catch 0;
        if (glyph_id >= font.maxp.num_glyphs) {
            var buf: [192]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "cmap('A') returned glyph_id={d} which >= num_glyphs={d}", .{ glyph_id, font.maxp.num_glyphs });
            try diag.addError(allocator, .{ .table_tag = "cmap".* }, msg);
        }
    }

    return diag;
}

test "validate DejaVuSans has no errors" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var result = try validate(std.testing.allocator, font);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}
