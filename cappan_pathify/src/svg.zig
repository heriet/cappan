const std = @import("std");
const cappan_core = @import("cappan_core");

pub const GlyphPath = struct {
    codepoint: u21,
    glyph_id: u16,
    path_data: []const u8,
    advance_width: f32,
    x_offset: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GlyphPath) void {
        self.allocator.free(self.path_data);
    }
};

/// Emits SVG path commands for one coordinate space: either raw font units
/// (Y-up, integer-formatted, `scale == null`) or scaled pixel space (Y-flipped,
/// 2-decimal-formatted, `scale != null`). All coordinate values it's given are
/// still the original i16 font-unit ints (or an i16 midpoint the caller already
/// computed via truncating integer division) -- the walk logic that decides
/// *which* points to feed it is fully shared between both coordinate spaces
/// (see `writeContours`); only the transform+number-formatting step, which
/// generally differs, lives here.
///
/// `{d}` formats an integer-valued f32 identically to the same value as an
/// i16 (verified: both print "5", "-12", etc. with no decimal point or
/// exponent), so the unscaled path can safely go through the same f32-typed
/// emit functions as the scaled path without changing its output.
const Pen = struct {
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    scale: ?f32,

    fn xy(self: Pen, x: i16, y: i16) struct { x: f32, y: f32 } {
        if (self.scale) |s| {
            return .{ .x = @as(f32, @floatFromInt(x)) * s, .y = -@as(f32, @floatFromInt(y)) * s };
        }
        return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }

    fn moveTo(self: Pen, x: i16, y: i16) !void {
        const p = self.xy(x, y);
        if (self.scale != null) {
            try self.buf.print(self.allocator, "M {d:.2} {d:.2} ", .{ p.x, p.y });
        } else {
            try self.buf.print(self.allocator, "M {d} {d} ", .{ p.x, p.y });
        }
    }

    fn lineTo(self: Pen, x: i16, y: i16) !void {
        const p = self.xy(x, y);
        if (self.scale != null) {
            try self.buf.print(self.allocator, "L {d:.2} {d:.2} ", .{ p.x, p.y });
        } else {
            try self.buf.print(self.allocator, "L {d} {d} ", .{ p.x, p.y });
        }
    }

    fn quadTo(self: Pen, cx: i16, cy: i16, ex: i16, ey: i16) !void {
        const c = self.xy(cx, cy);
        const e = self.xy(ex, ey);
        if (self.scale != null) {
            try self.buf.print(self.allocator, "Q {d:.2} {d:.2} {d:.2} {d:.2} ", .{ c.x, c.y, e.x, e.y });
        } else {
            try self.buf.print(self.allocator, "Q {d} {d} {d} {d} ", .{ c.x, c.y, e.x, e.y });
        }
    }

    fn curveTo(self: Pen, c1x: i16, c1y: i16, c2x: i16, c2y: i16, ex: i16, ey: i16) !void {
        const c1 = self.xy(c1x, c1y);
        const c2 = self.xy(c2x, c2y);
        const e = self.xy(ex, ey);
        if (self.scale != null) {
            try self.buf.print(self.allocator, "C {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} ", .{ c1.x, c1.y, c2.x, c2.y, e.x, e.y });
        } else {
            try self.buf.print(self.allocator, "C {d} {d} {d} {d} {d} {d} ", .{ c1.x, c1.y, c2.x, c2.y, e.x, e.y });
        }
    }

    fn close(self: Pen) !void {
        try self.buf.print(self.allocator, "Z ", .{});
    }
};

