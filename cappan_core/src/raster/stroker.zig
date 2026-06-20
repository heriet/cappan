const std = @import("std");
const outline_mod = @import("outline.zig");

pub const Segment = outline_mod.Segment;

pub const LineJoin = enum { miter, round, bevel };
pub const StrokePosition = enum { center, outside, inside };

const OffsetSegment = struct {
    outer: Segment,
    inner: Segment,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    dir_x: f32,
    dir_y: f32,
};

pub fn generateStrokeOutline(
    allocator: std.mem.Allocator,
    segments: []const Segment,
    width: f32,
    join: LineJoin,
    position: StrokePosition,
    miter_limit: f32,
) ![]Segment {
    if (segments.len == 0 or !(width > 0.0)) return try allocator.alloc(Segment, 0);

    const offsets = try allocator.alloc(OffsetSegment, segments.len);
    defer allocator.free(offsets);

    const outer_offset: f32 = switch (position) {
        .center => width * 0.5,
        .outside => width,
        .inside => 0.0,
    };
    const inner_offset: f32 = switch (position) {
        .center => -width * 0.5,
        .outside => 0.0,
        .inside => -width,
    };

    for (segments, 0..) |seg, i| {
        const dx = seg.x1 - seg.x0;
        const dy = seg.y1 - seg.y0;
        const len = @sqrt(dx * dx + dy * dy);
        if (len <= 0.0001) {
            offsets[i] = .{
                .outer = seg,
                .inner = seg,
                .x0 = seg.x0,
                .y0 = seg.y0,
                .x1 = seg.x1,
                .y1 = seg.y1,
                .dir_x = 0.0,
                .dir_y = 0.0,
            };
            continue;
        }

        const dir_x = dx / len;
        const dir_y = dy / len;
        const nx = -dy / len;
        const ny = dx / len;
        offsets[i] = .{
            .outer = offsetSegment(seg, nx, ny, outer_offset),
            .inner = offsetSegment(seg, nx, ny, inner_offset),
            .x0 = seg.x0,
            .y0 = seg.y0,
            .x1 = seg.x1,
            .y1 = seg.y1,
            .dir_x = dir_x,
            .dir_y = dir_y,
        };
    }

    var out: std.ArrayList(Segment) = .empty;
    errdefer out.deinit(allocator);

    for (offsets, 0..) |off, i| {
        const next = offsets[(i + 1) % offsets.len];
        try appendNonZero(allocator, &out, off.outer);
        try addJoin(
            allocator,
            &out,
            join,
            miter_limit,
            width,
            off.outer.x1,
            off.outer.y1,
            next.outer.x0,
            next.outer.y0,
            off.x1,
            off.y1,
            off.dir_x,
            off.dir_y,
            next.dir_x,
            next.dir_y,
        );
    }

    var i: usize = offsets.len;
    while (i > 0) {
        i -= 1;
        const off = offsets[i];
        const prev = offsets[(i + offsets.len - 1) % offsets.len];
        try appendNonZero(
            allocator,
            &out,
            .{ .x0 = off.inner.x1, .y0 = off.inner.y1, .x1 = off.inner.x0, .y1 = off.inner.y0 },
        );
        try addJoin(
            allocator,
            &out,
            join,
            miter_limit,
            width,
            off.inner.x0,
            off.inner.y0,
            prev.inner.x1,
            prev.inner.y1,
            off.x0,
            off.y0,
            -off.dir_x,
            -off.dir_y,
            -prev.dir_x,
            -prev.dir_y,
        );
    }

    return out.toOwnedSlice(allocator);
}

fn offsetSegment(seg: Segment, nx: f32, ny: f32, amount: f32) Segment {
    return .{
        .x0 = seg.x0 + nx * amount,
        .y0 = seg.y0 + ny * amount,
        .x1 = seg.x1 + nx * amount,
        .y1 = seg.y1 + ny * amount,
    };
}

fn appendLine(allocator: std.mem.Allocator, out: *std.ArrayList(Segment), x0: f32, y0: f32, x1: f32, y1: f32) !void {
    try appendNonZero(allocator, out, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 });
}

fn addJoin(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Segment),
    join: LineJoin,
    miter_limit: f32,
    width: f32,
    curr_x: f32,
    curr_y: f32,
    next_x: f32,
    next_y: f32,
    corner_x: f32,
    corner_y: f32,
    curr_dir_x: f32,
    curr_dir_y: f32,
    next_dir_x: f32,
    next_dir_y: f32,
) !void {
    switch (join) {
        .bevel => try appendLine(allocator, out, curr_x, curr_y, next_x, next_y),
        .miter => try addMiterJoin(
            allocator,
            out,
            miter_limit,
            width,
            curr_x,
            curr_y,
            next_x,
            next_y,
            corner_x,
            corner_y,
            curr_dir_x,
            curr_dir_y,
            next_dir_x,
            next_dir_y,
        ),
        .round => try addRoundJoin(
            allocator,
            out,
            curr_x,
            curr_y,
            next_x,
            next_y,
            corner_x,
            corner_y,
        ),
    }
}

