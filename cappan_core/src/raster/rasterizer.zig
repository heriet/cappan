const std = @import("std");
const glyph_mod = @import("../font/glyph.zig");
const outline_mod = @import("outline.zig");
const scanline_mod = @import("scanline.zig");
const stem_darkening_mod = @import("stem_darkening.zig");
const cff_hinting_mod = @import("cff_hinting.zig");
const ft = @import("../features.zig").features;

pub const RasterResult = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RasterResult) void {
        self.allocator.free(self.pixels);
    }
};

/// Rasterize a single glyph outline at the given scale
pub fn rasterizeGlyph(
    allocator: std.mem.Allocator,
    glyph_outline: glyph_mod.GlyphOutline,
    scale: f32,
    padding: u32,
    raster_options: scanline_mod.RasterOptions,
) !RasterResult {
    // Calculate glyph bounding box in pixel coordinates
    const embolden = @max(0.0, raster_options.embolden_strength);
    const half_embolden = embolden * 0.5;
    const x_min_px = @as(f32, @floatFromInt(glyph_outline.x_min)) * scale - half_embolden;
    const y_min_px = @as(f32, @floatFromInt(glyph_outline.y_min)) * scale - half_embolden;
    const x_max_px = @as(f32, @floatFromInt(glyph_outline.x_max)) * scale + half_embolden;
    const y_max_px = @as(f32, @floatFromInt(glyph_outline.y_max)) * scale + half_embolden;

    const glyph_width = @max(0.0, x_max_px - x_min_px);
    const glyph_height = @max(0.0, y_max_px - y_min_px);

    const pad_f = @as(f32, @floatFromInt(padding));
    const max_dim: f32 = 16384.0;
    const w_f = @ceil(glyph_width + pad_f * 2);
    const h_f = @ceil(glyph_height + pad_f * 2);
    const width: u32 = if (w_f > max_dim or w_f != w_f) return error.InvalidGlyphDimensions else @intFromFloat(w_f);
    const height: u32 = if (h_f > max_dim or h_f != h_f) return error.InvalidGlyphDimensions else @intFromFloat(h_f);

    if (width == 0 or height == 0) {
        const pixels = try allocator.alloc(u8, 0);
        return .{
            .pixels = pixels,
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .allocator = allocator,
        };
    }

    // offset: position in pixel space where font origin maps to
    const offset_x = -x_min_px + pad_f;
    const offset_y = y_max_px + pad_f; // Y flipped: top of glyph

    // Scale and flatten outline
    const scaled = try outline_mod.scaleOutline(allocator, glyph_outline, scale, offset_x, offset_y);
    defer outline_mod.freeScaledContours(allocator, scaled);

    if (comptime ft.enable_hinting) {
        if (glyph_outline.hints) |hint_data| {
            cff_hinting_mod.applyHints(scaled, hint_data, scale);
        }
        if (embolden > 0.0) {
            try stem_darkening_mod.emboldenContours(allocator, scaled, embolden);
        }
    }

    // Flatten all contours into segments
    var all_segments: std.ArrayList(outline_mod.Segment) = .empty;
    defer all_segments.deinit(allocator);

    for (scaled) |contour_points| {
        const segs = try outline_mod.flattenContour(allocator, contour_points);
        defer allocator.free(segs);
        try all_segments.appendSlice(allocator, segs);
    }

    // Rasterize
    const pixels = try scanline_mod.rasterize(allocator, all_segments.items, width, height, raster_options);

    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .allocator = allocator,
    };
}

test "rasterize glyph A from DejaVuSans" {
    const font_mod = @import("../font/font.zig");

    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId(0x0041); // 'A'
    const outline_opt = try font.getGlyphOutline(std.testing.allocator, glyph_id);
    try std.testing.expect(outline_opt != null);
    var outline = outline_opt.?;
    defer outline.deinit();

    const scale = 48.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    var result = try rasterizeGlyph(std.testing.allocator, outline, scale, 1, .{});
    defer result.deinit();

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);

    // Check that some pixels are non-zero (glyph has ink)
    var has_ink = false;
    for (result.pixels) |px| {
        if (px > 0) {
            has_ink = true;
            break;
        }
    }
    try std.testing.expect(has_ink);
}

pub const LcdRasterResult = struct {
    r_coverage: []u8,
    g_coverage: []u8,
    b_coverage: []u8,
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LcdRasterResult) void {
        self.allocator.free(self.r_coverage);
        self.allocator.free(self.g_coverage);
        self.allocator.free(self.b_coverage);
    }
};

