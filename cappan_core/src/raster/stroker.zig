const std = @import("std");
const outline_mod = @import("outline.zig");

pub const Segment = outline_mod.Segment;

pub const LineJoin = enum { miter, round, bevel };
pub const StrokePosition = enum { center, outside, inside };

const OffsetSegment = struct {
    outer: Segment,
    inner: Segment,
};

pub fn generateStrokeOutline(
    allocator: std.mem.Allocator,
    segments: []const Segment,
    width: f32,
    join: LineJoin,
    position: StrokePosition,
    miter_limit: f32,
) ![]Segment {
    _ = join;
    _ = miter_limit;

    if (segments.len == 0 or width <= 0.0) return try allocator.alloc(Segment, 0);

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
            offsets[i] = .{ .outer = seg, .inner = seg };
            continue;
        }

        const nx = -dy / len;
        const ny = dx / len;
        offsets[i] = .{
            .outer = offsetSegment(seg, nx, ny, outer_offset),
            .inner = offsetSegment(seg, nx, ny, inner_offset),
        };
    }

    var out: std.ArrayList(Segment) = .empty;
    errdefer out.deinit(allocator);

    for (offsets, 0..) |off, i| {
        const next = offsets[(i + 1) % offsets.len];
        try appendNonZero(allocator, &out, off.outer);
        try appendLine(allocator, &out, off.outer.x1, off.outer.y1, next.outer.x0, next.outer.y0);
    }

    var i: usize = offsets.len;
    while (i > 0) {
        i -= 1;
        const off = offsets[i];
        const prev = offsets[(i + offsets.len - 1) % offsets.len];
        try appendNonZero(allocator, &out, .{ .x0 = off.inner.x1, .y0 = off.inner.y1, .x1 = off.inner.x0, .y1 = off.inner.y0 });
        try appendLine(allocator, &out, off.inner.x0, off.inner.y0, prev.inner.x1, prev.inner.y1);
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

fn appendNonZero(allocator: std.mem.Allocator, out: *std.ArrayList(Segment), seg: Segment) !void {
    const dx = seg.x1 - seg.x0;
    const dy = seg.y1 - seg.y0;
    if (dx * dx + dy * dy <= 0.000001) return;
    try out.append(allocator, seg);
}

fn expectNear(actual: f32, expected: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.001);
}

test "stroke square produces outer and inner bevel contours" {
    const segments = [_]Segment{
        .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0 },
        .{ .x0 = 10, .y0 = 0, .x1 = 10, .y1 = 10 },
        .{ .x0 = 10, .y0 = 10, .x1 = 0, .y1 = 10 },
        .{ .x0 = 0, .y0 = 10, .x1 = 0, .y1 = 0 },
    };

    const stroked = try generateStrokeOutline(std.testing.allocator, &segments, 2.0, .bevel, .center, 4.0);
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

    const stroked = try generateStrokeOutline(std.testing.allocator, &segments, 2.0, .round, .center, 4.0);
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

    const center = try generateStrokeOutline(std.testing.allocator, &segments, 4.0, .bevel, .center, 4.0);
    defer std.testing.allocator.free(center);
    const outside = try generateStrokeOutline(std.testing.allocator, &segments, 4.0, .bevel, .outside, 4.0);
    defer std.testing.allocator.free(outside);
    const inside = try generateStrokeOutline(std.testing.allocator, &segments, 4.0, .bevel, .inside, 4.0);
    defer std.testing.allocator.free(inside);

    try expectNear(center[0].y0, 2.0);
    try expectNear(outside[0].y0, 4.0);
    try expectNear(inside[0].y0, 0.0);
}
