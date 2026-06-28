const std = @import("std");
const rgba_bitmap_mod = @import("rgba_bitmap.zig");
const colr_mod = @import("../font/table/colr.zig");

pub fn composite(dst: *rgba_bitmap_mod.RgbaBitmap, src: rgba_bitmap_mod.RgbaBitmap, mode: colr_mod.CompositeMode) void {
    if (src.pixels.len != dst.pixels.len) return;

    var i: usize = 0;
    while (i < dst.pixels.len) : (i += 4) {
        const result = compositePixel(
            src.pixels[i],
            src.pixels[i + 1],
            src.pixels[i + 2],
            src.pixels[i + 3],
            dst.pixels[i],
            dst.pixels[i + 1],
            dst.pixels[i + 2],
            dst.pixels[i + 3],
            mode,
        );
        dst.pixels[i] = result[0];
        dst.pixels[i + 1] = result[1];
        dst.pixels[i + 2] = result[2];
        dst.pixels[i + 3] = result[3];
    }
}

fn compositePixel(src_r: u8, src_g: u8, src_b: u8, src_a: u8, dst_r: u8, dst_g: u8, dst_b: u8, dst_a: u8, mode: colr_mod.CompositeMode) [4]u8 {
    const sa = @as(f32, @floatFromInt(src_a)) / 255.0;
    const da = @as(f32, @floatFromInt(dst_a)) / 255.0;
    const sr = @as(f32, @floatFromInt(src_r)) / 255.0;
    const sg = @as(f32, @floatFromInt(src_g)) / 255.0;
    const sb = @as(f32, @floatFromInt(src_b)) / 255.0;
    const dr = @as(f32, @floatFromInt(dst_r)) / 255.0;
    const dg = @as(f32, @floatFromInt(dst_g)) / 255.0;
    const db = @as(f32, @floatFromInt(dst_b)) / 255.0;

    return switch (mode) {
        .clear, .src, .dest, .src_over, .dest_over, .src_in, .dest_in, .src_out, .dest_out, .src_atop, .dest_atop, .xor, .plus => compositePorterDuff(sa, da, sr, sg, sb, dr, dg, db, mode),
        else => compositePixelNonPorterDuff(sa, da, sr, sg, sb, dr, dg, db, mode),
    };
}

fn compositePixelNonPorterDuff(sa: f32, da: f32, sr: f32, sg: f32, sb: f32, dr: f32, dg: f32, db: f32, mode: colr_mod.CompositeMode) [4]u8 {
    return switch (mode) {
        .screen, .overlay, .darken, .lighten, .color_dodge, .color_burn, .hard_light, .soft_light, .difference, .exclusion, .multiply => blk: {
            const ra = sa + da - sa * da;
            if (ra < 1e-6) break :blk .{ 0, 0, 0, 0 };
            const br = blendFunc(sr, dr, mode);
            const bg = blendFunc(sg, dg, mode);
            const bb = blendFunc(sb, db, mode);
            const co_r = sa * (1.0 - da) * sr + da * (1.0 - sa) * dr + sa * da * br;
            const co_g = sa * (1.0 - da) * sg + da * (1.0 - sa) * dg + sa * da * bg;
            const co_b = sa * (1.0 - da) * sb + da * (1.0 - sa) * db + sa * da * bb;
            break :blk .{ floatToByte(co_r / ra), floatToByte(co_g / ra), floatToByte(co_b / ra), floatToByte(ra) };
        },
        .hsl_hue, .hsl_saturation, .hsl_color, .hsl_luminosity => compositePorterDuff(sa, da, sr, sg, sb, dr, dg, db, .src_over),
        else => compositePorterDuff(sa, da, sr, sg, sb, dr, dg, db, .src_over),
    };
}

fn porterDuffFactors(sa: f32, da: f32, mode: colr_mod.CompositeMode) [2]f32 {
    return switch (mode) {
        .clear => .{ 0.0, 0.0 },
        .src => .{ 1.0, 0.0 },
        .dest => .{ 0.0, 1.0 },
        .src_over => .{ 1.0, 1.0 - sa },
        .dest_over => .{ 1.0 - da, 1.0 },
        .src_in => .{ da, 0.0 },
        .dest_in => .{ 0.0, sa },
        .src_out => .{ 1.0 - da, 0.0 },
        .dest_out => .{ 0.0, 1.0 - sa },
        .src_atop => .{ da, 1.0 - sa },
        .dest_atop => .{ 1.0 - da, sa },
        .xor => .{ 1.0 - da, 1.0 - sa },
        .plus => .{ 1.0, 1.0 },
        else => .{ 1.0, 1.0 - sa },
    };
}

