const std = @import("std");

pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
};

pub fn apply(easing: Easing, t: f32) f32 {
    const c = std.math.clamp(t, 0.0, 1.0);
    return switch (easing) {
        .linear => c,
        .ease_in => c * c,
        .ease_out => 1.0 - (1.0 - c) * (1.0 - c),
        .ease_in_out => if (c < 0.5) 2.0 * c * c else 1.0 - (-2.0 * c + 2.0) * (-2.0 * c + 2.0) / 2.0,
        .ease_in_cubic => c * c * c,
        .ease_out_cubic => 1.0 - (1.0 - c) * (1.0 - c) * (1.0 - c),
        .ease_in_out_cubic => if (c < 0.5) 4.0 * c * c * c else 1.0 - (-2.0 * c + 2.0) * (-2.0 * c + 2.0) * (-2.0 * c + 2.0) / 2.0,
    };
}

test "linear" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), apply(.linear, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), apply(.linear, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), apply(.linear, 1.0), 0.001);
}

test "ease_in starts slow" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), apply(.ease_in, 0.0), 0.001);
    try std.testing.expect(apply(.ease_in, 0.5) < 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), apply(.ease_in, 1.0), 0.001);
}

test "ease_out starts fast" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), apply(.ease_out, 0.0), 0.001);
    try std.testing.expect(apply(.ease_out, 0.5) > 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), apply(.ease_out, 1.0), 0.001);
}

test "ease_in_out symmetric" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), apply(.ease_in_out, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), apply(.ease_in_out, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), apply(.ease_in_out, 1.0), 0.001);
    try std.testing.expect(apply(.ease_in_out, 0.25) < 0.25);
    try std.testing.expect(apply(.ease_in_out, 0.75) > 0.75);
}

test "cubic variants" {
    try std.testing.expect(apply(.ease_in_cubic, 0.5) < apply(.ease_in, 0.5));
    try std.testing.expect(apply(.ease_out_cubic, 0.5) > apply(.ease_out, 0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), apply(.ease_in_out_cubic, 0.5), 0.001);
}

test "clamps out of range" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), apply(.ease_in, -0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), apply(.ease_out, 1.5), 0.001);
}
