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

pub const EdgeRun = struct {
    /// Not individually owned: a slice into the sibling DecomposedContour.segments
    /// buffer. Mutating in place (e.g. reverseRunSegments) is fine and intended --
    /// it mutates the shared buffer, which is exactly what contour-orientation
    /// normalization wants.
    segments: []Segment,
    dir_start: [2]f32,
    dir_end: [2]f32,
    /// MSDF edge-coloring mask (see msdf.zig): which of R/G/B this run's pseudo-distance
    /// contributes to.
    channels: u3 = 0b111,
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

/// Flatten every contour and concatenate the resulting segments into one owned list.
/// Shared by rasterizer.zig's prepareGlyphRasterization and sdf.zig's generateGlyphSdf.
pub fn flattenContours(allocator: std.mem.Allocator, contours: []const []ScaledPoint) !std.ArrayList(Segment) {
    var all_segments: std.ArrayList(Segment) = .empty;
    errdefer all_segments.deinit(allocator);

    for (contours) |contour_points| {
        const segs = try flattenContour(allocator, contour_points);
        defer allocator.free(segs);
        try all_segments.appendSlice(allocator, segs);
    }

    return all_segments;
}

/// Flatten a single contour into line segments, handling:
/// - On-curve to on-curve: straight line
/// - Quadratic bezier (on-curve, off-curve, on-curve)
/// - Implicit on-curve points between consecutive off-curve points
/// The contour is treated as closed (last point connects to first)
///
/// A thin wrapper over decomposeContourEdges -- the single parser shared with
/// MSDF's curve-level edge-run decomposition -- that keeps the flattened
/// segment buffer and discards the run/direction bookkeeping. Since both
/// consumers walk the exact same points with the exact same bezier
/// subdivision calls in the exact same order, the segment buffer returned
/// here is byte-identical to what this function computed before the two
/// parsers were unified.
pub fn flattenContour(allocator: std.mem.Allocator, points: []const ScaledPoint) ![]Segment {
    const decomposed = try decomposeContourEdges(allocator, points);
    allocator.free(decomposed.runs);
    return decomposed.segments;
}

/// Owns both the flattened segment buffer and the EdgeRun index into it.
/// EdgeRun.segments slices are borrowed from `segments`, not individually
/// owned, so deinit only needs to free the two backing allocations.
pub const DecomposedContour = struct {
    segments: []Segment,
    runs: []EdgeRun,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecomposedContour) void {
        self.allocator.free(self.segments);
        self.allocator.free(self.runs);
    }
};

/// Per-edge (start, len) into the segments list being built, recorded instead of
/// slicing eagerly: the backing ArrayList can still reallocate as later edges are
/// appended, which would invalidate a slice taken mid-build. Actual EdgeRun slices
/// are materialized after toOwnedSlice, once the segment buffer's address is final.
const RunSpan = struct {
    start: usize,
    len: usize,
    dir_start: [2]f32,
    dir_end: [2]f32,
};

fn normalizeDir(dx: f32, dy: f32, fallback: [2]f32) [2]f32 {
    const len_sq = dx * dx + dy * dy;
    if (len_sq <= 1e-12) return fallback;
    const inv_len = 1.0 / @sqrt(len_sq);
    return .{ dx * inv_len, dy * inv_len };
}

fn appendLineSpan(allocator: std.mem.Allocator, segments: *std.ArrayList(Segment), spans: *std.ArrayList(RunSpan), p0: ScaledPoint, p1: ScaledPoint) !void {
    const start = segments.items.len;
    try segments.append(allocator, .{ .x0 = p0.x, .y0 = p0.y, .x1 = p1.x, .y1 = p1.y });
    const dir = normalizeDir(p1.x - p0.x, p1.y - p0.y, .{ 1.0, 0.0 });
    try spans.append(allocator, .{ .start = start, .len = segments.items.len - start, .dir_start = dir, .dir_end = dir });
}

fn appendQuadSpan(allocator: std.mem.Allocator, segments: *std.ArrayList(Segment), spans: *std.ArrayList(RunSpan), p0: ScaledPoint, ctrl: ScaledPoint, p1: ScaledPoint) !void {
    const start = segments.items.len;
    try flattenQuadBezier(allocator, segments, p0.x, p0.y, ctrl.x, ctrl.y, p1.x, p1.y, 0.25);
    const fallback = normalizeDir(p1.x - p0.x, p1.y - p0.y, .{ 1.0, 0.0 });
    try spans.append(allocator, .{
        .start = start,
        .len = segments.items.len - start,
        .dir_start = normalizeDir(ctrl.x - p0.x, ctrl.y - p0.y, fallback),
        .dir_end = normalizeDir(p1.x - ctrl.x, p1.y - ctrl.y, fallback),
    });
}

