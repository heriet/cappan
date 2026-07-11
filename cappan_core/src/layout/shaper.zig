const std = @import("std");
const font_mod = @import("../font/font.zig");
const gdef_mod = @import("../font/table/gdef.zig");
const ft = @import("../features.zig").features;

pub const GlyphPosition = struct {
    glyph_id: u16,
    font_index: u8,
    codepoint: u21,
    x_offset: f32,
    y_offset: f32,
    pixel_size: f32 = 48.0,
};

pub const TextAlign = enum { left, center, right, justify };

pub const LayoutOptions = struct {
    pixel_size: f32 = 48.0,
    max_width: ?f32 = null,
    text_align: TextAlign = .left,
    vertical: bool = false,
};

pub const StyledSpan = struct {
    text: []const u8,
    pixel_size: f32,
    font_index: u8 = 0,
};

pub const StyledLayoutOptions = struct {
    max_width: ?f32 = null,
    text_align: TextAlign = .left,
    vertical: bool = false,
};

pub const TextLayout = struct {
    positions: []GlyphPosition,
    total_width: f32,
    total_height: f32,
    ascender_px: f32,
    descender_px: f32,
    line_height: f32,
    num_lines: u32,
    vertical: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TextLayout) void {
        self.allocator.free(self.positions);
    }
};

fn processCodepointInner(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    codepoint: u21,
    pixel_size: f32,
    line_height: f32,
    positions: *std.ArrayList(GlyphPosition),
    cursor_x: *f32,
    prev_glyph_id: *?u16,
    prev_font_index: *?u8,
    current_line: *u32,
    max_width: *f32,
) !void {
    if (codepoint == '\n') {
        if (cursor_x.* > max_width.*) max_width.* = cursor_x.*;
        cursor_x.* = 0;
        prev_glyph_id.* = null;
        prev_font_index.* = null;
        current_line.* += 1;
        return;
    }

    var glyph_id: u16 = 0;
    var font_index: u8 = 0;
    for (fonts, 0..) |f, i| {
        const id = f.getGlyphId(@as(u32, codepoint)) catch 0;
        if (id != 0) {
            glyph_id = id;
            font_index = @intCast(i);
            break;
        }
    }

    if (prev_glyph_id.*) |prev_id| {
        if (prev_font_index.*) |prev_fi| {
            if (prev_fi == font_index) {
                const kern_value = fonts[font_index].getKerning(prev_id, glyph_id);
                const kern_scale = pixel_size / @as(f32, @floatFromInt(fonts[font_index].getUnitsPerEm()));
                cursor_x.* += @as(f32, @floatFromInt(kern_value)) * kern_scale;
            }
        }
    }

    try positions.append(allocator, .{
        .glyph_id = glyph_id,
        .font_index = font_index,
        .codepoint = codepoint,
        .x_offset = cursor_x.*,
        .y_offset = @as(f32, @floatFromInt(current_line.*)) * line_height,
        .pixel_size = pixel_size,
    });

    const font_scale = pixel_size / @as(f32, @floatFromInt(fonts[font_index].getUnitsPerEm()));
    const metrics = fonts[font_index].getHMetrics(glyph_id) catch {
        prev_glyph_id.* = glyph_id;
        prev_font_index.* = font_index;
        return;
    };
    cursor_x.* += @as(f32, @floatFromInt(metrics.advance_width)) * font_scale;
    prev_glyph_id.* = glyph_id;
    prev_font_index.* = font_index;
}

pub fn layoutText(allocator: std.mem.Allocator, fonts: []const font_mod.Font, text: []const u8, options: LayoutOptions) !TextLayout {
    if (comptime ft.enable_vertical) {
        if (options.vertical) {
            return layoutTextVertical(allocator, fonts, text, options);
        }
    }

    const scale = options.pixel_size / @as(f32, @floatFromInt(fonts[0].getUnitsPerEm()));
    const ascender_px = @as(f32, @floatFromInt(fonts[0].getAscender())) * scale;
    const descender_px = @as(f32, @floatFromInt(fonts[0].getDescender())) * scale;
    const line_gap_px = @as(f32, @floatFromInt(fonts[0].getLineGap())) * scale;
    const line_height = ascender_px - descender_px + line_gap_px;

    var positions: std.ArrayList(GlyphPosition) = .empty;
    errdefer positions.deinit(allocator);

    var cursor_x: f32 = 0;
    var prev_glyph_id: ?u16 = null;
    var prev_font_index: ?u8 = null;
    var current_line: u32 = 0;
    var max_width: f32 = 0;

    if (std.unicode.Utf8View.init(text)) |view| {
        var iter = view.iterator();
        while (iter.nextCodepoint()) |codepoint| {
            try processCodepointInner(allocator, fonts, codepoint, options.pixel_size, line_height, &positions, &cursor_x, &prev_glyph_id, &prev_font_index, &current_line, &max_width);
        }
    } else |_| {
        for (text) |byte| {
            try processCodepointInner(allocator, fonts, @as(u21, byte), options.pixel_size, line_height, &positions, &cursor_x, &prev_glyph_id, &prev_font_index, &current_line, &max_width);
        }
    }

    if (cursor_x > max_width) max_width = cursor_x;
    const num_lines = current_line + 1;

    const result = try positions.toOwnedSlice(allocator);

    applyGposPositioning(result, fonts);

    var num_lines_var = num_lines;
    var max_width_var = max_width;

    if (options.max_width) |max_w| {
        applyWordWrap(result, fonts, max_w, line_height, &max_width_var, &num_lines_var);
    }

    if (options.text_align != .left) {
        const effective_width = options.max_width orelse max_width_var;
        applyAlignment(result, options.text_align, effective_width, fonts);
        if (effective_width > max_width_var) max_width_var = effective_width;
    }

    const total_height = @as(f32, @floatFromInt(num_lines_var)) * line_height;
    return .{
        .positions = result,
        .total_width = max_width_var,
        .total_height = total_height,
        .ascender_px = ascender_px,
        .descender_px = descender_px,
        .line_height = line_height,
        .num_lines = num_lines_var,
        .vertical = false,
        .allocator = allocator,
    };
}

