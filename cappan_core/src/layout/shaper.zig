const std = @import("std");
const font_mod = @import("../font/font.zig");
const gdef_mod = @import("../font/table/gdef.zig");
const gpos_mod = @import("../font/table/gpos.zig");
const ft = @import("../features.zig").features;

pub const GlyphPosition = struct {
    glyph_id: u16,
    font_index: u8,
    codepoint: u21,
    x_offset: f32,
    y_offset: f32,
    pixel_size: f32 = 48.0,
    line: u32 = 0,
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

    pub fn baseBaselineY(self: TextLayout, pad: f32) f32 {
        return if (self.vertical) pad else pad + self.ascender_px;
    }
};

const GlyphResolution = struct {
    glyph_id: u16,
    font_index: u8,
};

/// `preferred_font_index`, when given, is tried first (mirroring the fallback
/// order `layoutStyledText`'s inline resolution already uses for horizontal
/// styled spans -- see `StyledSpan.font_index`); pass `null` for the
/// unstyled/no-preference path, which just tries fonts in array order.
fn resolveGlyph(fonts: []const font_mod.Font, codepoint: u21, preferred_font_index: ?u8) GlyphResolution {
    if (preferred_font_index) |pfi| {
        const idx: usize = @min(@as(usize, pfi), fonts.len - 1);
        const id = fonts[idx].getGlyphId(@as(u32, codepoint)) catch 0;
        if (id != 0) {
            return .{ .glyph_id = id, .font_index = @intCast(idx) };
        }
    }
    for (fonts, 0..) |f, i| {
        if (preferred_font_index != null and i == @min(@as(usize, preferred_font_index.?), fonts.len - 1)) continue;
        const id = f.getGlyphId(@as(u32, codepoint)) catch 0;
        if (id != 0) {
            return .{ .glyph_id = id, .font_index = @intCast(i) };
        }
    }
    return .{ .glyph_id = 0, .font_index = 0 };
}

const SpanLineMetrics = struct {
    max_ascender_px: f32,
    min_descender_px: f32,
    max_line_gap_px: f32,
};

fn computeSpanLineMetrics(fonts: []const font_mod.Font, spans: []const StyledSpan) SpanLineMetrics {
    var metrics: SpanLineMetrics = .{
        .max_ascender_px = 0,
        .min_descender_px = 0,
        .max_line_gap_px = 0,
    };
    for (spans) |span| {
        const fi = @min(@as(usize, span.font_index), fonts.len - 1);
        const scale = span.pixel_size / @as(f32, @floatFromInt(fonts[fi].getUnitsPerEm()));
        const asc = @as(f32, @floatFromInt(fonts[fi].getAscender())) * scale;
        const desc = @as(f32, @floatFromInt(fonts[fi].getDescender())) * scale;
        const gap = @as(f32, @floatFromInt(fonts[fi].getLineGap())) * scale;
        if (asc > metrics.max_ascender_px) metrics.max_ascender_px = asc;
        if (desc < metrics.min_descender_px) metrics.min_descender_px = desc;
        if (gap > metrics.max_line_gap_px) metrics.max_line_gap_px = gap;
    }
    return metrics;
}

