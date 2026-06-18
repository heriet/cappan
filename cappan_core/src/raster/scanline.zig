const std = @import("std");
const outline_mod = @import("outline.zig");

pub const Edge = struct {
    y_top: f32,
    y_bottom: f32,
    x_at_y_top: f32,
    dx_per_dy: f32,
    direction: i8, // +1 downward, -1 upward
};

const SUPERSAMPLE_N: usize = 8;

pub fn buildEdges(allocator: std.mem.Allocator, segments: []const outline_mod.Segment) ![]Edge {
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);

    for (segments) |seg| {
        // Skip near-horizontal edges
        const dy = seg.y1 - seg.y0;
        if (@abs(dy) < 0.001) continue;

        var y_top: f32 = undefined;
        var y_bottom: f32 = undefined;
        var x_at_top: f32 = undefined;
        var direction: i8 = undefined;

        if (seg.y0 < seg.y1) {
            // Going down
            y_top = seg.y0;
            y_bottom = seg.y1;
            x_at_top = seg.x0;
            direction = 1;
        } else {
            // Going up
            y_top = seg.y1;
            y_bottom = seg.y0;
            x_at_top = seg.x1;
            direction = -1;
        }

        // dx_per_dy: for downward edges (direction=1), x_at_top is x0 and we walk forward in y.
        // For upward edges (direction=-1), x_at_top is x1 and we walk forward in y from y1 to y0.
        // In both cases, (x1-x0)/dy gives the correct slope when walking from y_top to y_bottom.
        const dx_per_dy = (seg.x1 - seg.x0) / dy;

        try edges.append(allocator, .{
            .y_top = y_top,
            .y_bottom = y_bottom,
            .x_at_y_top = x_at_top,
            .dx_per_dy = dx_per_dy,
            .direction = direction,
        });
    }

    return edges.toOwnedSlice(allocator);
}

const Intersection = struct {
    x: f32,
    direction: i8,
};

fn compareIntersections(_: void, a: Intersection, b: Intersection) bool {
    return a.x < b.x;
}

/// Rasterize segments into a grayscale pixel buffer using 8x supersampling
pub fn rasterize(
    allocator: std.mem.Allocator,
    segments: []const outline_mod.Segment,
    width: u32,
    height: u32,
) ![]u8 {
    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    @memset(pixels, 0);

    const edges = try buildEdges(allocator, segments);
    defer allocator.free(edges);

    if (edges.len == 0) return pixels;

    var intersections: std.ArrayList(Intersection) = .empty;
    defer intersections.deinit(allocator);

    const w = @as(usize, width);

    // Per-row coverage buffer
    const coverage = try allocator.alloc(u16, w);
    defer allocator.free(coverage);

    for (0..height) |y| {
        @memset(coverage, 0);

        for (0..SUPERSAMPLE_N) |s| {
            const sub_y = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, SUPERSAMPLE_N);

            intersections.clearRetainingCapacity();

            for (edges) |edge| {
                if (sub_y >= edge.y_top and sub_y < edge.y_bottom) {
                    const x = edge.x_at_y_top + (sub_y - edge.y_top) * edge.dx_per_dy;
                    try intersections.append(allocator, .{ .x = x, .direction = edge.direction });
                }
            }

            std.mem.sort(Intersection, intersections.items, {}, compareIntersections);

            // Apply non-zero winding fill rule
            var winding: i32 = 0;
            var ix_idx: usize = 0;

            for (0..w) |px| {
                const px_left = @as(f32, @floatFromInt(px));

                // Process intersections to the left of this pixel
                while (ix_idx < intersections.items.len and intersections.items[ix_idx].x < px_left) {
                    winding += intersections.items[ix_idx].direction;
                    ix_idx += 1;
                }

                if (winding != 0) {
                    coverage[px] += 1;
                }
            }
        }

        // Convert coverage to grayscale
        for (0..w) |px| {
            const value = @as(u8, @intCast(@min(coverage[px] * 255 / SUPERSAMPLE_N, 255)));
            pixels[y * w + px] = value;
        }
    }

    return pixels;
}

test "rasterize a simple triangle" {
    // Triangle covering roughly the center of a 16x16 bitmap
    const segments = [_]outline_mod.Segment{
        .{ .x0 = 8, .y0 = 2, .x1 = 14, .y1 = 14 },
        .{ .x0 = 14, .y0 = 14, .x1 = 2, .y1 = 14 },
        .{ .x0 = 2, .y0 = 14, .x1 = 8, .y1 = 2 },
    };

    const pixels = try rasterize(std.testing.allocator, &segments, 16, 16);
    defer std.testing.allocator.free(pixels);

    // Center pixels should have non-zero coverage
    try std.testing.expect(pixels[8 * 16 + 8] > 0);

    // Corner pixels should be zero (outside triangle)
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
}
