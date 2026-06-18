const std = @import("std");
const gamma = @import("gamma.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

pub const RgbaBitmap = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA, 4 bytes per pixel (R,G,B,A,R,G,B,A,...)
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, bg_color: Color) !RgbaBitmap {
        const pixel_count = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.OutOfMemory;
        const size = std.math.mul(usize, pixel_count, 4) catch return error.OutOfMemory;
        const pixels = try allocator.alloc(u8, size);
        // Fill with bg_color
        var i: usize = 0;
        while (i < size) : (i += 4) {
            pixels[i] = bg_color.r;
            pixels[i + 1] = bg_color.g;
            pixels[i + 2] = bg_color.b;
            pixels[i + 3] = bg_color.a;
        }
        return .{ .width = width, .height = height, .pixels = pixels, .allocator = allocator };
    }

    pub fn deinit(self: *RgbaBitmap) void {
        self.allocator.free(self.pixels);
    }

    /// Blend a coverage value with the given foreground color onto the pixel
    /// coverage: 0 = fully transparent, 255 = fully opaque
    pub fn blendPixel(self: *RgbaBitmap, x: u32, y: u32, coverage: u8, fg: Color) void {
        if (x >= self.width or y >= self.height) return;
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;
        // alpha = coverage * fg.a / 255
        const alpha = @as(u16, coverage) * @as(u16, fg.a) / 255;
        const inv_alpha = 255 - alpha;
        // blend each channel: result = existing * (1-alpha/255) + fg * alpha/255
        self.pixels[idx + 0] = @intCast((@as(u16, self.pixels[idx + 0]) * inv_alpha + @as(u16, fg.r) * alpha) / 255);
        self.pixels[idx + 1] = @intCast((@as(u16, self.pixels[idx + 1]) * inv_alpha + @as(u16, fg.g) * alpha) / 255);
        self.pixels[idx + 2] = @intCast((@as(u16, self.pixels[idx + 2]) * inv_alpha + @as(u16, fg.b) * alpha) / 255);
        self.pixels[idx + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.pixels[idx + 3]) + alpha));
    }

    pub fn blendPixelLinear(self: *RgbaBitmap, x: u32, y: u32, coverage: u8, fg: Color) void {
        if (x >= self.width or y >= self.height) return;
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;
        const alpha = @as(f32, @floatFromInt(coverage)) * @as(f32, @floatFromInt(fg.a)) / (255.0 * 255.0);
        self.pixels[idx + 0] = gamma.blendLinear(self.pixels[idx + 0], fg.r, alpha);
        self.pixels[idx + 1] = gamma.blendLinear(self.pixels[idx + 1], fg.g, alpha);
        self.pixels[idx + 2] = gamma.blendLinear(self.pixels[idx + 2], fg.b, alpha);
        self.pixels[idx + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.pixels[idx + 3]) + @as(u16, @intFromFloat(@round(alpha * 255.0)))));
    }

    pub fn blendPixelLcd(self: *RgbaBitmap, x: u32, y: u32, r_cov: u8, g_cov: u8, b_cov: u8, fg: Color) void {
        if (x >= self.width or y >= self.height) return;
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;

        const r_alpha = @as(u16, r_cov) * @as(u16, fg.a) / 255;
        const g_alpha = @as(u16, g_cov) * @as(u16, fg.a) / 255;
        const b_alpha = @as(u16, b_cov) * @as(u16, fg.a) / 255;

        self.pixels[idx + 0] = @intCast((@as(u16, self.pixels[idx + 0]) * (255 - r_alpha) + @as(u16, fg.r) * r_alpha) / 255);
        self.pixels[idx + 1] = @intCast((@as(u16, self.pixels[idx + 1]) * (255 - g_alpha) + @as(u16, fg.g) * g_alpha) / 255);
        self.pixels[idx + 2] = @intCast((@as(u16, self.pixels[idx + 2]) * (255 - b_alpha) + @as(u16, fg.b) * b_alpha) / 255);
        const max_alpha = @max(r_alpha, @max(g_alpha, b_alpha));
        self.pixels[idx + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.pixels[idx + 3]) + max_alpha));
    }
};

/// Blend a grayscale coverage map onto an external RGBA pixel buffer.
/// dst_pixels: RGBA buffer (4 bytes per pixel)
/// coverage: grayscale coverage map (1 byte per pixel)
/// dst_x/dst_y: destination top-left corner (may be negative for clipping)
/// color: foreground color
/// opacity: overall opacity multiplier [0.0, 1.0]
pub fn blitCoverage(
    dst_pixels: []u8,
    dst_width: u32,
    dst_height: u32,
    coverage: []const u8,
    cov_width: u32,
    cov_height: u32,
    dst_x: i32,
    dst_y: i32,
    color: Color,
    opacity: f32,
) void {
    var cy: u32 = 0;
    while (cy < cov_height) : (cy += 1) {
        const py = dst_y + @as(i32, @intCast(cy));
        if (py < 0 or py >= @as(i32, @intCast(dst_height))) continue;
        const dy: u32 = @intCast(py);

        var cx: u32 = 0;
        while (cx < cov_width) : (cx += 1) {
            const px = dst_x + @as(i32, @intCast(cx));
            if (px < 0 or px >= @as(i32, @intCast(dst_width))) continue;
            const dx: u32 = @intCast(px);

            const cov_val = coverage[@as(usize, cy) * @as(usize, cov_width) + @as(usize, cx)];

            // effective_alpha = coverage * color.a/255 * opacity
            const alpha_f = @as(f32, @floatFromInt(cov_val)) * @as(f32, @floatFromInt(color.a)) / 255.0 * opacity;
            const alpha: u16 = @intFromFloat(@min(255.0, @max(0.0, alpha_f)));
            const inv_alpha: u16 = 255 - alpha;

            const idx = (@as(usize, dy) * @as(usize, dst_width) + @as(usize, dx)) * 4;
            dst_pixels[idx + 0] = @intCast((@as(u16, dst_pixels[idx + 0]) * inv_alpha + @as(u16, color.r) * alpha) / 255);
            dst_pixels[idx + 1] = @intCast((@as(u16, dst_pixels[idx + 1]) * inv_alpha + @as(u16, color.g) * alpha) / 255);
            dst_pixels[idx + 2] = @intCast((@as(u16, dst_pixels[idx + 2]) * inv_alpha + @as(u16, color.b) * alpha) / 255);
            dst_pixels[idx + 3] = @intCast(@min(@as(u16, 255), @as(u16, dst_pixels[idx + 3]) + alpha));
        }
    }
}

