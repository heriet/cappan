const std = @import("std");
const font_mod = @import("../font/font.zig");
const shaper = @import("../layout/shaper.zig");
const rasterizer_mod = @import("../raster/rasterizer.zig");
const scanline_mod = @import("../raster/scanline.zig");
const stem_darkening_mod = @import("../raster/stem_darkening.zig");
const rgba_bitmap_mod = @import("rgba_bitmap.zig");
const easing_mod = @import("easing.zig");
const renderer_mod = @import("renderer.zig");
const glyphCacheKey = renderer_mod.glyphCacheKey;
const glyph_reveal_mod = @import("glyph_reveal.zig");
const paint_mod = @import("paint.zig");

pub const RgbaBitmap = rgba_bitmap_mod.RgbaBitmap;
pub const Color = rgba_bitmap_mod.Color;
pub const SweepDirection = glyph_reveal_mod.SweepDirection;
pub const SweepOptions = glyph_reveal_mod.SweepOptions;
pub const ContourTraceOptions = glyph_reveal_mod.ContourTraceOptions;
pub const ContourOrdering = glyph_reveal_mod.ContourOrdering;
pub const MedialAxisOptions = glyph_reveal_mod.MedialAxisOptions;
pub const DistanceFieldOptions = glyph_reveal_mod.DistanceFieldOptions;
pub const ExtremaWaveOptions = glyph_reveal_mod.ExtremaWaveOptions;
pub const SkeletonGrowOptions = glyph_reveal_mod.SkeletonGrowOptions;
pub const TangentFlowOptions = glyph_reveal_mod.TangentFlowOptions;
pub const Easing = easing_mod.Easing;

pub const GlyphInfo = glyph_reveal_mod.GlyphInfo;
pub const CustomReveal = glyph_reveal_mod.CustomReveal;
pub const RevealStrategy = glyph_reveal_mod.RevealStrategy;

pub const Timing = union(enum) {
    simultaneous,
    sequential,
    weighted,
    overlap: f32,
};

const CachedGlyph = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
    reveal_context: ?glyph_reveal_mod.GlyphRevealContext,
    complexity: f32,
};

fn paintGlyphCacheKey(font_index: u8, glyph_id: u16, paint_op_index: u16) u64 {
    return (@as(u64, font_index) << 32) | (@as(u64, glyph_id) << 16) | @as(u64, paint_op_index);
}

pub const PaintLayerTiming = enum {
    simultaneous,
    sequential,
};

pub const Options = struct {
    pixel_size: f32 = 48.0,
    padding: u32 = 4,
    fg_color: Color = Color.black,
    bg_color: Color = Color.white,
    gamma_correction: bool = false,
    fractional_positioning: bool = false,
    strategy: RevealStrategy = .{ .sweep = .{} },
    timing: Timing = .sequential,
    easing: Easing = .linear,
    max_width: ?f32 = null,
    text_align: shaper.TextAlign = .left,
    paint_stack: ?[]const paint_mod.PaintOperation = null,
    paint_layer_timing: PaintLayerTiming = .simultaneous,
    raster_options: scanline_mod.RasterOptions = .{},
    stem_darkening: bool = false,
};

