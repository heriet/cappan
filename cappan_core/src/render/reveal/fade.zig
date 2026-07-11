const std = @import("std");

/// Apply fade reveal to a coverage map.
/// Multiplies each coverage value by progress.
/// progress: 0.0 = nothing visible, 1.0 = fully visible.
pub fn apply(
    full_coverage: []const u8,
    output: []u8,
    progress: f32,
) void {
    const p = std.math.clamp(progress, 0.0, 1.0);
    for (full_coverage, 0..) |cov, i| {
        output[i] = @intFromFloat(@as(f32, @floatFromInt(cov)) * p);
    }
}

test "fade apply progress=0 all zeros" {
    const full: [8]u8 = .{ 100, 200, 50, 255, 128, 64, 32, 16 };
    var out: [8]u8 = undefined;

    apply(&full, &out, 0.0);

    for (out) |v| {
        try std.testing.expectEqual(@as(u8, 0), v);
    }
}

test "fade apply progress=1 equals input" {
    const full: [8]u8 = .{ 100, 200, 50, 255, 128, 64, 32, 16 };
    var out: [8]u8 = undefined;

    apply(&full, &out, 1.0);

    try std.testing.expectEqualSlices(u8, &full, &out);
}

test "fade apply progress=0.5 each byte approximately half" {
    const full: [4]u8 = .{ 200, 100, 50, 0 };
    var out: [4]u8 = undefined;

    apply(&full, &out, 0.5);

    // Each output should be approximately half the input (within rounding)
    try std.testing.expect(out[0] >= 99 and out[0] <= 101); // 200 * 0.5 = 100
    try std.testing.expect(out[1] >= 49 and out[1] <= 51); // 100 * 0.5 = 50
    try std.testing.expect(out[2] >= 24 and out[2] <= 26); // 50 * 0.5 = 25
    try std.testing.expectEqual(@as(u8, 0), out[3]); // 0 * 0.5 = 0
}
