const std = @import("std");
const font_mod = @import("../font/font.zig");
const shaper = @import("../layout/shaper.zig");
const rasterizer_mod = @import("../raster/rasterizer.zig");
const outline_mod = @import("../raster/outline.zig");
const scanline_mod = @import("../raster/scanline.zig");
const stem_darkening_mod = @import("../raster/stem_darkening.zig");
const stroker_mod = @import("../raster/stroker.zig");
const rgba_bitmap_mod = @import("rgba_bitmap.zig");
const gamma_mod = @import("gamma.zig");
const png_decoder_mod = @import("../image/png_decoder.zig");
const paint_mod = @import("paint.zig");
const glyph_mod = @import("../font/glyph.zig");
const auto_hinting_mod = @import("../raster/auto_hinting.zig");
const colr_painter_mod = @import("colr_painter.zig");
const ft = @import("../features.zig").features;

pub const RgbaBitmap = rgba_bitmap_mod.RgbaBitmap;
pub const Color = rgba_bitmap_mod.Color;

pub const RenderOptions = struct {
    pixel_size: f32 = 48.0,
    padding: u32 = 4,
    fg_color: rgba_bitmap_mod.Color = rgba_bitmap_mod.Color.black,
    bg_color: rgba_bitmap_mod.Color = rgba_bitmap_mod.Color.white,
    gamma_correction: bool = false,
    fractional_positioning: bool = false,
    max_width: ?f32 = null,
    text_align: shaper.TextAlign = .left,
    lcd_rendering: bool = false,
    paint_stack: ?[]const paint_mod.PaintOperation = null,
    raster_options: scanline_mod.RasterOptions = .{},
    stem_darkening: bool = false,
    cff_hinting: bool = false,
    auto_hinting: bool = false,
};

fn applyOutlineHinting(
    allocator: std.mem.Allocator,
    outline: *glyph_mod.GlyphOutline,
    glyph_font: font_mod.Font,
    glyph_id: u16,
    options: RenderOptions,
) !void {
    if (comptime !ft.enable_hinting) return;
    if (options.cff_hinting) {
        if (outline.hints) |*h| {
            h.blue_zones = glyph_font.getBlueZones(glyph_id);
        }
    }
    if (options.auto_hinting and outline.hints == null) {
        outline.hints = try auto_hinting_mod.generateHints(allocator, outline.*, glyph_font.getAutoBlueZones());
    }
}

pub const CachedRaster = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
};

const CachedLcdRaster = struct {
    r_coverage: []u8,
    g_coverage: []u8,
    b_coverage: []u8,
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
};

pub fn glyphCacheKey(font_index: u8, glyph_id: u16) u32 {
    return (@as(u32, font_index) << 16) | @as(u32, glyph_id);
}

const PaintOpKind = enum(u8) { fill, stroke };

const PaintCacheKey = struct {
    font_index: u8,
    glyph_id: u16,
    op_kind: PaintOpKind,
    stroke_width_q: u16,
    stroke_position: stroker_mod.StrokePosition,
    line_join: stroker_mod.LineJoin,
    miter_limit_q: u16,
};

fn resolveRasterOptions(options: RenderOptions) scanline_mod.RasterOptions {
    if (comptime ft.enable_hinting) {
        return if (options.stem_darkening)
            stem_darkening_mod.resolveRasterOptions(options.pixel_size, options.raster_options)
        else
            options.raster_options;
    }
    return options.raster_options;
}

