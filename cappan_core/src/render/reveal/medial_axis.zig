const std = @import("std");
const contour_trace_mod = @import("contour_trace.zig");
const morphology = @import("morphology.zig");
pub const ContourOrdering = contour_trace_mod.ContourOrdering;

pub const MedialAxisOptions = struct {
    ordering: contour_trace_mod.ContourOrdering = .font_order,
};

pub const SkeletonPoint = struct {
    x: u16,
    y: u16,
    radius: f32,
};

pub const MedialAxisAnimation = struct {
    path: []SkeletonPoint,
    cumulative_dist: []f32,
    total_length: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MedialAxisAnimation) void {
        self.allocator.free(self.path);
        self.allocator.free(self.cumulative_dist);
    }
};

fn computeDistanceField(allocator: std.mem.Allocator, coverage: []const u8, width: u32, height: u32) ![]f32 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total = w * h;

    if (total == 0) {
        return try allocator.alloc(f32, 0);
    }

    const grid = try allocator.alloc(f32, total);
    errdefer allocator.free(grid);

    for (0..total) |i| {
        grid[i] = if (coverage[i] > 0) 1e10 else 0.0;
    }

    try morphology.squaredEdt2dInPlace(allocator, grid, w, h);

    // Take sqrt
    for (0..total) |i| {
        grid[i] = @sqrt(grid[i]);
    }

    return grid;
}

const extractSkeleton = morphology.extractSkeleton;

fn shouldReverseForWritingOrder(path: []const SkeletonPoint) bool {
    if (path.len < 2) return false;
    var min_x: u16 = std.math.maxInt(u16);
    var max_x: u16 = 0;
    var min_y: u16 = std.math.maxInt(u16);
    var max_y: u16 = 0;
    for (path) |pt| {
        min_x = @min(min_x, pt.x);
        max_x = @max(max_x, pt.x);
        min_y = @min(min_y, pt.y);
        max_y = @max(max_y, pt.y);
    }
    const first = path[0];
    const last = path[path.len - 1];
    if (max_x - min_x > max_y - min_y) {
        return first.x > last.x;
    } else {
        return first.y > last.y;
    }
}

const TraceResult = struct {
    path: []SkeletonPoint,
    cumulative_dist: []f32,
    total_length: f32,
};

const ComponentRange = struct {
    start: usize,
    end: usize,
};

fn computeComponentCentroid(path: []const SkeletonPoint, range: ComponentRange) struct { x: f32, y: f32 } {
    const n = range.end - range.start;
    if (n == 0) return .{ .x = 0, .y = 0 };
    var sx: f32 = 0;
    var sy: f32 = 0;
    for (path[range.start..range.end]) |pt| {
        sx += @as(f32, @floatFromInt(pt.x));
        sy += @as(f32, @floatFromInt(pt.y));
    }
    return .{ .x = sx / @as(f32, @floatFromInt(n)), .y = sy / @as(f32, @floatFromInt(n)) };
}