pub const IncrementalRenderer = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    layout: shaper.TextLayout,
    strategy: RevealStrategy,
    timing: Timing,
    easing: Easing,
    glyph_cache: std.AutoHashMapUnmanaged(u32, CachedGlyph),
    paint_glyph_cache: std.AutoHashMapUnmanaged(u64, CachedGlyph),
    scale: f32,
    base_baseline_y: f32,
    pad: f32,
    fg_color: Color,
    bg_color: Color,
    gamma_correction: bool,
    fractional_positioning: bool,
    temp_coverage: []u8,
    weight_cumsum: []f32,
    paint_stack: ?[]paint_mod.PaintOperation,
    paint_layer_timing: PaintLayerTiming,
    paint_layer_cumsum: []f32,
    pixel_size: f32,
    raster_options: scanline_mod.RasterOptions,

    pub fn init(
        allocator: std.mem.Allocator,
        fonts: []const font_mod.Font,
        text: []const u8,
        options: Options,
    ) !IncrementalRenderer {
        const raster_options = if (options.stem_darkening)
            stem_darkening_mod.resolveRasterOptions(options.pixel_size, options.raster_options)
        else
            options.raster_options;

        var layout = try shaper.layoutText(allocator, fonts, text, .{
            .pixel_size = options.pixel_size,
            .max_width = options.max_width,
            .text_align = options.text_align,
        });
        errdefer layout.deinit();

        const scale = options.pixel_size / @as(f32, @floatFromInt(fonts[0].getUnitsPerEm()));

        var max_stroke_expansion: f32 = 0.0;
        const max_expansion_limit: f32 = 4096.0;
        if (options.paint_stack) |ps| {
            for (ps) |op| {
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
        }
        const extended_padding = options.padding +| @as(u32, @intFromFloat(@ceil(max_stroke_expansion)));
        const pad = @as(f32, @floatFromInt(extended_padding));

        const max_bmp_dim: f32 = 16384.0;
        const bmp_width_f = @ceil(layout.total_width + pad * 2);
        const bmp_height_f = @ceil(layout.total_height + pad * 2);
        const bmp_width: u32 = if (!(bmp_width_f >= 0.0 and bmp_width_f <= max_bmp_dim)) return error.OutOfMemory else @intFromFloat(bmp_width_f);
        const bmp_height: u32 = if (!(bmp_height_f >= 0.0 and bmp_height_f <= max_bmp_dim)) return error.OutOfMemory else @intFromFloat(bmp_height_f);

        const width = if (bmp_width == 0) 1 else bmp_width;
        const height = if (bmp_height == 0) 1 else bmp_height;

        var glyph_cache: std.AutoHashMapUnmanaged(u32, CachedGlyph) = .empty;
        errdefer {
            var it = glyph_cache.valueIterator();
            while (it.next()) |entry| {
                allocator.free(entry.pixels);
                if (entry.reveal_context) |*ctx| {
                    ctx.deinit();
                }
            }
            glyph_cache.deinit(allocator);
        }

        var paint_glyph_cache: std.AutoHashMapUnmanaged(u64, CachedGlyph) = .empty;
        errdefer {
            var it = paint_glyph_cache.valueIterator();
            while (it.next()) |entry| {
                allocator.free(entry.pixels);
                if (entry.reveal_context) |*ctx| {
                    ctx.deinit();
                }
            }
            paint_glyph_cache.deinit(allocator);
        }

        var max_glyph_pixels: usize = 0;

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
                    .reveal_context = null,
                    .complexity = 1.0,
                });
                continue;
            }
            var outline = outline_opt.?;
            defer outline.deinit();

            const info = GlyphInfo{
                .glyph_id = pos.glyph_id,
                .x_min = @as(f32, @floatFromInt(outline.x_min)) * glyph_scale,
                .y_min = @as(f32, @floatFromInt(outline.y_min)) * glyph_scale,
                .x_max = @as(f32, @floatFromInt(outline.x_max)) * glyph_scale,
                .y_max = @as(f32, @floatFromInt(outline.y_max)) * glyph_scale,
                .num_contours = @intCast(outline.contours.len),
            };

            const fill_padding = if (options.paint_stack != null) extended_padding else options.padding;
            const glyph_result = try rasterizer_mod.rasterizeGlyph(allocator, outline, glyph_scale, fill_padding, raster_options);
            const pixel_count = @as(usize, glyph_result.width) * @as(usize, glyph_result.height);
            if (pixel_count > max_glyph_pixels) max_glyph_pixels = pixel_count;

            var glyph_strategy = options.strategy;
            switch (glyph_strategy) {
                .custom => |*c| {
                    c.deinitFn = null;
                },
                else => {},
            }

            var reveal_ctx = try glyph_reveal_mod.GlyphRevealContext.initFromOutline(
                allocator,
                glyph_strategy,
                info,
                glyph_result.pixels,
                glyph_result.width,
                glyph_result.height,
                outline,
                glyph_scale,
                glyph_result.offset_x,
                glyph_result.offset_y,
                raster_options,
            );
            var reveal_ctx_owned = true;
            errdefer if (reveal_ctx_owned) reveal_ctx.deinit();

            var total_points: usize = 0;
            for (outline.contours) |contour| {
                total_points += contour.points.len;
            }
            const complexity = @max(1.0, @as(f32, @floatFromInt(total_points)));

            if (options.paint_stack) |ps| {
                reveal_ctx.deinit();
                reveal_ctx_owned = false;
                try glyph_cache.put(allocator, cache_key, .{
                    .pixels = glyph_result.pixels,
                    .width = glyph_result.width,
                    .height = glyph_result.height,
                    .offset_x = glyph_result.offset_x,
                    .offset_y = glyph_result.offset_y,
                    .reveal_context = null,
                    .complexity = complexity,
                });

                for (ps, 0..) |op, op_idx| {
                    const paint_key = paintGlyphCacheKey(pos.font_index, pos.glyph_id, @intCast(op_idx));
                    if (paint_glyph_cache.get(paint_key) != null) continue;

                    const paint_entry = switch (op) {
                        .fill => blk: {
                            const dup_pixels = try allocator.dupe(u8, glyph_result.pixels);
                            errdefer allocator.free(dup_pixels);
                            var fill_strategy = options.strategy;
                            switch (fill_strategy) {
                                .custom => |*c| {
                                    c.deinitFn = null;
                                },
                                else => {},
                            }
                            var fill_reveal = try glyph_reveal_mod.GlyphRevealContext.initFromOutline(
                                allocator,
                                fill_strategy,
                                info,
                                dup_pixels,
                                glyph_result.width,
                                glyph_result.height,
                                outline,
                                glyph_scale,
                                glyph_result.offset_x,
                                glyph_result.offset_y,
                                raster_options,
                            );
                            errdefer fill_reveal.deinit();
                            const pc = @as(usize, glyph_result.width) * @as(usize, glyph_result.height);
                            if (pc > max_glyph_pixels) max_glyph_pixels = pc;
                            break :blk CachedGlyph{
                                .pixels = dup_pixels,
                                .width = glyph_result.width,
                                .height = glyph_result.height,
                                .offset_x = glyph_result.offset_x,
                                .offset_y = glyph_result.offset_y,
                                .reveal_context = fill_reveal,
                                .complexity = complexity,
                            };
                        },
                        .stroke => |stroke| blk: {
                            const stroke_result = try renderer_mod.rasterizeStrokeGlyph(
                                allocator,
                                outline,
                                glyph_scale,
                                extended_padding,
                                stroke,
                                options.pixel_size,
                                raster_options,
                            );
                            errdefer allocator.free(stroke_result.pixels);
                            var stroke_strategy = options.strategy;
                            switch (stroke_strategy) {
                                .custom => |*c| {
                                    c.deinitFn = null;
                                },
                                else => {},
                            }
                            var stroke_reveal = try glyph_reveal_mod.GlyphRevealContext.initFromOutline(
                                allocator,
                                stroke_strategy,
                                info,
                                stroke_result.pixels,
                                stroke_result.width,
                                stroke_result.height,
                                outline,
                                glyph_scale,
                                stroke_result.offset_x,
                                stroke_result.offset_y,
                                raster_options,
                            );
                            errdefer stroke_reveal.deinit();
                            const pc = @as(usize, stroke_result.width) * @as(usize, stroke_result.height);
                            if (pc > max_glyph_pixels) max_glyph_pixels = pc;
                            break :blk CachedGlyph{
                                .pixels = stroke_result.pixels,
                                .width = stroke_result.width,
                                .height = stroke_result.height,
                                .offset_x = stroke_result.offset_x,
                                .offset_y = stroke_result.offset_y,
                                .reveal_context = stroke_reveal,
                                .complexity = complexity,
                            };
                        },
                    };
                    errdefer {
                        allocator.free(paint_entry.pixels);
                        if (paint_entry.reveal_context) |*ctx| {
                            var c = ctx.*;
                            c.deinit();
                        }
                    }
                    try paint_glyph_cache.put(allocator, paint_key, paint_entry);
                }
            } else {
                try glyph_cache.put(allocator, cache_key, .{
                    .pixels = glyph_result.pixels,
                    .width = glyph_result.width,
                    .height = glyph_result.height,
                    .offset_x = glyph_result.offset_x,
                    .offset_y = glyph_result.offset_y,
                    .reveal_context = reveal_ctx,
                    .complexity = complexity,
                });
            }
        }

        const temp_coverage = try allocator.alloc(u8, max_glyph_pixels);
        errdefer allocator.free(temp_coverage);

        const weight_cumsum: []f32 = if (options.timing == .weighted) blk: {
            const cumsum = try allocator.alloc(f32, layout.positions.len + 1);
            errdefer allocator.free(cumsum);

            var total_weight: f32 = 0;
            for (layout.positions) |pos| {
                const cache_key = glyphCacheKey(pos.font_index, pos.glyph_id);
                const cached = glyph_cache.get(cache_key) orelse continue;
                total_weight += cached.complexity;
            }
            if (total_weight == 0) total_weight = 1.0;

            cumsum[0] = 0.0;
            for (layout.positions, 0..) |pos, i| {
                const cache_key = glyphCacheKey(pos.font_index, pos.glyph_id);
                const cached = glyph_cache.get(cache_key) orelse {
                    cumsum[i + 1] = cumsum[i];
                    continue;
                };
                cumsum[i + 1] = cumsum[i] + cached.complexity / total_weight;
            }
            if (layout.positions.len > 0) {
                cumsum[layout.positions.len] = 1.0;
            }
            break :blk cumsum;
        } else try allocator.alloc(f32, 0);
        errdefer allocator.free(weight_cumsum);

        const owned_paint_stack: ?[]paint_mod.PaintOperation = if (options.paint_stack) |ps| blk: {
            const copy = try allocator.dupe(paint_mod.PaintOperation, ps);
            break :blk copy;
        } else null;
        errdefer if (owned_paint_stack) |ps| allocator.free(ps);

        const paint_layer_cumsum: []f32 = if (owned_paint_stack) |ps| blk: {
            const cumsum = try allocator.alloc(f32, ps.len + 1);
            errdefer allocator.free(cumsum);
            var total_weight: f32 = 0;
            for (ps) |op| {
                total_weight += op.timeWeight();
            }
            if (total_weight <= 0) total_weight = 1.0;
            cumsum[0] = 0.0;
            for (ps, 0..) |op, i| {
                cumsum[i + 1] = cumsum[i] + op.timeWeight() / total_weight;
            }
            if (ps.len > 0) {
                cumsum[ps.len] = 1.0;
            }
            break :blk cumsum;
        } else try allocator.alloc(f32, 0);
        errdefer allocator.free(paint_layer_cumsum);

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .layout = layout,
            .strategy = options.strategy,
            .timing = options.timing,
            .easing = options.easing,
            .glyph_cache = glyph_cache,
            .paint_glyph_cache = paint_glyph_cache,
            .scale = scale,
            .base_baseline_y = pad + layout.ascender_px,
            .pad = pad,
            .fg_color = options.fg_color,
            .bg_color = options.bg_color,
            .gamma_correction = options.gamma_correction,
            .fractional_positioning = options.fractional_positioning,
            .temp_coverage = temp_coverage,
            .weight_cumsum = weight_cumsum,
            .paint_stack = owned_paint_stack,
            .paint_layer_timing = options.paint_layer_timing,
            .paint_layer_cumsum = paint_layer_cumsum,
            .pixel_size = options.pixel_size,
            .raster_options = raster_options,
        };
    }

    pub fn deinit(self: *IncrementalRenderer) void {
        self.allocator.free(self.temp_coverage);
        self.allocator.free(self.weight_cumsum);
        self.allocator.free(self.paint_layer_cumsum);
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.pixels);
            if (entry.reveal_context) |*ctx| {
                ctx.deinit();
            }
        }
        self.glyph_cache.deinit(self.allocator);
        var pit = self.paint_glyph_cache.valueIterator();
        while (pit.next()) |entry| {
            self.allocator.free(entry.pixels);
            if (entry.reveal_context) |*ctx| {
                ctx.deinit();
            }
        }
        self.paint_glyph_cache.deinit(self.allocator);
        if (self.paint_stack) |ps| {
            self.allocator.free(ps);
        }
        self.layout.deinit();
        switch (self.strategy) {
            .custom => |c| {
                if (c.deinitFn) |deinit_fn| {
                    deinit_fn(c.context);
                }
            },
            else => {},
        }
    }

    fn glyphProgress(self: *const IncrementalRenderer, glyph_index: usize, overall_progress: f32) f32 {
        const n = self.layout.positions.len;
        if (n == 0) return 0.0;
        if (overall_progress >= 1.0) return 1.0;
        if (overall_progress <= 0.0) return 0.0;

        return switch (self.timing) {
            .simultaneous => overall_progress,
            .sequential => blk: {
                const nf = @as(f32, @floatFromInt(n));
                const d = 1.0 / nf;
                const start = @as(f32, @floatFromInt(glyph_index)) * d;
                break :blk std.math.clamp((overall_progress - start) / d, 0.0, 1.0);
            },
            .weighted => blk: {
                const start = self.weight_cumsum[glyph_index];
                const end = self.weight_cumsum[glyph_index + 1];
                const duration = end - start;
                if (duration <= 0) break :blk if (overall_progress >= end) @as(f32, 1.0) else @as(f32, 0.0);
                break :blk std.math.clamp((overall_progress - start) / duration, 0.0, 1.0);
            },
            .overlap => |o| blk: {
                const nf = @as(f32, @floatFromInt(n));
                const oc = std.math.clamp(o, 0.0, 1.0);
                const d = 1.0 / ((nf - 1.0) * (1.0 - oc) + 1.0);
                const stride = d * (1.0 - oc);
                const start = @as(f32, @floatFromInt(glyph_index)) * stride;
                break :blk std.math.clamp((overall_progress - start) / d, 0.0, 1.0);
            },
        };
    }

    fn applyStrategy(self: *IncrementalRenderer, cached: CachedGlyph, glyph_prog: f32) ![]const u8 {
        const pixel_count = @as(usize, cached.width) * @as(usize, cached.height);
        if (pixel_count == 0) return cached.pixels[0..0];

        const output = self.temp_coverage[0..pixel_count];
        if (cached.reveal_context) |ctx| {
            try ctx.apply(cached.pixels[0..pixel_count], output, cached.width, cached.height, glyph_prog);
        } else {
            @memset(output, 0);
        }
        return output;
    }

    fn blendCoverageToTarget(
        self: *IncrementalRenderer,
        target: *RgbaBitmap,
        cached: CachedGlyph,
        coverage: []const u8,
        pos: shaper.GlyphPosition,
        color: Color,
    ) void {
        const origin_x = pos.x_offset + self.pad;
        const origin_y = self.base_baseline_y + pos.y_offset;
        const bmp_x0 = origin_x - cached.offset_x;
        const bmp_y0 = origin_y - cached.offset_y;

        for (0..cached.height) |gy| {
            for (0..cached.width) |gx| {
                const cov = coverage[gy * @as(usize, cached.width) + gx];
                if (cov == 0) continue;

                const bmp_xf = bmp_x0 + @as(f32, @floatFromInt(gx));
                const bmp_yf = bmp_y0 + @as(f32, @floatFromInt(gy));

                if (self.fractional_positioning) {
                    const ix = @as(i32, @intFromFloat(@floor(bmp_xf)));
                    const iy = @as(i32, @intFromFloat(@floor(bmp_yf)));
                    const dx = bmp_xf - @as(f32, @floatFromInt(ix));
                    const dy = bmp_yf - @as(f32, @floatFromInt(iy));
                    const cov_f = @as(f32, @floatFromInt(cov));

                    const pairs = [_]struct { x: i32, y: i32, w: f32 }{
                        .{ .x = ix, .y = iy, .w = (1.0 - dx) * (1.0 - dy) },
                        .{ .x = ix + 1, .y = iy, .w = dx * (1.0 - dy) },
                        .{ .x = ix, .y = iy + 1, .w = (1.0 - dx) * dy },
                        .{ .x = ix + 1, .y = iy + 1, .w = dx * dy },
                    };
                    for (pairs) |pair| {
                        if (pair.x < 0 or pair.y < 0) continue;
                        const ux = @as(u32, @intCast(pair.x));
                        const uy = @as(u32, @intCast(pair.y));
                        if (ux >= self.width or uy >= self.height) continue;
                        const weighted: u8 = @intFromFloat(@min(255.0, @round(cov_f * pair.w)));
                        if (weighted == 0) continue;
                        if (self.gamma_correction) {
                            target.blendPixelLinear(ux, uy, weighted, color);
                        } else {
                            target.blendPixel(ux, uy, weighted, color);
                        }
                    }
                } else {
                    if (bmp_xf < 0 or bmp_yf < 0) continue;

                    const bmp_xi = @as(u32, @intFromFloat(bmp_xf));
                    const bmp_yi = @as(u32, @intFromFloat(bmp_yf));
                    if (bmp_xi >= self.width or bmp_yi >= self.height) continue;

                    if (self.gamma_correction) {
                        target.blendPixelLinear(bmp_xi, bmp_yi, cov, color);
                    } else {
                        target.blendPixel(bmp_xi, bmp_yi, cov, color);
                    }
                }
            }
        }
    }

    pub fn renderFrame(self: *IncrementalRenderer, progress: f32) !RgbaBitmap {
        const p = std.math.clamp(progress, 0.0, 1.0);

        var bitmap = try RgbaBitmap.init(self.allocator, self.width, self.height, self.bg_color);
        errdefer bitmap.deinit();

        if (self.paint_stack) |paint_stack| {
            for (paint_stack, 0..) |op, op_idx| {
                const opacity = switch (op) {
                    .fill => |fill| fill.opacity,
                    .stroke => |stroke| stroke.opacity,
                };
                const needs_temp = opacity < 0.996;

                var temp_bmp: ?RgbaBitmap = if (needs_temp)
                    try RgbaBitmap.init(self.allocator, self.width, self.height, rgba_bitmap_mod.Color.transparent)
                else
                    null;
                defer if (temp_bmp) |*tb| tb.deinit();

                const target = if (temp_bmp) |*tb| tb else &bitmap;
                const blend_color: Color = switch (op) {
                    .fill => |fill| if (needs_temp) fill.color else renderer_mod.applyOpacity(fill.color, fill.opacity),
                    .stroke => |stroke| if (needs_temp) stroke.color else renderer_mod.applyOpacity(stroke.color, stroke.opacity),
                };

                for (self.layout.positions, 0..) |pos, i| {
                    const gp = easing_mod.apply(self.easing, self.glyphProgress(i, p));
                    if (gp <= 0.0) continue;

                    const layer_gp = switch (self.paint_layer_timing) {
                        .simultaneous => gp,
                        .sequential => blk: {
                            const start = self.paint_layer_cumsum[op_idx];
                            const end = self.paint_layer_cumsum[op_idx + 1];
                            const duration = end - start;
                            if (duration <= 0) break :blk if (gp >= end) @as(f32, 1.0) else @as(f32, 0.0);
                            break :blk std.math.clamp((gp - start) / duration, 0.0, 1.0);
                        },
                    };
                    if (layer_gp <= 0.0) continue;

                    const paint_key = paintGlyphCacheKey(pos.font_index, pos.glyph_id, @intCast(op_idx));
                    const cached = self.paint_glyph_cache.get(paint_key) orelse continue;
                    if (cached.width == 0 or cached.height == 0) continue;

                    const coverage: []const u8 = if (layer_gp >= 1.0)
                        cached.pixels[0 .. @as(usize, cached.width) * @as(usize, cached.height)]
                    else
                        try self.applyStrategy(cached, layer_gp);

                    self.blendCoverageToTarget(target, cached, coverage, pos, blend_color);
                }

                if (temp_bmp) |tb| {
                    renderer_mod.compositeWithOpacity(&bitmap, tb, opacity);
                }
            }
        } else {
            for (self.layout.positions, 0..) |pos, i| {
                const gp = easing_mod.apply(self.easing, self.glyphProgress(i, p));
                if (gp <= 0.0) continue;

                const cache_key = glyphCacheKey(pos.font_index, pos.glyph_id);
                const cached = self.glyph_cache.get(cache_key) orelse continue;
                if (cached.width == 0 or cached.height == 0) continue;

                const coverage: []const u8 = if (gp >= 1.0)
                    cached.pixels[0 .. @as(usize, cached.width) * @as(usize, cached.height)]
                else
                    try self.applyStrategy(cached, gp);

                self.blendCoverageToTarget(&bitmap, cached, coverage, pos, self.fg_color);
            }
        }

        return bitmap;
    }

    pub fn renderFrameByIndex(self: *IncrementalRenderer, frame: u32, total_frames: u32) !RgbaBitmap {
        const p: f32 = if (total_frames <= 1)
            1.0
        else
            @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(total_frames - 1));
        return self.renderFrame(p);
    }
};