pub fn renderText(allocator: std.mem.Allocator, fonts: []const font_mod.Font, text: []const u8, options: RenderOptions) !rgba_bitmap_mod.RgbaBitmap {
    if (options.paint_stack) |paint_stack| {
        return renderTextPaintStack(allocator, fonts, text, options, paint_stack);
    }

    const raster_options = resolveRasterOptions(options);

    var layout = try shaper.layoutText(allocator, fonts, text, .{
        .pixel_size = options.pixel_size,
        .max_width = options.max_width,
        .text_align = options.text_align,
    });
    defer layout.deinit();

    const pad = @as(f32, @floatFromInt(options.padding));

    const bmp_width = @as(u32, @intFromFloat(@ceil(layout.total_width + pad * 2)));
    const bmp_height = @as(u32, @intFromFloat(@ceil(layout.total_height + pad * 2)));

    if (bmp_width == 0 or bmp_height == 0) {
        return rgba_bitmap_mod.RgbaBitmap.init(allocator, 1, 1, options.bg_color);
    }

    var bitmap = try rgba_bitmap_mod.RgbaBitmap.init(allocator, bmp_width, bmp_height, options.bg_color);
    errdefer bitmap.deinit();

    const base_baseline_y = pad + layout.ascender_px;
    if (options.lcd_rendering) {
        var lcd_cache: std.AutoHashMapUnmanaged(u32, CachedLcdRaster) = .empty;
        defer {
            var it = lcd_cache.valueIterator();
            while (it.next()) |entry| {
                allocator.free(entry.r_coverage);
                allocator.free(entry.g_coverage);
                allocator.free(entry.b_coverage);
            }
            lcd_cache.deinit(allocator);
        }

        for (layout.positions) |pos| {
            const cache_key = glyphCacheKey(pos.font_index, pos.glyph_id);

            if (lcd_cache.get(cache_key)) |cached| {
                if (cached.width == 0 or cached.height == 0) continue;
                blendLcdRaster(&bitmap, cached, pos, base_baseline_y, pad, bmp_width, bmp_height, options.fg_color);
                continue;
            }

            const glyph_font = fonts[pos.font_index];
            const glyph_scale = options.pixel_size / @as(f32, @floatFromInt(glyph_font.getUnitsPerEm()));

            const outline_opt = glyph_font.getGlyphOutline(allocator, pos.glyph_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (outline_opt == null) {
                const empty_r = try allocator.alloc(u8, 0);
                errdefer allocator.free(empty_r);
                const empty_g = try allocator.alloc(u8, 0);
                errdefer allocator.free(empty_g);
                const empty_b = try allocator.alloc(u8, 0);
                errdefer allocator.free(empty_b);
                try lcd_cache.put(allocator, cache_key, .{
                    .r_coverage = empty_r,
                    .g_coverage = empty_g,
                    .b_coverage = empty_b,
                    .width = 0,
                    .height = 0,
                    .offset_x = 0,
                    .offset_y = 0,
                });
                continue;
            }
            var outline = outline_opt.?;
            defer outline.deinit();

            try applyOutlineHinting(allocator, &outline, glyph_font, pos.glyph_id, options);
            const lcd_result = try rasterizer_mod.rasterizeGlyphLcd(allocator, outline, glyph_scale, options.padding, raster_options);

            const entry = CachedLcdRaster{
                .r_coverage = lcd_result.r_coverage,
                .g_coverage = lcd_result.g_coverage,
                .b_coverage = lcd_result.b_coverage,
                .width = lcd_result.width,
                .height = lcd_result.height,
                .offset_x = lcd_result.offset_x,
                .offset_y = lcd_result.offset_y,
            };
            errdefer {
                allocator.free(entry.r_coverage);
                allocator.free(entry.g_coverage);
                allocator.free(entry.b_coverage);
            }
            try lcd_cache.put(allocator, cache_key, entry);

            if (entry.width == 0 or entry.height == 0) continue;
            blendLcdRaster(&bitmap, entry, pos, base_baseline_y, pad, bmp_width, bmp_height, options.fg_color);
        }
    } else {
        var glyph_cache: std.AutoHashMapUnmanaged(u32, CachedRaster) = .empty;
        defer {
            var it = glyph_cache.valueIterator();
            while (it.next()) |entry| {
                allocator.free(entry.pixels);
            }
            glyph_cache.deinit(allocator);
        }

        for (layout.positions) |pos| {
            const cache_key = glyphCacheKey(pos.font_index, pos.glyph_id);

            if (glyph_cache.get(cache_key)) |cached| {
                if (cached.width == 0 or cached.height == 0) continue;
                blendRaster(&bitmap, cached, pos, base_baseline_y, pad, bmp_width, bmp_height, options.fg_color, options.gamma_correction, options.fractional_positioning);
                continue;
            }

            const glyph_font = fonts[pos.font_index];
            const glyph_scale = options.pixel_size / @as(f32, @floatFromInt(glyph_font.getUnitsPerEm()));

            if (glyph_font.getBitmapGlyph(pos.glyph_id)) |bitmap_glyph| {
                if (comptime ft.enable_bitmap) {
                    // Decode embedded PNG from CBDT and blend onto the output bitmap
                    var decoded = png_decoder_mod.decode(allocator, bitmap_glyph.png_data) catch {
                        // If decode fails, skip this glyph
                        const empty_pixels = try allocator.alloc(u8, 0);
                        try glyph_cache.put(allocator, cache_key, .{ .pixels = empty_pixels, .width = 0, .height = 0, .offset_x = 0, .offset_y = 0 });
                        continue;
                    };
                    defer decoded.deinit();

                    const bearing_x: f32 = @floatFromInt(bitmap_glyph.metrics.bearing_x);
                    const bearing_y: f32 = @floatFromInt(bitmap_glyph.metrics.bearing_y);
                    const dst_x = @as(i32, @intFromFloat(pos.x_offset + pad + bearing_x));
                    const dst_y = @as(i32, @intFromFloat(base_baseline_y + pos.y_offset - bearing_y));

                    blendBitmapGlyph(&bitmap, decoded.pixels, decoded.width, decoded.height, dst_x, dst_y, bmp_width, bmp_height);
                }
            } else if (try tryRenderColrV1(allocator, &bitmap, &glyph_font, pos, glyph_scale, raster_options, options, base_baseline_y, pad, bmp_width, bmp_height)) {
                // COLR v1 rendered successfully, skip other paths
            } else if (glyph_font.getColorLayers(pos.glyph_id)) |base| {
                var layer_idx: u16 = base.first_layer_idx;
                const end_idx: u16 = base.first_layer_idx + base.num_layers;
                while (layer_idx < end_idx) : (layer_idx += 1) {
                    if (glyph_font.getColorLayer(layer_idx)) |layer| {
                        const layer_color = if (layer.palette_index == 0xFFFF)
                            options.fg_color
                        else if (glyph_font.getPaletteColor(0, layer.palette_index)) |pc|
                            rgba_bitmap_mod.Color{ .r = pc.r, .g = pc.g, .b = pc.b, .a = pc.a }
                        else
                            options.fg_color;
                        const layer_cache_key = glyphCacheKey(pos.font_index, layer.glyph_id);
                        if (glyph_cache.get(layer_cache_key)) |cached| {
                            if (cached.width == 0 or cached.height == 0) continue;
                            blendRaster(&bitmap, cached, pos, base_baseline_y, pad, bmp_width, bmp_height, layer_color, options.gamma_correction, options.fractional_positioning);
                            continue;
                        }
                        const layer_outline_opt = glyph_font.getGlyphOutline(allocator, layer.glyph_id) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => null,
                        };
                        if (layer_outline_opt == null) {
                            const empty_pixels = try allocator.alloc(u8, 0);
                            try glyph_cache.put(allocator, layer_cache_key, .{ .pixels = empty_pixels, .width = 0, .height = 0, .offset_x = 0, .offset_y = 0 });
                            continue;
                        }
                        var layer_outline = layer_outline_opt.?;
                        defer layer_outline.deinit();
                        const layer_result = try rasterizer_mod.rasterizeGlyph(allocator, layer_outline, glyph_scale, options.padding, raster_options);
                        const layer_entry = CachedRaster{ .pixels = layer_result.pixels, .width = layer_result.width, .height = layer_result.height, .offset_x = layer_result.offset_x, .offset_y = layer_result.offset_y };
                        try glyph_cache.put(allocator, layer_cache_key, layer_entry);
                        if (layer_entry.width == 0 or layer_entry.height == 0) continue;
                        blendRaster(&bitmap, layer_entry, pos, base_baseline_y, pad, bmp_width, bmp_height, layer_color, options.gamma_correction, options.fractional_positioning);
                    }
                }
            } else {
                const outline_opt = glyph_font.getGlyphOutline(allocator, pos.glyph_id) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => null,
                };
                if (outline_opt == null) {
                    const empty_pixels = try allocator.alloc(u8, 0);
                    try glyph_cache.put(allocator, cache_key, .{
                        .pixels = empty_pixels,
                        .width = 0,
                        .height = 0,
                        .offset_x = 0,
                        .offset_y = 0,
                    });
                    continue;
                }
                var outline = outline_opt.?;
                defer outline.deinit();

                try applyOutlineHinting(allocator, &outline, glyph_font, pos.glyph_id, options);
                const glyph_result = try rasterizer_mod.rasterizeGlyph(allocator, outline, glyph_scale, options.padding, raster_options);

                const entry = CachedRaster{
                    .pixels = glyph_result.pixels,
                    .width = glyph_result.width,
                    .height = glyph_result.height,
                    .offset_x = glyph_result.offset_x,
                    .offset_y = glyph_result.offset_y,
                };
                try glyph_cache.put(allocator, cache_key, entry);

                if (entry.width == 0 or entry.height == 0) continue;
                blendRaster(&bitmap, entry, pos, base_baseline_y, pad, bmp_width, bmp_height, options.fg_color, options.gamma_correction, options.fractional_positioning);
            }
        }
    }

    return bitmap;
}

