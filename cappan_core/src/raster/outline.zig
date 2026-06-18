const std = @import("std");
const glyph_mod = @import("../font/glyph.zig");

pub const ScaledPoint = struct {
    x: f32,
    y: f32,
    on_curve: bool,
    is_cubic: bool = false, // true for CFF cubic Bezier control points
};

pub const Segment = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

/// Scale glyph outline from font units to pixel coordinates
/// Y is flipped: font Y-up -> bitmap Y-down
pub fn scaleOutline(
    allocator: std.mem.Allocator,
    outline: glyph_mod.GlyphOutline,
    scale: f32,
    offset_x: f32,
    offset_y: f32,
) ![][]ScaledPoint {
    const scaled_contours = try allocator.alloc([]ScaledPoint, outline.contours.len);
    errdefer {
        for (scaled_contours) |sc| {
            if (sc.len > 0) allocator.free(sc);
        }
        allocator.free(scaled_contours);
    }

    for (outline.contours, 0..) |contour, i| {
        const points = try allocator.alloc(ScaledPoint, contour.points.len);
        for (contour.points, 0..) |pt, j| {
            points[j] = .{
                .x = @as(f32, @floatFromInt(pt.x)) * scale + offset_x,
                .y = offset_y - @as(f32, @floatFromInt(pt.y)) * scale,
                .on_curve = pt.on_curve,
                .is_cubic = pt.is_cubic,
            };
        }
        scaled_contours[i] = points;
    }

    return scaled_contours;
}

pub fn freeScaledContours(allocator: std.mem.Allocator, contours: [][]ScaledPoint) void {
    for (contours) |points| {
        allocator.free(points);
    }
    allocator.free(contours);
}

/// Flatten a single contour into line segments, handling:
/// - On-curve to on-curve: straight line
/// - Quadratic bezier (on-curve, off-curve, on-curve)
/// - Implicit on-curve points between consecutive off-curve points
/// The contour is treated as closed (last point connects to first)
pub fn flattenContour(allocator: std.mem.Allocator, points: []const ScaledPoint) ![]Segment {
    if (points.len < 2) return try allocator.alloc(Segment, 0);

    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(allocator);

    const n = points.len;

    // Find the first on-curve point (or create one from implicit rule)
    var start_idx: usize = 0;
    var start_point: ScaledPoint = undefined;

    // Find first on-curve point
    var found_on_curve = false;
    for (points, 0..) |pt, i| {
        if (pt.on_curve) {
            start_idx = i;
            start_point = pt;
            found_on_curve = true;
            break;
        }
    }

    if (!found_on_curve) {
        // All off-curve: start with midpoint of first two
        start_point = .{
            .x = (points[0].x + points[1].x) * 0.5,
            .y = (points[0].y + points[1].y) * 0.5,
            .on_curve = true,
        };
        start_idx = 0;
    }

    var current = start_point;
    var i: usize = 1;
    // Safety guard: in a well-formed contour we consume at most n points.
    // Each iteration consumes at least 1 point (on-curve) or 1-2 points (off-curve),
    // so n iterations is an upper bound. Allow n+1 as a safety margin.
    const max_iterations = n + 1;
    var iterations: usize = 0;

    while (i <= n and iterations < max_iterations) : (iterations += 1) {
        const idx = (start_idx + i) % n;
        const pt = points[idx];

        if (pt.on_curve) {
            // Straight line
            try segments.append(allocator, .{ .x0 = current.x, .y0 = current.y, .x1 = pt.x, .y1 = pt.y });
            current = pt;
            i += 1;
        } else if (pt.is_cubic) {
            // CFF cubic Bezier: consume control1 (pt), control2, and end point
            const ctrl2_idx = (start_idx + i + 1) % n;
            const end_idx = (start_idx + i + 2) % n;
            const ctrl2 = points[ctrl2_idx];
            const end_pt = points[end_idx];

            try flattenCubicBezier(allocator, &segments, current.x, current.y, pt.x, pt.y, ctrl2.x, ctrl2.y, end_pt.x, end_pt.y, 0.25);
            current = end_pt;
            i += 3;
        } else {
            // Off-curve point (quadratic): find the next on-curve point
            const next_idx = (start_idx + i + 1) % n;
            const next_pt = points[next_idx];

            var end_pt: ScaledPoint = undefined;
            if (next_pt.on_curve) {
                end_pt = next_pt;
                i += 2;
            } else {
                // Two consecutive off-curve: implicit on-curve at midpoint
                end_pt = .{
                    .x = (pt.x + next_pt.x) * 0.5,
                    .y = (pt.y + next_pt.y) * 0.5,
                    .on_curve = true,
                };
                i += 1;
            }

            // Flatten quadratic bezier: current -> pt (control) -> end_pt
            try flattenQuadBezier(allocator, &segments, current.x, current.y, pt.x, pt.y, end_pt.x, end_pt.y, 0.25);
            current = end_pt;
        }
    }

    // Close the contour: always connect back to start_point unless they are
    // already the same pixel (zero-length segment would be noise).
    const dx = current.x - start_point.x;
    const dy = current.y - start_point.y;
    if (dx * dx + dy * dy > 0.0) {
        try segments.append(allocator, .{ .x0 = current.x, .y0 = current.y, .x1 = start_point.x, .y1 = start_point.y });
    }

    return segments.toOwnedSlice(allocator);
}