fn appendCubicSpan(allocator: std.mem.Allocator, segments: *std.ArrayList(Segment), spans: *std.ArrayList(RunSpan), p0: ScaledPoint, c1: ScaledPoint, c2: ScaledPoint, p1: ScaledPoint) !void {
    const start = segments.items.len;
    try flattenCubicBezier(allocator, segments, p0.x, p0.y, c1.x, c1.y, c2.x, c2.y, p1.x, p1.y, 0.25);
    const fallback = normalizeDir(p1.x - p0.x, p1.y - p0.y, .{ 1.0, 0.0 });
    const start_fallback = normalizeDir(c2.x - p0.x, c2.y - p0.y, fallback);
    const end_fallback = normalizeDir(p1.x - c1.x, p1.y - c1.y, fallback);
    try spans.append(allocator, .{
        .start = start,
        .len = segments.items.len - start,
        .dir_start = normalizeDir(c1.x - p0.x, c1.y - p0.y, start_fallback),
        .dir_end = normalizeDir(p1.x - c2.x, p1.y - c2.y, end_fallback),
    });
}

/// Decompose a contour into a shared flattened-segment buffer plus curve-level
/// edge runs slicing into it (used for MSDF edge coloring). This is the single
/// parser -- implicit-midpoint handling, cubic consumption, the max_iterations
/// guard, and contour closing -- shared with flattenContour (a thin wrapper
/// that only keeps the segment buffer). Same points, same bezier subdivision
/// calls, same order as before unification, so segment output is unchanged.
pub fn decomposeContourEdges(allocator: std.mem.Allocator, points: []const ScaledPoint) !DecomposedContour {
    if (points.len < 2) {
        return .{
            .segments = try allocator.alloc(Segment, 0),
            .runs = try allocator.alloc(EdgeRun, 0),
            .allocator = allocator,
        };
    }

    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(allocator);
    var spans: std.ArrayList(RunSpan) = .empty;
    defer spans.deinit(allocator);

    const n = points.len;
    var start_idx: usize = 0;
    var start_point: ScaledPoint = undefined;
    var found_on_curve = false;
    for (points, 0..) |pt, idx| {
        if (pt.on_curve) {
            start_idx = idx;
            start_point = pt;
            found_on_curve = true;
            break;
        }
    }
    if (!found_on_curve) {
        start_point = .{
            .x = (points[0].x + points[1].x) * 0.5,
            .y = (points[0].y + points[1].y) * 0.5,
            .on_curve = true,
        };
        start_idx = 0;
    }

    var current = start_point;
    var i: usize = 1;
    const max_iterations = n + 1;
    var iterations: usize = 0;
    while (i <= n and iterations < max_iterations) : (iterations += 1) {
        const idx = (start_idx + i) % n;
        const pt = points[idx];
        if (pt.on_curve) {
            try appendLineSpan(allocator, &segments, &spans, current, pt);
            current = pt;
            i += 1;
        } else if (pt.is_cubic) {
            const ctrl2 = points[(start_idx + i + 1) % n];
            const end_pt = points[(start_idx + i + 2) % n];
            try appendCubicSpan(allocator, &segments, &spans, current, pt, ctrl2, end_pt);
            current = end_pt;
            i += 3;
        } else {
            const next_pt = points[(start_idx + i + 1) % n];
            var end_pt: ScaledPoint = undefined;
            if (next_pt.on_curve) {
                end_pt = next_pt;
                i += 2;
            } else {
                end_pt = .{
                    .x = (pt.x + next_pt.x) * 0.5,
                    .y = (pt.y + next_pt.y) * 0.5,
                    .on_curve = true,
                };
                i += 1;
            }
            try appendQuadSpan(allocator, &segments, &spans, current, pt, end_pt);
            current = end_pt;
        }
    }

    const dx = current.x - start_point.x;
    const dy = current.y - start_point.y;
    if (dx * dx + dy * dy > 0.0) {
        try appendLineSpan(allocator, &segments, &spans, current, start_point);
    }

    const owned_segments = try segments.toOwnedSlice(allocator);
    errdefer allocator.free(owned_segments);

    const runs = try allocator.alloc(EdgeRun, spans.items.len);
    for (spans.items, 0..) |span, ri| {
        runs[ri] = .{
            .segments = owned_segments[span.start .. span.start + span.len],
            .dir_start = span.dir_start,
            .dir_end = span.dir_end,
        };
    }

    return .{ .segments = owned_segments, .runs = runs, .allocator = allocator };
}

/// Flatten quadratic bezier using De Casteljau subdivision
pub fn flattenQuadBezier(
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
pub fn flattenCubicBezier(
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