fn addMiterJoin(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Segment),
    miter_limit: f32,
    width: f32,
    curr_x: f32,
    curr_y: f32,
    next_x: f32,
    next_y: f32,
    corner_x: f32,
    corner_y: f32,
    curr_dir_x: f32,
    curr_dir_y: f32,
    next_dir_x: f32,
    next_dir_y: f32,
) !void {
    const cross = curr_dir_x * next_dir_y - curr_dir_y * next_dir_x;
    if (@abs(cross) < 0.000001) {
        try appendLine(allocator, out, curr_x, curr_y, next_x, next_y);
        return;
    }

    const delta_x = next_x - curr_x;
    const delta_y = next_y - curr_y;
    const t = (delta_x * next_dir_y - delta_y * next_dir_x) / cross;
    const ix = curr_x + t * curr_dir_x;
    const iy = curr_y + t * curr_dir_y;

    const mx = ix - corner_x;
    const my = iy - corner_y;
    const miter_length = @sqrt(mx * mx + my * my);
    if (miter_length > miter_limit * width * 0.5) {
        try appendLine(allocator, out, curr_x, curr_y, next_x, next_y);
        return;
    }

    try appendLine(allocator, out, curr_x, curr_y, ix, iy);
    try appendLine(allocator, out, ix, iy, next_x, next_y);
}

fn addRoundJoin(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Segment),
    curr_x: f32,
    curr_y: f32,
    next_x: f32,
    next_y: f32,
    corner_x: f32,
    corner_y: f32,
) !void {
    const radius_x = curr_x - corner_x;
    const radius_y = curr_y - corner_y;
    const radius = @sqrt(radius_x * radius_x + radius_y * radius_y);
    if (radius <= 0.000001) {
        try appendLine(allocator, out, curr_x, curr_y, next_x, next_y);
        return;
    }

    const start_angle = std.math.atan2(radius_y, radius_x);
    const end_angle = std.math.atan2(next_y - corner_y, next_x - corner_x);
    var sweep = end_angle - start_angle;
    const two_pi = std.math.pi * 2.0;
    while (sweep > std.math.pi) : (sweep -= two_pi) {}
    while (sweep < -std.math.pi) : (sweep += two_pi) {}

    if (std.math.isNan(sweep) or std.math.isInf(sweep)) {
        try appendLine(allocator, out, curr_x, curr_y, next_x, next_y);
        return;
    }

    const steps: usize = @max(
        @as(usize, 1),
        @as(usize, @intFromFloat(@ceil(@abs(sweep) / (std.math.pi / 8.0)))),
    );
    var prev_x = curr_x;
    var prev_y = curr_y;
    var step: usize = 1;
    while (step <= steps) : (step += 1) {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
        const angle = start_angle + sweep * t;
        const x = if (step == steps) next_x else corner_x + @cos(angle) * radius;
        const y = if (step == steps) next_y else corner_y + @sin(angle) * radius;
        try appendLine(allocator, out, prev_x, prev_y, x, y);
        prev_x = x;
        prev_y = y;
    }
}

fn appendNonZero(allocator: std.mem.Allocator, out: *std.ArrayList(Segment), seg: Segment) !void {
    const dx = seg.x1 - seg.x0;
    const dy = seg.y1 - seg.y0;
    if (dx * dx + dy * dy <= 0.00000001) return;
    try out.append(allocator, seg);
}

fn expectNear(actual: f32, expected: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.001);
}

fn segmentTouchesPoint(seg: Segment, x: f32, y: f32) bool {
    return (@abs(seg.x0 - x) <= 0.001 and @abs(seg.y0 - y) <= 0.001) or
        (@abs(seg.x1 - x) <= 0.001 and @abs(seg.y1 - y) <= 0.001);
}

fn outlineTouchesPoint(segments: []const Segment, x: f32, y: f32) bool {
    for (segments) |seg| {
        if (segmentTouchesPoint(seg, x, y)) return true;
    }
    return false;
}