fn processVerticalCodepoint(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    codepoint: u21,
    pixel_size: f32,
    max_width: ?f32,
    ascender_px: f32,
    descender_px: f32,
    positions: *std.ArrayList(GlyphPosition),
    columns: *std.ArrayList(u32),
    advances: *std.ArrayList(f32),
    current_column: *u32,
    pen_y: *f32,
    max_column_height: *f32,
    prev_glyph_id: *?u16,
    prev_font_index: *?u8,
) !void {
    _ = ascender_px;
    if (codepoint == '\n') {
        if (pen_y.* > max_column_height.*) max_column_height.* = pen_y.*;
        current_column.* += 1;
        pen_y.* = 0;
        prev_glyph_id.* = null;
        prev_font_index.* = null;
        return;
    }

    var glyph_id: u16 = 0;
    var font_index: u8 = 0;
    for (fonts, 0..) |f, i| {
        const id = f.getGlyphId(@as(u32, codepoint)) catch 0;
        if (id != 0) {
            glyph_id = id;
            font_index = @intCast(i);
            break;
        }
    }

    glyph_id = fonts[font_index].substituteVerticalGlyph(glyph_id);

    const font_scale = pixel_size / @as(f32, @floatFromInt(fonts[font_index].getUnitsPerEm()));
    const vm = fonts[font_index].getVMetrics(glyph_id) catch null;
    const fallback_advance_units = @as(i32, fonts[font_index].getAscender()) - @as(i32, fonts[font_index].getDescender());
    const advance_h_units: f32 = if (vm) |m|
        @floatFromInt(m.advance_height)
    else
        @floatFromInt(fallback_advance_units);
    const advance_h_px = advance_h_units * font_scale;

    const h_metrics = fonts[font_index].getHMetrics(glyph_id) catch null;
    const advance_w_px: f32 = if (h_metrics) |m|
        @as(f32, @floatFromInt(m.advance_width)) * font_scale
    else
        pixel_size;

    if (max_width) |max_h| {
        if (pen_y.* > 0 and pen_y.* + advance_h_px > max_h) {
            if (pen_y.* > max_column_height.*) max_column_height.* = pen_y.*;
            current_column.* += 1;
            pen_y.* = 0;
            prev_glyph_id.* = null;
            prev_font_index.* = null;
        }
    }

    if (prev_glyph_id.*) |pid| {
        if (prev_font_index.*) |pfi| {
            if (pfi == font_index) {
                const kv = fonts[font_index].getVerticalKerning(pid, glyph_id);
                // GPOS yAdvance is positive upward in font coordinates; pen_y is positive downward.
                pen_y.* -= @as(f32, @floatFromInt(kv)) * font_scale;
            }
        }
    }

    const vert_origin_px: f32 = if (fonts[font_index].getVertOriginY(glyph_id)) |vy|
        @as(f32, @floatFromInt(vy)) * font_scale
    else
        @as(f32, @floatFromInt(fonts[font_index].getAscender())) * font_scale;

    try columns.append(allocator, current_column.*);
    try advances.append(allocator, advance_h_px);
    try positions.append(allocator, .{
        .glyph_id = glyph_id,
        .font_index = font_index,
        .codepoint = codepoint,
        .x_offset = advance_w_px,
        .y_offset = pen_y.* + vert_origin_px,
        .pixel_size = pixel_size,
    });

    pen_y.* += advance_h_px;
    const column_extent = pen_y.* + @max(0.0, -descender_px);
    if (column_extent > max_column_height.*) max_column_height.* = column_extent;
    prev_glyph_id.* = glyph_id;
    prev_font_index.* = font_index;
}