fn tracePaths(allocator: std.mem.Allocator, skeleton: []const u8, dist_field: []const f32, width: u32, height: u32, ordering: contour_trace_mod.ContourOrdering) !TraceResult {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const total = w * h;

    // Collect skeleton pixels
    var pixel_positions: std.ArrayListUnmanaged(u32) = .empty;
    defer pixel_positions.deinit(allocator);

    for (0..total) |i| {
        if (skeleton[i] == 1) {
            try pixel_positions.append(allocator, @intCast(i));
        }
    }

    if (pixel_positions.items.len == 0) {
        const empty_path = try allocator.alloc(SkeletonPoint, 0);
        const empty_dist = try allocator.alloc(f32, 0);
        return .{ .path = empty_path, .cumulative_dist = empty_dist, .total_length = 0 };
    }

    // Build position-to-index map
    var pos_to_idx: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer pos_to_idx.deinit(allocator);

    for (pixel_positions.items, 0..) |pos, i| {
        try pos_to_idx.put(allocator, pos, @intCast(i));
    }

    const n_pixels = pixel_positions.items.len;

    // Build adjacency lists
    const adj_offsets = try allocator.alloc(u32, n_pixels + 1);
    defer allocator.free(adj_offsets);

    var adj_list: std.ArrayListUnmanaged(u32) = .empty;
    defer adj_list.deinit(allocator);

    const dx_offsets = [_]i32{ -1, 0, 1, -1, 1, -1, 0, 1 };
    const dy_offsets = [_]i32{ -1, -1, -1, 0, 0, 1, 1, 1 };

    for (pixel_positions.items, 0..) |pos, i| {
        adj_offsets[i] = @intCast(adj_list.items.len);
        const x: i32 = @intCast(pos % w);
        const y: i32 = @intCast(pos / w);

        for (0..8) |d| {
            const nx = x + dx_offsets[d];
            const ny = y + dy_offsets[d];
            if (nx < 0 or ny < 0 or nx >= @as(i32, @intCast(w)) or ny >= @as(i32, @intCast(h))) continue;
            const npos: u32 = @intCast(@as(usize, @intCast(ny)) * w + @as(usize, @intCast(nx)));
            if (pos_to_idx.get(npos)) |neighbor_idx| {
                try adj_list.append(allocator, neighbor_idx);
            }
        }
    }
    adj_offsets[n_pixels] = @intCast(adj_list.items.len);

    // Compute degrees and find endpoints
    var endpoints: std.ArrayListUnmanaged(u32) = .empty;
    defer endpoints.deinit(allocator);

    for (0..n_pixels) |i| {
        const degree = adj_offsets[i + 1] - adj_offsets[i];
        if (degree == 1) {
            try endpoints.append(allocator, @intCast(i));
        }
    }

    // Sort endpoints by position (y*width+x ascending)
    const SortCtx = struct {
        positions: []const u32,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            return ctx.positions[a] < ctx.positions[b];
        }
    };
    std.mem.sort(u32, endpoints.items, SortCtx{ .positions = pixel_positions.items }, SortCtx.lessThan);

    // Trace paths
    const visited = try allocator.alloc(bool, n_pixels);
    defer allocator.free(visited);
    @memset(visited, false);

    var result_path: std.ArrayListUnmanaged(SkeletonPoint) = .empty;
    defer result_path.deinit(allocator);

    var components: std.ArrayListUnmanaged(ComponentRange) = .empty;
    defer components.deinit(allocator);

    // Trace from endpoints first
    for (endpoints.items) |ep_idx| {
        if (visited[ep_idx]) continue;
        const comp_start = result_path.items.len;
        try traceFrom(ep_idx, pixel_positions.items, adj_offsets, adj_list.items, visited, dist_field, w, allocator, &result_path, null);
        if (result_path.items.len > comp_start) {
            if (ordering == .writing_order and shouldReverseForWritingOrder(result_path.items[comp_start..])) {
                std.mem.reverse(SkeletonPoint, result_path.items[comp_start..]);
            }
            try components.append(allocator, .{ .start = comp_start, .end = result_path.items.len });
        }
    }

    // Handle remaining unvisited pixels (cycles)
    for (0..n_pixels) |i| {
        if (!visited[i]) {
            const comp_start = result_path.items.len;
            try traceFrom(@intCast(i), pixel_positions.items, adj_offsets, adj_list.items, visited, dist_field, w, allocator, &result_path, null);
            if (result_path.items.len > comp_start) {
                if (ordering == .writing_order and shouldReverseForWritingOrder(result_path.items[comp_start..])) {
                    std.mem.reverse(SkeletonPoint, result_path.items[comp_start..]);
                }
                try components.append(allocator, .{ .start = comp_start, .end = result_path.items.len });
            }
        }
    }

    // Sort components by ordering (if not font_order)
    const raw_path = result_path.items;

    const indices = try allocator.alloc(usize, components.items.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = i;

    switch (ordering) {
        .font_order => {}, // keep as-is
        .writing_order => {
            const WritingCtx = struct {
                path: []const SkeletonPoint,
                ranges: []const ComponentRange,
                fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    const ca = computeComponentCentroid(ctx.path, ctx.ranges[a]);
                    const cb = computeComponentCentroid(ctx.path, ctx.ranges[b]);
                    if (@abs(ca.x - cb.x) > 5.0) return ca.x < cb.x;
                    return ca.y < cb.y;
                }
            };
            std.mem.sort(usize, indices, WritingCtx{ .path = raw_path, .ranges = components.items }, WritingCtx.lessThan);
        },
        .stroke_heuristic => {
            const StrokeCtx = struct {
                path: []const SkeletonPoint,
                ranges: []const ComponentRange,
                width: usize,
                fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    const ra = ctx.ranges[a];
                    const rb = ctx.ranges[b];
                    if (ra.end <= ra.start) return false;
                    if (rb.end <= rb.start) return true;
                    const pa = ctx.path[ra.start];
                    const pb = ctx.path[rb.start];
                    const va = @as(usize, pa.y) * ctx.width + @as(usize, pa.x);
                    const vb = @as(usize, pb.y) * ctx.width + @as(usize, pb.x);
                    return va < vb;
                }
            };
            std.mem.sort(usize, indices, StrokeCtx{ .path = raw_path, .ranges = components.items, .width = w }, StrokeCtx.lessThan);
        },
        .area_priority => {
            const AreaCtx = struct {
                ranges: []const ComponentRange,
                fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    const la = ctx.ranges[a].end - ctx.ranges[a].start;
                    const lb = ctx.ranges[b].end - ctx.ranges[b].start;
                    return la > lb; // largest first
                }
            };
            std.mem.sort(usize, indices, AreaCtx{ .ranges = components.items }, AreaCtx.lessThan);
        },
    }

    // Rebuild path in component order
    var sorted_path: std.ArrayListUnmanaged(SkeletonPoint) = .empty;
    errdefer sorted_path.deinit(allocator);
    try sorted_path.ensureTotalCapacity(allocator, raw_path.len);
    for (indices) |ci| {
        const range = components.items[ci];
        try sorted_path.appendSlice(allocator, raw_path[range.start..range.end]);
    }

    // result_path is freed by defer above; sorted_path becomes the output
    // Compute cumulative distances
    const path_slice = try sorted_path.toOwnedSlice(allocator);
    errdefer allocator.free(path_slice);

    const cumulative = try allocator.alloc(f32, path_slice.len);
    errdefer allocator.free(cumulative);

    var total_len: f32 = 0;
    for (path_slice, 0..) |pt, i| {
        if (i == 0) {
            cumulative[0] = 0;
        } else {
            const prev = path_slice[i - 1];
            const ddx = @as(f32, @floatFromInt(pt.x)) - @as(f32, @floatFromInt(prev.x));
            const ddy = @as(f32, @floatFromInt(pt.y)) - @as(f32, @floatFromInt(prev.y));
            total_len += @sqrt(ddx * ddx + ddy * ddy);
            cumulative[i] = total_len;
        }
    }

    return .{ .path = path_slice, .cumulative_dist = cumulative, .total_length = total_len };
}

