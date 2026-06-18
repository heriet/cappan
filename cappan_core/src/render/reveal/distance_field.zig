const std = @import("std");

pub const DistanceFieldOptions = struct {};

/// Compute a reveal map where 0.0 = revealed first (interior), 1.0 = revealed last (edge).
/// Uses Felzenszwalb-Huttenlocher EDT algorithm.
pub fn buildRevealMap(allocator: std.mem.Allocator, coverage: []const u8, width: u32, height: u32) ![]f32 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total = w * h;

    if (total == 0) {
        return try allocator.alloc(f32, 0);
    }

    // Compute distance from boundary for interior pixels
    // Interior pixels (coverage > 0) get distance to nearest boundary
    // Boundary = inside pixel adjacent to outside pixel
    const grid = try allocator.alloc(f32, total);
    errdefer allocator.free(grid);

    // Initialize: inside pixels get large value, outside get 0
    for (0..total) |i| {
        grid[i] = if (coverage[i] > 0) 1e10 else 0.0;
    }

    const max_dim = @max(w, h);
    const temp = try allocator.alloc(f32, max_dim);
    defer allocator.free(temp);
    const output_buf = try allocator.alloc(f32, max_dim);
    defer allocator.free(output_buf);
    const v_buf = try allocator.alloc(usize, max_dim);
    defer allocator.free(v_buf);
    const z_buf = try allocator.alloc(f32, max_dim + 1);
    defer allocator.free(z_buf);

    // EDT rows
    for (0..h) |y| {
        const row_start = y * w;
        edt1d(grid[row_start .. row_start + w], w, v_buf, z_buf, output_buf[0..w]);
        @memcpy(grid[row_start .. row_start + w], output_buf[0..w]);
    }

    // EDT columns
    for (0..w) |x| {
        for (0..h) |y| {
            temp[y] = grid[y * w + x];
        }
        edt1d(temp[0..h], h, v_buf, z_buf, output_buf[0..h]);
        for (0..h) |y| {
            grid[y * w + x] = output_buf[y];
        }
    }

    // sqrt and normalize
    var max_dist: f32 = 0;
    for (0..total) |i| {
        grid[i] = @sqrt(grid[i]);
        if (coverage[i] > 0 and grid[i] > max_dist) {
            max_dist = grid[i];
        }
    }

    // Normalize: interior (high distance) -> 0.0 (revealed first), edge (low distance) -> 1.0 (revealed last)
    // Non-glyph pixels get 1.0 (never revealed by threshold)
    if (max_dist > 0) {
        for (0..total) |i| {
            if (coverage[i] > 0) {
                grid[i] = 1.0 - grid[i] / max_dist;
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

// Felzenszwalb-Huttenlocher 1D distance transform
fn edt1d(f: []const f32, n: usize, v_buf: []usize, z_buf: []f32, output: []f32) void {
    if (n == 0) return;
    if (n == 1) {
        output[0] = f[0];
        return;
    }

    var k: usize = 0;
    v_buf[0] = 0;
    z_buf[0] = -1e10;
    z_buf[1] = 1e10;

    for (1..n) |q| {
        const q_f = @as(f32, @floatFromInt(q));
        while (true) {
            const v_f = @as(f32, @floatFromInt(v_buf[k]));
            const s = ((f[q] + q_f * q_f) - (f[v_buf[k]] + v_f * v_f)) / (2.0 * q_f - 2.0 * v_f);
            if (k > 0 and s <= z_buf[k]) {
                k -= 1;
            } else {
                k += 1;
                v_buf[k] = q;
                z_buf[k] = s;
                z_buf[k + 1] = 1e10;
                break;
            }
        }
    }

    k = 0;
    for (0..n) |q| {
        const q_f = @as(f32, @floatFromInt(q));
        while (z_buf[k + 1] < q_f) : (k += 1) {}
        const v_f = @as(f32, @floatFromInt(v_buf[k]));
        output[q] = (q_f - v_f) * (q_f - v_f) + f[v_buf[k]];
    }
}

/// Apply the reveal map threshold to produce output coverage.
/// Pixels with reveal_map value <= progress are fully revealed.
/// A soft edge of `edge` (in normalized 0-1 space) provides smooth transition.
pub fn apply(
    full_coverage: []const u8,
    output: []u8,
    reveal_map: []const f32,
    progress: f32,
) void {
    const edge: f32 = 0.05;
    for (full_coverage, 0..) |cov, i| {
        if (cov == 0) {
            output[i] = 0;
            continue;
        }
        const threshold = reveal_map[i];
        if (threshold <= progress - edge) {
            output[i] = cov;
        } else if (threshold >= progress) {
            output[i] = 0;
        } else {
            const t = (progress - threshold) / edge;
            output[i] = @intFromFloat(@round(@as(f32, @floatFromInt(cov)) * t));
        }
    }
}

test "buildRevealMap basic" {
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

    // Center pixel (2,2) should have lowest reveal order (revealed first = interior)
    try std.testing.expect(map[2 * 5 + 2] < map[0 * 5 + 2]);
    // Edge pixels should have higher reveal order
    try std.testing.expect(map[0 * 5 + 2] > map[2 * 5 + 2]);
    // Outside pixels should be 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map[0 * 5 + 0], 0.001);
}

test "apply threshold" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var coverage = [_]u8{ 255, 200, 100, 50 };
    var reveal_map = [_]f32{ 0.0, 0.3, 0.6, 0.9 };
    var output: [4]u8 = undefined;

    // At progress 0: nothing visible
    apply(&coverage, &output, &reveal_map, 0.0);
    try std.testing.expectEqual(@as(u8, 0), output[3]);

    // At progress 1: everything visible
    apply(&coverage, &output, &reveal_map, 1.0);
    try std.testing.expectEqual(@as(u8, 255), output[0]);
    try std.testing.expectEqual(@as(u8, 200), output[1]);
    try std.testing.expectEqual(@as(u8, 100), output[2]);
    try std.testing.expectEqual(@as(u8, 50), output[3]);
}

test "empty coverage" {
    const allocator = std.testing.allocator;
    var coverage: [0]u8 = .{};
    const map = try buildRevealMap(allocator, &coverage, 0, 0);
    defer allocator.free(map);
    try std.testing.expectEqual(@as(usize, 0), map.len);
}