fn renderTextPaintStack(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    text: []const u8,
    options: RenderOptions,
    paint_stack: []const paint_mod.PaintOperation,
) !rgba_bitmap_mod.RgbaBitmap {
    const raster_options = resolveRasterOptions(options);

    var layout = try shaper.layoutText(allocator, fonts, text, .{
        .pixel_size = options.pixel_size,
        .max_width = options.max_width,
        .text_align = options.text_align,
    });
    defer layout.deinit();

    var max_stroke_expansion: f32 = 0.0;
    const max_expansion_limit: f32 = 4096.0;
    for (paint_stack) |op| {
        switch (op) {
            .fill => {},
            .stroke => |stroke| {
                const width = stroke.width.resolveToPixels(options.pixel_size);
                if (std.math.isNan(width) or std.math.isInf(width)) continue;
                const expansion = switch (stroke.position) {
                    .center => width * 0.5,
                    .outside => width,
                    .inside => 0.0,
                };
                max_stroke_expansion = @max(max_stroke_expansion, expansion);
            },
        }
    }
    max_stroke_expansion = @min(max_stroke_expansion, max_expansion_limit);

    const extended_padding = options.padding +| @as(u32, @intFromFloat(@ceil(max_stroke_expansion)));
    const pad = @as(f32, @floatFromInt(extended_padding));

    const max_bmp_dim: f32 = 16384.0;
    const bmp_width_f = @ceil(layout.total_width + pad * 2);
    const bmp_height_f = @ceil(layout.total_height + pad * 2);
    const bmp_width: u32 = if (!(bmp_width_f >= 0.0 and bmp_width_f <= max_bmp_dim)) return error.OutOfMemory else @intFromFloat(bmp_width_f);
    const bmp_height: u32 = if (!(bmp_height_f >= 0.0 and bmp_height_f <= max_bmp_dim)) return error.OutOfMemory else @intFromFloat(bmp_height_f);

    if (bmp_width == 0 or bmp_height == 0) {
        return rgba_bitmap_mod.RgbaBitmap.init(allocator, 1, 1, options.bg_color);
    }

    var bitmap = try rgba_bitmap_mod.RgbaBitmap.init(allocator, bmp_width, bmp_height, options.bg_color);
    errdefer bitmap.deinit();

    const base_baseline_y = pad + layout.ascender_px;
    var paint_cache: std.AutoHashMapUnmanaged(PaintCacheKey, CachedRaster) = .empty;
    defer {
        var it = paint_cache.valueIterator();
        while (it.next()) |entry| {
            allocator.free(entry.pixels);
        }
        paint_cache.deinit(allocator);
    }

    for (paint_stack) |op| {
        const opacity = getOpacity(op);
        const needs_temp = opacity < 0.996;

        var temp_bmp: ?rgba_bitmap_mod.RgbaBitmap = if (needs_temp)
            try rgba_bitmap_mod.RgbaBitmap.init(allocator, bmp_width, bmp_height, rgba_bitmap_mod.Color.transparent)
        else
            null;
        defer if (temp_bmp) |*tb| tb.deinit();

        const target = if (temp_bmp) |*tb| tb else &bitmap;
        const blend_color = if (needs_temp) opaqueColor(op) else paintColor(op);

        for (layout.positions) |pos| {
            const glyph_font = fonts[pos.font_index];
            const glyph_scale = options.pixel_size / @as(f32, @floatFromInt(glyph_font.getUnitsPerEm()));
            const cache_key = paintCacheKey(pos.font_index, pos.glyph_id, op, options.pixel_size);

            if (paint_cache.get(cache_key)) |cached| {
                if (cached.width == 0 or cached.height == 0) continue;
                blendRaster(target, cached, pos, base_baseline_y, pad, bmp_width, bmp_height, blend_color, options.gamma_correction, options.fractional_positioning);
                continue;
            }

            const outline_opt = glyph_font.getGlyphOutline(allocator, pos.glyph_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (outline_opt == null) {
                const empty_pixels = try allocator.alloc(u8, 0);
                try paint_cache.put(allocator, cache_key, .{
                    .pixels = empty_pixels,
                    .width = 0,
                    .height = 0,
                    .offset_x = 0,
                    .offset_y = 0,
                });
                continue;
            }
            var outline = outline_opt.?;
            defer outline.deinit();

            const entry = switch (op) {
                .fill => blk: {
                    try applyOutlineHinting(allocator, &outline, glyph_font, pos.glyph_id, options);
                    const glyph_result = try rasterizer_mod.rasterizeGlyph(allocator, outline, glyph_scale, extended_padding, raster_options);
                    break :blk CachedRaster{
                        .pixels = glyph_result.pixels,
                        .width = glyph_result.width,
                        .height = glyph_result.height,
                        .offset_x = glyph_result.offset_x,
                        .offset_y = glyph_result.offset_y,
                    };
                },
                .stroke => |stroke| try rasterizeStrokeGlyph(allocator, outline, glyph_scale, extended_padding, stroke, options.pixel_size, raster_options),
            };
            errdefer allocator.free(entry.pixels);
            try paint_cache.put(allocator, cache_key, entry);

            if (entry.width == 0 or entry.height == 0) continue;
            blendRaster(target, entry, pos, base_baseline_y, pad, bmp_width, bmp_height, blend_color, options.gamma_correction, options.fractional_positioning);
        }

        if (temp_bmp) |tb| {
            compositeWithOpacity(&bitmap, tb, opacity);
        }
    }

    return bitmap;
}

fn paintCacheKey(font_index: u8, glyph_id: u16, op: paint_mod.PaintOperation, pixel_size: f32) PaintCacheKey {
    return switch (op) {
        .fill => .{
            .font_index = font_index,
            .glyph_id = glyph_id,
            .op_kind = .fill,
            .stroke_width_q = 0,
            .stroke_position = .center,
            .line_join = .bevel,
            .miter_limit_q = 0,
        },
        .stroke => |stroke| .{
            .font_index = font_index,
            .glyph_id = glyph_id,
            .op_kind = .stroke,
            .stroke_width_q = quantizedStrokeWidth(stroke.width.resolveToPixels(pixel_size)),
            .stroke_position = stroke.position,
            .line_join = stroke.join,
            .miter_limit_q = quantizedStrokeWidth(stroke.miter_limit),
        },
    };
}

fn quantizedStrokeWidth(width: f32) u16 {
    if (!(width > 0.0)) return 0;
    const q = @round(width * 4.0);
    if (q >= @as(f32, @floatFromInt(std.math.maxInt(u16)))) return std.math.maxInt(u16);
    return @intFromFloat(q);
}

fn paintColor(op: paint_mod.PaintOperation) rgba_bitmap_mod.Color {
    return switch (op) {
        .fill => |fill| applyOpacity(fill.color, fill.opacity),
        .stroke => |stroke| applyOpacity(stroke.color, stroke.opacity),
    };
}

fn getOpacity(op: paint_mod.PaintOperation) f32 {
    return switch (op) {
        .fill => |fill| fill.opacity,
        .stroke => |stroke| stroke.opacity,
    };
}

fn opaqueColor(op: paint_mod.PaintOperation) rgba_bitmap_mod.Color {
    return switch (op) {
        .fill => |fill| fill.color,
        .stroke => |stroke| stroke.color,
    };
}

pub fn applyOpacity(color: rgba_bitmap_mod.Color, opacity: f32) rgba_bitmap_mod.Color {
    const clamped = @max(0.0, @min(1.0, opacity));
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = @intFromFloat(@round(@as(f32, @floatFromInt(color.a)) * clamped)),
    };
}

