const std = @import("std");
const outline_mod = @import("outline.zig");

// pub: rasterizer.zig's RasterScratch holds a scratch `std.ArrayList(Cell)` (reused
// across rasterize() calls instead of allocated fresh every time), threaded through
// via scanline.zig's RasterizeScratch (the single dispatch point for both raster
// methods).
pub const Cell = struct {
    cover: f32 = 0,
    area: f32 = 0,
};

pub fn rasterize(
    allocator: std.mem.Allocator,
    segments: []const outline_mod.Segment,
    width: u32,
    height: u32,
    cells_scratch: ?*std.ArrayList(Cell),
) ![]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    const pixels = try allocator.alloc(u8, w * h);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    if (w == 0 or h == 0) return pixels;

    var local_cells: std.ArrayList(Cell) = .empty;
    defer local_cells.deinit(allocator);
    const cells_list: *std.ArrayList(Cell) = cells_scratch orelse &local_cells;
    try cells_list.resize(allocator, w * h);
    const cells = cells_list.items;
    @memset(cells, .{});

    for (segments) |seg| {
        renderLine(cells, w, h, seg.x0, seg.y0, seg.x1, seg.y1);
    }

    for (0..h) |y| {
        var acc: f32 = 0;
        for (0..w) |x| {
            const cell = cells[y * w + x];
            const coverage = @abs(acc + cell.area * 0.5);
            acc += cell.cover;
            pixels[y * w + x] = @intFromFloat(@min(coverage * 255.0, 255.0));
        }
    }

    return pixels;
}

fn renderLine(cells: []Cell, w: usize, h: usize, x0: f32, y0: f32, x1: f32, y1: f32) void {
    const dy = y1 - y0;
    if (@abs(dy) < 1e-7) return;

    const dx = x1 - x0;
    const h_f: f32 = @floatFromInt(h);

    var t_start: f32 = 0;
    var t_end: f32 = 1;

    if (dy > 0) {
        if (y0 >= h_f or y1 <= 0) return;
        if (y0 < 0) t_start = -y0 / dy;
        if (y1 > h_f) t_end = (h_f - y0) / dy;
    } else {
        if (y1 >= h_f or y0 <= 0) return;
        if (y0 > h_f) t_start = (h_f - y0) / dy;
        if (y1 < 0) t_end = -y0 / dy;
    }

    if (t_start >= t_end) return;

    const cx0 = x0 + t_start * dx;
    const cy0 = y0 + t_start * dy;
    const cy1 = y0 + t_end * dy;

    const slope = dx / dy;
    var cur_x = cx0;
    var cur_y = cy0;

    if (dy > 0) {
        while (cur_y < cy1 - 1e-7) {
            const iy: usize = @intFromFloat(@floor(cur_y));
            if (iy >= h) break;

            const row_end = @min(@as(f32, @floatFromInt(iy + 1)), cy1);
            const end_x = cur_x + (row_end - cur_y) * slope;

            renderRowSegment(cells, w, iy, cur_x, cur_y, end_x, row_end);

            cur_x = end_x;
            cur_y = row_end;
        }
    } else {
        while (cur_y > cy1 + 1e-7) {
            const floor_y = @floor(cur_y);
            const iy_f: f32 = if (cur_y == floor_y) floor_y - 1.0 else floor_y;
            if (iy_f < 0) break;
            const iy: usize = @intFromFloat(iy_f);
            if (iy >= h) {
                const row_top: f32 = @floatFromInt(iy);
                cur_x += (row_top - cur_y) * slope;
                cur_y = row_top;
                continue;
            }

            const row_top = @max(@as(f32, @floatFromInt(iy)), cy1);
            const end_x = cur_x + (row_top - cur_y) * slope;

            renderRowSegment(cells, w, iy, cur_x, cur_y, end_x, row_top);

            cur_x = end_x;
            cur_y = row_top;
        }
    }
}