test "rgba bitmap init fills bg_color" {
    var bmp = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.white);
    defer bmp.deinit();

    // All pixels should be white (255,255,255,255)
    var i: usize = 0;
    while (i < bmp.pixels.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 255), bmp.pixels[i + 0]);
        try std.testing.expectEqual(@as(u8, 255), bmp.pixels[i + 1]);
        try std.testing.expectEqual(@as(u8, 255), bmp.pixels[i + 2]);
        try std.testing.expectEqual(@as(u8, 255), bmp.pixels[i + 3]);
    }
}

test "rgba bitmap blendPixel coverage=255 fg=black" {
    var bmp = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.white);
    defer bmp.deinit();

    bmp.blendPixel(0, 0, 255, Color.black);

    // Pixel (0,0) should be fully black
    try std.testing.expectEqual(@as(u8, 0), bmp.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), bmp.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), bmp.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), bmp.pixels[3]);
}

test "rgba bitmap blendPixel coverage=0 keeps original" {
    var bmp = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.white);
    defer bmp.deinit();

    bmp.blendPixel(0, 0, 0, Color.black);

    // Pixel (0,0) should still be white
    try std.testing.expectEqual(@as(u8, 255), bmp.pixels[0]);
    try std.testing.expectEqual(@as(u8, 255), bmp.pixels[1]);
    try std.testing.expectEqual(@as(u8, 255), bmp.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), bmp.pixels[3]);
}

test "rgba bitmap blendPixelLinear differs from blendPixel for half coverage" {
    var bmp1 = try RgbaBitmap.init(std.testing.allocator, 1, 1, Color.white);
    defer bmp1.deinit();
    var bmp2 = try RgbaBitmap.init(std.testing.allocator, 1, 1, Color.white);
    defer bmp2.deinit();
    bmp1.blendPixel(0, 0, 128, Color.black);
    bmp2.blendPixelLinear(0, 0, 128, Color.black);
    try std.testing.expect(bmp2.pixels[0] > bmp1.pixels[0]);
}

test "rgba bitmap blendPixelLcd" {
    var bmp = try RgbaBitmap.init(std.testing.allocator, 1, 1, Color.white);
    defer bmp.deinit();

    bmp.blendPixelLcd(0, 0, 255, 0, 0, Color.black);

    try std.testing.expectEqual(@as(u8, 0), bmp.pixels[0]);
    try std.testing.expectEqual(@as(u8, 255), bmp.pixels[1]);
    try std.testing.expectEqual(@as(u8, 255), bmp.pixels[2]);
}

test "blitCoverage full opacity blends onto buffer" {
    // 2x2 white RGBA buffer
    var pixels = [_]u8{255} ** (2 * 2 * 4);
    // 1x1 coverage map with full coverage
    const coverage = [_]u8{255};
    blitCoverage(&pixels, 2, 2, &coverage, 1, 1, 0, 0, Color.black, 1.0);
    // Pixel (0,0) should be fully black
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), pixels[2]);
    // Other pixels unchanged
    try std.testing.expectEqual(@as(u8, 255), pixels[4]);
}

test "blitCoverage clipping with negative dst_x dst_y" {
    // 2x2 white RGBA buffer
    var pixels = [_]u8{255} ** (2 * 2 * 4);
    // 2x2 full-coverage map placed at (-1, -1): only pixel (1,1) in coverage maps to (0,0) in dst
    const coverage = [_]u8{ 255, 255, 255, 255 };
    blitCoverage(&pixels, 2, 2, &coverage, 2, 2, -1, -1, Color.black, 1.0);
    // Only pixel (0,0) should be blended (coverage[3] = bottom-right)
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), pixels[2]);
    // Pixel (1,0) and (0,1) also land in bounds: (1,0) from coverage[1], (0,1) from coverage[2]
    // All in-bounds pixels get blended; check at least one out-of-bounds was skipped (no crash)
}

test "blitCoverage opacity=0 leaves buffer unchanged" {
    var pixels = [_]u8{255} ** (2 * 2 * 4);
    const coverage = [_]u8{255};
    blitCoverage(&pixels, 2, 2, &coverage, 1, 1, 0, 0, Color.black, 0.0);
    // All pixels should remain white
    for (pixels, 0..) |v, i| {
        _ = i;
        try std.testing.expectEqual(@as(u8, 255), v);
    }
}