fn layoutTextVertical(allocator: std.mem.Allocator, fonts: []const font_mod.Font, text: []const u8, options: LayoutOptions) !TextLayout {
    const scale = options.pixel_size / @as(f32, @floatFromInt(fonts[0].getUnitsPerEm()));
    const ascender_px = @as(f32, @floatFromInt(fonts[0].getAscender())) * scale;
    const descender_px = @as(f32, @floatFromInt(fonts[0].getDescender())) * scale;
    const line_gap_px = @as(f32, @floatFromInt(fonts[0].getLineGap())) * scale;
    const line_height = ascender_px - descender_px + line_gap_px;
    const column_width = line_height;

    var positions: std.ArrayList(GlyphPosition) = .empty;
    errdefer positions.deinit(allocator);
    var columns: std.ArrayList(u32) = .empty;
    defer columns.deinit(allocator);
    var advances: std.ArrayList(f32) = .empty;
    defer advances.deinit(allocator);

    var current_column: u32 = 0;
    var pen_y: f32 = 0;
    var max_column_height: f32 = 0;
    var prev_glyph_id: ?u16 = null;
    var prev_font_index: ?u8 = null;

    if (std.unicode.Utf8View.init(text)) |view| {
        var iter = view.iterator();
        while (iter.nextCodepoint()) |codepoint| {
            try processVerticalCodepoint(allocator, fonts, codepoint, options.pixel_size, options.max_width, ascender_px, descender_px, &positions, &columns, &advances, &current_column, &pen_y, &max_column_height, &prev_glyph_id, &prev_font_index);
        }
    } else |_| {
        for (text) |byte| {
            try processVerticalCodepoint(allocator, fonts, @as(u21, byte), options.pixel_size, options.max_width, ascender_px, descender_px, &positions, &columns, &advances, &current_column, &pen_y, &max_column_height, &prev_glyph_id, &prev_font_index);
        }
    }

    if (pen_y > max_column_height) max_column_height = pen_y;
    const num_columns = if (positions.items.len == 0) @as(u32, 0) else current_column + 1;
    const total_width = @as(f32, @floatFromInt(num_columns)) * column_width;
    var total_height = max_column_height;
    if (options.max_width) |max_h| {
        if (max_h > total_height) total_height = max_h;
    }

    for (positions.items, columns.items) |*pos, column| {
        const column_center_x = total_width - (@as(f32, @floatFromInt(column)) + 0.5) * column_width;
        pos.x_offset = column_center_x - pos.x_offset / 2.0;
    }

    if (options.text_align != .left and total_height > 0) {
        try applyVerticalAlignment(allocator, positions.items, columns.items, advances.items, options.text_align, total_height, ascender_px, num_columns);
    }

    const result = try positions.toOwnedSlice(allocator);
    return .{
        .positions = result,
        .total_width = total_width,
        .total_height = total_height,
        .ascender_px = ascender_px,
        .descender_px = descender_px,
        .line_height = line_height,
        .num_lines = num_columns,
        .vertical = true,
        .allocator = allocator,
    };
}