pub fn compositeWithOpacity(dst: *rgba_bitmap_mod.RgbaBitmap, src: rgba_bitmap_mod.RgbaBitmap, opacity: f32) void {
    std.debug.assert(src.pixels.len == dst.pixels.len);
    const clamped = @max(0.0, @min(1.0, opacity));
    var i: usize = 0;
    while (i < dst.pixels.len) : (i += 4) {
        const sa = src.pixels[i + 3];
        if (sa == 0) continue;

        const alpha = @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(sa)) * clamped)));
        if (alpha == 0) continue;

        const inv_alpha = 255 - alpha;
        dst.pixels[i + 0] = @intCast((@as(u16, dst.pixels[i + 0]) * inv_alpha + @as(u16, src.pixels[i + 0]) * alpha) / 255);
        dst.pixels[i + 1] = @intCast((@as(u16, dst.pixels[i + 1]) * inv_alpha + @as(u16, src.pixels[i + 1]) * alpha) / 255);
        dst.pixels[i + 2] = @intCast((@as(u16, dst.pixels[i + 2]) * inv_alpha + @as(u16, src.pixels[i + 2]) * alpha) / 255);
        dst.pixels[i + 3] = @intCast(@min(@as(u16, 255), @as(u16, dst.pixels[i + 3]) + alpha));
    }
}

pub fn rasterizeStrokeGlyph(
    allocator: std.mem.Allocator,
    glyph_outline: glyph_mod.GlyphOutline,
    scale: f32,
    padding: u32,
    stroke: paint_mod.StrokePaint,
    pixel_size: f32,
    raster_options: scanline_mod.RasterOptions,
) !CachedRaster {
    const x_min_px = @as(f32, @floatFromInt(glyph_outline.x_min)) * scale;
    const y_min_px = @as(f32, @floatFromInt(glyph_outline.y_min)) * scale;
    const x_max_px = @as(f32, @floatFromInt(glyph_outline.x_max)) * scale;
    const y_max_px = @as(f32, @floatFromInt(glyph_outline.y_max)) * scale;

    const glyph_width = @max(0.0, x_max_px - x_min_px);
    const glyph_height = @max(0.0, y_max_px - y_min_px);

    const pad_f = @as(f32, @floatFromInt(padding));
    const max_dim: f32 = 16384.0;
    const w_f = @ceil(glyph_width + pad_f * 2);
    const h_f = @ceil(glyph_height + pad_f * 2);
    const width: u32 = if (!(w_f >= 0.0 and w_f <= max_dim)) return error.InvalidGlyphDimensions else @intFromFloat(w_f);
    const height: u32 = if (!(h_f >= 0.0 and h_f <= max_dim)) return error.InvalidGlyphDimensions else @intFromFloat(h_f);

    if (width == 0 or height == 0) {
        return .{
            .pixels = try allocator.alloc(u8, 0),
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
        };
    }

    const offset_x = -x_min_px + pad_f;
    const offset_y = y_max_px + pad_f;

    const scaled = try outline_mod.scaleOutline(allocator, glyph_outline, scale, offset_x, offset_y);
    defer outline_mod.freeScaledContours(allocator, scaled);

    var all_segments: std.ArrayList(outline_mod.Segment) = .empty;
    defer all_segments.deinit(allocator);

    const width_px = stroke.width.resolveToPixels(pixel_size);
    for (scaled) |contour_points| {
        const segs = try outline_mod.flattenContour(allocator, contour_points);
        defer allocator.free(segs);

        const stroke_segments = try stroker_mod.generateStrokeOutline(allocator, segs, width_px, stroke.join, stroke.position, stroke.miter_limit);
        defer allocator.free(stroke_segments);
        try all_segments.appendSlice(allocator, stroke_segments);
    }

    const pixels = try scanline_mod.rasterize(allocator, all_segments.items, width, height, raster_options);

    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .offset_x = offset_x,
        .offset_y = offset_y,
    };
}

fn blendSubpixel(
    bitmap: *rgba_bitmap_mod.RgbaBitmap,
    ix: i32,
    iy: i32,
    coverage: u8,
    bmp_width: u32,
    bmp_height: u32,
    fg_color: rgba_bitmap_mod.Color,
    gamma_correction: bool,
) void {
    if (ix < 0 or iy < 0) return;
    const ux = @as(u32, @intCast(ix));
    const uy = @as(u32, @intCast(iy));
    if (ux >= bmp_width or uy >= bmp_height) return;
    if (coverage == 0) return;
    if (gamma_correction) {
        bitmap.blendPixelLinear(ux, uy, coverage, fg_color);
    } else {
        bitmap.blendPixel(ux, uy, coverage, fg_color);
    }
}