test "renderFrame progress=1.0 matches renderText" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const pixel_size: f32 = 32;
    const text = "Hi";

    var expected = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{font}, text, .{ .pixel_size = pixel_size });
    defer expected.deinit();

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, text, .{
        .pixel_size = pixel_size,
        .strategy = .{ .sweep = .{} },
        .timing = .simultaneous,
    });
    defer inc.deinit();

    var actual = try inc.renderFrame(1.0);
    defer actual.deinit();

    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
    try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
}

test "renderFrame progress=0.0 is all background" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .bg_color = Color.white,
    });
    defer inc.deinit();

    var bitmap = try inc.renderFrame(0.0);
    defer bitmap.deinit();

    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 255), bitmap.pixels[i + 0]);
        try std.testing.expectEqual(@as(u8, 255), bitmap.pixels[i + 1]);
        try std.testing.expectEqual(@as(u8, 255), bitmap.pixels[i + 2]);
        try std.testing.expectEqual(@as(u8, 255), bitmap.pixels[i + 3]);
    }
}

test "sweep strategy shows partial content" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 48,
        .strategy = .{ .sweep = .{ .direction = .left_to_right } },
        .timing = .simultaneous,
    });
    defer inc.deinit();

    var bitmap = try inc.renderFrame(0.5);
    defer bitmap.deinit();

    var has_non_bg = false;
    var has_bg = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        const is_white = bitmap.pixels[i] == 255 and bitmap.pixels[i + 1] == 255 and
            bitmap.pixels[i + 2] == 255 and bitmap.pixels[i + 3] == 255;
        if (is_white) {
            has_bg = true;
        } else {
            has_non_bg = true;
        }
    }
    try std.testing.expect(has_non_bg);
    try std.testing.expect(has_bg);
}