pub fn layoutStyledText(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    spans: []const StyledSpan,
    options: StyledLayoutOptions,
) !TextLayout {
    if (spans.len == 0) {
        return .{
            .positions = try allocator.alloc(GlyphPosition, 0),
            .total_width = 0,
            .total_height = 0,
            .ascender_px = 0,
            .descender_px = 0,
            .line_height = 0,
            .num_lines = 0,
            .vertical = false,
            .allocator = allocator,
        };
    }

    if (comptime ft.enable_vertical) {
        if (options.vertical) {
            return layoutStyledTextVertical(allocator, fonts, spans, options);
        }
    }

    // Compute line metrics as max ascender, min descender, max line_gap across all spans.
    var max_ascender_px: f32 = 0;
    var min_descender_px: f32 = 0;
    var max_line_gap_px: f32 = 0;
    for (spans) |span| {
        const fi = @min(@as(usize, span.font_index), fonts.len - 1);
        const scale = span.pixel_size / @as(f32, @floatFromInt(fonts[fi].getUnitsPerEm()));
        const asc = @as(f32, @floatFromInt(fonts[fi].getAscender())) * scale;
        const desc = @as(f32, @floatFromInt(fonts[fi].getDescender())) * scale;
        const gap = @as(f32, @floatFromInt(fonts[fi].getLineGap())) * scale;
        if (asc > max_ascender_px) max_ascender_px = asc;
        if (desc < min_descender_px) min_descender_px = desc;
        if (gap > max_line_gap_px) max_line_gap_px = gap;
    }
    const line_height = max_ascender_px - min_descender_px + max_line_gap_px;

    var positions: std.ArrayList(GlyphPosition) = .empty;
    errdefer positions.deinit(allocator);

    var cursor_x: f32 = 0;
    var prev_glyph_id: ?u16 = null;
    var prev_font_index: ?u8 = null;
    var current_line: u32 = 0;
    var max_width: f32 = 0;

    for (spans) |span| {
        const primary_fi = @min(@as(usize, span.font_index), fonts.len - 1);

        // Build a reordered font slice: primary font first, then others for fallback.
        // We use the full fonts array but check primary_fi first.
        if (std.unicode.Utf8View.init(span.text)) |view| {
            var iter = view.iterator();
            while (iter.nextCodepoint()) |codepoint| {
                if (codepoint == '\n') {
                    if (cursor_x > max_width) max_width = cursor_x;
                    cursor_x = 0;
                    prev_glyph_id = null;
                    prev_font_index = null;
                    current_line += 1;
                    continue;
                }

                // Find glyph: try primary font first, then fallback.
                var glyph_id: u16 = 0;
                var actual_fi: u8 = @intCast(primary_fi);
                const primary_id = fonts[primary_fi].getGlyphId(@as(u32, codepoint)) catch 0;
                if (primary_id != 0) {
                    glyph_id = primary_id;
                } else {
                    for (fonts, 0..) |f, idx| {
                        if (idx == primary_fi) continue;
                        const id = f.getGlyphId(@as(u32, codepoint)) catch 0;
                        if (id != 0) {
                            glyph_id = id;
                            actual_fi = @intCast(idx);
                            break;
                        }
                    }
                }

                // Apply kerning if same font as previous glyph.
                if (prev_glyph_id) |prev_id| {
                    if (prev_font_index) |prev_fii| {
                        if (prev_fii == actual_fi) {
                            const kern_value = fonts[actual_fi].getKerning(prev_id, glyph_id);
                            const kern_scale = span.pixel_size / @as(f32, @floatFromInt(fonts[actual_fi].getUnitsPerEm()));
                            cursor_x += @as(f32, @floatFromInt(kern_value)) * kern_scale;
                        }
                    }
                }

                try positions.append(allocator, .{
                    .glyph_id = glyph_id,
                    .font_index = actual_fi,
                    .codepoint = codepoint,
                    .x_offset = cursor_x,
                    .y_offset = @as(f32, @floatFromInt(current_line)) * line_height,
                    .pixel_size = span.pixel_size,
                });

                const font_scale = span.pixel_size / @as(f32, @floatFromInt(fonts[actual_fi].getUnitsPerEm()));
                const metrics = fonts[actual_fi].getHMetrics(glyph_id) catch {
                    prev_glyph_id = glyph_id;
                    prev_font_index = actual_fi;
                    continue;
                };
                cursor_x += @as(f32, @floatFromInt(metrics.advance_width)) * font_scale;
                prev_glyph_id = glyph_id;
                prev_font_index = actual_fi;
            }
        } else |_| {
            for (span.text) |byte| {
                const codepoint: u21 = @as(u21, byte);
                if (codepoint == '\n') {
                    if (cursor_x > max_width) max_width = cursor_x;
                    cursor_x = 0;
                    prev_glyph_id = null;
                    prev_font_index = null;
                    current_line += 1;
                    continue;
                }

                var glyph_id: u16 = 0;
                var actual_fi: u8 = @intCast(primary_fi);
                const primary_id = fonts[primary_fi].getGlyphId(@as(u32, codepoint)) catch 0;
                if (primary_id != 0) {
                    glyph_id = primary_id;
                } else {
                    for (fonts, 0..) |f, idx| {
                        if (idx == primary_fi) continue;
                        const id = f.getGlyphId(@as(u32, codepoint)) catch 0;
                        if (id != 0) {
                            glyph_id = id;
                            actual_fi = @intCast(idx);
                            break;
                        }
                    }
                }

                if (prev_glyph_id) |prev_id| {
                    if (prev_font_index) |prev_fii| {
                        if (prev_fii == actual_fi) {
                            const kern_value = fonts[actual_fi].getKerning(prev_id, glyph_id);
                            const kern_scale = span.pixel_size / @as(f32, @floatFromInt(fonts[actual_fi].getUnitsPerEm()));
                            cursor_x += @as(f32, @floatFromInt(kern_value)) * kern_scale;
                        }
                    }
                }

                try positions.append(allocator, .{
                    .glyph_id = glyph_id,
                    .font_index = actual_fi,
                    .codepoint = codepoint,
                    .x_offset = cursor_x,
                    .y_offset = @as(f32, @floatFromInt(current_line)) * line_height,
                    .pixel_size = span.pixel_size,
                });

                const font_scale = span.pixel_size / @as(f32, @floatFromInt(fonts[actual_fi].getUnitsPerEm()));
                const metrics = fonts[actual_fi].getHMetrics(glyph_id) catch {
                    prev_glyph_id = glyph_id;
                    prev_font_index = actual_fi;
                    continue;
                };
                cursor_x += @as(f32, @floatFromInt(metrics.advance_width)) * font_scale;
                prev_glyph_id = glyph_id;
                prev_font_index = actual_fi;
            }
        }
    }

    if (cursor_x > max_width) max_width = cursor_x;
    const num_lines = current_line + 1;

    const result = try positions.toOwnedSlice(allocator);

    applyGposPositioning(result, fonts);

    var num_lines_var = num_lines;
    var max_width_var = max_width;

    if (options.max_width) |max_w| {
        applyWordWrap(result, fonts, max_w, line_height, &max_width_var, &num_lines_var);
    }

    if (options.text_align != .left) {
        const effective_width = options.max_width orelse max_width_var;
        applyAlignment(result, options.text_align, effective_width, fonts);
        if (effective_width > max_width_var) max_width_var = effective_width;
    }

    const total_height = @as(f32, @floatFromInt(num_lines_var)) * line_height;
    return .{
        .positions = result,
        .total_width = max_width_var,
        .total_height = total_height,
        .ascender_px = max_ascender_px,
        .descender_px = min_descender_px,
        .line_height = line_height,
        .num_lines = num_lines_var,
        .vertical = false,
        .allocator = allocator,
    };
}