fn blendRaster(
    bitmap: *rgba_bitmap_mod.RgbaBitmap,
    raster: CachedRaster,
    pos: shaper.GlyphPosition,
    base_baseline_y: f32,
    pad: f32,
    bmp_width: u32,
    bmp_height: u32,
    fg_color: rgba_bitmap_mod.Color,
    gamma_correction: bool,
    fractional_positioning: bool,
) void {
    const origin_x = pos.x_offset + pad;
    const origin_y = base_baseline_y + pos.y_offset;
    const bmp_x0 = origin_x - raster.offset_x;
    const bmp_y0 = origin_y - raster.offset_y;

    for (0..raster.height) |gy| {
        for (0..raster.width) |gx| {
            const coverage = raster.pixels[gy * @as(usize, raster.width) + gx];
            if (coverage == 0) continue;

            const bmp_xf = bmp_x0 + @as(f32, @floatFromInt(gx));
            const bmp_yf = bmp_y0 + @as(f32, @floatFromInt(gy));

            if (fractional_positioning) {
                const ix = @as(i32, @intFromFloat(@floor(bmp_xf)));
                const iy = @as(i32, @intFromFloat(@floor(bmp_yf)));
                const dx = bmp_xf - @as(f32, @floatFromInt(ix));
                const dy = bmp_yf - @as(f32, @floatFromInt(iy));
                const cov_f = @as(f32, @floatFromInt(coverage));

                const w00 = (1.0 - dx) * (1.0 - dy);
                const w10 = dx * (1.0 - dy);
                const w01 = (1.0 - dx) * dy;
                const w11 = dx * dy;

                blendSubpixel(bitmap, ix, iy, @intFromFloat(@min(255.0, @round(cov_f * w00))), bmp_width, bmp_height, fg_color, gamma_correction);
                blendSubpixel(bitmap, ix + 1, iy, @intFromFloat(@min(255.0, @round(cov_f * w10))), bmp_width, bmp_height, fg_color, gamma_correction);
                blendSubpixel(bitmap, ix, iy + 1, @intFromFloat(@min(255.0, @round(cov_f * w01))), bmp_width, bmp_height, fg_color, gamma_correction);
                blendSubpixel(bitmap, ix + 1, iy + 1, @intFromFloat(@min(255.0, @round(cov_f * w11))), bmp_width, bmp_height, fg_color, gamma_correction);
            } else {
                if (bmp_xf < 0 or bmp_yf < 0) continue;
                const bmp_xi = @as(u32, @intFromFloat(bmp_xf));
                const bmp_yi = @as(u32, @intFromFloat(bmp_yf));
                if (bmp_xi >= bmp_width or bmp_yi >= bmp_height) continue;

                if (gamma_correction) {
                    bitmap.blendPixelLinear(bmp_xi, bmp_yi, coverage, fg_color);
                } else {
                    bitmap.blendPixel(bmp_xi, bmp_yi, coverage, fg_color);
                }
            }
        }
    }
}

fn blendLcdRaster(
    bitmap: *rgba_bitmap_mod.RgbaBitmap,
    raster: CachedLcdRaster,
    pos: shaper.GlyphPosition,
    base_baseline_y: f32,
    pad: f32,
    bmp_width: u32,
    bmp_height: u32,
    fg_color: rgba_bitmap_mod.Color,
) void {
    const origin_x = pos.x_offset + pad;
    const origin_y = base_baseline_y + pos.y_offset;
    const bmp_x0 = origin_x - raster.offset_x;
    const bmp_y0 = origin_y - raster.offset_y;

    for (0..raster.height) |gy| {
        for (0..raster.width) |gx| {
            const idx = gy * @as(usize, raster.width) + gx;
            const r = raster.r_coverage[idx];
            const g = raster.g_coverage[idx];
            const b = raster.b_coverage[idx];
            if (r == 0 and g == 0 and b == 0) continue;

            const bmp_xf = bmp_x0 + @as(f32, @floatFromInt(gx));
            const bmp_yf = bmp_y0 + @as(f32, @floatFromInt(gy));

            if (bmp_xf < 0 or bmp_yf < 0) continue;
            const bmp_xi = @as(u32, @intFromFloat(bmp_xf));
            const bmp_yi = @as(u32, @intFromFloat(bmp_yf));
            if (bmp_xi >= bmp_width or bmp_yi >= bmp_height) continue;

            bitmap.blendPixelLcd(bmp_xi, bmp_yi, r, g, b, fg_color);
        }
    }
}

/// Alpha-blend an RGBA bitmap onto the destination bitmap at (dst_x, dst_y).
fn blendBitmapGlyph(
    dst: *rgba_bitmap_mod.RgbaBitmap,
    src_pixels: []const u8,
    src_width: u32,
    src_height: u32,
    dst_x: i32,
    dst_y: i32,
    bmp_width: u32,
    bmp_height: u32,
) void {
    var sy: u32 = 0;
    while (sy < src_height) : (sy += 1) {
        const dy = dst_y + @as(i32, @intCast(sy));
        if (dy < 0 or dy >= @as(i32, @intCast(bmp_height))) continue;
        const dy_u: u32 = @intCast(dy);

        var sx: u32 = 0;
        while (sx < src_width) : (sx += 1) {
            const dx = dst_x + @as(i32, @intCast(sx));
            if (dx < 0 or dx >= @as(i32, @intCast(bmp_width))) continue;
            const dx_u: u32 = @intCast(dx);

            const src_idx = (@as(usize, sy) * @as(usize, src_width) + @as(usize, sx)) * 4;
            const sr = src_pixels[src_idx];
            const sg = src_pixels[src_idx + 1];
            const sb = src_pixels[src_idx + 2];
            const sa = src_pixels[src_idx + 3];

            if (sa == 0) continue;

            const dst_idx = (@as(usize, dy_u) * @as(usize, bmp_width) + @as(usize, dx_u)) * 4;
            const alpha: u16 = sa;
            const inv_alpha: u16 = 255 - alpha;
            dst.pixels[dst_idx + 0] = @intCast((@as(u16, dst.pixels[dst_idx + 0]) * inv_alpha + @as(u16, sr) * alpha) / 255);
            dst.pixels[dst_idx + 1] = @intCast((@as(u16, dst.pixels[dst_idx + 1]) * inv_alpha + @as(u16, sg) * alpha) / 255);
            dst.pixels[dst_idx + 2] = @intCast((@as(u16, dst.pixels[dst_idx + 2]) * inv_alpha + @as(u16, sb) * alpha) / 255);
            dst.pixels[dst_idx + 3] = @intCast(@min(@as(u16, 255), @as(u16, dst.pixels[dst_idx + 3]) + alpha));
        }
    }
}

