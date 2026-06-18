const std = @import("std");
const outline_mod = @import("../../raster/outline.zig");
const distance_field_mod = @import("distance_field.zig");

pub const TangentFlowOptions = struct {};

/// Build reveal map where pixels are revealed based on the tangent direction of the
/// nearest outline segment. Horizontal strokes (angle near 0 or π) are revealed first
/// (map value near 0.0), vertical strokes (angle near ±π/2) second (near 0.5), and
/// diagonal strokes last (near 1.0).
pub fn buildRevealMap(
    allocator: std.mem.Allocator,
    scaled_contours: []const []const outline_mod.ScaledPoint,
    coverage: []const u8,
    width: u32,
    height: u32,
    options: TangentFlowOptions,
) ![]f32 {
    _ = options;

    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total = w * h;

    if (total == 0) {
        return try allocator.alloc(f32, 0);
    }

    // Step 1: Flatten all contours into line segments
    var all_segments: std.ArrayListUnmanaged(outline_mod.Segment) = .empty;
    defer all_segments.deinit(allocator);

    for (scaled_contours) |contour| {
        if (contour.len < 2) continue;
        const segs = try outline_mod.flattenContour(allocator, contour);
        defer allocator.free(segs);
        for (segs) |seg| {
            try all_segments.append(allocator, seg);
        }
    }

    const map = try allocator.alloc(f32, total);
    errdefer allocator.free(map);

    if (all_segments.items.len == 0) {
        // No segments: assign axis-aligned value (0.0) to filled pixels
        for (0..total) |i| {
            map[i] = if (coverage[i] > 0) 0.0 else 1.0;
        }
        return map;
    }

    // Step 2: For each pixel with coverage > 0, find the nearest segment and
    // compute the reveal value from its tangent direction.
    for (0..h) |y| {
        for (0..w) |x| {
            const idx = y * w + x;
            if (coverage[idx] == 0) {
                map[idx] = 1.0;
                continue;
            }

            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;

            var min_dist: f32 = std.math.inf(f32);
            var nearest_seg: outline_mod.Segment = all_segments.items[0];

            for (all_segments.items) |seg| {
                const d = pointToSegmentDist(px, py, seg);
                if (d < min_dist) {
                    min_dist = d;
                    nearest_seg = seg;
                }
            }

            // Compute tangent angle of nearest segment
            const angle = std.math.atan2(nearest_seg.y1 - nearest_seg.y0, nearest_seg.x1 - nearest_seg.x0);

            // Map angle to reveal order:
            // - Horizontal (angle near 0 or ±π): 0.0 (revealed first)
            // - Vertical (angle near ±π/2): 0.5 (revealed second)
            // - Diagonal (in between): 1.0 (revealed last)
            const abs_angle = @abs(angle); // [0, π]

            // Distance from nearest horizontal axis: 0 at angle=0 or π, π/2 at angle=±π/2
            const horizontal_dist = @min(abs_angle, std.math.pi - abs_angle);

            // Distance from nearest vertical axis: 0 at angle=±π/2, π/2 at angle=0 or π
            const vertical_dist = @abs(abs_angle - std.math.pi / 2.0);

            // Distance from nearest axis (either horizontal or vertical): 0 on axis, π/4 at diagonal
            const min_axis_dist = @min(horizontal_dist, vertical_dist);

            // Normalize to [0, 1]: 0.0 at any axis-aligned direction, 1.0 at diagonal (45°)
            const reveal_value = min_axis_dist / (std.math.pi / 4.0);

            map[idx] = reveal_value;
        }
    }

    return map;
}

fn pointToSegmentDist(px: f32, py: f32, seg: outline_mod.Segment) f32 {
    const dx = seg.x1 - seg.x0;
    const dy = seg.y1 - seg.y0;
    const len_sq = dx * dx + dy * dy;
    if (len_sq < 1e-10) {
        const ex = px - seg.x0;
        const ey = py - seg.y0;
        return @sqrt(ex * ex + ey * ey);
    }
    const t = std.math.clamp(((px - seg.x0) * dx + (py - seg.y0) * dy) / len_sq, 0.0, 1.0);
    const proj_x = seg.x0 + t * dx;
    const proj_y = seg.y0 + t * dy;
    const ex = px - proj_x;
    const ey = py - proj_y;
    return @sqrt(ex * ex + ey * ey);
}

/// Reuse the threshold-based apply from distance_field.
pub const apply = distance_field_mod.apply;

test "basic tangent flow" {
    const allocator = std.testing.allocator;
    // 5x5 coverage with a filled 3x3 square
    var coverage = [_]u8{
        0,   0,   0,   0,   0,
        0,   255, 255, 255, 0,
        0,   255, 255, 255, 0,
        0,   255, 255, 255, 0,
        0,   0,   0,   0,   0,
    };
    // Square contour matching the filled region
    const points = [_]outline_mod.ScaledPoint{
        .{ .x = 1, .y = 1, .on_curve = true, .is_cubic = false },
        .{ .x = 4, .y = 1, .on_curve = true, .is_cubic = false },
        .{ .x = 4, .y = 4, .on_curve = true, .is_cubic = false },
        .{ .x = 1, .y = 4, .on_curve = true, .is_cubic = false },
    };
    const contours = [_][]const outline_mod.ScaledPoint{&points};
    const map = try buildRevealMap(allocator, &contours, &coverage, 5, 5, .{});
    defer allocator.free(map);

    // All filled pixels should have values in [0, 1]
    for (0..25) |i| {
        if (coverage[i] > 0) {
            try std.testing.expect(map[i] >= 0.0);
            try std.testing.expect(map[i] <= 1.0);
        }
    }

    // Outside pixels should be 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map[4], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map[20], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map[24], 0.001);
}

test "empty coverage" {
    const allocator = std.testing.allocator;
    var coverage: [0]u8 = .{};
    const contours: [0][]const outline_mod.ScaledPoint = .{};
    const map = try buildRevealMap(allocator, &contours, &coverage, 0, 0, .{});
    defer allocator.free(map);
    try std.testing.expectEqual(@as(usize, 0), map.len);
}