fn layoutStyledTextVertical(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    spans: []const StyledSpan,
    options: StyledLayoutOptions,
) !TextLayout {
    var max_ascender_px: f32 = 0;
    var min_descender_px: f32 = 0;
    var max_line_gap_px: f32 = 0;
    for (spans) |span| {
        const fi = @min(@as(usize, span.font_index), fonts.len - 1);
        const scale = span.pixel_size / @as(f32, @floatFromInt(fonts[fi].getUnitsPerEm()));
        const asc = @as(f32, @floatFromInt(fonts[fi].getAscender())) * scale;
        const desc = @as(f32, @floatFromInt(fonts[fi].getDescender())) * scale;
        const gap = @as(f32, @floatFromInt(fonts[fi].getLineGap())) * scale;
        if (asc > max_ascender_px) max_ascender_px = asc;
        if (desc < min_descender_px) min_descender_px = desc;
        if (gap > max_line_gap_px) max_line_gap_px = gap;
    }
    const line_height = max_ascender_px - min_descender_px + max_line_gap_px;
    const column_width = line_height;

    var positions: std.ArrayList(GlyphPosition) = .empty;
    errdefer positions.deinit(allocator);
    var columns: std.ArrayList(u32) = .empty;
    defer columns.deinit(allocator);
    var advances: std.ArrayList(f32) = .empty;
    defer advances.deinit(allocator);

    var current_column: u32 = 0;
    var pen_y: f32 = 0;
    var max_column_height: f32 = 0;
    var prev_glyph_id: ?u16 = null;
    var prev_font_index: ?u8 = null;

    for (spans) |span| {
        if (std.unicode.Utf8View.init(span.text)) |view| {
            var iter = view.iterator();
            while (iter.nextCodepoint()) |codepoint| {
                try processVerticalCodepoint(allocator, fonts, codepoint, span.pixel_size, options.max_width, max_ascender_px, min_descender_px, &positions, &columns, &advances, &current_column, &pen_y, &max_column_height, &prev_glyph_id, &prev_font_index);
            }
        } else |_| {
            for (span.text) |byte| {
                try processVerticalCodepoint(allocator, fonts, @as(u21, byte), span.pixel_size, options.max_width, max_ascender_px, min_descender_px, &positions, &columns, &advances, &current_column, &pen_y, &max_column_height, &prev_glyph_id, &prev_font_index);
            }
        }
    }

    if (pen_y > max_column_height) max_column_height = pen_y;
    const num_columns = if (positions.items.len == 0) @as(u32, 0) else current_column + 1;
    const total_width = @as(f32, @floatFromInt(num_columns)) * column_width;
    var total_height = max_column_height;
    if (options.max_width) |max_h| {
        if (max_h > total_height) total_height = max_h;
    }

    for (positions.items, columns.items) |*pos, column| {
        const column_center_x = total_width - (@as(f32, @floatFromInt(column)) + 0.5) * column_width;
        pos.x_offset = column_center_x - pos.x_offset / 2.0;
    }

    if (options.text_align != .left and total_height > 0) {
        try applyVerticalAlignment(allocator, positions.items, columns.items, advances.items, options.text_align, total_height, max_ascender_px, num_columns);
    }

    const result = try positions.toOwnedSlice(allocator);
    return .{
        .positions = result,
        .total_width = total_width,
        .total_height = total_height,
        .ascender_px = max_ascender_px,
        .descender_px = min_descender_px,
        .line_height = line_height,
        .num_lines = num_columns,
        .vertical = true,
        .allocator = allocator,
    };
}

