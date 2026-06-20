const std = @import("std");
const font_mod = @import("../font/font.zig");
const shaper = @import("../layout/shaper.zig");
const rasterizer_mod = @import("../raster/rasterizer.zig");
const rgba_bitmap_mod = @import("rgba_bitmap.zig");
const easing_mod = @import("easing.zig");
const glyphCacheKey = @import("renderer.zig").glyphCacheKey;
const glyph_reveal_mod = @import("glyph_reveal.zig");

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
    scale: f32,
    base_baseline_y: f32,
    pad: f32,
    fg_color: Color,
    bg_color: Color,
    gamma_correction: bool,
    fractional_positioning: bool,
    temp_coverage: []u8,
    weight_cumsum: []f32,

    pub fn init(
        allocator: std.mem.Allocator,
        fonts: []const font_mod.Font,
        text: []const u8,
        options: Options,
    ) !IncrementalRenderer {
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

        var max_glyph_pixels: usize = 0;

        for (layout.positions) |pos| {
            const cache_key = glyphCacheKey(pos.font_index, pos.glyph_id);
            if (glyph_cache.get(cache_key) != null) continue;

            const glyph_font = fonts[pos.font_index];
            const glyph_scale = options.pixel_size / @as(f32, @floatFromInt(glyph_font.getUnitsPerEm()));

            const outline_opt = glyph_font.getGlyphOutline(allocator, pos.glyph_id) catch null;
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

            const glyph_result = try rasterizer_mod.rasterizeGlyph(allocator, outline, glyph_scale, options.padding);
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
            );
            errdefer reveal_ctx.deinit();

            var total_points: usize = 0;
            for (outline.contours) |contour| {
                total_points += contour.points.len;
            }
            const complexity = @max(1.0, @as(f32, @floatFromInt(total_points)));

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

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .layout = layout,
            .strategy = options.strategy,
            .timing = options.timing,
            .easing = options.easing,
            .glyph_cache = glyph_cache,
            .scale = scale,
            .base_baseline_y = pad + layout.ascender_px,
            .pad = pad,
            .fg_color = options.fg_color,
            .bg_color = options.bg_color,
            .gamma_correction = options.gamma_correction,
            .fractional_positioning = options.fractional_positioning,
            .temp_coverage = temp_coverage,
            .weight_cumsum = weight_cumsum,
        };
    }

    pub fn deinit(self: *IncrementalRenderer) void {
        self.allocator.free(self.temp_coverage);
        self.allocator.free(self.weight_cumsum);
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.pixels);
            if (entry.reveal_context) |*ctx| {
                ctx.deinit();
            }
        }
        self.glyph_cache.deinit(self.allocator);
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

    pub fn renderFrame(self: *IncrementalRenderer, progress: f32) !RgbaBitmap {
        const p = std.math.clamp(progress, 0.0, 1.0);

        var bitmap = try RgbaBitmap.init(self.allocator, self.width, self.height, self.bg_color);
        errdefer bitmap.deinit();

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
                                bitmap.blendPixelLinear(ux, uy, weighted, self.fg_color);
                            } else {
                                bitmap.blendPixel(ux, uy, weighted, self.fg_color);
                            }
                        }
                    } else {
                        if (bmp_xf < 0 or bmp_yf < 0) continue;

                        const bmp_xi = @as(u32, @intFromFloat(bmp_xf));
                        const bmp_yi = @as(u32, @intFromFloat(bmp_yf));
                        if (bmp_xi >= self.width or bmp_yi >= self.height) continue;

                        if (self.gamma_correction) {
                            bitmap.blendPixelLinear(bmp_xi, bmp_yi, cov, self.fg_color);
                        } else {
                            bitmap.blendPixel(bmp_xi, bmp_yi, cov, self.fg_color);
                        }
                    }
                }
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
    const renderer_mod = @import("renderer.zig");
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
    const renderer_mod = @import("renderer.zig");
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