test "fade strategy shows partial content" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 48,
        .strategy = .fade,
        .timing = .simultaneous,
    });
    defer inc.deinit();

    var bitmap = try inc.renderFrame(0.5);
    defer bitmap.deinit();

    var has_non_bg = false;
    var has_bg = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        const is_white = bitmap.pixels[i] == 255 and bitmap.pixels[i + 1] == 255 and
            bitmap.pixels[i + 2] == 255 and bitmap.pixels[i + 3] == 255;
        if (is_white) {
            has_bg = true;
        } else {
            has_non_bg = true;
        }
    }
    try std.testing.expect(has_non_bg);
    try std.testing.expect(has_bg);
}

test "sequential timing reveals glyphs in order" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "AB", .{
        .pixel_size = 48,
        .strategy = .{ .sweep = .{} },
        .timing = .sequential,
    });
    defer inc.deinit();

    var bitmap_partial = try inc.renderFrame(0.25);
    defer bitmap_partial.deinit();

    var bitmap_full = try inc.renderFrame(1.0);
    defer bitmap_full.deinit();

    var partial_non_bg: usize = 0;
    var full_non_bg: usize = 0;
    var i: usize = 0;
    while (i < bitmap_partial.pixels.len) : (i += 4) {
        const partial_white = bitmap_partial.pixels[i] == 255 and bitmap_partial.pixels[i + 1] == 255 and
            bitmap_partial.pixels[i + 2] == 255 and bitmap_partial.pixels[i + 3] == 255;
        const full_white = bitmap_full.pixels[i] == 255 and bitmap_full.pixels[i + 1] == 255 and
            bitmap_full.pixels[i + 2] == 255 and bitmap_full.pixels[i + 3] == 255;
        if (!partial_white) partial_non_bg += 1;
        if (!full_white) full_non_bg += 1;
    }
    try std.testing.expect(partial_non_bg > 0);
    try std.testing.expect(full_non_bg > partial_non_bg);
}