fn applyVerticalAlignment(
    allocator: std.mem.Allocator,
    positions: []GlyphPosition,
    columns: []const u32,
    advances: []const f32,
    align_type: TextAlign,
    container_height: f32,
    ascender_px: f32,
    num_columns: u32,
) !void {
    if (positions.len == 0 or num_columns == 0) return;

    const count = @as(usize, num_columns);
    var column_heights = try allocator.alloc(f32, count);
    defer allocator.free(column_heights);
    var glyph_counts = try allocator.alloc(u32, count);
    defer allocator.free(glyph_counts);
    @memset(column_heights, 0);
    @memset(glyph_counts, 0);

    for (positions, columns, advances) |pos, column, advance| {
        const idx = @as(usize, @intCast(column));
        if (idx >= count) continue;
        const cell_top = pos.y_offset - ascender_px;
        const extent = cell_top + advance;
        if (extent > column_heights[idx]) column_heights[idx] = extent;
        glyph_counts[idx] += 1;
    }

    var ordinals = try allocator.alloc(u32, count);
    defer allocator.free(ordinals);
    @memset(ordinals, 0);

    for (positions, columns) |*pos, column| {
        const idx = @as(usize, @intCast(column));
        if (idx >= count) continue;
        const extra = @max(0.0, container_height - column_heights[idx]);
        const ordinal = ordinals[idx];
        ordinals[idx] += 1;

        const shift = switch (align_type) {
            .left => 0,
            .center => extra / 2.0,
            .right => extra,
            .justify => blk: {
                if (glyph_counts[idx] <= 1) break :blk 0;
                break :blk extra * @as(f32, @floatFromInt(ordinal)) / @as(f32, @floatFromInt(glyph_counts[idx] - 1));
            },
        };
        pos.y_offset += shift;
    }
}

fn applyGposPositioning(positions: []GlyphPosition, fonts: []const font_mod.Font) void {
    if (comptime !ft.enable_opentype_layout) return;
    for (positions, 0..) |*pos, i| {
        const font = &fonts[pos.font_index];
        const gdef = font.getGdefTable() orelse continue;

        if (gdef.getGlyphClass(pos.glyph_id) != .mark) continue;

        // Mark-to-Mark (Type 6): attach to preceding mark
        if (i > 0) {
            const prev = positions[i - 1];
            if (prev.font_index == pos.font_index and
                @abs(prev.y_offset - pos.y_offset) < 0.1)
            {
                const prev_class = gdef.getGlyphClass(prev.glyph_id);
                if (prev_class == .mark) {
                    if (font.getMarkMarkAnchors(prev.glyph_id, pos.glyph_id)) |anchors| {
                        const scale = pos.pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
                        pos.x_offset = prev.x_offset + @as(f32, @floatFromInt(anchors.base_x - anchors.mark_x)) * scale;
                        pos.y_offset = prev.y_offset - @as(f32, @floatFromInt(anchors.base_y - anchors.mark_y)) * scale;
                        continue;
                    }
                }
            }
        }

        // Mark-to-Base (Type 4): attach to preceding base glyph
        const max_scan: usize = 64;
        var j: usize = i;
        var scanned: usize = 0;
        while (j > 0 and scanned < max_scan) {
            j -= 1;
            scanned += 1;
            if (positions[j].font_index != pos.font_index) break;
            if (@abs(positions[j].y_offset - pos.y_offset) >= 0.1) break;
            const base_class = gdef.getGlyphClass(positions[j].glyph_id);
            if (base_class == .base or base_class == .ligature) {
                if (font.getMarkBaseAnchors(positions[j].glyph_id, pos.glyph_id)) |anchors| {
                    const scale = pos.pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
                    pos.x_offset = positions[j].x_offset + @as(f32, @floatFromInt(anchors.base_x - anchors.mark_x)) * scale;
                    pos.y_offset = positions[j].y_offset - @as(f32, @floatFromInt(anchors.base_y - anchors.mark_y)) * scale;
                }
                break;
            }
        }
    }
}

fn applyWordWrap(
    positions: []GlyphPosition,
    fonts: []const font_mod.Font,
    max_width: f32,
    line_height: f32,
    total_max_width: *f32,
    num_lines: *u32,
) void {
    if (positions.len == 0) return;

    var line_start_idx: usize = 0;
    var line_start_x: f32 = 0;
    var last_break_idx: ?usize = null;
    var current_line: u32 = 0;
    var i: usize = 0;

    while (i < positions.len) {
        const pos = &positions[i];

        const expected_y = @as(f32, @floatFromInt(current_line)) * line_height;
        if (pos.y_offset > expected_y + 0.1) {
            current_line = @intFromFloat(@round(pos.y_offset / line_height));
            line_start_idx = i;
            line_start_x = pos.x_offset;
            last_break_idx = null;
            i += 1;
            continue;
        }

        if (isBreakable(pos.codepoint)) {
            last_break_idx = i;
        }

        const font_scale = pos.pixel_size / @as(f32, @floatFromInt(fonts[pos.font_index].getUnitsPerEm()));
        const metrics = fonts[pos.font_index].getHMetrics(pos.glyph_id) catch {
            i += 1;
            continue;
        };
        const advance = @as(f32, @floatFromInt(metrics.advance_width)) * font_scale;
        const line_x = pos.x_offset - line_start_x;

        if (line_x + advance > max_width and i > line_start_idx) {
            const break_at: usize = if (last_break_idx) |bi|
                if (bi > line_start_idx) bi + 1 else i
            else
                i;

            current_line += 1;
            const new_y = @as(f32, @floatFromInt(current_line)) * line_height;

            const base_x = positions[break_at].x_offset;
            var j = break_at;
            while (j < positions.len) : (j += 1) {
                if (positions[j].y_offset > expected_y + 0.1) break;
                positions[j].x_offset -= base_x;
                positions[j].y_offset = new_y;
            }

            line_start_idx = break_at;
            line_start_x = 0;
            last_break_idx = null;
            i = break_at;
        } else {
            i += 1;
        }
    }

    total_max_width.* = 0;
    var line_max: f32 = 0;
    var prev_y: f32 = -1.0;
    for (positions) |pos| {
        if (pos.y_offset > prev_y + 0.1) {
            if (line_max > total_max_width.*) total_max_width.* = line_max;
            line_max = 0;
            prev_y = pos.y_offset;
        }
        const font_scale = pos.pixel_size / @as(f32, @floatFromInt(fonts[pos.font_index].getUnitsPerEm()));
        const adv = @as(f32, @floatFromInt((fonts[pos.font_index].getHMetrics(pos.glyph_id) catch continue).advance_width)) * font_scale;
        line_max = pos.x_offset + adv;
    }
    if (line_max > total_max_width.*) total_max_width.* = line_max;
    num_lines.* = current_line + 1;
}