const VerticalLayoutState = struct {
    positions: std.ArrayList(GlyphPosition) = .empty,
    columns: std.ArrayList(u32) = .empty,
    advances: std.ArrayList(f32) = .empty,
    widths: std.ArrayList(f32) = .empty,
    current_column: u32 = 0,
    pen_y: f32 = 0,
    max_column_height: f32 = 0,
    prev_glyph_id: ?u16 = null,
    prev_font_index: ?u8 = null,
    substituters: if (ft.enable_vertical and ft.enable_opentype_layout) []?font_mod.VerticalSubstituter else void,

    fn init(allocator: std.mem.Allocator, fonts_len: usize) !VerticalLayoutState {
        if (comptime ft.enable_vertical and ft.enable_opentype_layout) {
            const substituters = try allocator.alloc(?font_mod.VerticalSubstituter, fonts_len);
            @memset(substituters, null);
            return .{ .substituters = substituters };
        }
        return .{ .substituters = {} };
    }

    fn deinit(self: *VerticalLayoutState, allocator: std.mem.Allocator) void {
        self.columns.deinit(allocator);
        self.advances.deinit(allocator);
        self.widths.deinit(allocator);
        if (comptime ft.enable_vertical and ft.enable_opentype_layout) {
            for (self.substituters) |substituter| {
                if (substituter) |s| s.deinit();
            }
            allocator.free(self.substituters);
        }
    }

    fn substituteVerticalGlyph(self: *VerticalLayoutState, allocator: std.mem.Allocator, font: *const font_mod.Font, font_index: u8, glyph_id: u16) u16 {
        if (comptime !ft.enable_vertical or !ft.enable_opentype_layout) return glyph_id;
        const idx = @as(usize, font_index);
        if (self.substituters[idx] == null) {
            self.substituters[idx] = font_mod.VerticalSubstituter.init(allocator, font);
        }
        return self.substituters[idx].?.substitute(glyph_id);
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

    const resolved = resolveGlyph(fonts, codepoint, null);
    const glyph_id = resolved.glyph_id;
    const font_index = resolved.font_index;

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
        .line = current_line.*,
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

    return finishHorizontalLayout(allocator, result, fonts, options.max_width, options.text_align, max_width, num_lines, line_height, ascender_px, descender_px);
}

/// Applies word-wrap and alignment (mirroring the layout options), then GPOS mark/cursive
/// attachment, to an already-shaped horizontal glyph run, and builds the resulting
/// `TextLayout`. Shared tail of `layoutText` and `layoutStyledText`; symmetric with
/// `finishVerticalLayout` for the vertical path.
///
/// GPOS runs *after* wrap+alignment (not before, as this used to do) so marks anchor to
/// each base glyph's *final* x/y_offset: justify redistributing space no longer strands a
/// mark at its pre-justify offset (I4a), and word-wrap establishing a base's final line/y
/// no longer runs after the mark has already been positioned against a stale y (I4b). This
/// also makes `applyGposPositioning`'s same-line check (`pos.line`) *more* correct, not
/// less: wrap re-stamps `.line` to the final physical line, so by the time GPOS reads it,
/// a base/mark pair that wrap split across two lines is correctly seen as different lines.
fn finishHorizontalLayout(
    allocator: std.mem.Allocator,
    result: []GlyphPosition,
    fonts: []const font_mod.Font,
    max_width: ?f32,
    text_align: TextAlign,
    computed_max_width: f32,
    num_lines: u32,
    line_height: f32,
    ascender_px: f32,
    descender_px: f32,
) !TextLayout {
    var num_lines_var = num_lines;
    var max_width_var = computed_max_width;

    if (max_width) |max_w| {
        try applyWordWrap(allocator, result, fonts, max_w, line_height, &max_width_var, &num_lines_var);
    }

    if (text_align != .left) {
        const effective_width = max_width orelse max_width_var;
        applyAlignment(result, text_align, effective_width, fonts);
        if (effective_width > max_width_var) max_width_var = effective_width;
    }

    applyGposPositioning(result, fonts, false);

    // I6: (re-)derive total_width from the actual final (post-GPOS, post-wrap,
    // post-alignment) glyph extents rather than trusting the pre-GPOS estimate --
    // a trailing zero-advance mark can sit narrower *or* wider than the last
    // non-mark glyph's own extent once GPOS has anchored it. `@max` with the
    // existing value preserves the wrap-constraint/justify-stretch floor.
    max_width_var = computeMaxLineExtent(result, fonts, max_width_var);

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

/// Running-max line-content-width scan over final glyph positions, grouped by
/// `.line`. Used both by `applyWordWrap`'s own (pre-GPOS) estimate and by
/// `finishHorizontalLayout`'s post-GPOS refinement (I6) -- see call sites for
/// why both exist. `floor` seeds the result (e.g. a justify-stretched
/// container width that must never be reported as narrower than intended).
fn computeMaxLineExtent(positions: []const GlyphPosition, fonts: []const font_mod.Font, floor: f32) f32 {
    var result = floor;
    var line_max: f32 = 0;
    var prev_line: ?u32 = null;
    for (positions) |pos| {
        if (prev_line == null or pos.line != prev_line.?) {
            if (line_max > result) result = line_max;
            line_max = 0;
            prev_line = pos.line;
        }
        const font_scale = pos.pixel_size / @as(f32, @floatFromInt(fonts[pos.font_index].getUnitsPerEm()));
        const adv = @as(f32, @floatFromInt((fonts[pos.font_index].getHMetrics(pos.glyph_id) catch continue).advance_width)) * font_scale;
        const extent = pos.x_offset + adv;
        if (extent > line_max) line_max = extent;
    }
    if (line_max > result) result = line_max;
    return result;
}

fn processVerticalCodepoint(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    codepoint: u21,
    pixel_size: f32,
    max_width: ?f32,
    descender_px: f32,
    state: *VerticalLayoutState,
    preferred_font_index: ?u8,
) !void {
    if (codepoint == '\n') {
        if (state.pen_y > state.max_column_height) state.max_column_height = state.pen_y;
        state.current_column += 1;
        state.pen_y = 0;
        state.prev_glyph_id = null;
        state.prev_font_index = null;
        return;
    }

    const resolved = resolveGlyph(fonts, codepoint, preferred_font_index);
    var glyph_id = resolved.glyph_id;
    const font_index = resolved.font_index;
    glyph_id = state.substituteVerticalGlyph(allocator, &fonts[font_index], font_index, glyph_id);

    const font_scale = pixel_size / @as(f32, @floatFromInt(fonts[font_index].getUnitsPerEm()));
    const vm = fonts[font_index].getVMetrics(glyph_id) catch null;
    const advance_h_units: f32 = if (vm) |m|
        @floatFromInt(m.advance_height)
    else blk: {
        const fallback_advance_units = @as(i32, fonts[font_index].getAscender()) - @as(i32, fonts[font_index].getDescender());
        break :blk @floatFromInt(fallback_advance_units);
    };
    var advance_h_px = advance_h_units * font_scale;
    // Combining marks must not advance the pen. When vmtx is present we trust it (marks
    // normally carry 0 advance_height there, mirroring horizontal's trust of hmtx). When vmtx
    // is absent, the fallback above is ~1em, which would push the following glyph a full em
    // down; zero it for GDEF mark-class glyphs so the mark stays on its base.
    if (comptime ft.enable_opentype_layout) {
        if (vm == null) {
            if (fonts[font_index].getGdefTable()) |gdef| {
                if (gdef.getGlyphClass(glyph_id) == .mark) advance_h_px = 0;
            }
        }
    }

    const h_metrics = fonts[font_index].getHMetrics(glyph_id) catch null;
    const advance_w_px: f32 = if (h_metrics) |m|
        @as(f32, @floatFromInt(m.advance_width)) * font_scale
    else
        pixel_size;

    if (max_width) |max_h| {
        if (state.pen_y > 0 and state.pen_y + advance_h_px > max_h) {
            if (state.pen_y > state.max_column_height) state.max_column_height = state.pen_y;
            state.current_column += 1;
            state.pen_y = 0;
            state.prev_glyph_id = null;
            state.prev_font_index = null;
        }
    }

    if (state.prev_glyph_id) |pid| {
        if (state.prev_font_index) |pfi| {
            if (pfi == font_index) {
                const kv = fonts[font_index].getVerticalKerning(pid, glyph_id);
                // GPOS yAdvance is positive upward in font coordinates; pen_y is positive downward.
                state.pen_y -= @as(f32, @floatFromInt(kv)) * font_scale;
            }
        }
    }

    const vert_origin_px: f32 = if (fonts[font_index].getVertOriginY(glyph_id)) |vy|
        @as(f32, @floatFromInt(vy)) * font_scale
    else
        @as(f32, @floatFromInt(fonts[font_index].getAscender())) * font_scale;

    try state.columns.append(allocator, state.current_column);
    try state.advances.append(allocator, advance_h_px);
    try state.widths.append(allocator, advance_w_px);
    try state.positions.append(allocator, .{
        .glyph_id = glyph_id,
        .font_index = font_index,
        .codepoint = codepoint,
        .x_offset = 0,
        .y_offset = state.pen_y + vert_origin_px,
        .pixel_size = pixel_size,
        .line = state.current_column,
    });

    state.pen_y += advance_h_px;
    const column_extent = state.pen_y + @max(0.0, -descender_px);
    if (column_extent > state.max_column_height) state.max_column_height = column_extent;
    state.prev_glyph_id = glyph_id;
    state.prev_font_index = font_index;
}

fn layoutTextVertical(allocator: std.mem.Allocator, fonts: []const font_mod.Font, text: []const u8, options: LayoutOptions) !TextLayout {
    const scale = options.pixel_size / @as(f32, @floatFromInt(fonts[0].getUnitsPerEm()));
    const ascender_px = @as(f32, @floatFromInt(fonts[0].getAscender())) * scale;
    const descender_px = @as(f32, @floatFromInt(fonts[0].getDescender())) * scale;
    const line_gap_px = @as(f32, @floatFromInt(fonts[0].getLineGap())) * scale;
    const line_height = ascender_px - descender_px + line_gap_px;
    const column_width = line_height;

    var state = try VerticalLayoutState.init(allocator, fonts.len);
    errdefer state.positions.deinit(allocator);
    defer state.deinit(allocator);

    if (std.unicode.Utf8View.init(text)) |view| {
        var iter = view.iterator();
        while (iter.nextCodepoint()) |codepoint| {
            try processVerticalCodepoint(allocator, fonts, codepoint, options.pixel_size, options.max_width, descender_px, &state, null);
        }
    } else |_| {
        for (text) |byte| {
            try processVerticalCodepoint(allocator, fonts, @as(u21, byte), options.pixel_size, options.max_width, descender_px, &state, null);
        }
    }

    return finishVerticalLayout(allocator, fonts, &state, column_width, options.max_width, options.text_align, ascender_px, descender_px, line_height);
}

fn finishVerticalLayout(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    state: *VerticalLayoutState,
    column_width: f32,
    max_width: ?f32,
    text_align: TextAlign,
    ascender_px: f32,
    descender_px: f32,
    line_height: f32,
) !TextLayout {
    if (state.pen_y > state.max_column_height) state.max_column_height = state.pen_y;
    const num_columns = if (state.positions.items.len == 0) @as(u32, 0) else state.current_column + 1;
    const total_width = @as(f32, @floatFromInt(num_columns)) * column_width;
    var total_height = state.max_column_height;
    if (max_width) |max_h| {
        if (max_h > total_height) total_height = max_h;
    }

    for (state.positions.items, state.columns.items, state.widths.items) |*pos, column, width| {
        const column_center_x = total_width - (@as(f32, @floatFromInt(column)) + 0.5) * column_width;
        pos.x_offset = column_center_x - width / 2.0;
    }

    if (text_align != .left and total_height > 0) {
        try applyVerticalAlignment(allocator, state.positions.items, state.columns.items, state.advances.items, text_align, total_height, ascender_px, num_columns);
    }

    // GPOS mark attachment (Mark-to-Base / Mark-to-Mark / Mark-to-Ligature) for vertical.
    // applyMarkAnchor operates purely on x_offset/y_offset, whose device semantics are identical
    // in both writing modes. Must run AFTER x_offset is finalized above and after vertical
    // alignment, because it reads each base's final x_offset/y_offset. GlyphPosition.line here is
    // the column index, so same-line checks become same-column checks. Cursive is skipped in
    // vertical (horizontal-only semantics); self-gates on enable_opentype_layout.
    applyGposPositioning(state.positions.items, fonts, true);

    const result = try state.positions.toOwnedSlice(allocator);
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

    const span_metrics = computeSpanLineMetrics(fonts, spans);
    const max_ascender_px = span_metrics.max_ascender_px;
    const min_descender_px = span_metrics.min_descender_px;
    const max_line_gap_px = span_metrics.max_line_gap_px;
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
                    .line = current_line,
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
                    .line = current_line,
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

    return finishHorizontalLayout(allocator, result, fonts, options.max_width, options.text_align, max_width, num_lines, line_height, max_ascender_px, min_descender_px);
}

fn layoutStyledTextVertical(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    spans: []const StyledSpan,
    options: StyledLayoutOptions,
) !TextLayout {
    const span_metrics = computeSpanLineMetrics(fonts, spans);
    const max_ascender_px = span_metrics.max_ascender_px;
    const min_descender_px = span_metrics.min_descender_px;
    const max_line_gap_px = span_metrics.max_line_gap_px;
    const line_height = max_ascender_px - min_descender_px + max_line_gap_px;
    const column_width = line_height;

    var state = try VerticalLayoutState.init(allocator, fonts.len);
    errdefer state.positions.deinit(allocator);
    defer state.deinit(allocator);

    for (spans) |span| {
        // Mirrors horizontal `layoutStyledText`'s primary-font-first resolution
        // (I5): previously this always resolved through `resolveGlyph`'s
        // array-order fallback, silently ignoring `span.font_index`.
        const preferred_font_index: ?u8 = @intCast(@min(@as(usize, span.font_index), fonts.len - 1));
        if (std.unicode.Utf8View.init(span.text)) |view| {
            var iter = view.iterator();
            while (iter.nextCodepoint()) |codepoint| {
                try processVerticalCodepoint(allocator, fonts, codepoint, span.pixel_size, options.max_width, min_descender_px, &state, preferred_font_index);
            }
        } else |_| {
            for (span.text) |byte| {
                try processVerticalCodepoint(allocator, fonts, @as(u21, byte), span.pixel_size, options.max_width, min_descender_px, &state, preferred_font_index);
            }
        }
    }

    return finishVerticalLayout(allocator, fonts, &state, column_width, options.max_width, options.text_align, max_ascender_px, min_descender_px, line_height);
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

fn applyGposPositioning(positions: []GlyphPosition, fonts: []const font_mod.Font, vertical: bool) void {
    if (comptime !ft.enable_opentype_layout) return;
    // Cursive attachment first: it can shift base-glyph y_offset, which the
    // mark attachment pass below depends on. Skipped in vertical mode: this
    // codebase's cursive attachment is a horizontal-only, LTR-baseline-chain
    // semantic and would misapply as an unintended intra-column y cascade.
    if (!vertical) applyCursiveAttachment(positions, fonts);
    for (positions, 0..) |*pos, i| {
        const font = &fonts[pos.font_index];
        const gdef = font.getGdefTable() orelse continue;

        if (gdef.getGlyphClass(pos.glyph_id) != .mark) continue;

        // Mark-to-Mark (Type 6): attach to preceding mark
        if (i > 0) {
            const prev = positions[i - 1];
            if (prev.font_index == pos.font_index and
                prev.line == pos.line)
            {
                const prev_class = gdef.getGlyphClass(prev.glyph_id);
                if (prev_class == .mark) {
                    if (font.getMarkMarkAnchors(prev.glyph_id, pos.glyph_id)) |anchors| {
                        const scale = pos.pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
                        applyMarkAnchor(pos, prev, anchors, scale);
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
            if (positions[j].line != pos.line) break;
            const base_class = gdef.getGlyphClass(positions[j].glyph_id);
            if (base_class == .base or base_class == .ligature) {
                const anchors: ?gpos_mod.AnchorPair = if (base_class == .ligature) blk: {
                    // Approximate ligature component ownership without GSUB cluster data:
                    // the nth mark after a ligature maps to the nth component.
                    // Known limitation: multiple marks on one component (e.g. shadda + vowel)
                    // mis-map to later components; usually mitigated by the mark-to-mark pass above.
                    const comp: u16 = @intCast(i - j - 1);
                    const lig_anchors = font.getMarkLigAnchors(positions[j].glyph_id, pos.glyph_id, comp) orelse
                        (if (comp != 0) font.getMarkLigAnchors(positions[j].glyph_id, pos.glyph_id, 0) else null);
                    break :blk lig_anchors orelse font.getMarkBaseAnchors(positions[j].glyph_id, pos.glyph_id);
                } else font.getMarkBaseAnchors(positions[j].glyph_id, pos.glyph_id);
                if (anchors) |a| {
                    const scale = pos.pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
                    applyMarkAnchor(pos, positions[j], a, scale);
                }
                break;
            }
        }
    }
}

fn applyMarkAnchor(pos: *GlyphPosition, ref: GlyphPosition, anchors: gpos_mod.AnchorPair, scale: f32) void {
    pos.x_offset = ref.x_offset + @as(f32, @floatFromInt(anchors.base_x - anchors.mark_x)) * scale;
    pos.y_offset = ref.y_offset - @as(f32, @floatFromInt(anchors.base_y - anchors.mark_y)) * scale;
}

/// Cursive attachment (Type 3): shift a glyph's y so its entry anchor
/// meets the previous glyph's exit anchor (same font, same line only).
fn applyCursiveAttachment(positions: []GlyphPosition, fonts: []const font_mod.Font) void {
    var carried_anchors: ?gpos_mod.CursiveAnchors = null;

    for (positions, 0..) |*pos, i| {
        var cur_anchors_for_carry: ?gpos_mod.CursiveAnchors = null;

        attach: {
            if (i == 0) break :attach;
            const prev = &positions[i - 1];
            if (prev.font_index != pos.font_index) break :attach;
            if (prev.line != pos.line) break :attach;
            const font = &fonts[pos.font_index];
            const prev_anchors = carried_anchors orelse (font.getCursiveAnchors(prev.glyph_id) orelse break :attach);
            const cur_anchors = font.getCursiveAnchors(pos.glyph_id) orelse break :attach;
            cur_anchors_for_carry = cur_anchors;
            const exit = prev_anchors.exit orelse break :attach;
            const entry = cur_anchors.entry orelse break :attach;
            const scale = pos.pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
            pos.y_offset = prev.y_offset +
                (@as(f32, @floatFromInt(entry.y)) - @as(f32, @floatFromInt(exit.y))) * scale;
        }
        carried_anchors = cur_anchors_for_carry;
    }
}

fn applyWordWrap(
    allocator: std.mem.Allocator,
    positions: []GlyphPosition,
    fonts: []const font_mod.Font,
    max_width: f32,
    line_height: f32,
    total_max_width: *f32,
    num_lines: *u32,
) !void {
    if (positions.len == 0) return;

    // I3: snapshot each glyph's original (pre-wrap, explicit-`\n`-only) line index
    // before any mutation below. Word-wrap inserts extra physical lines and directly
    // rewrites `pos.line`/`pos.y_offset` to the final physical-line index as it goes; without
    // this snapshot there is no way to tell "just wrap-rebased onto final line N" glyphs
    // apart from "not yet visited, still on original explicit line N" glyphs purely from the
    // live, mutated `.line` field -- exactly the ambiguity that let a wrap-inserted line and
    // a later explicit `\n` line collide onto the same final line index (and same y).
    const raw_lines = try allocator.alloc(u32, positions.len);
    defer allocator.free(raw_lines);
    for (positions, 0..) |p, idx| raw_lines[idx] = p.line;

    var line_start_idx: usize = 0;
    var line_start_x: f32 = 0;
    var last_break_idx: ?usize = null;
    var current_line: u32 = 0;
    var current_raw_line: u32 = 0;
    var i: usize = 0;

    while (i < positions.len) {
        const pos = &positions[i];

        if (raw_lines[i] > current_raw_line) {
            // Crossing into a new explicit-`\n` line: advance the final line
            // counter by the same delta (preserving any blank-line gaps from
            // consecutive newlines) on top of whatever word-wrap has already
            // inserted, so this line's final index never collides with a
            // wrap-inserted one.
            const delta = raw_lines[i] - current_raw_line;
            current_raw_line = raw_lines[i];
            current_line += delta;
            pos.line = current_line;
            pos.y_offset = @as(f32, @floatFromInt(current_line)) * line_height;
            line_start_idx = i;
            line_start_x = pos.x_offset;
            last_break_idx = null;
            i += 1;
            continue;
        }

        // Not a line-boundary glyph: still on `current_line`, but its `.line`/
        // `.y_offset` may be stale (still holding their pre-wrap raw values) if
        // an *earlier* raw line was wrap-split, since only a raw-line's own
        // first glyph (jump branch above) or a wrap-break's rebase loop below
        // actually rewrite these fields -- every other glyph on the line was
        // never touched. Sync unconditionally so every visited position ends
        // up consistent with `current_line`, not just the ones that happened
        // to trigger a branch.
        pos.line = current_line;
        pos.y_offset = @as(f32, @floatFromInt(current_line)) * line_height;

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
                // Stop at the next *explicit* line (by original/raw numbering,
                // immune to the final `.line` field having just been rewritten
                // above) rather than re-deriving it from the live field.
                if (raw_lines[j] != current_raw_line) break;
                positions[j].x_offset -= base_x;
                positions[j].y_offset = new_y;
                positions[j].line = current_line;
            }

            line_start_idx = break_at;
            line_start_x = 0;
            last_break_idx = null;
            i = break_at;
        } else {
            i += 1;
        }
    }

    // I6: running max per line (not "last glyph wins"), so a trailing
    // zero-advance mark whose anchor sits left of the preceding base's own
    // right edge doesn't shrink the measured line width.
    total_max_width.* = computeMaxLineExtent(positions, fonts, 0);
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
    var prev_line: u32 = positions[0].line;

    var i: usize = 0;
    while (i <= positions.len) : (i += 1) {
        const at_end = (i == positions.len);
        const new_line = !at_end and (positions[i].line != prev_line);

        if (new_line or at_end) {
            alignLine(positions[line_start..i], align_type, container_width, fonts);
            if (!at_end) {
                line_start = i;
                prev_line = positions[i].line;
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
    // justify: distribute extra space evenly between glyphs. Gaps go only at
    // *advancing* boundaries (glyphs whose advance > 0); a zero-advance glyph
    // (a combining mark) belongs to its base's cluster, so it takes the same
    // shift as the base rather than consuming its own gap slot -- otherwise a
    // mark leaves a spurious extra gap after the cluster it sits on. For text
    // with no zero-advance glyphs this reduces exactly to `gap * index`
    // (byte-identical to the pre-fix behavior). Spaces have a real advance, so
    // they still expand as normal justify.
    if (positions.len <= 1) return;
    if (line_width >= container_width) return;

    var advancing: usize = 0;
    for (positions) |pos| {
        if (glyphAdvancesForJustify(pos, fonts)) advancing += 1;
    }
    if (advancing <= 1) return;

    const extra_space = container_width - line_width;
    const gap = extra_space / @as(f32, @floatFromInt(advancing - 1));
    var shift: f32 = 0;
    var advancing_seen: usize = 0;
    for (positions) |*pos| {
        if (glyphAdvancesForJustify(pos.*, fonts)) {
            // Gap before every advancing glyph except the first, so the space
            // lands between clusters, not inside one.
            if (advancing_seen > 0) shift += gap;
            advancing_seen += 1;
        }
        pos.x_offset += shift;
    }
}

/// A glyph counts as an advancing justify boundary when its horizontal advance
/// is nonzero. Zero-advance glyphs (combining marks) ride with their base's
/// cluster instead of taking their own gap slot. Advance is unavailable only
/// on a malformed hmtx read; treat that as advancing (the conservative choice,
/// matching the pre-fix `gap * index` distribution).
fn glyphAdvancesForJustify(pos: GlyphPosition, fonts: []const font_mod.Font) bool {
    const metrics = fonts[pos.font_index].getHMetrics(pos.glyph_id) catch return true;
    return metrics.advance_width > 0;
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

test "line index stamped per line" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "a\nb", .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions.len);
    try std.testing.expectEqual(@as(u32, 0), layout.positions[0].line);
    try std.testing.expectEqual(@as(u32, 1), layout.positions[1].line);
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

test "cursive attachment is no-op without curs lookups" {
    if (comptime !ft.enable_opentype_layout) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "abc", .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.positions.len);
    for (layout.positions) |pos| {
        try std.testing.expectEqual(@as(f32, 0), pos.y_offset);
    }
}

test "mark-to-base still attaches (regression)" {
    if (comptime !ft.enable_opentype_layout) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_e = font.getGlyphId('e') catch return error.SkipZigTest;
    const glyph_acute = font.getGlyphId(0x0301) catch return error.SkipZigTest;
    if (font.getMarkBaseAnchors(glyph_e, glyph_acute) == null) return error.SkipZigTest;

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "e\xCC\x81", .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions.len);
    try std.testing.expect(layout.positions[1].x_offset != 0 or layout.positions[1].y_offset != 0);
}

test "mark-to-ligature attaches to ligature glyph" {
    if (comptime !ft.enable_opentype_layout) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_fi = font.getGlyphId(0xFB01) catch return error.SkipZigTest;
    if (glyph_fi == 0) return error.SkipZigTest;
    const gdef = font.getGdefTable() orelse return error.SkipZigTest;
    if (gdef.getGlyphClass(glyph_fi) != .ligature) return error.SkipZigTest;

    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "\xEF\xAC\x81\xCC\x81", .{ .pixel_size = 48.0 });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions.len);
}

test "vertical mark-to-base attaches at anchor position" {
    if (comptime !ft.enable_vertical or !ft.enable_opentype_layout) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_e = font.getGlyphId('e') catch return error.SkipZigTest;
    const glyph_acute = font.getGlyphId(0x0301) catch return error.SkipZigTest;
    const anchors = font.getMarkBaseAnchors(glyph_e, glyph_acute) orelse return error.SkipZigTest;

    // "e" + U+0301 (combining acute), vertical.
    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "e\xCC\x81", .{ .pixel_size = 48.0, .vertical = true });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions.len);
    try std.testing.expect(layout.vertical);
    // Same column.
    try std.testing.expectEqual(layout.positions[0].line, layout.positions[1].line);
    // The mark must land exactly where the anchor formula puts it, relative to the base's FINAL
    // offsets. Unattached it would sit a full vmtx-fallback advance (~1.17em ≈ 56px) below the
    // base, far outside the tolerance — so this simultaneously proves (a) the GPOS pass ran in
    // vertical mode and (b) the y-sign (font-units up-positive -> device down-positive) is right.
    const scale = 48.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    const expected_x = layout.positions[0].x_offset + @as(f32, @floatFromInt(anchors.base_x - anchors.mark_x)) * scale;
    const expected_y = layout.positions[0].y_offset - @as(f32, @floatFromInt(anchors.base_y - anchors.mark_y)) * scale;
    try std.testing.expectApproxEqAbs(expected_x, layout.positions[1].x_offset, 0.01);
    try std.testing.expectApproxEqAbs(expected_y, layout.positions[1].y_offset, 0.01);
}

test "vertical mark does not advance following glyph" {
    if (comptime !ft.enable_vertical or !ft.enable_opentype_layout) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_acute = font.getGlyphId(0x0301) catch return error.SkipZigTest;
    const gdef = font.getGdefTable() orelse return error.SkipZigTest;
    if (gdef.getGlyphClass(glyph_acute) != .mark) return error.SkipZigTest;

    // "e" + U+0301 + "X": the mark must not push X a full em down.
    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "e\xCC\x81X", .{ .pixel_size = 48.0, .vertical = true });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 3), layout.positions.len);

    // Baseline-to-baseline gap e->X should be about one glyph advance, not two (mark contributes 0).
    // Compare against plain "eX" spacing as reference.
    var ref = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "eX", .{ .pixel_size = 48.0, .vertical = true });
    defer ref.deinit();
    const gap_marked = layout.positions[2].y_offset - layout.positions[0].y_offset;
    const gap_ref = ref.positions[1].y_offset - ref.positions[0].y_offset;
    // With the guard, the marked gap equals the reference gap (mark advance == 0).
    try std.testing.expect(@abs(gap_marked - gap_ref) < 1.0);
}