fn blendColrV1Bitmap(
    dst: *rgba_bitmap_mod.RgbaBitmap,
    result: colr_painter_mod.RenderResult,
    pos: shaper.GlyphPosition,
    base_baseline_y: f32,
    pad: f32,
    bmp_width: u32,
    bmp_height: u32,
) void {
    const origin_x = pos.x_offset + pad;
    const origin_y = base_baseline_y + pos.y_offset;
    const raw_x = origin_x - result.offset_x;
    const raw_y = origin_y - result.offset_y;
    if (!(@abs(raw_x) < 2e9 and @abs(raw_y) < 2e9)) return;
    const dst_x = @as(i32, @intFromFloat(@round(raw_x)));
    const dst_y = @as(i32, @intFromFloat(@round(raw_y)));

    blendBitmapGlyph(dst, result.bitmap.pixels, result.bitmap.width, result.bitmap.height, dst_x, dst_y, bmp_width, bmp_height);
}

fn tryRenderColrV1(
    allocator: std.mem.Allocator,
    bitmap: *rgba_bitmap_mod.RgbaBitmap,
    glyph_font: *const font_mod.Font,
    pos: shaper.GlyphPosition,
    glyph_scale: f32,
    raster_options: scanline_mod.RasterOptions,
    options: RenderOptions,
    base_baseline_y: f32,
    pad: f32,
    bmp_width: u32,
    bmp_height: u32,
) !bool {
    if (comptime !ft.enable_color) return false;
    const colr = glyph_font.colr orelse return false;
    if (colr.findBaseGlyphV1Paint(pos.glyph_id) == null) return false;
    const cpal = glyph_font.cpal;
    const result = colr_painter_mod.renderColrV1Glyph(
        allocator,
        glyph_font,
        colr,
        cpal,
        pos.glyph_id,
        glyph_scale,
        options.fg_color,
        raster_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (result) |r| {
        var cr = r;
        defer cr.deinit();
        blendColrV1Bitmap(bitmap, cr, pos, base_baseline_y, pad, bmp_width, bmp_height);
        return true;
    }
    return false;
}

test "render text produces non-empty bitmap" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var bitmap = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{ .pixel_size = 32 });
    defer bitmap.deinit();

    try std.testing.expect(bitmap.width > 0);
    try std.testing.expect(bitmap.height > 0);

    var has_dark = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        if (bitmap.pixels[i] < 200) {
            has_dark = true;
            break;
        }
    }
    try std.testing.expect(has_dark);
}

test "render text with red fg color" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const red = rgba_bitmap_mod.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    var bitmap = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .fg_color = red,
        .bg_color = rgba_bitmap_mod.Color.white,
    });
    defer bitmap.deinit();

    try std.testing.expect(bitmap.width > 0);
    try std.testing.expect(bitmap.height > 0);

    var has_red_pixel = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        const g = bitmap.pixels[i + 1];
        if (g < 200) {
            has_red_pixel = true;
            break;
        }
    }
    try std.testing.expect(has_red_pixel);
}

test "render text with paint stack outside stroke and fill" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const red = rgba_bitmap_mod.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const paint_stack = [_]paint_mod.PaintOperation{
        .{ .stroke = .{ .color = red, .width = .{ .px = 6.0 }, .position = .outside } },
        .{ .fill = .{ .color = rgba_bitmap_mod.Color.black } },
    };

    var base = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{ .pixel_size = 32 });
    defer base.deinit();

    var bitmap = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .bg_color = rgba_bitmap_mod.Color.white,
        .paint_stack = &paint_stack,
    });
    defer bitmap.deinit();

    try std.testing.expect(bitmap.width >= base.width + 12);
    try std.testing.expect(bitmap.height >= base.height + 12);

    var has_red = false;
    var has_dark = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        const r = bitmap.pixels[i];
        const g = bitmap.pixels[i + 1];
        const b = bitmap.pixels[i + 2];
        if (r > 200 and g < 120 and b < 120) has_red = true;
        if (r < 80 and g < 80 and b < 80) has_dark = true;
    }

    try std.testing.expect(has_red);
    try std.testing.expect(has_dark);
}

test "render text with semi-transparent paint stack" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const red = rgba_bitmap_mod.Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const opaque_ops = [_]paint_mod.PaintOperation{
        .{ .stroke = .{ .color = red, .width = .{ .px = 6.0 }, .position = .outside, .opacity = 1.0 } },
        .{ .fill = .{ .color = rgba_bitmap_mod.Color.black } },
    };
    const transparent_ops = [_]paint_mod.PaintOperation{
        .{ .stroke = .{ .color = red, .width = .{ .px = 6.0 }, .position = .outside, .opacity = 0.5 } },
        .{ .fill = .{ .color = rgba_bitmap_mod.Color.black, .opacity = 0.5 } },
    };

    var opaque_bmp = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "lll", .{
        .pixel_size = 32,
        .bg_color = rgba_bitmap_mod.Color.white,
        .paint_stack = &opaque_ops,
    });
    defer opaque_bmp.deinit();

    var transparent_bmp = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "lll", .{
        .pixel_size = 32,
        .bg_color = rgba_bitmap_mod.Color.white,
        .paint_stack = &transparent_ops,
    });
    defer transparent_bmp.deinit();

    try std.testing.expectEqual(opaque_bmp.width, transparent_bmp.width);
    try std.testing.expectEqual(opaque_bmp.height, transparent_bmp.height);

    var opaque_sum: u64 = 0;
    var transparent_sum: u64 = 0;
    var i: usize = 0;
    while (i < opaque_bmp.pixels.len) : (i += 4) {
        opaque_sum += @as(u64, opaque_bmp.pixels[i]) + @as(u64, opaque_bmp.pixels[i + 1]) + @as(u64, opaque_bmp.pixels[i + 2]);
        transparent_sum += @as(u64, transparent_bmp.pixels[i]) + @as(u64, transparent_bmp.pixels[i + 1]) + @as(u64, transparent_bmp.pixels[i + 2]);
    }
    try std.testing.expect(transparent_sum > opaque_sum);
}

test "render text with repeated characters uses cache" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var bitmap = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "lllll", .{ .pixel_size = 48 });
    defer bitmap.deinit();

    try std.testing.expect(bitmap.width > 0);
    try std.testing.expect(bitmap.height > 0);
}