fn isBreakable(codepoint: u21) bool {
    if (codepoint == ' ' or codepoint == '\t') return true;
    if (codepoint >= 0x4E00 and codepoint <= 0x9FFF) return true;
    if (codepoint >= 0x3400 and codepoint <= 0x4DBF) return true;
    if (codepoint >= 0xF900 and codepoint <= 0xFAFF) return true;
    if (codepoint >= 0xFF00 and codepoint <= 0xFFEF) return true;
    if (codepoint >= 0x3040 and codepoint <= 0x30FF) return true;
    return false;
}

fn applyAlignment(
    positions: []GlyphPosition,
    align_type: TextAlign,
    container_width: f32,
    fonts: []const font_mod.Font,
) void {
    if (positions.len == 0) return;

    var line_start: usize = 0;
    var prev_y: f32 = positions[0].y_offset;

    var i: usize = 0;
    while (i <= positions.len) : (i += 1) {
        const at_end = (i == positions.len);
        const new_line = !at_end and (positions[i].y_offset > prev_y + 0.1);

        if (new_line or at_end) {
            alignLine(positions[line_start..i], align_type, container_width, fonts);
            if (!at_end) {
                line_start = i;
                prev_y = positions[i].y_offset;
            }
        }
    }
}

fn alignLine(
    positions: []GlyphPosition,
    align_type: TextAlign,
    container_width: f32,
    fonts: []const font_mod.Font,
) void {
    if (positions.len == 0) return;
    const last = positions[positions.len - 1];
    const font_scale = last.pixel_size / @as(f32, @floatFromInt(fonts[last.font_index].getUnitsPerEm()));
    const last_advance = @as(f32, @floatFromInt((fonts[last.font_index].getHMetrics(last.glyph_id) catch return).advance_width)) * font_scale;
    const line_width = last.x_offset + last_advance - positions[0].x_offset;
    const offset = switch (align_type) {
        .center => (container_width - line_width) / 2.0,
        .right => container_width - line_width,
        .left, .justify => 0,
    };
    if (align_type != .justify) {
        if (offset <= 0) return;
        for (positions) |*pos| {
            pos.x_offset += offset;
        }
        return;
    }
    // justify: distribute extra space evenly between glyphs
    if (positions.len <= 1) return;
    if (line_width >= container_width) return;
    const extra_space = container_width - line_width;
    const gap = extra_space / @as(f32, @floatFromInt(positions.len - 1));
    for (positions, 0..) |*pos, i| {
        pos.x_offset += gap * @as(f32, @floatFromInt(i));
    }
}

test "layout text Hello" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "Hello", .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 5), layout.positions.len);
    try std.testing.expect(layout.total_width > 0);
    try std.testing.expect(layout.total_height > 0);
    try std.testing.expectEqual(@as(u32, 1), layout.num_lines);
    try std.testing.expect(layout.positions[1].x_offset > layout.positions[0].x_offset);
}

test "layout text multiline Hello\\nWorld" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "Hello\nWorld", .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 10), layout.positions.len);
    try std.testing.expectEqual(@as(u32, 2), layout.num_lines);
    try std.testing.expect(layout.positions[5].y_offset > 0);
    for (layout.positions[0..5]) |pos| {
        try std.testing.expectEqual(@as(f32, 0), pos.y_offset);
    }
}

test "layout text UTF-8 café" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "caf\xC3\xA9", .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 4), layout.positions.len);
    try std.testing.expect(layout.total_width > 0);
}

test "layout text UTF-8 naïve" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "na\xC3\xAFve", .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 5), layout.positions.len);
    try std.testing.expect(layout.total_width > 0);
}

