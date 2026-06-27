const std = @import("std");
const outline_mod = @import("outline.zig");
const scanline_mod = @import("scanline.zig");

const ControlPoint = struct { stem: f32, darken: f32 };

/// FreeType 互換のデフォルト制御点 (単位: 1/1000 ピクセル)
const default_params = [4]ControlPoint{
    .{ .stem = 500, .darken = 400 },
    .{ .stem = 1000, .darken = 275 },
    .{ .stem = 1667, .darken = 275 },
    .{ .stem = 2333, .darken = 0 },
};

pub fn computeDarkeningAmount(stem_width_px: f32) f32 {
    const w = stem_width_px * 1000.0;
    const params = default_params;

    const amount = if (w <= params[0].stem)
        params[0].darken
    else if (w <= params[1].stem)
        lerp(params[0].darken, params[1].darken, (w - params[0].stem) / (params[1].stem - params[0].stem))
    else if (w <= params[2].stem)
        lerp(params[1].darken, params[2].darken, (w - params[1].stem) / (params[2].stem - params[1].stem))
    else if (w <= params[3].stem)
        lerp(params[2].darken, params[3].darken, (w - params[2].stem) / (params[3].stem - params[2].stem))
    else
        params[3].darken;

    return amount / 1000.0;
}

pub fn estimateStemWidth(pixel_size: f32) f32 {
    return pixel_size * 0.1;
}

pub fn resolveRasterOptions(pixel_size: f32, base: scanline_mod.RasterOptions) scanline_mod.RasterOptions {
    var opts = base;
    opts.embolden_strength = computeDarkeningAmount(estimateStemWidth(pixel_size));
    return opts;
}

pub fn emboldenContours(
    allocator: std.mem.Allocator,
    contours: [][]outline_mod.ScaledPoint,
    amount: f32,
) !void {
    if (amount == 0.0) return;

    for (contours) |contour| {
        if (contour.len < 3) continue;

        const original = try allocator.alloc(Point, contour.len);
        defer allocator.free(original);

        for (contour, 0..) |pt, i| {
            original[i] = .{ .x = pt.x, .y = pt.y };
        }

        const area = signedArea(original);
        if (area == 0.0) continue;

        const winding_sign: f32 = if (area > 0.0) 1.0 else -1.0;
        const shift = amount * 0.5 * winding_sign;

        for (contour, 0..) |*pt, i| {
            const prev = original[(i + contour.len - 1) % contour.len];
            const curr = original[i];
            const next = original[(i + 1) % contour.len];

            const edge_in = normalize(.{ .x = curr.x - prev.x, .y = curr.y - prev.y });
            const edge_out = normalize(.{ .x = next.x - curr.x, .y = next.y - curr.y });

            var normal = Point{ .x = 0.0, .y = 0.0 };
            if (edge_in) |edge| {
                normal.x += edge.y;
                normal.y += -edge.x;
            }
            if (edge_out) |edge| {
                normal.x += edge.y;
                normal.y += -edge.x;
            }

            const unit_normal = normalize(normal) orelse continue;
            pt.x += unit_normal.x * shift;
            pt.y += unit_normal.y * shift;
        }
    }
}

const Point = struct {
    x: f32,
    y: f32,
};

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn signedArea(points: []const Point) f32 {
    var area: f32 = 0.0;
    for (points, 0..) |pt, i| {
        const next = points[(i + 1) % points.len];
        area += pt.x * next.y - next.x * pt.y;
    }
    return area * 0.5;
}

fn normalize(vec: Point) ?Point {
    const len_sq = vec.x * vec.x + vec.y * vec.y;
    if (len_sq <= 0.000001) return null;
    const inv_len = 1.0 / @sqrt(len_sq);
    return .{ .x = vec.x * inv_len, .y = vec.y * inv_len };
}

fn expectApprox(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "computeDarkeningAmount boundary values" {
    try expectApprox(0.4, computeDarkeningAmount(0.5));
    try expectApprox(0.275, computeDarkeningAmount(1.0));
    try expectApprox(0.275, computeDarkeningAmount(1.667));
    try expectApprox(0.0, computeDarkeningAmount(2.333));
    try expectApprox(0.0, computeDarkeningAmount(3.0));
}

test "computeDarkeningAmount interpolation" {
    try expectApprox(0.3375, computeDarkeningAmount(0.75));
    try expectApprox(0.1375, computeDarkeningAmount((1.667 + 2.333) * 0.5));
}

test "estimateStemWidth" {
    try expectApprox(4.8, estimateStemWidth(48.0));
}

test "emboldenContours expands square contour" {
    var contour = [_]outline_mod.ScaledPoint{
        .{ .x = 0.0, .y = 0.0, .on_curve = true },
        .{ .x = 10.0, .y = 0.0, .on_curve = true },
        .{ .x = 10.0, .y = 10.0, .on_curve = true },
        .{ .x = 0.0, .y = 10.0, .on_curve = true },
    };
    var contours = [_][]outline_mod.ScaledPoint{&contour};

    try emboldenContours(std.testing.allocator, &contours, 2.0);

    try std.testing.expect(contour[0].x < 0.0);
    try std.testing.expect(contour[0].y < 0.0);
    try std.testing.expect(contour[1].x > 10.0);
    try std.testing.expect(contour[1].y < 0.0);
    try std.testing.expect(contour[2].x > 10.0);
    try std.testing.expect(contour[2].y > 10.0);
    try std.testing.expect(contour[3].x < 0.0);
    try std.testing.expect(contour[3].y > 10.0);
}

test "emboldenContours with zero amount does not change points" {
    var contour = [_]outline_mod.ScaledPoint{
        .{ .x = 0.0, .y = 0.0, .on_curve = true },
        .{ .x = 10.0, .y = 0.0, .on_curve = true },
        .{ .x = 10.0, .y = 10.0, .on_curve = true },
        .{ .x = 0.0, .y = 10.0, .on_curve = true },
    };
    const original = contour;
    var contours = [_][]outline_mod.ScaledPoint{&contour};

    try emboldenContours(std.testing.allocator, &contours, 0.0);

    for (contour, 0..) |pt, i| {
        try expectApprox(original[i].x, pt.x);
        try expectApprox(original[i].y, pt.y);
    }
}