// --- Fix D probes (findings.md I3/I4/I5/I6) ---

test "word wrap and explicit newline do not collide (I3)" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    // "Hello World\nZig" at max_width=150 must wrap "Hello World" into two
    // lines *and* keep the explicit-newline "Zig" on its own third line --
    // before the fix, wrap's line-renumbering collided with the explicit
    // newline's pre-assigned line index, stacking "World" and "Zig" onto the
    // same y (and undercounting num_lines).
    var layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "Hello World\nZig", .{
        .pixel_size = 48.0,
        .max_width = 150.0,
    });
    defer layout.deinit();

    // "Hello World" (11 chars, incl. the space) + "Zig" (3 chars); '\n' itself
    // does not get a GlyphPosition.
    try std.testing.expectEqual(@as(usize, 14), layout.positions.len);
    try std.testing.expectEqual(@as(u32, 3), layout.num_lines);
    try std.testing.expectApproxEqAbs(@as(f32, 3) * layout.line_height, layout.total_height, 0.01);

    // Every glyph on the same `.line` must share exactly the same y_offset
    // (no collisions), and each distinct line's y must be a distinct
    // multiple of line_height (no overlap).
    var line_ys: [3]?f32 = .{ null, null, null };
    for (layout.positions) |pos| {
        try std.testing.expect(pos.line < 3);
        if (line_ys[pos.line]) |y| {
            try std.testing.expectEqual(y, pos.y_offset);
        } else {
            line_ys[pos.line] = pos.y_offset;
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0) * layout.line_height, line_ys[0].?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1) * layout.line_height, line_ys[1].?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2) * layout.line_height, line_ys[2].?, 0.01);

    // "Zig" (the trailing 3 glyphs) must land on the third (last) line.
    const zig_positions = layout.positions[layout.positions.len - 3 ..];
    for (zig_positions) |pos| {
        try std.testing.expectEqual(@as(u32, 2), pos.line);
    }
}