fn traceFrom(
    start_idx: u32,
    positions: []const u32,
    adj_offsets: []const u32,
    adj_list: []const u32,
    visited: []bool,
    dist_field: []const f32,
    w: usize,
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(SkeletonPoint),
    prev_dir: ?[2]f32,
) !void {
    var current = start_idx;
    var dir = prev_dir;

    while (!visited[current]) {
        visited[current] = true;
        const pos = positions[current];
        const px: u16 = @intCast(pos % w);
        const py: u16 = @intCast(pos / w);
        try result.append(allocator, .{
            .x = px,
            .y = py,
            .radius = dist_field[pos],
        });

        // Find next unvisited neighbor
        const adj_start = adj_offsets[current];
        const adj_end = adj_offsets[current + 1];

        var best_neighbor: ?u32 = null;
        var best_angle_diff: f32 = std.math.inf(f32);

        for (adj_start..adj_end) |ai| {
            const neighbor = adj_list[ai];
            if (visited[neighbor]) continue;

            if (dir) |d| {
                const npos = positions[neighbor];
                const nnx = @as(f32, @floatFromInt(npos % w)) - @as(f32, @floatFromInt(px));
                const nny = @as(f32, @floatFromInt(npos / w)) - @as(f32, @floatFromInt(py));
                const new_angle = std.math.atan2(nny, nnx);
                const old_angle = std.math.atan2(d[1], d[0]);
                var angle_diff = @abs(new_angle - old_angle);
                if (angle_diff > std.math.pi) angle_diff = 2.0 * std.math.pi - angle_diff;
                if (angle_diff < best_angle_diff) {
                    best_angle_diff = angle_diff;
                    best_neighbor = neighbor;
                }
            } else {
                best_neighbor = neighbor;
                break;
            }
        }

        if (best_neighbor) |next| {
            const npos = positions[next];
            dir = .{
                @as(f32, @floatFromInt(npos % w)) - @as(f32, @floatFromInt(px)),
                @as(f32, @floatFromInt(npos / w)) - @as(f32, @floatFromInt(py)),
            };
            current = next;
        } else {
            break;
        }
    }
}