test "renderFrameByIndex" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const total_frames: u32 = 5;

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .bg_color = Color.white,
        .timing = .simultaneous,
    });
    defer inc.deinit();

    var frame0 = try inc.renderFrameByIndex(0, total_frames);
    defer frame0.deinit();
    var i: usize = 0;
    while (i < frame0.pixels.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 255), frame0.pixels[i + 0]);
        try std.testing.expectEqual(@as(u8, 255), frame0.pixels[i + 1]);
        try std.testing.expectEqual(@as(u8, 255), frame0.pixels[i + 2]);
        try std.testing.expectEqual(@as(u8, 255), frame0.pixels[i + 3]);
    }

    var frame_last = try inc.renderFrameByIndex(total_frames - 1, total_frames);
    defer frame_last.deinit();

    var frame_full = try inc.renderFrame(1.0);
    defer frame_full.deinit();

    try std.testing.expectEqualSlices(u8, frame_full.pixels, frame_last.pixels);
}

test "contour_trace progress=1.0 matches renderText" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const pixel_size: f32 = 32;
    const text = "Hi";

    var expected = try renderer_mod.renderText(std.testing.allocator, &[_]font_mod.Font{font}, text, .{ .pixel_size = pixel_size });
    defer expected.deinit();

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, text, .{
        .pixel_size = pixel_size,
        .strategy = .{ .contour_trace = .{} },
        .timing = .simultaneous,
    });
    defer inc.deinit();

    var actual = try inc.renderFrame(1.0);
    defer actual.deinit();

    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
    try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
}