fn compositePorterDuff(sa: f32, da: f32, sr: f32, sg: f32, sb: f32, dr: f32, dg: f32, db: f32, mode: colr_mod.CompositeMode) [4]u8 {
    const factors = porterDuffFactors(sa, da, mode);
    const fa = factors[0];
    const fb = factors[1];
    const rp_r = sr * sa * fa + dr * da * fb;
    const rp_g = sg * sa * fa + dg * da * fb;
    const rp_b = sb * sa * fa + db * da * fb;
    const ra = @min(1.0, sa * fa + da * fb);
    if (ra > 1e-6) {
        return .{ floatToByte(rp_r / ra), floatToByte(rp_g / ra), floatToByte(rp_b / ra), floatToByte(ra) };
    }
    return .{ 0, 0, 0, 0 };
}

fn blendFunc(sc: f32, dc: f32, mode: colr_mod.CompositeMode) f32 {
    return switch (mode) {
        .screen => sc + dc - sc * dc,
        .overlay => if (dc < 0.5) 2.0 * sc * dc else 1.0 - 2.0 * (1.0 - sc) * (1.0 - dc),
        .darken => @min(sc, dc),
        .lighten => @max(sc, dc),
        .color_dodge => if (sc >= 1.0) 1.0 else @min(1.0, dc / (1.0 - sc)),
        .color_burn => if (sc <= 0.0) 0.0 else 1.0 - @min(1.0, (1.0 - dc) / sc),
        .hard_light => if (sc < 0.5) 2.0 * sc * dc else 1.0 - 2.0 * (1.0 - sc) * (1.0 - dc),
        .soft_light => blendSoftLight(sc, dc),
        .difference => @abs(sc - dc),
        .exclusion => sc + dc - 2.0 * sc * dc,
        .multiply => sc * dc,
        else => sc,
    };
}

fn blendSoftLight(sc: f32, dc: f32) f32 {
    if (sc <= 0.5) {
        return dc - (1.0 - 2.0 * sc) * dc * (1.0 - dc);
    }
    const d_fn = if (dc <= 0.25) ((16.0 * dc - 12.0) * dc + 4.0) * dc else @sqrt(dc);
    return dc + (2.0 * sc - 1.0) * (d_fn - dc);
}

fn floatToByte(value: f32) u8 {
    return @intFromFloat(@round(@min(255.0, @max(0.0, value * 255.0))));
}

test "composite clear" {
    var dst = try rgba_bitmap_mod.RgbaBitmap.init(std.testing.allocator, 2, 2, rgba_bitmap_mod.Color.white);
    defer dst.deinit();
    var src = try rgba_bitmap_mod.RgbaBitmap.init(std.testing.allocator, 2, 2, .{ .r = 255, .g = 0, .b = 0, .a = 200 });
    defer src.deinit();

    composite(&dst, src, .clear);

    var i: usize = 0;
    while (i < dst.pixels.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 0), dst.pixels[i + 3]);
    }
}

test "composite src replaces dst" {
    var dst = try rgba_bitmap_mod.RgbaBitmap.init(std.testing.allocator, 1, 1, rgba_bitmap_mod.Color.white);
    defer dst.deinit();
    var src = try rgba_bitmap_mod.RgbaBitmap.init(std.testing.allocator, 1, 1, .{ .r = 100, .g = 150, .b = 200, .a = 255 });
    defer src.deinit();

    composite(&dst, src, .src);

    try std.testing.expectEqual(@as(u8, 100), dst.pixels[0]);
    try std.testing.expectEqual(@as(u8, 150), dst.pixels[1]);
    try std.testing.expectEqual(@as(u8, 200), dst.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), dst.pixels[3]);
}

test "composite src_over alpha blending" {
    var dst = try rgba_bitmap_mod.RgbaBitmap.init(std.testing.allocator, 1, 1, rgba_bitmap_mod.Color.white);
    defer dst.deinit();
    var src = try rgba_bitmap_mod.RgbaBitmap.init(std.testing.allocator, 1, 1, .{ .r = 0, .g = 0, .b = 0, .a = 128 });
    defer src.deinit();

    composite(&dst, src, .src_over);

    try std.testing.expect(dst.pixels[0] >= 120 and dst.pixels[0] <= 135);
    try std.testing.expectEqual(@as(u8, 255), dst.pixels[3]);
}

test "composite multiply fully opaque" {
    var dst = try rgba_bitmap_mod.RgbaBitmap.init(std.testing.allocator, 1, 1, rgba_bitmap_mod.Color.white);
    defer dst.deinit();
    var src = try rgba_bitmap_mod.RgbaBitmap.init(std.testing.allocator, 1, 1, .{ .r = 128, .g = 128, .b = 128, .a = 255 });
    defer src.deinit();

    composite(&dst, src, .multiply);

    try std.testing.expect(dst.pixels[0] >= 126 and dst.pixels[0] <= 130);
    try std.testing.expectEqual(@as(u8, 255), dst.pixels[3]);
}