pub fn rasterizeGlyphLcd(
    allocator: std.mem.Allocator,
    glyph_outline: glyph_mod.GlyphOutline,
    scale: f32,
    padding: u32,
    raster_options: scanline_mod.RasterOptions,
) !LcdRasterResult {
    const embolden_lcd = @max(0.0, raster_options.embolden_strength);
    const half_embolden_lcd = embolden_lcd * 0.5;
    const x_min_px = @as(f32, @floatFromInt(glyph_outline.x_min)) * scale - half_embolden_lcd;
    const y_min_px = @as(f32, @floatFromInt(glyph_outline.y_min)) * scale - half_embolden_lcd;
    const x_max_px = @as(f32, @floatFromInt(glyph_outline.x_max)) * scale + half_embolden_lcd;
    const y_max_px = @as(f32, @floatFromInt(glyph_outline.y_max)) * scale + half_embolden_lcd;

    const glyph_width = @max(0.0, x_max_px - x_min_px);
    const glyph_height = @max(0.0, y_max_px - y_min_px);

    const pad_f = @as(f32, @floatFromInt(padding));
    const max_dim: f32 = 16384.0;
    const w_f = @ceil(glyph_width + pad_f * 2);
    const h_f = @ceil(glyph_height + pad_f * 2);
    const width: u32 = if (w_f > max_dim or w_f != w_f) return error.InvalidGlyphDimensions else @intFromFloat(w_f);
    const height: u32 = if (h_f > max_dim or h_f != h_f) return error.InvalidGlyphDimensions else @intFromFloat(h_f);

    if (width == 0 or height == 0) {
        const empty_r = try allocator.alloc(u8, 0);
        errdefer allocator.free(empty_r);
        const empty_g = try allocator.alloc(u8, 0);
        errdefer allocator.free(empty_g);
        const empty_b = try allocator.alloc(u8, 0);

        return .{
            .r_coverage = empty_r,
            .g_coverage = empty_g,
            .b_coverage = empty_b,
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .allocator = allocator,
        };
    }

    const offset_x = -x_min_px + pad_f;
    const offset_y = y_max_px + pad_f;
    const wide_width = width * 3;

    // Scale with offset_x=0, then transform X into the 3x-wide LCD coordinate space.
    const scaled = try outline_mod.scaleOutline(allocator, glyph_outline, scale, 0.0, offset_y);
    defer outline_mod.freeScaledContours(allocator, scaled);

    if (comptime ft.enable_hinting) {
        if (glyph_outline.hints) |hint_data| {
            cff_hinting_mod.applyHints(scaled, hint_data, scale);
        }
        if (embolden_lcd > 0.0) {
            try stem_darkening_mod.emboldenContours(allocator, scaled, embolden_lcd);
        }
    }

    for (scaled) |contour_points| {
        for (contour_points) |*pt| {
            pt.x = pt.x * 3.0 + offset_x * 3.0;
        }
    }

    var all_segments: std.ArrayList(outline_mod.Segment) = .empty;
    defer all_segments.deinit(allocator);

    for (scaled) |contour_points| {
        const segs = try outline_mod.flattenContour(allocator, contour_points);
        defer allocator.free(segs);
        try all_segments.appendSlice(allocator, segs);
    }

    const wide_pixels = try scanline_mod.rasterize(allocator, all_segments.items, wide_width, height, raster_options);
    defer allocator.free(wide_pixels);

    const pixel_count = @as(usize, width) * @as(usize, height);
    const r_cov = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(r_cov);
    const g_cov = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(g_cov);
    const b_cov = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(b_cov);

    for (0..height) |y| {
        for (0..@as(usize, width)) |x| {
            const dst = y * @as(usize, width) + x;
            const src_base = y * @as(usize, wide_width) + x * 3;
            r_cov[dst] = wide_pixels[src_base];
            g_cov[dst] = wide_pixels[src_base + 1];
            b_cov[dst] = wide_pixels[src_base + 2];
        }
    }

    return .{
        .r_coverage = r_cov,
        .g_coverage = g_cov,
        .b_coverage = b_cov,
        .width = width,
        .height = height,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .allocator = allocator,
    };
}

test "rasterize glyph LCD A from DejaVuSans" {
    const font_mod = @import("../font/font.zig");
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId(0x0041);
    var outline = (try font.getGlyphOutline(std.testing.allocator, glyph_id)).?;
    defer outline.deinit();

    const scale = 48.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    var result = try rasterizeGlyphLcd(std.testing.allocator, outline, scale, 1, .{});
    defer result.deinit();

    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
    try std.testing.expect(result.r_coverage.len > 0);
    try std.testing.expect(result.g_coverage.len == result.r_coverage.len);
    try std.testing.expect(result.b_coverage.len == result.r_coverage.len);
}
