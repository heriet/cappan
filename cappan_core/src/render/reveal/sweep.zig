const std = @import("std");

pub const SweepDirection = enum {
    left_to_right,
    right_to_left,
    top_to_bottom,
    bottom_to_top,
};

pub const SweepOptions = struct {
    direction: SweepDirection = .left_to_right,
};

/// Apply sweep reveal to a coverage map.
/// full_coverage: source coverage (read-only), output: destination (same dimensions).
/// progress: 0.0 = nothing visible, 1.0 = fully visible.
pub fn apply(
    full_coverage: []const u8,
    output: []u8,
    width: u32,
    height: u32,
    progress: f32,
    options: SweepOptions,
) void {
    const p = std.math.clamp(progress, 0.0, 1.0);

    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * @as(usize, width) + x;
            const visible = switch (options.direction) {
                .left_to_right => @as(f32, @floatFromInt(x)) < @as(f32, @floatFromInt(width)) * p,
                .right_to_left => @as(f32, @floatFromInt(x)) >= @as(f32, @floatFromInt(width)) * (1.0 - p),
                .top_to_bottom => @as(f32, @floatFromInt(y)) < @as(f32, @floatFromInt(height)) * p,
                .bottom_to_top => @as(f32, @floatFromInt(y)) >= @as(f32, @floatFromInt(height)) * (1.0 - p),
            };
            output[idx] = if (visible) full_coverage[idx] else 0;
        }
    }
}

test "sweep apply progress=0 all zeros" {
    const width: u32 = 4;
    const height: u32 = 4;
    const full: [16]u8 = .{100} ** 16;
    var out: [16]u8 = undefined;

    apply(&full, &out, width, height, 0.0, .{});

    for (out) |v| {
        try std.testing.expectEqual(@as(u8, 0), v);
    }
}

test "sweep apply progress=1 equals full_coverage" {
    const width: u32 = 4;
    const height: u32 = 4;
    const full: [16]u8 = .{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160 };
    var out: [16]u8 = undefined;

    apply(&full, &out, width, height, 1.0, .{});

    try std.testing.expectEqualSlices(u8, &full, &out);
}

test "sweep apply progress=0.5 left_to_right left half visible" {
    const width: u32 = 4;
    const height: u32 = 2;
    // All coverage = 200
    const full: [8]u8 = .{200} ** 8;
    var out: [8]u8 = undefined;

    apply(&full, &out, width, height, 0.5, .{ .direction = .left_to_right });

    // x=0,1 visible (< 4*0.5=2.0), x=2,3 not visible
    for (0..height) |y| {
        try std.testing.expectEqual(@as(u8, 200), out[y * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 200), out[y * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 0), out[y * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 0), out[y * 4 + 3]);
    }
}

test "sweep apply all 4 directions at 0.5" {
    const width: u32 = 4;
    const height: u32 = 4;
    const full: [16]u8 = .{100} ** 16;
    var out: [16]u8 = undefined;

    // left_to_right: left 2 columns visible
    apply(&full, &out, width, height, 0.5, .{ .direction = .left_to_right });
    for (0..height) |y| {
        try std.testing.expectEqual(@as(u8, 100), out[y * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 100), out[y * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 0), out[y * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 0), out[y * 4 + 3]);
    }

    // right_to_left: right 2 columns visible (x >= 4*(1-0.5)=2)
    apply(&full, &out, width, height, 0.5, .{ .direction = .right_to_left });
    for (0..height) |y| {
        try std.testing.expectEqual(@as(u8, 0), out[y * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 0), out[y * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 100), out[y * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 100), out[y * 4 + 3]);
    }

    // top_to_bottom: top 2 rows visible (y < 4*0.5=2)
    apply(&full, &out, width, height, 0.5, .{ .direction = .top_to_bottom });
    for (0..width) |x| {
        try std.testing.expectEqual(@as(u8, 100), out[0 * 4 + x]);
        try std.testing.expectEqual(@as(u8, 100), out[1 * 4 + x]);
        try std.testing.expectEqual(@as(u8, 0), out[2 * 4 + x]);
        try std.testing.expectEqual(@as(u8, 0), out[3 * 4 + x]);
    }

    // bottom_to_top: bottom 2 rows visible (y >= 4*(1-0.5)=2)
    apply(&full, &out, width, height, 0.5, .{ .direction = .bottom_to_top });
    for (0..width) |x| {
        try std.testing.expectEqual(@as(u8, 0), out[0 * 4 + x]);
        try std.testing.expectEqual(@as(u8, 0), out[1 * 4 + x]);
        try std.testing.expectEqual(@as(u8, 100), out[2 * 4 + x]);
        try std.testing.expectEqual(@as(u8, 100), out[3 * 4 + x]);
    }
}