test "justify preserves mark-to-base relative offset (I4a)" {
    if (comptime !ft.enable_opentype_layout) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_e = font.getGlyphId('e') catch return error.SkipZigTest;
    const glyph_acute = font.getGlyphId(0x0301) catch return error.SkipZigTest;
    if (font.getMarkBaseAnchors(glyph_e, glyph_acute) == null) return error.SkipZigTest;

    // Reference: unjustified single line. Captures the "correct" mark offset
    // relative to its base, uncontaminated by justify's per-glyph gap
    // distribution (this codebase's justify spreads extra space evenly
    // across *every* glyph gap by index, not just word-breaking spaces).
    var ref_layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "e\xCC\x81fg", .{ .pixel_size = 48.0 });
    defer ref_layout.deinit();
    const ref_dx = ref_layout.positions[1].x_offset - ref_layout.positions[0].x_offset;
    const ref_dy = ref_layout.positions[1].y_offset - ref_layout.positions[0].y_offset;

    // Same text, justified across a much wider container: the base "e" (glyph
    // index 0) gets a gap*0=0 shift and stays put, but before the fix GPOS ran
    // *before* justify, so the mark (index 1) was anchored to "e"'s
    // pre-justify x and then independently shifted by justify's own
    // gap*1 -- drifting the mark away from its base by one gap-width.
    var just_layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "e\xCC\x81fg", .{
        .pixel_size = 48.0,
        .max_width = 400.0,
        .text_align = .justify,
    });
    defer just_layout.deinit();
    const just_dx = just_layout.positions[1].x_offset - just_layout.positions[0].x_offset;
    const just_dy = just_layout.positions[1].y_offset - just_layout.positions[0].y_offset;

    try std.testing.expectApproxEqAbs(ref_dx, just_dx, 0.5);
    try std.testing.expectApproxEqAbs(ref_dy, just_dy, 0.5);
}

