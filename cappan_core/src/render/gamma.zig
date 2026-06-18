const std = @import("std");

pub fn linearToSrgb(linear: f32) u8 {
    const clamped = @max(0.0, @min(1.0, linear));
    const srgb = if (clamped <= 0.0031308)
        clamped * 12.92
    else
        1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(@max(0.0, @min(255.0, srgb * 255.0))));
}

pub fn srgbToLinear(v: u8) f32 {
    const c = @as(f32, @floatFromInt(v)) / 255.0;
    if (c <= 0.04045) {
        return c / 12.92;
    }
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

pub fn blendLinear(bg_srgb: u8, fg_srgb: u8, alpha: f32) u8 {
    const bg_lin = srgbToLinear(bg_srgb);
    const fg_lin = srgbToLinear(fg_srgb);
    const result_lin = bg_lin * (1.0 - alpha) + fg_lin * alpha;
    return linearToSrgb(result_lin);
}

test "srgb roundtrip" {
    try std.testing.expectEqual(@as(u8, 0), linearToSrgb(srgbToLinear(0)));
    try std.testing.expectEqual(@as(u8, 255), linearToSrgb(srgbToLinear(255)));
    const mid = linearToSrgb(srgbToLinear(128));
    try std.testing.expect(mid >= 127 and mid <= 129);
}

test "blendLinear fully opaque replaces bg" {
    const result = blendLinear(255, 0, 1.0);
    try std.testing.expectEqual(@as(u8, 0), result);
}

test "blendLinear fully transparent keeps bg" {
    const result = blendLinear(255, 0, 0.0);
    try std.testing.expectEqual(@as(u8, 255), result);
}

test "blendLinear half alpha differs from naive" {
    const gamma_result = blendLinear(255, 0, 0.5);
    try std.testing.expect(gamma_result > 140);
    try std.testing.expect(gamma_result < 200);
}