/// Write contour data from an outline into `buf`.
/// If `scale` is null, coordinates are output as integers (font units, Y-up).
/// If `scale` is set, coordinates are scaled and Y-flipped (pixel space, Y-down).
fn writeContours(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    outline: anytype,
    scale: ?f32,
) !void {
    const pen = Pen{ .allocator = allocator, .buf = buf, .scale = scale };

    for (outline.contours) |contour| {
        const points = contour.points;
        if (points.len == 0) continue;

        // Find first on-curve point index
        var start_idx: usize = points.len;
        for (points, 0..) |pt, i| {
            if (pt.on_curve) {
                start_idx = i;
                break;
            }
        }

        var walk_start: usize = undefined;
        if (start_idx == points.len) {
            // No on-curve point in this contour at all: synthesize a start
            // point as the midpoint of the first two (off-curve) points.
            // Truncating integer division here (matching both coordinate
            // spaces) -- deliberately done before any float conversion.
            const mx = @divTrunc(points[0].x + points[1].x, 2);
            const my = @divTrunc(points[0].y + points[1].y, 2);
            try pen.moveTo(mx, my);
            walk_start = 0;
        } else {
            try pen.moveTo(points[start_idx].x, points[start_idx].y);
            walk_start = start_idx + 1;
        }

        var i: usize = 0;
        const n = points.len;
        while (i < n) {
            const idx = (walk_start + i) % n;
            const pt = points[idx];

            if (pt.is_cubic) {
                const idx2 = (walk_start + i + 1) % n;
                const idx3 = (walk_start + i + 2) % n;
                const cp2 = points[idx2];
                const ep = points[idx3];
                try pen.curveTo(pt.x, pt.y, cp2.x, cp2.y, ep.x, ep.y);
                i += 3;
                continue;
            }

            if (!pt.on_curve) {
                const next_idx = (walk_start + i + 1) % n;
                const next_pt = points[next_idx];
                if (next_pt.on_curve) {
                    try pen.quadTo(pt.x, pt.y, next_pt.x, next_pt.y);
                    i += 2;
                } else {
                    const mx = @divTrunc(pt.x + next_pt.x, 2);
                    const my = @divTrunc(pt.y + next_pt.y, 2);
                    try pen.quadTo(pt.x, pt.y, mx, my);
                    i += 1;
                }
                continue;
            }

            try pen.lineTo(pt.x, pt.y);
            i += 1;
        }

        try pen.close();
    }
}

/// Shared implementation behind `glyphToSvgPath` (`scale = null`, font units,
/// Y-up) and `textToSvgPaths`'s per-glyph scaled/Y-flipped pixel-space path
/// (`scale != null`).
fn glyphOutlineToSvgPath(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    glyph_id: u16,
    scale: ?f32,
) !?[]const u8 {
    const maybe_outline = try font.getGlyphOutline(allocator, glyph_id);
    if (maybe_outline == null) return null;
    var outline = maybe_outline.?;
    defer outline.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try writeContours(allocator, &buf, outline, scale);

    return try buf.toOwnedSlice(allocator);
}

/// Convert a single glyph outline to SVG path d attribute string in font units (Y-up, integer coords).
pub fn glyphToSvgPath(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    glyph_id: u16,
) !?[]const u8 {
    return glyphOutlineToSvgPath(allocator, font, glyph_id, null);
}

/// Convert text to array of GlyphPath with pixel coordinates (scaled + Y-flipped).
pub fn textToSvgPaths(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    text: []const u8,
    pixel_size: f32,
) ![]GlyphPath {
    const scale = pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    var result: std.ArrayList(GlyphPath) = .empty;
    errdefer {
        for (result.items) |*p| {
            p.deinit();
        }
        result.deinit(allocator);
    }

    var x_offset: f32 = 0.0;
    var prev_glyph_id: ?u16 = null;

    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        const glyph_id = font.getGlyphId(codepoint) catch continue;
        const metrics = font.getHMetrics(glyph_id) catch continue;

        if (prev_glyph_id) |prev| {
            const kern = font.getKerning(prev, glyph_id);
            x_offset += @as(f32, @floatFromInt(kern)) * scale;
        }

        const path_data = (try glyphOutlineToSvgPath(allocator, font, glyph_id, scale)) orelse blk: {
            const empty = try allocator.dupe(u8, "");
            break :blk empty;
        };
        errdefer allocator.free(path_data);

        try result.append(allocator, GlyphPath{
            .codepoint = codepoint,
            .glyph_id = glyph_id,
            .path_data = path_data,
            .advance_width = @as(f32, @floatFromInt(metrics.advance_width)) * scale,
            .x_offset = x_offset,
            .allocator = allocator,
        });

        x_offset += @as(f32, @floatFromInt(metrics.advance_width)) * scale;
        prev_glyph_id = glyph_id;
    }

    return try result.toOwnedSlice(allocator);
}

test "glyphToSvgPath for letter A" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId('A');
    const path = try glyphToSvgPath(std.testing.allocator, font, glyph_id);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.startsWith(u8, path.?, "M"));
    try std.testing.expect(std.mem.indexOf(u8, path.?, "Z") != null);
}

test "textToSvgPaths for Hello" {
    const font_data = @embedFile("fixture/DejaVuSans.ttf");
    var font = try cappan_core.font.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const paths = try textToSvgPaths(std.testing.allocator, font, "Hello", 48.0);
    defer {
        for (paths) |*p| {
            @constCast(p).deinit();
        }
        std.testing.allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 5), paths.len);
    for (1..paths.len) |i| {
        try std.testing.expect(paths[i].x_offset > paths[i - 1].x_offset);
    }
}
