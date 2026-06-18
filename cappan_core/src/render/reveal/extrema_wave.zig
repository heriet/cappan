const std = @import("std");
const outline_mod = @import("../../raster/outline.zig");
const distance_field_mod = @import("distance_field.zig");

pub const ExtremaWaveOptions = struct {
    invert: bool = true,
};

/// Build reveal map based on distance from outline extrema points.
/// Extrema points (topmost, bottommost, leftmost, rightmost, and local direction-change points)
/// are revealed first (map value 0.0), pixels farthest from any extremum last (1.0).
pub fn buildRevealMap(
    allocator: std.mem.Allocator,
    scaled_contours: []const []const outline_mod.ScaledPoint,
    coverage: []const u8,
    width: u32,
    height: u32,
    options: ExtremaWaveOptions,
) ![]f32 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total = w * h;

    if (total == 0) {
        return try allocator.alloc(f32, 0);
    }

    // Step 1: Find extrema points on the outline
    // Global extrema: top, bottom, left, right of all contours
    // Local extrema: points where X or Y direction changes (local min/max)
    var extrema: std.ArrayListUnmanaged([2]f32) = .empty;
    defer extrema.deinit(allocator);

    var global_min_x: f32 = std.math.inf(f32);
    var global_max_x: f32 = -std.math.inf(f32);
    var global_min_y: f32 = std.math.inf(f32);
    var global_max_y: f32 = -std.math.inf(f32);
    var min_x_point: [2]f32 = .{ 0, 0 };
    var max_x_point: [2]f32 = .{ 0, 0 };
    var min_y_point: [2]f32 = .{ 0, 0 };
    var max_y_point: [2]f32 = .{ 0, 0 };

    for (scaled_contours) |contour| {
        if (contour.len < 2) continue;

        for (contour) |pt| {
            if (pt.x < global_min_x) {
                global_min_x = pt.x;
                min_x_point = .{ pt.x, pt.y };
            }
            if (pt.x > global_max_x) {
                global_max_x = pt.x;
                max_x_point = .{ pt.x, pt.y };
            }
            if (pt.y < global_min_y) {
                global_min_y = pt.y;
                min_y_point = .{ pt.x, pt.y };
            }
            if (pt.y > global_max_y) {
                global_max_y = pt.y;
                max_y_point = .{ pt.x, pt.y };
            }
        }

        // Find local extrema: points where X or Y direction reverses
        for (contour, 0..) |pt, i| {
            const prev = contour[if (i == 0) contour.len - 1 else i - 1];
            const next = contour[(i + 1) % contour.len];

            // X direction change (local min or max in X)
            const dx_prev = pt.x - prev.x;
            const dx_next = next.x - pt.x;
            const is_x_extremum = (dx_prev > 0 and dx_next < 0) or (dx_prev < 0 and dx_next > 0);
            if (is_x_extremum) {
                try extrema.append(allocator, .{ pt.x, pt.y });
            }

            // Y direction change (local min or max in Y)
            const dy_prev = pt.y - prev.y;
            const dy_next = next.y - pt.y;
            const is_y_extremum = (dy_prev > 0 and dy_next < 0) or (dy_prev < 0 and dy_next > 0);
            // Don't add duplicate if already added for X
            if (is_y_extremum and !is_x_extremum) {
                try extrema.append(allocator, .{ pt.x, pt.y });
            }
        }
    }

    // Add global extrema
    if (global_min_x < std.math.inf(f32)) {
        try extrema.append(allocator, min_x_point);
        try extrema.append(allocator, max_x_point);
        try extrema.append(allocator, min_y_point);
        try extrema.append(allocator, max_y_point);
    }

    if (extrema.items.len == 0) {
        const map = try allocator.alloc(f32, total);
        for (0..total) |i| {
            map[i] = if (coverage[i] > 0) 0.0 else 1.0;
        }
        return map;
    }

    // Step 2: For each filled pixel, compute distance to nearest extremum
    const map = try allocator.alloc(f32, total);
    errdefer allocator.free(map);

    var max_dist: f32 = 0;

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
            for (extrema.items) |ext| {
                const dx = px - ext[0];
                const dy = py - ext[1];
                const dist = @sqrt(dx * dx + dy * dy);
                if (dist < min_dist) min_dist = dist;
            }

            map[idx] = min_dist;
            if (min_dist > max_dist) max_dist = min_dist;
        }
    }

    // Step 3: Normalize to [0, 1]
    if (max_dist > 0) {
        for (0..total) |i| {
            if (coverage[i] > 0) {
                const normalized = map[i] / max_dist;
                map[i] = if (options.invert) 1.0 - normalized else normalized;
            }
        }
    }

    return map;
}

/// Reuse the threshold-based apply from distance_field.
pub const apply = distance_field_mod.apply;

test "basic extrema detection" {
    const allocator = std.testing.allocator;
    var coverage = [_]u8{
        0,   0,   0,   0,   0,
        0,   255, 255, 255, 0,
        0,   255, 255, 255, 0,
        0,   255, 255, 255, 0,
        0,   0,   0,   0,   0,
    };
    // Square contour
    const points = [_]outline_mod.ScaledPoint{
        .{ .x = 1, .y = 1, .on_curve = true, .is_cubic = false },
        .{ .x = 4, .y = 1, .on_curve = true, .is_cubic = false },
        .{ .x = 4, .y = 4, .on_curve = true, .is_cubic = false },
        .{ .x = 1, .y = 4, .on_curve = true, .is_cubic = false },
    };
    const contours = [_][]const outline_mod.ScaledPoint{&points};
    const map = try buildRevealMap(allocator, &contours, &coverage, 5, 5, .{ .invert = false });
    defer allocator.free(map);

    // All filled pixels should have values in [0, 1]
    for (0..25) |i| {
        if (coverage[i] > 0) {
            try std.testing.expect(map[i] >= 0.0);
            try std.testing.expect(map[i] <= 1.0);
        }
    }
    // Outside should be 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map[0], 0.001);

    // Inverted: values should be flipped for filled pixels
    const map_inv = try buildRevealMap(allocator, &contours, &coverage, 5, 5, .{ .invert = true });
    defer allocator.free(map_inv);
    for (0..25) |i| {
        if (coverage[i] > 0) {
            try std.testing.expectApproxEqAbs(1.0 - map[i], map_inv[i], 0.001);
        }
    }
}

test "empty" {
    const allocator = std.testing.allocator;
    var coverage: [0]u8 = .{};
    const contours: [0][]const outline_mod.ScaledPoint = .{};
    const map = try buildRevealMap(allocator, &contours, &coverage, 0, 0, .{});
    defer allocator.free(map);
    try std.testing.expectEqual(@as(usize, 0), map.len);
}