/// Flatten quadratic bezier using De Casteljau subdivision
fn flattenQuadBezier(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(Segment),
    x0: f32,
    y0: f32, // start
    cx: f32,
    cy: f32, // control
    x1: f32,
    y1: f32, // end
    tolerance: f32,
) !void {
    // Check if curve is flat enough
    const mid_x = (x0 + 2 * cx + x1) / 4.0;
    const mid_y = (y0 + 2 * cy + y1) / 4.0;
    const linear_mid_x = (x0 + x1) / 2.0;
    const linear_mid_y = (y0 + y1) / 2.0;
    const dx = mid_x - linear_mid_x;
    const dy = mid_y - linear_mid_y;
    const dist_sq = dx * dx + dy * dy;

    if (dist_sq <= tolerance * tolerance) {
        try segments.append(allocator, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 });
        return;
    }

    // Subdivide at t=0.5
    const q0x = (x0 + cx) * 0.5;
    const q0y = (y0 + cy) * 0.5;
    const q1x = (cx + x1) * 0.5;
    const q1y = (cy + y1) * 0.5;
    const qmx = (q0x + q1x) * 0.5;
    const qmy = (q0y + q1y) * 0.5;

    try flattenQuadBezier(allocator, segments, x0, y0, q0x, q0y, qmx, qmy, tolerance);
    try flattenQuadBezier(allocator, segments, qmx, qmy, q1x, q1y, x1, y1, tolerance);
}

/// Flatten a cubic Bezier curve (p0 → c1 → c2 → p1) into line segments
fn flattenCubicBezier(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(Segment),
    x0: f32,
    y0: f32,
    cx1: f32,
    cy1: f32,
    cx2: f32,
    cy2: f32,
    x1: f32,
    y1: f32,
    tolerance: f32,
) !void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const d1 = @abs((cx1 - x1) * dy - (cy1 - y1) * dx);
    const d2 = @abs((cx2 - x1) * dy - (cy2 - y1) * dx);
    const d_sq = dx * dx + dy * dy;

    if ((d1 + d2) * (d1 + d2) <= tolerance * tolerance * d_sq) {
        try segments.append(allocator, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 });
        return;
    }

    const mx01 = (x0 + cx1) * 0.5;
    const my01 = (y0 + cy1) * 0.5;
    const mx12 = (cx1 + cx2) * 0.5;
    const my12 = (cy1 + cy2) * 0.5;
    const mx23 = (cx2 + x1) * 0.5;
    const my23 = (cy2 + y1) * 0.5;
    const mx012 = (mx01 + mx12) * 0.5;
    const my012 = (my01 + my12) * 0.5;
    const mx123 = (mx12 + mx23) * 0.5;
    const my123 = (my12 + my23) * 0.5;
    const mx0123 = (mx012 + mx123) * 0.5;
    const my0123 = (my012 + my123) * 0.5;

    try flattenCubicBezier(allocator, segments, x0, y0, mx01, my01, mx012, my012, mx0123, my0123, tolerance);
    try flattenCubicBezier(allocator, segments, mx0123, my0123, mx123, my123, mx23, my23, x1, y1, tolerance);
}

test "flatten straight line contour" {
    // A square contour (all on-curve)
    const points = [_]ScaledPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 10, .on_curve = true },
        .{ .x = 0, .y = 10, .on_curve = true },
    };
    const segments = try flattenContour(std.testing.allocator, &points);
    defer std.testing.allocator.free(segments);

    // 4 sides of the square
    try std.testing.expectEqual(@as(usize, 4), segments.len);
}

test "flatten bezier contour" {
    // Triangle with one bezier curve side
    const points = [_]ScaledPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 5, .y = -3, .on_curve = false }, // control point
        .{ .x = 10, .y = 0, .on_curve = true },
        .{ .x = 5, .y = 10, .on_curve = true },
    };
    const segments = try flattenContour(std.testing.allocator, &points);
    defer std.testing.allocator.free(segments);

    // Should have more than 3 segments due to bezier subdivision
    try std.testing.expect(segments.len >= 3);
}

test "flattenCubicBezier: linear curve produces single segment" {
    // 制御点が始点-終点の直線上にある場合、1セグメントになる
    const allocator = std.testing.allocator;
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(allocator);

    // (0,0) → (100,0) の直線（制御点も同じライン上）
    try flattenCubicBezier(allocator, &segments, 0, 0, 33, 0, 67, 0, 100, 0, 0.25);
    try std.testing.expectEqual(@as(usize, 1), segments.items.len);
}

test "flattenCubicBezier: curved bezier produces multiple segments" {
    // S字カーブ: 複数セグメントになることを確認
    const allocator = std.testing.allocator;
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(allocator);

    try flattenCubicBezier(allocator, &segments, 0, 0, 0, 100, 100, -100, 100, 0, 0.25);
    try std.testing.expect(segments.items.len > 1);
}
