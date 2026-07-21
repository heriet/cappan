const std = @import("std");
const distance_field_mod = @import("distance_field.zig");
const morphology = @import("morphology.zig");

pub const SkeletonGrowOptions = struct {};

/// Compute a reveal map where 0.0 = revealed first (skeleton), 1.0 = revealed last (edges).
/// Uses Zhang-Suen thinning to extract the skeleton, then EDT from skeleton outward.
pub fn buildRevealMap(allocator: std.mem.Allocator, coverage: []const u8, width: u32, height: u32) ![]f32 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total = w * h;

    if (total == 0) {
        return try allocator.alloc(f32, 0);
    }

    // Extract skeleton via Zhang-Suen thinning
    const skeleton = try extractSkeleton(allocator, coverage, width, height);
    defer allocator.free(skeleton);

    // Build grid: skeleton pixels = 0.0, inside non-skeleton pixels = 1e10, outside = 0.0
    // EDT will propagate distances from the skeleton outward through the glyph interior.
    const grid = try allocator.alloc(f32, total);
    errdefer allocator.free(grid);

    for (0..total) |i| {
        if (coverage[i] == 0) {
            // Outside pixel: distance = 0 so EDT treats it as a source (but we'll set to 1.0 at end)
            grid[i] = 0.0;
        } else if (skeleton[i] == 1) {
            // Skeleton pixel: revealed first (distance = 0)
            grid[i] = 0.0;
        } else {
            // Interior non-skeleton pixel: large value, EDT will fill in distance to nearest skeleton
            grid[i] = 1e10;
        }
    }

    try morphology.squaredEdt2dInPlace(allocator, grid, w, h);

    // sqrt and find max distance among inside pixels
    var max_dist: f32 = 0;
    for (0..total) |i| {
        grid[i] = @sqrt(grid[i]);
        if (coverage[i] > 0 and grid[i] > max_dist) {
            max_dist = grid[i];
        }
    }

    // Normalize: skeleton pixels (dist=0) -> 0.0 (revealed first), farthest inside pixels -> 1.0 (revealed last)
    // Outside pixels get 1.0
    if (max_dist > 0) {
        for (0..total) |i| {
            if (coverage[i] > 0) {
                grid[i] = grid[i] / max_dist;
            } else {
                grid[i] = 1.0;
            }
        }
    } else {
        for (0..total) |i| {
            grid[i] = if (coverage[i] > 0) 0.0 else 1.0;
        }
    }

    return grid;
}

/// Reuse the apply function from distance_field
pub const apply = distance_field_mod.apply;

const extractSkeleton = morphology.extractSkeleton;

test "basic skeleton grow" {
    const allocator = std.testing.allocator;
    // 5x5 cross pattern
    var coverage = [_]u8{
        0,   0,   255, 0,   0,
        0,   0,   255, 0,   0,
        255, 255, 255, 255, 255,
        0,   0,   255, 0,   0,
        0,   0,   255, 0,   0,
    };
    const map = try buildRevealMap(allocator, &coverage, 5, 5);
    defer allocator.free(map);

    // Center pixel (2,2) is on the skeleton, should have lower value (revealed earlier)
    // than edge pixels of the cross which are farther from skeleton
    // Outside pixels should be 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map[0 * 5 + 0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map[1 * 5 + 1], 0.001);

    // Center on skeleton = 0.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), map[2 * 5 + 2], 0.001);

    // Tips of cross arms are farther from skeleton center - they should have higher value
    // than center but the skeleton may run through them too (single-pixel wide arms = skeleton)
    // So at minimum, center should be <= tip values (since center IS skeleton = 0)
    try std.testing.expect(map[2 * 5 + 2] <= map[0 * 5 + 2]);
}

test "empty coverage" {
    const allocator = std.testing.allocator;
    var coverage: [0]u8 = .{};
    const map = try buildRevealMap(allocator, &coverage, 0, 0);
    defer allocator.free(map);
    try std.testing.expectEqual(@as(usize, 0), map.len);
}