test "word wrap preserves mark-to-mark y anchor (I4b)" {
    if (comptime !ft.enable_opentype_layout) return error.SkipZigTest;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    // "e" + grave (mark-to-base) + acute (mark-to-mark, stacked on the grave).
    // DejaVuSans's mark-to-*base* anchors always carry base_y == mark_y here (no
    // vertical component -- the diacritic's own outline supplies the height), so
    // a mark-to-base-only pair can't exercise a real Y anchor. Its mark-to-*mark*
    // anchors do carry a substantial Y delta (two stacked diacritics must be
    // vertically separated), so the second mark (acute-on-grave) is what
    // actually exercises the y-anchor-survives-wrap path.
    const glyph_e = font.getGlyphId('e') catch return error.SkipZigTest;
    const glyph_grave = font.getGlyphId(0x0300) catch return error.SkipZigTest;
    const glyph_acute = font.getGlyphId(0x0301) catch return error.SkipZigTest;
    if (font.getMarkBaseAnchors(glyph_e, glyph_grave) == null) return error.SkipZigTest;
    if (font.getMarkMarkAnchors(glyph_grave, glyph_acute) == null) return error.SkipZigTest;

    // Reference: "e"+grave+acute alone, unwrapped -- the "correct" y offset the
    // second mark should have relative to the first, regardless of which line
    // the cluster is on.
    var ref_layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "e\xCC\x80\xCC\x81", .{ .pixel_size = 48.0 });
    defer ref_layout.deinit();
    try std.testing.expectEqual(@as(usize, 3), ref_layout.positions.len);
    const ref_dy = ref_layout.positions[2].y_offset - ref_layout.positions[1].y_offset;
    try std.testing.expect(@abs(ref_dy) > 0.5); // sanity: this pair's anchor really is vertical

    // "Hello e"+grave+acute with a narrow max_width forces the whole cluster
    // onto the second (wrapped) line -- wrap only breaks at the breakable space
    // before "e", never mid-cluster (combining marks aren't breakable). Before
    // the fix, GPOS ran before wrap, so the second mark's anchor-derived
    // y_offset got stomped back to the wrapped line's flat y by word-wrap's
    // rebase loop (which unconditionally overwrites `y_offset = new_y` for
    // every glyph it moves, marks included).
    var wrapped_layout = try layoutText(std.testing.allocator, &[_]font_mod.Font{font}, "Hello e\xCC\x80\xCC\x81", .{
        .pixel_size = 48.0,
        .max_width = 110.0,
    });
    defer wrapped_layout.deinit();
    try std.testing.expectEqual(@as(u32, 2), wrapped_layout.num_lines);

    // Last three positions are "e", grave, acute; confirm they actually landed
    // on line 1 (the wrapped line), i.e. this probe is exercising the wrap
    // path and not accidentally fitting on one line.
    const base_pos = wrapped_layout.positions[wrapped_layout.positions.len - 3];
    const grave_pos = wrapped_layout.positions[wrapped_layout.positions.len - 2];
    const acute_pos = wrapped_layout.positions[wrapped_layout.positions.len - 1];
    try std.testing.expectEqual(@as(u32, 1), base_pos.line);
    try std.testing.expectEqual(@as(u32, 1), grave_pos.line);
    try std.testing.expectEqual(@as(u32, 1), acute_pos.line);

    const wrapped_dy = acute_pos.y_offset - grave_pos.y_offset;
    try std.testing.expectApproxEqAbs(ref_dy, wrapped_dy, 0.5);
}

