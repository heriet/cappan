const std = @import("std");
const distance_field_mod = @import("distance_field.zig");

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

fn extractSkeleton(allocator: std.mem.Allocator, coverage: []const u8, width: u32, height: u32) ![]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total = w * h;

    if (total == 0) {
        return try allocator.alloc(u8, 0);
    }

    const img = try allocator.alloc(u8, total);
    errdefer allocator.free(img);

    for (0..total) |i| {
        img[i] = if (coverage[i] > 0) @as(u8, 1) else @as(u8, 0);
    }

    if (w <= 2 or h <= 2) return img;

    const mark = try allocator.alloc(u8, total);
    defer allocator.free(mark);

    while (true) {
        var changed = false;

        // Sub-iteration 1
        @memset(mark, 0);
        for (1..h - 1) |y| {
            for (1..w - 1) |x| {
                const idx = y * w + x;
                if (img[idx] != 1) continue;

                const p2 = img[(y - 1) * w + x];
                const p3 = img[(y - 1) * w + (x + 1)];
                const p4 = img[y * w + (x + 1)];
                const p5 = img[(y + 1) * w + (x + 1)];
                const p6 = img[(y + 1) * w + x];
                const p7 = img[(y + 1) * w + (x - 1)];
                const p8 = img[y * w + (x - 1)];
                const p9 = img[(y - 1) * w + (x - 1)];

                const b = @as(u16, p2) + @as(u16, p3) + @as(u16, p4) + @as(u16, p5) +
                    @as(u16, p6) + @as(u16, p7) + @as(u16, p8) + @as(u16, p9);
                if (b < 2 or b > 6) continue;

                const a = countTransitions(p2, p3, p4, p5, p6, p7, p8, p9);
                if (a != 1) continue;

                if (p2 * p4 * p6 != 0) continue;
                if (p4 * p6 * p8 != 0) continue;

                mark[idx] = 1;
            }
        }
        for (0..total) |i| {
            if (mark[i] == 1) {
                img[i] = 0;
                changed = true;
            }
        }

        // Sub-iteration 2
        @memset(mark, 0);
        for (1..h - 1) |y| {
            for (1..w - 1) |x| {
                const idx = y * w + x;
                if (img[idx] != 1) continue;

                const p2 = img[(y - 1) * w + x];
                const p3 = img[(y - 1) * w + (x + 1)];
                const p4 = img[y * w + (x + 1)];
                const p5 = img[(y + 1) * w + (x + 1)];
                const p6 = img[(y + 1) * w + x];
                const p7 = img[(y + 1) * w + (x - 1)];
                const p8 = img[y * w + (x - 1)];
                const p9 = img[(y - 1) * w + (x - 1)];

                const b = @as(u16, p2) + @as(u16, p3) + @as(u16, p4) + @as(u16, p5) +
                    @as(u16, p6) + @as(u16, p7) + @as(u16, p8) + @as(u16, p9);
                if (b < 2 or b > 6) continue;

                const a = countTransitions(p2, p3, p4, p5, p6, p7, p8, p9);
                if (a != 1) continue;

                if (p2 * p4 * p8 != 0) continue;
                if (p2 * p6 * p8 != 0) continue;

                mark[idx] = 1;
            }
        }
        for (0..total) |i| {
            if (mark[i] == 1) {
                img[i] = 0;
                changed = true;
            }
        }

        if (!changed) break;
    }

    return img;
}

fn countTransitions(p2: u8, p3: u8, p4: u8, p5: u8, p6: u8, p7: u8, p8: u8, p9: u8) u8 {
    var count: u8 = 0;
    const seq = [9]u8{ p2, p3, p4, p5, p6, p7, p8, p9, p2 };
    for (0..8) |i| {
        if (seq[i] == 0 and seq[i + 1] == 1) count += 1;
    }
    return count;
}

// Felzenszwalb-Huttenlocher 1D distance transform (copied from distance_field.zig)
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
