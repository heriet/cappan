const std = @import("std");
const colr_mod = @import("../font/table/colr.zig");
const cpal_mod = @import("../font/table/cpal.zig");
const rgba_bitmap_mod = @import("rgba_bitmap.zig");

pub fn resolveStopColor(stop: colr_mod.ColorStop, cpal: ?cpal_mod.CpalTable, palette_idx: u16, fg_color: rgba_bitmap_mod.Color) rgba_bitmap_mod.Color {
    var base_r = fg_color.r;
    var base_g = fg_color.g;
    var base_b = fg_color.b;
    var base_a = fg_color.a;

    if (stop.palette_index != 0xFFFF) {
        if (cpal) |table| {
            if (table.getColor(palette_idx, stop.palette_index)) |color| {
                base_r = color.r;
                base_g = color.g;
                base_b = color.b;
                base_a = color.a;
            }
        }
    }

    const alpha = @min(255.0, @max(0.0, @as(f32, @floatFromInt(base_a)) * stop.alpha));
    return .{
        .r = base_r,
        .g = base_g,
        .b = base_b,
        .a = @intFromFloat(@round(alpha)),
    };
}

pub fn applyExtendMode(t: f32, extend: colr_mod.ExtendMode) f32 {
    return switch (extend) {
        .pad => @max(0.0, @min(1.0, t)),
        .repeat => t - @floor(t),
        .reflect => blk: {
            const cycle = t - 2.0 * @floor(t / 2.0);
            break :blk if (cycle > 1.0) 2.0 - cycle else cycle;
        },
        else => @max(0.0, @min(1.0, t)),
    };
}

pub fn interpolateColorLine(
    stops: []const colr_mod.ColorStop,
    extend: colr_mod.ExtendMode,
    t: f32,
    cpal: ?cpal_mod.CpalTable,
    palette_idx: u16,
    fg_color: rgba_bitmap_mod.Color,
) rgba_bitmap_mod.Color {
    if (stops.len == 0) {
        return .{ .r = fg_color.r, .g = fg_color.g, .b = fg_color.b, .a = fg_color.a };
    }
    if (stops.len == 1) {
        return resolveStopColor(stops[0], cpal, palette_idx, fg_color);
    }

    const first_offset = stops[0].stop_offset;
    const last_offset = stops[stops.len - 1].stop_offset;
    const range = last_offset - first_offset;
    const t_final = if (@abs(range) < 1e-6) first_offset else blk: {
        const t_norm = (t - first_offset) / range;
        const t_ext = applyExtendMode(t_norm, extend);
        break :blk first_offset + t_ext * range;
    };

    if (t_final <= stops[0].stop_offset) {
        return resolveStopColor(stops[0], cpal, palette_idx, fg_color);
    }
    if (t_final >= stops[stops.len - 1].stop_offset) {
        return resolveStopColor(stops[stops.len - 1], cpal, palette_idx, fg_color);
    }

    var i: usize = 0;
    while (i + 1 < stops.len) : (i += 1) {
        const s0 = stops[i];
        const s1 = stops[i + 1];
        if (s0.stop_offset <= t_final and t_final <= s1.stop_offset) {
            const segment_range = s1.stop_offset - s0.stop_offset;
            const blend_t = if (@abs(segment_range) < 1e-6) 0.0 else (t_final - s0.stop_offset) / segment_range;
            const c0 = resolveStopColor(s0, cpal, palette_idx, fg_color);
            const c1 = resolveStopColor(s1, cpal, palette_idx, fg_color);
            return .{
                .r = lerpChannel(c0.r, c1.r, blend_t),
                .g = lerpChannel(c0.g, c1.g, blend_t),
                .b = lerpChannel(c0.b, c1.b, blend_t),
                .a = lerpChannel(c0.a, c1.a, blend_t),
            };
        }
    }

    return resolveStopColor(stops[stops.len - 1], cpal, palette_idx, fg_color);
}

fn lerpChannel(c0: u8, c1: u8, t: f32) u8 {
    const start: f32 = @floatFromInt(c0);
    const end: f32 = @floatFromInt(c1);
    return @intFromFloat(@round(@min(255.0, @max(0.0, start + (end - start) * t))));
}

pub fn linearGradientParam(px: f32, py: f32, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const nx = -(y2 - y0);
    const ny = x2 - x0;
    const dot_dn = dx * nx + dy * ny;
    if (@abs(dot_dn) < 1e-6) {
        const dot_dd = dx * dx + dy * dy;
        if (@abs(dot_dd) < 1e-6) return 0.0;
        return ((px - x0) * dx + (py - y0) * dy) / dot_dd;
    }
    return ((px - x0) * nx + (py - y0) * ny) / dot_dn;
}