test "render text with LCD rendering" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var bitmap = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .lcd_rendering = true,
    });
    defer bitmap.deinit();

    try std.testing.expect(bitmap.width > 0);
    try std.testing.expect(bitmap.height > 0);

    var has_colored = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        const r = bitmap.pixels[i];
        const g = bitmap.pixels[i + 1];
        const b = bitmap.pixels[i + 2];
        if (r != g or g != b) {
            has_colored = true;
            break;
        }
    }
    try std.testing.expect(has_colored);
}

pub const RowRenderer = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    row_buffer: []u8,
    glyph_cache: std.AutoHashMapUnmanaged(u32, CachedRaster),
    layout: shaper.TextLayout,
    scale: f32,
    base_baseline_y: f32,
    pad: f32,
    fg_color: rgba_bitmap_mod.Color,
    bg_color: rgba_bitmap_mod.Color,
    gamma_correction: bool,
    fractional_positioning: bool,

    pub fn init(allocator: std.mem.Allocator, fonts: []const font_mod.Font, text: []const u8, options: RenderOptions) !RowRenderer {
        const raster_options = resolveRasterOptions(options);

        var layout = try shaper.layoutText(allocator, fonts, text, .{
            .pixel_size = options.pixel_size,
            .max_width = options.max_width,
            .text_align = options.text_align,
        });
        errdefer layout.deinit();

        const scale = options.pixel_size / @as(f32, @floatFromInt(fonts[0].getUnitsPerEm()));
        const pad = @as(f32, @floatFromInt(options.padding));

        const bmp_width = @as(u32, @intFromFloat(@ceil(layout.total_width + pad * 2)));
        const bmp_height = @as(u32, @intFromFloat(@ceil(layout.total_height + pad * 2)));

        const width = if (bmp_width == 0) 1 else bmp_width;
        const height = if (bmp_height == 0) 1 else bmp_height;

        var glyph_cache: std.AutoHashMapUnmanaged(u32, CachedRaster) = .empty;
        errdefer {
            var it = glyph_cache.valueIterator();
            while (it.next()) |entry| {
                allocator.free(entry.pixels);
            }
            glyph_cache.deinit(allocator);
        }

        for (layout.positions) |pos| {
            const cache_key = glyphCacheKey(pos.font_index, pos.glyph_id);
            if (glyph_cache.get(cache_key) != null) continue;

            const glyph_font = fonts[pos.font_index];
            const glyph_scale = options.pixel_size / @as(f32, @floatFromInt(glyph_font.getUnitsPerEm()));

            const outline_opt = glyph_font.getGlyphOutline(allocator, pos.glyph_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (outline_opt == null) {
                const empty_pixels = try allocator.alloc(u8, 0);
                try glyph_cache.put(allocator, cache_key, .{
                    .pixels = empty_pixels,
                    .width = 0,
                    .height = 0,
                    .offset_x = 0,
                    .offset_y = 0,
                });
                continue;
            }
            var outline = outline_opt.?;
            defer outline.deinit();

            try applyOutlineHinting(allocator, &outline, glyph_font, pos.glyph_id, options);
            const glyph_result = try rasterizer_mod.rasterizeGlyph(allocator, outline, glyph_scale, options.padding, raster_options);
            try glyph_cache.put(allocator, cache_key, .{
                .pixels = glyph_result.pixels,
                .width = glyph_result.width,
                .height = glyph_result.height,
                .offset_x = glyph_result.offset_x,
                .offset_y = glyph_result.offset_y,
            });
        }

        const row_buffer = try allocator.alloc(u8, @as(usize, width) * 4);
        errdefer allocator.free(row_buffer);

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .row_buffer = row_buffer,
            .glyph_cache = glyph_cache,
            .layout = layout,
            .scale = scale,
            .base_baseline_y = pad + layout.ascender_px,
            .pad = pad,
            .fg_color = options.fg_color,
            .bg_color = options.bg_color,
            .gamma_correction = options.gamma_correction,
            .fractional_positioning = options.fractional_positioning,
        };
    }

    pub fn deinit(self: *RowRenderer) void {
        self.allocator.free(self.row_buffer);
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.pixels);
        }
        self.glyph_cache.deinit(self.allocator);
        self.layout.deinit();
    }

    pub fn renderRow(self: *RowRenderer, y: u32) []const u8 {
        const bg = self.bg_color;
        var x: usize = 0;
        while (x < self.width) : (x += 1) {
            const off = x * 4;
            self.row_buffer[off] = bg.r;
            self.row_buffer[off + 1] = bg.g;
            self.row_buffer[off + 2] = bg.b;
            self.row_buffer[off + 3] = bg.a;
        }

        const yf = @as(f32, @floatFromInt(y));

        for (self.layout.positions) |pos| {
            const cache_key = glyphCacheKey(pos.font_index, pos.glyph_id);
            const cached = self.glyph_cache.get(cache_key) orelse continue;
            if (cached.width == 0 or cached.height == 0) continue;

            const origin_x = pos.x_offset + self.pad;
            const origin_y = self.base_baseline_y + pos.y_offset;
            const bmp_y0 = origin_y - cached.offset_y;

            const glyph_y_f = yf - bmp_y0;
            const gy_f = @ceil(glyph_y_f);
            if (gy_f < 0 or gy_f >= @as(f32, @floatFromInt(cached.height))) continue;
            const gy = @as(u32, @intFromFloat(gy_f));

            const bmp_x0 = origin_x - cached.offset_x;

            for (0..cached.width) |gx| {
                const coverage = cached.pixels[gy * @as(usize, cached.width) + gx];
                if (coverage == 0) continue;

                const bmp_xf = bmp_x0 + @as(f32, @floatFromInt(gx));

                if (self.fractional_positioning) {
                    const ix = @as(i32, @intFromFloat(@floor(bmp_xf)));
                    const dx = bmp_xf - @as(f32, @floatFromInt(ix));
                    const cov_f = @as(f32, @floatFromInt(coverage));

                    const w0: u8 = @intFromFloat(@min(255.0, @round(cov_f * (1.0 - dx))));
                    const w1: u8 = @intFromFloat(@min(255.0, @round(cov_f * dx)));

                    if (w0 > 0 and ix >= 0 and @as(u32, @intCast(ix)) < self.width) {
                        const off0 = @as(usize, @intCast(ix)) * 4;
                        const fg = self.fg_color;
                        if (self.gamma_correction) {
                            const alpha_f = @as(f32, @floatFromInt(w0)) * @as(f32, @floatFromInt(fg.a)) / (255.0 * 255.0);
                            self.row_buffer[off0] = gamma_mod.blendLinear(self.row_buffer[off0], fg.r, alpha_f);
                            self.row_buffer[off0 + 1] = gamma_mod.blendLinear(self.row_buffer[off0 + 1], fg.g, alpha_f);
                            self.row_buffer[off0 + 2] = gamma_mod.blendLinear(self.row_buffer[off0 + 2], fg.b, alpha_f);
                            self.row_buffer[off0 + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.row_buffer[off0 + 3]) + @as(u16, @intFromFloat(@round(alpha_f * 255.0)))));
                        } else {
                            const alpha = @as(u16, w0) * @as(u16, fg.a) / 255;
                            const inv_alpha = 255 - alpha;
                            self.row_buffer[off0] = @intCast((@as(u16, self.row_buffer[off0]) * inv_alpha + @as(u16, fg.r) * alpha) / 255);
                            self.row_buffer[off0 + 1] = @intCast((@as(u16, self.row_buffer[off0 + 1]) * inv_alpha + @as(u16, fg.g) * alpha) / 255);
                            self.row_buffer[off0 + 2] = @intCast((@as(u16, self.row_buffer[off0 + 2]) * inv_alpha + @as(u16, fg.b) * alpha) / 255);
                            self.row_buffer[off0 + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.row_buffer[off0 + 3]) + alpha));
                        }
                    }
                    const ix1 = ix + 1;
                    if (w1 > 0 and ix1 >= 0 and @as(u32, @intCast(ix1)) < self.width) {
                        const off1 = @as(usize, @intCast(ix1)) * 4;
                        const fg = self.fg_color;
                        if (self.gamma_correction) {
                            const alpha_f = @as(f32, @floatFromInt(w1)) * @as(f32, @floatFromInt(fg.a)) / (255.0 * 255.0);
                            self.row_buffer[off1] = gamma_mod.blendLinear(self.row_buffer[off1], fg.r, alpha_f);
                            self.row_buffer[off1 + 1] = gamma_mod.blendLinear(self.row_buffer[off1 + 1], fg.g, alpha_f);
                            self.row_buffer[off1 + 2] = gamma_mod.blendLinear(self.row_buffer[off1 + 2], fg.b, alpha_f);
                            self.row_buffer[off1 + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.row_buffer[off1 + 3]) + @as(u16, @intFromFloat(@round(alpha_f * 255.0)))));
                        } else {
                            const alpha = @as(u16, w1) * @as(u16, fg.a) / 255;
                            const inv_alpha = 255 - alpha;
                            self.row_buffer[off1] = @intCast((@as(u16, self.row_buffer[off1]) * inv_alpha + @as(u16, fg.r) * alpha) / 255);
                            self.row_buffer[off1 + 1] = @intCast((@as(u16, self.row_buffer[off1 + 1]) * inv_alpha + @as(u16, fg.g) * alpha) / 255);
                            self.row_buffer[off1 + 2] = @intCast((@as(u16, self.row_buffer[off1 + 2]) * inv_alpha + @as(u16, fg.b) * alpha) / 255);
                            self.row_buffer[off1 + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.row_buffer[off1 + 3]) + alpha));
                        }
                    }
                } else {
                    if (bmp_xf < 0) continue;
                    const bmp_xi = @as(u32, @intFromFloat(bmp_xf));
                    if (bmp_xi >= self.width) continue;

                    const off = @as(usize, bmp_xi) * 4;
                    const fg = self.fg_color;
                    if (self.gamma_correction) {
                        const alpha_f = @as(f32, @floatFromInt(coverage)) * @as(f32, @floatFromInt(fg.a)) / (255.0 * 255.0);
                        self.row_buffer[off] = gamma_mod.blendLinear(self.row_buffer[off], fg.r, alpha_f);
                        self.row_buffer[off + 1] = gamma_mod.blendLinear(self.row_buffer[off + 1], fg.g, alpha_f);
                        self.row_buffer[off + 2] = gamma_mod.blendLinear(self.row_buffer[off + 2], fg.b, alpha_f);
                        self.row_buffer[off + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.row_buffer[off + 3]) + @as(u16, @intFromFloat(@round(alpha_f * 255.0)))));
                    } else {
                        const alpha = @as(u16, coverage) * @as(u16, fg.a) / 255;
                        const inv_alpha = 255 - alpha;
                        self.row_buffer[off] = @intCast((@as(u16, self.row_buffer[off]) * inv_alpha + @as(u16, fg.r) * alpha) / 255);
                        self.row_buffer[off + 1] = @intCast((@as(u16, self.row_buffer[off + 1]) * inv_alpha + @as(u16, fg.g) * alpha) / 255);
                        self.row_buffer[off + 2] = @intCast((@as(u16, self.row_buffer[off + 2]) * inv_alpha + @as(u16, fg.b) * alpha) / 255);
                        self.row_buffer[off + 3] = @intCast(@min(@as(u16, 255), @as(u16, self.row_buffer[off + 3]) + alpha));
                    }
                }
            }
        }

        return self.row_buffer[0 .. @as(usize, self.width) * 4];
    }
};

test "RowRenderer produces same output as renderText" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const options = RenderOptions{ .pixel_size = 32 };

    var bitmap = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "Hello", options);
    defer bitmap.deinit();

    var row_renderer = try RowRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hello", options);
    defer row_renderer.deinit();

    try std.testing.expectEqual(bitmap.width, row_renderer.width);
    try std.testing.expectEqual(bitmap.height, row_renderer.height);

    for (0..bitmap.height) |y| {
        const row_data = row_renderer.renderRow(@intCast(y));
        const bitmap_offset = y * @as(usize, bitmap.width) * 4;
        const bitmap_row = bitmap.pixels[bitmap_offset .. bitmap_offset + @as(usize, bitmap.width) * 4];
        try std.testing.expectEqualSlices(u8, bitmap_row, row_data);
    }
}

test "render text with fractional positioning" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var bitmap = try renderText(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .fractional_positioning = true,
    });
    defer bitmap.deinit();

    try std.testing.expect(bitmap.width > 0);
    try std.testing.expect(bitmap.height > 0);

    var has_dark = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        if (bitmap.pixels[i] < 200) {
            has_dark = true;
            break;
        }
    }
    try std.testing.expect(has_dark);
}