test "layout invalid UTF-8 does not crash" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const invalid_utf8 = &[_]u8{ 0xFF, 0xFE };
    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, invalid_utf8, .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions.len);
}

test "layout text center alignment" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();
    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 48.0,
        .max_width = 500.0,
        .text_align = .center,
    });
    defer layout.deinit();
    try std.testing.expect(layout.positions[0].x_offset > 0);
}

test "layout text right alignment" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();
    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 48.0,
        .max_width = 500.0,
        .text_align = .right,
    });
    defer layout.deinit();
    try std.testing.expect(layout.positions[0].x_offset > 100);
}

test "layout text justify alignment" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();
    const max_width: f32 = 500.0;
    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 48.0,
        .max_width = max_width,
        .text_align = .justify,
    });
    defer layout.deinit();
    // first glyph should stay near x=0
    try std.testing.expectApproxEqAbs(@as(f32, 0), layout.positions[0].x_offset, 1.0);
    // last glyph's right edge should be near max_width
    const last = layout.positions[layout.positions.len - 1];
    const font_scale = last.pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    const last_advance = @as(f32, @floatFromInt((try font.getHMetrics(last.glyph_id)).advance_width)) * font_scale;
    const last_right = last.x_offset + last_advance;
    try std.testing.expectApproxEqAbs(max_width, last_right, 1.0);
}

test "layout text word wrap" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();
    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "Hello World", .{
        .pixel_size = 48.0,
        .max_width = 150.0,
    });
    defer layout.deinit();
    try std.testing.expect(layout.num_lines > 1);
    var found_second_line = false;
    for (layout.positions) |pos| {
        if (pos.y_offset > 0) {
            found_second_line = true;
            try std.testing.expect(pos.x_offset < 10.0);
            break;
        }
    }
    try std.testing.expect(found_second_line);
}

test "layoutStyledText mixed sizes" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const spans = [_]StyledSpan{
        .{ .text = "Big ", .pixel_size = 48.0 },
        .{ .text = "small", .pixel_size = 24.0 },
    };

    var layout = try layoutStyledText(
        std.testing.allocator,
        &[_]font_mod.Font{font},
        &spans,
        .{},
    );
    defer layout.deinit();

    // "Big " = 4 chars, "small" = 5 chars = 9 total
    try std.testing.expectEqual(@as(usize, 9), layout.positions.len);
    try std.testing.expect(layout.total_width > 0);
    // All on one line
    try std.testing.expectEqual(@as(u32, 1), layout.num_lines);
}

test "vertical layout stacks glyphs downward" {
    if (comptime !ft.enable_vertical) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "AB", .{ .pixel_size = 48.0, .vertical = true });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions.len);
    try std.testing.expect(layout.positions[1].y_offset > layout.positions[0].y_offset);
    try std.testing.expect(layout.total_height > 0);
    try std.testing.expect(layout.vertical);
}

test "vertical layout columns go right to left" {
    if (comptime !ft.enable_vertical) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "A\nB", .{ .pixel_size = 48.0, .vertical = true });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions.len);
    try std.testing.expect(layout.positions[1].x_offset < layout.positions[0].x_offset);
    try std.testing.expectEqual(@as(u32, 2), layout.num_lines);
}

test "vertical layout without vmtx does not crash" {
    if (comptime !ft.enable_vertical) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "A", .{ .pixel_size = 48.0, .vertical = true });
    defer layout.deinit();

    try std.testing.expect(layout.total_height > 0);
}

test "vertical styled layout stacks glyphs downward" {
    if (comptime !ft.enable_vertical) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const spans = [_]StyledSpan{
        .{ .text = "Big ", .pixel_size = 48.0 },
        .{ .text = "small", .pixel_size = 24.0 },
    };
    var layout = try layoutStyledText(std.testing.allocator, &[_]font_mod.Font{font}, &spans, .{ .vertical = true });
    defer layout.deinit();

    try std.testing.expect(layout.vertical);
    try std.testing.expect(layout.positions[1].y_offset > layout.positions[0].y_offset);
    try std.testing.expect(layout.total_height > 0);
    try std.testing.expectEqual(@as(f32, 48.0), layout.positions[0].pixel_size);
    try std.testing.expectEqual(@as(f32, 24.0), layout.positions[4].pixel_size);
}

test "vertical styled layout columns right to left" {
    if (comptime !ft.enable_vertical) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const spans = [_]StyledSpan{
        .{ .text = "AB\nCD", .pixel_size = 48.0 },
    };
    var layout = try layoutStyledText(std.testing.allocator, &[_]font_mod.Font{font}, &spans, .{ .vertical = true });
    defer layout.deinit();

    try std.testing.expect(layout.vertical);
    try std.testing.expectEqual(@as(usize, 4), layout.positions.len);
    try std.testing.expect(layout.positions[2].x_offset < layout.positions[0].x_offset);
    try std.testing.expectEqual(@as(u32, 2), layout.num_lines);
}