fn renderRowSegment(cells: []Cell, w: usize, cy: usize, x0_raw: f32, y0_raw: f32, x1_raw: f32, y1_raw: f32) void {
    const full_dy = y1_raw - y0_raw;
    if (@abs(full_dy) < 1e-10) return;

    const full_dx = x1_raw - x0_raw;
    const w_f: f32 = @floatFromInt(w);

    var x0 = x0_raw;
    var y0 = y0_raw;
    var x1 = x1_raw;
    var y1 = y1_raw;

    if (@abs(full_dx) > 1e-10) {
        const dy_per_dx = full_dy / full_dx;
        const x_lo = @min(x0, x1);
        const x_hi = @max(x0, x1);

        if (x_hi <= 0) {
            addCellContribution(cells, w, cy, 0, full_dy, 0, 0);
            return;
        }
        if (x_lo >= w_f) return;

        if (x0 < 0) {
            y0 += (0 - x0) * dy_per_dx;
            x0 = 0;
        } else if (x1 < 0) {
            y1 += (0 - x1) * dy_per_dx;
            x1 = 0;
        }

        if (x0 > w_f) {
            y0 += (w_f - x0) * dy_per_dx;
            x0 = w_f;
        } else if (x1 > w_f) {
            y1 += (w_f - x1) * dy_per_dx;
            x1 = w_f;
        }

        if (x0 <= 0 and x1 <= 0) {
            addCellContribution(cells, w, cy, 0, y1 - y0, 0, 0);
            return;
        }
    }

    const dy = y1 - y0;
    if (@abs(dy) < 1e-10) return;

    const dx = x1 - x0;

    if (@abs(dx) < 1e-10) {
        const ix: i32 = @intFromFloat(@floor(@max(x0, 0)));
        addCellContribution(cells, w, cy, ix, dy, x0, x0);
        return;
    }

    const dy_per_dx = dy / dx;
    var cur_x = x0;
    var cur_y = y0;

    if (dx > 0) {
        while (cur_x < x1 - 1e-7) {
            const ix: i32 = @intFromFloat(@floor(cur_x));
            const col_right: f32 = @floatFromInt(ix + 1);
            const next_x = @min(col_right, x1);
            const next_y = cur_y + (next_x - cur_x) * dy_per_dx;

            addCellContribution(cells, w, cy, ix, next_y - cur_y, cur_x, next_x);

            cur_x = next_x;
            cur_y = next_y;
        }
    } else {
        while (cur_x > x1 + 1e-7) {
            const floor_x = @floor(cur_x);
            const ix: i32 = if (cur_x == floor_x)
                @as(i32, @intFromFloat(floor_x)) - 1
            else
                @intFromFloat(floor_x);

            const col_left: f32 = @floatFromInt(ix);
            const next_x = @max(col_left, x1);
            const next_y = cur_y + (next_x - cur_x) * dy_per_dx;

            addCellContribution(cells, w, cy, ix, next_y - cur_y, cur_x, next_x);

            cur_x = next_x;
            cur_y = next_y;
        }
    }
}

fn addCellContribution(cells: []Cell, w: usize, cy: usize, cx: i32, dy: f32, x0: f32, x1: f32) void {
    if (cx >= @as(i32, @intCast(w))) return;

    const target_cx: usize = if (cx < 0) 0 else @intCast(cx);
    const cell = &cells[cy * w + target_cx];

    if (cx < 0) {
        cell.cover += dy;
    } else {
        const cx_f: f32 = @floatFromInt(cx);
        cell.cover += dy;
        cell.area += (x0 - cx_f + x1 - cx_f) * dy;
    }
}

test "analytical rasterize a simple triangle" {
    const segments = [_]outline_mod.Segment{
        .{ .x0 = 8, .y0 = 2, .x1 = 14, .y1 = 14 },
        .{ .x0 = 14, .y0 = 14, .x1 = 2, .y1 = 14 },
        .{ .x0 = 2, .y0 = 14, .x1 = 8, .y1 = 2 },
    };

    const pixels = try rasterize(std.testing.allocator, &segments, 16, 16, null);
    defer std.testing.allocator.free(pixels);

    try std.testing.expect(pixels[8 * 16 + 8] > 0);
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
}

test "analytical rectangle coverage" {
    const segments = [_]outline_mod.Segment{
        .{ .x0 = 2.5, .y0 = 1, .x1 = 2.5, .y1 = 4 },
        .{ .x0 = 2.5, .y0 = 4, .x1 = 7.5, .y1 = 4 },
        .{ .x0 = 7.5, .y0 = 4, .x1 = 7.5, .y1 = 1 },
        .{ .x0 = 7.5, .y0 = 1, .x1 = 2.5, .y1 = 1 },
    };

    const pixels = try rasterize(std.testing.allocator, &segments, 10, 5, null);
    defer std.testing.allocator.free(pixels);

    try std.testing.expectEqual(@as(u8, 0), pixels[2 * 10 + 0]);
    try std.testing.expectEqual(@as(u8, 0), pixels[2 * 10 + 1]);

    try std.testing.expect(pixels[2 * 10 + 2] > 100 and pixels[2 * 10 + 2] < 150);

    try std.testing.expectEqual(@as(u8, 255), pixels[2 * 10 + 3]);
    try std.testing.expectEqual(@as(u8, 255), pixels[2 * 10 + 5]);

    try std.testing.expect(pixels[2 * 10 + 7] > 100 and pixels[2 * 10 + 7] < 150);

    try std.testing.expectEqual(@as(u8, 0), pixels[2 * 10 + 8]);
}