test "stroke square produces outer and inner bevel contours" {
    const segments = [_]Segment{
        .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0 },
        .{ .x0 = 10, .y0 = 0, .x1 = 10, .y1 = 10 },
        .{ .x0 = 10, .y0 = 10, .x1 = 0, .y1 = 10 },
        .{ .x0 = 0, .y0 = 10, .x1 = 0, .y1 = 0 },
    };

    const stroked = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        2.0,
        .bevel,
        .center,
        4.0,
    );
    defer std.testing.allocator.free(stroked);

    try std.testing.expectEqual(@as(usize, 16), stroked.len);
    try expectNear(stroked[0].x0, 0.0);
    try expectNear(stroked[0].y0, 1.0);
    try expectNear(stroked[0].x1, 10.0);
    try expectNear(stroked[0].y1, 1.0);
}

test "stroke triangle uses bevel corner connectors" {
    const segments = [_]Segment{
        .{ .x0 = 5, .y0 = 0, .x1 = 10, .y1 = 10 },
        .{ .x0 = 10, .y0 = 10, .x1 = 0, .y1 = 10 },
        .{ .x0 = 0, .y0 = 10, .x1 = 5, .y1 = 0 },
    };

    const stroked = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        2.0,
        .bevel,
        .center,
        4.0,
    );
    defer std.testing.allocator.free(stroked);

    try std.testing.expectEqual(@as(usize, 12), stroked.len);
    try std.testing.expect(stroked[1].x0 != stroked[1].x1 or stroked[1].y0 != stroked[1].y1);
}

test "stroke positions resolve expected offsets" {
    const segments = [_]Segment{
        .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0 },
        .{ .x0 = 10, .y0 = 0, .x1 = 10, .y1 = 10 },
        .{ .x0 = 10, .y0 = 10, .x1 = 0, .y1 = 10 },
        .{ .x0 = 0, .y0 = 10, .x1 = 0, .y1 = 0 },
    };

    const center = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        4.0,
        .bevel,
        .center,
        4.0,
    );
    defer std.testing.allocator.free(center);
    const outside = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        4.0,
        .bevel,
        .outside,
        4.0,
    );
    defer std.testing.allocator.free(outside);
    const inside = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        4.0,
        .bevel,
        .inside,
        4.0,
    );
    defer std.testing.allocator.free(inside);

    try expectNear(center[0].y0, 2.0);
    try expectNear(outside[0].y0, 4.0);
    try expectNear(inside[0].y0, 0.0);
}

test "miter join on square produces intersection points" {
    const segments = [_]Segment{
        .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0 },
        .{ .x0 = 10, .y0 = 0, .x1 = 10, .y1 = 10 },
        .{ .x0 = 10, .y0 = 10, .x1 = 0, .y1 = 10 },
        .{ .x0 = 0, .y0 = 10, .x1 = 0, .y1 = 0 },
    };

    const bevel_result = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        2.0,
        .bevel,
        .center,
        4.0,
    );
    defer std.testing.allocator.free(bevel_result);
    const result = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        2.0,
        .miter,
        .center,
        4.0,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(result.len > bevel_result.len);
    try std.testing.expect(outlineTouchesPoint(result, 9.0, 1.0));
    try std.testing.expect(outlineTouchesPoint(result, 9.0, 9.0));
    try std.testing.expect(outlineTouchesPoint(result, 1.0, 9.0));
    try std.testing.expect(outlineTouchesPoint(result, 1.0, 1.0));
}

test "miter limit causes fallback to bevel on acute angle" {
    const segments = [_]Segment{
        .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 0 },
        .{ .x0 = 100, .y0 = 0, .x1 = 1, .y1 = 0.1 },
        .{ .x0 = 1, .y0 = 0.1, .x1 = 0, .y1 = 0 },
    };

    const bevel_result = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        2.0,
        .bevel,
        .center,
        0.1,
    );
    defer std.testing.allocator.free(bevel_result);
    const result = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        2.0,
        .miter,
        .center,
        0.1,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(bevel_result.len, result.len);
}

test "round join produces arc segments" {
    const segments = [_]Segment{
        .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0 },
        .{ .x0 = 10, .y0 = 0, .x1 = 10, .y1 = 10 },
        .{ .x0 = 10, .y0 = 10, .x1 = 0, .y1 = 10 },
        .{ .x0 = 0, .y0 = 10, .x1 = 0, .y1 = 0 },
    };

    const bevel_result = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        2.0,
        .bevel,
        .center,
        4.0,
    );
    defer std.testing.allocator.free(bevel_result);
    const round_result = try generateStrokeOutline(
        std.testing.allocator,
        &segments,
        2.0,
        .round,
        .center,
        4.0,
    );
    defer std.testing.allocator.free(round_result);

    try std.testing.expect(round_result.len > bevel_result.len);
}