test "vertical styled layout honors span.font_index (I5)" {
    if (comptime !ft.enable_vertical) return error.SkipZigTest;
    // Two genuinely different fonts (not the same font loaded twice) so a
    // resolved glyph_id actually distinguishes "which font resolved this" --
    // before the fix, `layoutStyledTextVertical` ignored `span.font_index`
    // entirely and always resolved through font-array order (font 0 first),
    // so this would silently come back with DejaVuSans's glyph id instead.
    const dejavu_data = @embedFile("../fixture/DejaVuSans.ttf");
    const source_sans_data = @embedFile("../fixture/SourceSans3-Regular.otf");
    var font0 = try font_mod.Font.init(std.testing.allocator, dejavu_data, null);
    defer font0.deinit();
    var font1 = try font_mod.Font.init(std.testing.allocator, source_sans_data, null);
    defer font1.deinit();

    const fonts = [_]font_mod.Font{ font0, font1 };
    const glyph_from_font0 = try fonts[0].getGlyphId('A');
    const glyph_from_font1 = try fonts[1].getGlyphId('A');
    // Sanity: the two fonts must actually assign 'A' a different glyph id,
    // otherwise this test can't distinguish correct-vs-buggy resolution.
    try std.testing.expect(glyph_from_font0 != glyph_from_font1);

    const spans = [_]StyledSpan{
        .{ .text = "A", .pixel_size = 48.0, .font_index = 1 },
    };
    var layout = try layoutStyledText(std.testing.allocator, &fonts, &spans, .{ .vertical = true });
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 1), layout.positions.len);
    try std.testing.expectEqual(@as(u8, 1), layout.positions[0].font_index);
    try std.testing.expectEqual(glyph_from_font1, layout.positions[0].glyph_id);
}
