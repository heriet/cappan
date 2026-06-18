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

/// Write contour data from an outline into `buf`.
/// If `scale` is null, coordinates are output as integers (font units, Y-up).
/// If `scale` is set, coordinates are scaled and Y-flipped (pixel space, Y-down).
fn writeContours(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    outline: anytype,
    scale: ?f32,
) !void {
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

        if (scale) |s| {
            // Scaled + Y-flipped (pixel space)
            var sx: f32 = undefined;
            var sy: f32 = undefined;
            if (start_idx == points.len) {
                sx = @as(f32, @floatFromInt(@divTrunc(points[0].x + points[1].x, 2))) * s;
                sy = -@as(f32, @floatFromInt(@divTrunc(points[0].y + points[1].y, 2))) * s;
                walk_start = 0;
            } else {
                sx = @as(f32, @floatFromInt(points[start_idx].x)) * s;
                sy = -@as(f32, @floatFromInt(points[start_idx].y)) * s;
                walk_start = start_idx + 1;
            }
            try buf.print(allocator, "M {d:.2} {d:.2} ", .{ sx, sy });

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
                    const cx1 = @as(f32, @floatFromInt(pt.x)) * s;
                    const cy1 = -@as(f32, @floatFromInt(pt.y)) * s;
                    const cx2 = @as(f32, @floatFromInt(cp2.x)) * s;
                    const cy2 = -@as(f32, @floatFromInt(cp2.y)) * s;
                    const ex = @as(f32, @floatFromInt(ep.x)) * s;
                    const ey = -@as(f32, @floatFromInt(ep.y)) * s;
                    try buf.print(allocator, "C {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} ", .{ cx1, cy1, cx2, cy2, ex, ey });
                    i += 3;
                    continue;
                }

                if (!pt.on_curve) {
                    const next_idx = (walk_start + i + 1) % n;
                    const next_pt = points[next_idx];
                    if (next_pt.on_curve) {
                        const cx = @as(f32, @floatFromInt(pt.x)) * s;
                        const cy = -@as(f32, @floatFromInt(pt.y)) * s;
                        const ex = @as(f32, @floatFromInt(next_pt.x)) * s;
                        const ey = -@as(f32, @floatFromInt(next_pt.y)) * s;
                        try buf.print(allocator, "Q {d:.2} {d:.2} {d:.2} {d:.2} ", .{ cx, cy, ex, ey });
                        i += 2;
                    } else {
                        const mx = @as(f32, @floatFromInt(@divTrunc(pt.x + next_pt.x, 2))) * s;
                        const my = -@as(f32, @floatFromInt(@divTrunc(pt.y + next_pt.y, 2))) * s;
                        const cx = @as(f32, @floatFromInt(pt.x)) * s;
                        const cy = -@as(f32, @floatFromInt(pt.y)) * s;
                        try buf.print(allocator, "Q {d:.2} {d:.2} {d:.2} {d:.2} ", .{ cx, cy, mx, my });
                        i += 1;
                    }
                    continue;
                }

                const ex = @as(f32, @floatFromInt(pt.x)) * s;
                const ey = -@as(f32, @floatFromInt(pt.y)) * s;
                try buf.print(allocator, "L {d:.2} {d:.2} ", .{ ex, ey });
                i += 1;
            }
        } else {
            // Integer font units, Y-up
            var start_x: i16 = undefined;
            var start_y: i16 = undefined;
            if (start_idx == points.len) {
                start_x = @divTrunc(points[0].x + points[1].x, 2);
                start_y = @divTrunc(points[0].y + points[1].y, 2);
                walk_start = 0;
            } else {
                start_x = points[start_idx].x;
                start_y = points[start_idx].y;
                walk_start = start_idx + 1;
            }
            try buf.print(allocator, "M {d} {d} ", .{ start_x, start_y });

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
                    try buf.print(allocator, "C {d} {d} {d} {d} {d} {d} ", .{ pt.x, pt.y, cp2.x, cp2.y, ep.x, ep.y });
                    i += 3;
                    continue;
                }

                if (!pt.on_curve) {
                    const next_idx = (walk_start + i + 1) % n;
                    const next_pt = points[next_idx];
                    if (next_pt.on_curve) {
                        try buf.print(allocator, "Q {d} {d} {d} {d} ", .{ pt.x, pt.y, next_pt.x, next_pt.y });
                        i += 2;
                    } else {
                        const mx = @divTrunc(pt.x + next_pt.x, 2);
                        const my = @divTrunc(pt.y + next_pt.y, 2);
                        try buf.print(allocator, "Q {d} {d} {d} {d} ", .{ pt.x, pt.y, mx, my });
                        i += 1;
                    }
                    continue;
                }

                try buf.print(allocator, "L {d} {d} ", .{ pt.x, pt.y });
                i += 1;
            }
        }

        try buf.print(allocator, "Z ", .{});
    }
}

/// Convert a single glyph outline to SVG path d attribute string in font units (Y-up, integer coords).
pub fn glyphToSvgPath(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    glyph_id: u16,
) !?[]const u8 {
    const maybe_outline = try font.getGlyphOutline(allocator, glyph_id);
    if (maybe_outline == null) return null;
    var outline = maybe_outline.?;
    defer outline.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try writeContours(allocator, &buf, outline, null);

    return try buf.toOwnedSlice(allocator);
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

        const path_data = (try glyphToSvgPathScaled(allocator, font, glyph_id, scale)) orelse blk: {
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

fn glyphToSvgPathScaled(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    glyph_id: u16,
    scale: f32,
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
