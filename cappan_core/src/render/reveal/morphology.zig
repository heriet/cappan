const std = @import("std");

// Shared morphology primitives used by distance_field.zig, medial_axis.zig, and
// skeleton_grow.zig. These three previously each carried their own byte-identical
// copy of `edt1d`, the row-then-column 2D EDT wrapper, and (medial_axis.zig /
// skeleton_grow.zig only) `extractSkeleton`/`countTransitions`. Verified identical
// across all copies before being consolidated here (see Batch 2 Phase A/B dedup
// pass); each caller keeps its own seeding (how `coverage` maps to the initial
// large-value/zero grid) and its own post-EDT sqrt+normalization formula, since
// those differ per reveal strategy.

/// Felzenszwalb-Huttenlocher 1D squared-distance transform (parabola lower envelope).
/// `f` holds squared "seed" values (0 at sources, a large sentinel elsewhere);
/// `output` receives the squared distance to the nearest source along this 1D line.
/// `v_buf`/`z_buf` are caller-owned scratch, sized `n` and `n + 1` respectively.
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

/// Runs the 2D squared-EDT (row pass then column pass) on `grid` in place.
/// `grid` must already be seeded by the caller (0.0 at "source" pixels, a large
/// sentinel such as 1e10 elsewhere) and have exactly `width * height` elements.
/// On return, `grid[y*width+x]` holds the squared distance from that pixel to the
/// nearest seeded-zero pixel. Does NOT take the sqrt and does NOT normalize --
/// callers do that themselves afterward, since the exact formula (and whether a
/// sqrt is taken at all) differs per caller. Owns its own scratch (allocated and
/// freed within this call), matching prior per-call-site behavior exactly.
pub fn squaredEdt2dInPlace(allocator: std.mem.Allocator, grid: []f32, width: usize, height: usize) !void {
    const w = width;
    const h = height;
    if (w == 0 or h == 0) return;

    const max_dim = @max(w, h);
    const temp = try allocator.alloc(f32, max_dim);
    defer allocator.free(temp);
    const output_buf = try allocator.alloc(f32, max_dim);
    defer allocator.free(output_buf);
    const v_buf = try allocator.alloc(usize, max_dim);
    defer allocator.free(v_buf);
    const z_buf = try allocator.alloc(f32, max_dim + 1);
    defer allocator.free(z_buf);

    // Transform rows
    for (0..h) |y| {
        const row_start = y * w;
        edt1d(grid[row_start .. row_start + w], w, v_buf, z_buf, output_buf[0..w]);
        @memcpy(grid[row_start .. row_start + w], output_buf[0..w]);
    }

    // Transform columns
    for (0..w) |x| {
        for (0..h) |y| {
            temp[y] = grid[y * w + x];
        }
        edt1d(temp[0..h], h, v_buf, z_buf, output_buf[0..h]);
        for (0..h) |y| {
            grid[y * w + x] = output_buf[y];
        }
    }
}

fn countTransitions(p2: u8, p3: u8, p4: u8, p5: u8, p6: u8, p7: u8, p8: u8, p9: u8) u8 {
    var count: u8 = 0;
    const seq = [9]u8{ p2, p3, p4, p5, p6, p7, p8, p9, p2 };
    for (0..8) |i| {
        if (seq[i] == 0 and seq[i + 1] == 1) count += 1;
    }
    return count;
}

/// Zhang-Suen thinning: reduces a binary coverage mask to a 1px-wide skeleton.
/// Returns a freshly-allocated `width*height` buffer of 0/1 values (1 = skeleton
/// pixel), which the caller owns and must free.
pub fn extractSkeleton(allocator: std.mem.Allocator, coverage: []const u8, width: u32, height: u32) ![]u8 {
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

test "squaredEdt2dInPlace matches direct edt1d row/column composition for a small grid" {
    // A 3x3 grid with a single seeded zero at the center; verify the corner
    // distances come out as expected (squared distance 2 = sqrt(2)^2 diagonal).
    var grid = [_]f32{
        1e10, 1e10, 1e10,
        1e10, 0.0,  1e10,
        1e10, 1e10, 1e10,
    };
    try squaredEdt2dInPlace(std.testing.allocator, &grid, 3, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), grid[4], 0.001); // center
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), grid[1], 0.001); // directly above
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), grid[0], 0.001); // diagonal corner
}

test "extractSkeleton keeps the center of a cross pattern and never adds pixels" {
    // 5x5 cross (matches the pattern already used by distance_field.zig's and
    // skeleton_grow.zig's own tests): thinning must not turn any originally-0 pixel
    // into a 1, and the cross's 1px-wide arms mean the center stays part of the
    // skeleton (a single-pixel-wide shape is already its own skeleton).
    const coverage = [_]u8{
        0, 0, 1, 0, 0,
        0, 0, 1, 0, 0,
        1, 1, 1, 1, 1,
        0, 0, 1, 0, 0,
        0, 0, 1, 0, 0,
    };
    const skeleton = try extractSkeleton(std.testing.allocator, &coverage, 5, 5);
    defer std.testing.allocator.free(skeleton);

    try std.testing.expectEqual(@as(usize, 25), skeleton.len);
    try std.testing.expectEqual(@as(u8, 1), skeleton[2 * 5 + 2]); // center stays on skeleton
    for (coverage, 0..) |c, i| {
        if (c == 0) try std.testing.expectEqual(@as(u8, 0), skeleton[i]);
    }
}

test "extractSkeleton returns input unchanged for width or height <= 2" {
    const coverage = [_]u8{ 1, 1 };
    const skeleton = try extractSkeleton(std.testing.allocator, &coverage, 2, 1);
    defer std.testing.allocator.free(skeleton);
    try std.testing.expectEqualSlices(u8, &coverage, skeleton);
}