test "contour_trace progress=0.0 is all background" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .bg_color = Color.white,
        .strategy = .{ .contour_trace = .{} },
    });
    defer inc.deinit();

    var bitmap = try inc.renderFrame(0.0);
    defer bitmap.deinit();

    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 255), bitmap.pixels[i + 0]);
        try std.testing.expectEqual(@as(u8, 255), bitmap.pixels[i + 1]);
        try std.testing.expectEqual(@as(u8, 255), bitmap.pixels[i + 2]);
        try std.testing.expectEqual(@as(u8, 255), bitmap.pixels[i + 3]);
    }
}

test "contour_trace shows partial content" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    var inc = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 48,
        .strategy = .{ .contour_trace = .{} },
        .timing = .simultaneous,
    });
    defer inc.deinit();

    var bitmap = try inc.renderFrame(0.5);
    defer bitmap.deinit();

    var has_non_bg = false;
    var has_bg = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        const is_white = bitmap.pixels[i] == 255 and bitmap.pixels[i + 1] == 255 and
            bitmap.pixels[i + 2] == 255 and bitmap.pixels[i + 3] == 255;
        if (is_white) {
            has_bg = true;
        } else {
            has_non_bg = true;
        }
    }
    try std.testing.expect(has_non_bg);
    try std.testing.expect(has_bg);
}

test "custom strategy" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const CustomCtx = struct {
        fn reveal(
            _: *anyopaque,
            full_coverage: []const u8,
            output: []u8,
            _: u32,
            _: u32,
            _: GlyphInfo,
            _: f32,
        ) void {
            @memcpy(output, full_coverage);
        }
    };

    var dummy: u8 = 0;

    var inc_custom = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .strategy = .{ .custom = .{
            .context = &dummy,
            .revealFn = CustomCtx.reveal,
            .deinitFn = null,
        } },
        .timing = .simultaneous,
    });
    defer inc_custom.deinit();

    var bitmap_custom = try inc_custom.renderFrame(0.5);
    defer bitmap_custom.deinit();

    var inc_full = try IncrementalRenderer.init(std.testing.allocator, &[_]font_mod.Font{font}, "Hi", .{
        .pixel_size = 32,
        .strategy = .{ .sweep = .{} },
        .timing = .simultaneous,
    });
    defer inc_full.deinit();

    var bitmap_full = try inc_full.renderFrame(1.0);
    defer bitmap_full.deinit();

    try std.testing.expectEqualSlices(u8, bitmap_full.pixels, bitmap_custom.pixels);
}