pub fn radialGradientParam(px: f32, py: f32, x0: f32, y0: f32, r0: f32, x1: f32, y1: f32, r1: f32) ?f32 {
    const cdx = x1 - x0;
    const cdy = y1 - y0;
    const dr = r1 - r0;
    const pdx = px - x0;
    const pdy = py - y0;
    const a = cdx * cdx + cdy * cdy - dr * dr;
    const b = -2.0 * (pdx * cdx + pdy * cdy + r0 * dr);
    const c = pdx * pdx + pdy * pdy - r0 * r0;

    if (@abs(a) < 1e-6) {
        if (@abs(b) < 1e-6) return null;
        const t = -c / b;
        return if (r0 + t * dr >= 0.0) t else null;
    }

    const disc = b * b - 4.0 * a * c;
    if (disc < 0.0) return null;

    const sqrt_disc = @sqrt(disc);
    const t1 = (-b + sqrt_disc) / (2.0 * a);
    const t2 = (-b - sqrt_disc) / (2.0 * a);
    var best: ?f32 = null;
    if (r0 + t1 * dr >= 0.0) best = t1;
    if (r0 + t2 * dr >= 0.0) {
        if (best == null or t2 > best.?) best = t2;
    }
    return best;
}

pub fn fillLinearGradient(
    bitmap: *rgba_bitmap_mod.RgbaBitmap,
    coverage: ?[]const u8,
    stops: []const colr_mod.ColorStop,
    extend: colr_mod.ExtendMode,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    cpal: ?cpal_mod.CpalTable,
    palette_idx: u16,
    fg_color: rgba_bitmap_mod.Color,
) void {
    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const t = linearGradientParam(px, py, x0, y0, x1, y1, x2, y2);
            const gc = interpolateColorLine(stops, extend, t, cpal, palette_idx, fg_color);
            blendGradientPixel(bitmap, coverage, x, y, gc);
        }
    }
}

fn blendGradientPixel(bitmap: *rgba_bitmap_mod.RgbaBitmap, coverage: ?[]const u8, x: u32, y: u32, gc: rgba_bitmap_mod.Color) void {
    var final_a = gc.a;
    if (coverage) |cov| {
        const idx = @as(usize, y) * @as(usize, bitmap.width) + @as(usize, x);
        if (idx >= cov.len) return;
        final_a = @intCast(@as(u16, final_a) * @as(u16, cov[idx]) / 255);
    }
    if (final_a > 0) {
        bitmap.blendPixel(x, y, 255, rgba_bitmap_mod.Color{ .r = gc.r, .g = gc.g, .b = gc.b, .a = final_a });
    }
}

test "applyExtendMode pad clamps" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), applyExtendMode(-0.5, .pad), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), applyExtendMode(0.5, .pad), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), applyExtendMode(1.5, .pad), 0.001);
}

test "applyExtendMode repeat wraps" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), applyExtendMode(1.3, .repeat), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), applyExtendMode(-0.3, .repeat), 0.001);
}

test "applyExtendMode reflect ping-pongs" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), applyExtendMode(0.25, .reflect), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), applyExtendMode(0.75, .reflect), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), applyExtendMode(1.25, .reflect), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), applyExtendMode(1.75, .reflect), 0.001);
}

test "linearGradientParam horizontal gradient" {
    const t0 = linearGradientParam(0, 0, 0, 0, 100, 0, 0, 100);
    const t50 = linearGradientParam(50, 25, 0, 0, 100, 0, 0, 100);
    const t100 = linearGradientParam(100, 0, 0, 0, 100, 0, 0, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), t0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), t50, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t100, 0.001);
}

test "interpolateColorLine two stops midpoint" {
    const stops2 = [2]colr_mod.ColorStop{
        .{ .stop_offset = 0.0, .palette_index = 0xFFFF, .alpha = 0.0 },
        .{ .stop_offset = 1.0, .palette_index = 0xFFFF, .alpha = 1.0 },
    };
    const color = rgba_bitmap_mod.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const mid = interpolateColorLine(&stops2, .pad, 0.5, null, 0, color);
    try std.testing.expectEqual(@as(u8, 255), mid.r);
    try std.testing.expect(mid.a >= 126 and mid.a <= 129);
}