pub fn buildAnimation(
    allocator: std.mem.Allocator,
    coverage: []const u8,
    width: u32,
    height: u32,
    options: MedialAxisOptions,
) !MedialAxisAnimation {
    const dist_field = try computeDistanceField(allocator, coverage, width, height);
    defer allocator.free(dist_field);

    const skeleton = try extractSkeleton(allocator, coverage, width, height);
    defer allocator.free(skeleton);

    const trace = try tracePaths(allocator, skeleton, dist_field, width, height, options.ordering);

    return .{
        .path = trace.path,
        .cumulative_dist = trace.cumulative_dist,
        .total_length = trace.total_length,
        .allocator = allocator,
    };
}

pub fn renderAtProgress(
    animation: MedialAxisAnimation,
    full_coverage: []const u8,
    output: []u8,
    width: u32,
    height: u32,
    progress: f32,
) void {
    @memset(output, 0);

    if (animation.total_length == 0 or animation.path.len == 0) return;

    const clamped = std.math.clamp(progress, 0.0, 1.0);
    if (clamped == 0.0) return;
    const target = clamped * animation.total_length;

    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);

    for (animation.path, 0..) |pt, i| {
        if (animation.cumulative_dist[i] > target) break;

        const max_r = @as(f32, @floatFromInt(@max(width, height)));
        const r = @min(pt.radius, max_r);
        const ceil_r = @as(i32, @intFromFloat(@ceil(r)));
        const cx: i32 = @intCast(pt.x);
        const cy: i32 = @intCast(pt.y);
        const r_sq = r * r;

        var dy: i32 = -ceil_r;
        while (dy <= ceil_r) : (dy += 1) {
            var dx: i32 = -ceil_r;
            while (dx <= ceil_r) : (dx += 1) {
                const px = cx + dx;
                const py = cy + dy;
                if (px < 0 or py < 0 or px >= w or py >= h) continue;
                const df = @as(f32, @floatFromInt(dx));
                const dyf = @as(f32, @floatFromInt(dy));
                if (df * df + dyf * dyf > r_sq) continue;
                const upx: usize = @intCast(px);
                const upy: usize = @intCast(py);
                const idx = upy * @as(usize, @intCast(width)) + upx;
                output[idx] = full_coverage[idx];
            }
        }
    }
}

test "distance field basic" {
    const allocator = std.testing.allocator;
    var coverage = [_]u8{
        0,   0,   255, 0,   0,
        0,   0,   255, 0,   0,
        255, 255, 255, 255, 255,
        0,   0,   255, 0,   0,
        0,   0,   255, 0,   0,
    };
    const dist = try computeDistanceField(allocator, &coverage, 5, 5);
    defer allocator.free(dist);
    try std.testing.expect(dist[2 * 5 + 2] >= dist[0 * 5 + 2]);
    try std.testing.expect(dist[2 * 5 + 2] >= dist[2 * 5 + 0]);
}

test "skeleton extraction simple rectangle" {
    const allocator = std.testing.allocator;
    var coverage: [50]u8 = undefined;
    for (&coverage) |*c| c.* = 255;
    const skeleton = try extractSkeleton(allocator, &coverage, 10, 5);
    defer allocator.free(skeleton);
    var center_count: u32 = 0;
    for (0..10) |x| {
        if (skeleton[2 * 10 + x] == 1) center_count += 1;
    }
    try std.testing.expect(center_count > 0);
}

test "buildAnimation and renderAtProgress" {
    const allocator = std.testing.allocator;
    var coverage: [64]u8 = undefined;
    for (&coverage) |*c| c.* = 200;
    var anim = try buildAnimation(allocator, &coverage, 8, 8, .{});
    defer anim.deinit();

    var out0: [64]u8 = undefined;
    renderAtProgress(anim, &coverage, &out0, 8, 8, 0.0);
    for (out0) |v| try std.testing.expectEqual(@as(u8, 0), v);

    var out1: [64]u8 = undefined;
    renderAtProgress(anim, &coverage, &out1, 8, 8, 1.0);
    var nonzero: u32 = 0;
    for (out1) |v| if (v > 0) {
        nonzero += 1;
    };
    try std.testing.expect(nonzero > 0);
}

test "empty coverage" {
    const allocator = std.testing.allocator;
    var coverage: [16]u8 = .{0} ** 16;
    var anim = try buildAnimation(allocator, &coverage, 4, 4, .{});
    defer anim.deinit();
    try std.testing.expectEqual(@as(f32, 0), anim.total_length);

    var out: [16]u8 = undefined;
    renderAtProgress(anim, &coverage, &out, 4, 4, 1.0);
    for (out) |v| try std.testing.expectEqual(@as(u8, 0), v);
}
