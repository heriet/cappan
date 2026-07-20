const std = @import("std");
const glyph_mod = @import("../font/glyph.zig");
const outline_mod = @import("outline.zig");
const font_mod = @import("../font/font.zig");
const shaper = @import("../layout/shaper.zig");
const bitmap_mod = @import("../render/bitmap.zig");
const rasterizer_mod = @import("rasterizer.zig");
const glyph_cache_mod = @import("glyph_cache.zig");
const ft = @import("../features.zig").features;

pub const SdfOptions = struct {
    spread: f32 = 8.0,
};

pub const SdfResult = struct {
    pixels: []u8, // grayscale SDF (128 ~= on contour)
    width: u32,
    height: u32,
    offset_x: f32, // same semantics as RasterResult (= -x_min_px + pad)
    offset_y: f32, // (= y_max_px + pad)
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SdfResult) void {
        self.allocator.free(self.pixels);
    }
};

fn emptySdfResult(allocator: std.mem.Allocator) SdfResult {
    return .{
        .pixels = &.{},
        .width = 0,
        .height = 0,
        .offset_x = 0,
        .offset_y = 0,
        .allocator = allocator,
    };
}

/// A segment with everything the hot texel loop needs precomputed once, so the
/// per-texel inner loop can bbox-reject far segments before touching the (more
/// expensive) point-to-segment distance math.
///
/// Note: `t`'s division by `ab_len_sq` is deliberately NOT replaced by a
/// precomputed reciprocal multiply here, even though that's the more obvious
/// "eliminate the division" move. Measured against the pre-refactor reference
/// atlas render, `t = dot * (1/ab_len_sq)` flips a handful of texels sitting
/// exactly on a contour (value 127 vs 128) relative to `t = dot/ab_len_sq`,
/// because IEEE754 multiply-by-reciprocal isn't bit-identical to division in
/// general. `ab_len_sq` is still precomputed once (that part is exact: it's
/// the same fixed-input arithmetic whether it runs once per segment or once
/// per segment per texel), only the division itself stays at the use site.
const PreparedSegment = struct {
    x0: f32,
    y0: f32,
    abx: f32,
    aby: f32,
    ab_len_sq: f32, // <= 1e-12 for degenerate (near-zero-length) segments
    min_y: f32,
    max_y: f32,
    wind_sign: i32,
    slope: f32, // (x1-x0)/(y1-y0); only read when min_y < max_y
    bx0: f32,
    bx1: f32,
};

fn prepareSegments(allocator: std.mem.Allocator, segments: []const outline_mod.Segment) ![]PreparedSegment {
    const prepared = try allocator.alloc(PreparedSegment, segments.len);
    errdefer allocator.free(prepared);

    for (segments, 0..) |seg, i| {
        const abx = seg.x1 - seg.x0;
        const aby = seg.y1 - seg.y0;
        const min_y = @min(seg.y0, seg.y1);
        const max_y = @max(seg.y0, seg.y1);

        prepared[i] = .{
            .x0 = seg.x0,
            .y0 = seg.y0,
            .abx = abx,
            .aby = aby,
            .ab_len_sq = abx * abx + aby * aby,
            .min_y = min_y,
            .max_y = max_y,
            .wind_sign = if (seg.y1 > seg.y0) 1 else -1,
            .slope = if (seg.y1 != seg.y0) (seg.x1 - seg.x0) / (seg.y1 - seg.y0) else 0.0,
            .bx0 = @min(seg.x0, seg.x1),
            .bx1 = @max(seg.x0, seg.x1),
        };
    }

    return prepared;
}

/// Generate a single-channel signed distance field for one glyph outline.
/// scale = pixel_size / unitsPerEm. Distances are measured in pixels; the
/// stored byte is `round(clamp(0.5 + sign * dist / (2*spread), 0, 1) * 255)`,
/// so 128 is approximately the contour, 255 is >= spread px inside, and
/// 0 is >= spread px outside.
pub fn generateGlyphSdf(
    allocator: std.mem.Allocator,
    outline: glyph_mod.GlyphOutline,
    scale: f32,
    options: SdfOptions,
) !SdfResult {
    // Defense for this pub API: a non-positive or non-finite spread makes pad_f
    // negative below, which makes glyphBitmapGeometry's w_f/h_f go negative -- caught
    // there too, but this gives a clearer, spread-specific error before we even get
    // that far (and before doing any allocation).
    if (!(options.spread > 0) or !std.math.isFinite(options.spread)) {
        return error.InvalidSdfSpread;
    }

    const spread = options.spread;

    if (outline.contours.len == 0) {
        return emptySdfResult(allocator);
    }

    const pad_f = @ceil(spread) + 1.0;
    const geom = try rasterizer_mod.glyphBitmapGeometry(outline, scale, 0.0, pad_f);
    const width = geom.width;
    const height = geom.height;
    const offset_x = geom.offset_x;
    const offset_y = geom.offset_y;

    if (width == 0 or height == 0) {
        return emptySdfResult(allocator);
    }

    const scaled = try outline_mod.scaleOutline(allocator, outline, scale, offset_x, offset_y);
    defer outline_mod.freeScaledContours(allocator, scaled);

    var segments = try outline_mod.flattenContours(allocator, scaled);
    defer segments.deinit(allocator);

    const prepared_segments = try prepareSegments(allocator, segments.items);
    defer allocator.free(prepared_segments);

    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(pixels);

    const spread_x2 = 2.0 * spread;
    // Segments farther than `spread` from a texel can only saturate the clamp
    // to the same 0/255 value the initial min_dist_sq already produces (proof:
    // dist >= spread => clamp(0.5 +/- dist/(2*spread), 0, 1) saturates to 0.5+/-0.5),
    // so starting the search here instead of at floatMax is output-invariant and
    // also doubles as the bbox early-reject threshold below.
    const spread_sq = spread * spread;

    for (0..height) |py| {
        const p_y = @as(f32, @floatFromInt(py)) + 0.5;
        for (0..width) |px| {
            const p_x = @as(f32, @floatFromInt(px)) + 0.5;

            var min_dist_sq: f32 = spread_sq;
            var winding: i32 = 0;

            for (prepared_segments) |seg| {
                // bbox lower-bound distance rejection (winding is still evaluated below).
                const dxb = @max(@max(seg.bx0 - p_x, 0.0), p_x - seg.bx1);
                const dyb = @max(@max(seg.min_y - p_y, 0.0), p_y - seg.max_y);
                if (dxb * dxb + dyb * dyb < min_dist_sq) {
                    const apx = p_x - seg.x0;
                    const apy = p_y - seg.y0;
                    // Exact division (see PreparedSegment's doc comment for why this
                    // isn't a precomputed-reciprocal multiply). Same degenerate-segment
                    // guard as the original unoptimized loop: t=0 when ab_len_sq is
                    // near zero, i.e. the segment is a point.
                    var t: f32 = 0.0;
                    if (seg.ab_len_sq > 1e-12) {
                        t = std.math.clamp((apx * seg.abx + apy * seg.aby) / seg.ab_len_sq, 0.0, 1.0);
                    }
                    const cx = seg.x0 + t * seg.abx;
                    const cy = seg.y0 + t * seg.aby;
                    const dx = p_x - cx;
                    const dy = p_y - cy;
                    const d_sq = dx * dx + dy * dy;
                    if (d_sq < min_dist_sq) min_dist_sq = d_sq;
                }

                // non-zero winding via horizontal ray cast, half-open on y
                if (p_y >= seg.min_y and p_y < seg.max_y) {
                    const x_int = seg.x0 + (p_y - seg.y0) * seg.slope;
                    if (x_int > p_x) {
                        winding += seg.wind_sign;
                    }
                }
            }

            const dist = @sqrt(min_dist_sq);
            const sign: f32 = if (winding != 0) 1.0 else -1.0;
            const value = std.math.clamp(0.5 + sign * dist / spread_x2, 0.0, 1.0);
            pixels[py * @as(usize, width) + px] = @intFromFloat(@round(value * 255.0));
        }
    }

    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .allocator = allocator,
    };
}

pub const SdfTextOptions = struct {
    pixel_size: f32,
    spread: f32 = 8.0,
    padding: u32 = 4,
    max_width: ?f32 = null,
    text_align: shaper.TextAlign = .left,
    vertical: bool = false,
    /// avar-adjusted coordinates returned by Font.computeNormalizedCoords, same type as
    /// renderer.zig's RenderOptions.normalized_coords. Only non-null changes anything:
    /// getGlyphOutlineWithVariation is used instead of getGlyphOutline in that case,
    /// otherwise the exact pre-variation code path runs (byte-identical default output).
    normalized_coords: ?[]const f32 = null,
};

/// Render a whole line of text into a single grayscale SDF buffer. Overlapping
/// glyphs are combined with a max-blend (a reasonable approximation of the
/// union of the underlying signed distance fields once clamped to u8).
pub fn renderTextSdf(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    text: []const u8,
    options: SdfTextOptions,
) !bitmap_mod.Bitmap {
    var layout = try shaper.layoutText(allocator, fonts, text, .{
        .pixel_size = options.pixel_size,
        .max_width = options.max_width,
        .text_align = options.text_align,
        .vertical = options.vertical,
    });
    defer layout.deinit();

    const pad = @as(f32, @floatFromInt(options.padding));
    const bmp_width_f = @ceil(layout.total_width + pad * 2);
    const bmp_height_f = @ceil(layout.total_height + pad * 2);

    if (bmp_width_f < 1.0 or bmp_height_f < 1.0) {
        const bmp = try bitmap_mod.Bitmap.init(allocator, 1, 1);
        @memset(bmp.pixels, 0);
        return bmp;
    }

    const bmp_width: u32 = @intFromFloat(bmp_width_f);
    const bmp_height: u32 = @intFromFloat(bmp_height_f);

    var bitmap = try bitmap_mod.Bitmap.init(allocator, bmp_width, bmp_height);
    errdefer bitmap.deinit();
    @memset(bitmap.pixels, 0); // 0 = far outside; Bitmap.init defaults to 255 (white bg), not applicable here

    const base_baseline_y = layout.baseBaselineY(pad);

    var cache: std.AutoHashMapUnmanaged(u32, SdfResult) = .empty;
    defer {
        var it = cache.valueIterator();
        while (it.next()) |entry| {
            allocator.free(entry.pixels);
        }
        cache.deinit(allocator);
    }

    for (layout.positions) |pos| {
        const cache_key = glyph_cache_mod.glyphCacheKeyU32(pos.font_index, pos.glyph_id);
        const sdf_glyph = blk: {
            if (cache.get(cache_key)) |cached| break :blk cached;

            const glyph_font = fonts[pos.font_index];
            const outline_opt = (if (options.normalized_coords) |coords|
                glyph_font.getGlyphOutlineWithVariation(allocator, pos.glyph_id, coords)
            else
                glyph_font.getGlyphOutline(allocator, pos.glyph_id)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (outline_opt == null) {
                const empty = emptySdfResult(allocator);
                try cache.put(allocator, cache_key, empty);
                break :blk empty;
            }
            var outline = outline_opt.?;
            defer outline.deinit();

            const glyph_scale = options.pixel_size / @as(f32, @floatFromInt(glyph_font.getUnitsPerEm()));
            const generated = try generateGlyphSdf(allocator, outline, glyph_scale, .{ .spread = options.spread });
            errdefer allocator.free(generated.pixels);
            try cache.put(allocator, cache_key, generated);
            break :blk generated;
        };

        if (sdf_glyph.width == 0 or sdf_glyph.height == 0) continue;

        const origin_x = pos.x_offset + pad;
        const origin_y = base_baseline_y + pos.y_offset;
        const bmp_x0 = origin_x - sdf_glyph.offset_x;
        const bmp_y0 = origin_y - sdf_glyph.offset_y;

        // Clipped destination rect computed once per glyph (in integer bitmap
        // coordinates), then blitted with a branch-free integer inner loop.
        // floor(bmp_x0 + gx) == floor(bmp_x0) + gx for any integer gx (exact
        // identity), and truncating a non-negative float (the old per-pixel
        // ">=0 check then @intFromFloat") is the same as floor, so this is the
        // same set of destination pixels the old float loop produced.
        const dst_x0: i64 = @intFromFloat(@floor(bmp_x0));
        const dst_y0: i64 = @intFromFloat(@floor(bmp_y0));

        const gx_start: u32 = if (dst_x0 < 0) @intCast(@min(-dst_x0, @as(i64, sdf_glyph.width))) else 0;
        const gx_end_i64 = @as(i64, bmp_width) - dst_x0;
        const gx_end: u32 = if (gx_end_i64 <= 0) 0 else @intCast(@min(gx_end_i64, @as(i64, sdf_glyph.width)));

        const gy_start: u32 = if (dst_y0 < 0) @intCast(@min(-dst_y0, @as(i64, sdf_glyph.height))) else 0;
        const gy_end_i64 = @as(i64, bmp_height) - dst_y0;
        const gy_end: u32 = if (gy_end_i64 <= 0) 0 else @intCast(@min(gy_end_i64, @as(i64, sdf_glyph.height)));

        var gy = gy_start;
        while (gy < gy_end) : (gy += 1) {
            const bmp_yi: u32 = @intCast(dst_y0 + @as(i64, gy));
            const src_row = gy * @as(usize, sdf_glyph.width);
            const dst_row = @as(usize, bmp_yi) * @as(usize, bmp_width);

            var gx = gx_start;
            while (gx < gx_end) : (gx += 1) {
                const bmp_xi: u32 = @intCast(dst_x0 + @as(i64, gx));
                const src = sdf_glyph.pixels[src_row + gx];
                const idx = dst_row + @as(usize, bmp_xi);
                if (src > bitmap.pixels[idx]) bitmap.pixels[idx] = src;
            }
        }
    }

    return bitmap;
}

test "generateGlyphSdf: synthetic square distance field" {
    const allocator = std.testing.allocator;

    var points = [_]glyph_mod.Point{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 400, .y = 0, .on_curve = true },
        .{ .x = 400, .y = 400, .on_curve = true },
        .{ .x = 0, .y = 400, .on_curve = true },
    };
    var contours = [_]glyph_mod.Contour{.{ .points = &points }};
    const outline = glyph_mod.GlyphOutline{
        .contours = &contours,
        .x_min = 0,
        .y_min = 0,
        .x_max = 400,
        .y_max = 400,
        .allocator = allocator,
    };

    var result = try generateGlyphSdf(allocator, outline, 0.1, .{ .spread = 8.0 });
    defer result.deinit();

    // 40x40px glyph + pad = ceil(8)+1 = 9 on each side -> 58x58
    try std.testing.expectEqual(@as(u32, 58), result.width);
    try std.testing.expectEqual(@as(u32, 58), result.height);

    // Center of the square: distance to every edge is ~19.5-20.5px >= spread -> fully inside
    const cx: usize = result.width / 2;
    const cy: usize = result.height / 2;
    try std.testing.expectEqual(@as(u8, 255), result.pixels[cy * result.width + cx]);

    // Bitmap corners: outside the square by > spread -> fully outside
    try std.testing.expectEqual(@as(u8, 0), result.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), result.pixels[result.width - 1]);
    try std.testing.expectEqual(@as(u8, 0), result.pixels[(result.height - 1) * result.width]);
    try std.testing.expectEqual(@as(u8, 0), result.pixels[(result.height - 1) * result.width + result.width - 1]);

    // Top edge sits at bitmap y=9.0, square spans x=[9,49]; sample near horizontal mid (x=29)
    const mid_x: usize = 29;

    // Row 9 (center y=9.5) is ~0.5px inside the top edge: close to the contour value (128)
    const near_edge_val = result.pixels[9 * result.width + mid_x];
    try std.testing.expect(near_edge_val > 108 and near_edge_val < 148);

    // Row 4 (center y=4.5) is ~4.5px outside: expected ~round((0.5-4.5/16)*255)=56, tolerance ±10 of the 64 reference
    const outside_val = result.pixels[4 * result.width + mid_x];
    try std.testing.expect(outside_val >= 54 and outside_val <= 74);

    // Row 13 (center y=13.5) is ~4.5px inside: expected ~round((0.5+4.5/16)*255)=199, tolerance ±10 of the 191 reference
    const inside_val = result.pixels[13 * result.width + mid_x];
    try std.testing.expect(inside_val >= 181 and inside_val <= 201);
}

test "generateGlyphSdf: matches rasterizeGlyph inside/outside for DejaVuSans 'A'" {
    const allocator = std.testing.allocator;

    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId('A');
    var outline = (try font.getGlyphOutline(allocator, glyph_id)).?;
    defer outline.deinit();

    const scale = 64.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    const spread: f32 = 8.0;
    const pad: u32 = @intFromFloat(@ceil(spread) + 1.0); // matches sdf.zig's internal padding rule

    var sdf_result = try generateGlyphSdf(allocator, outline, scale, .{ .spread = spread });
    defer sdf_result.deinit();

    var raster_result = try rasterizer_mod.rasterizeGlyph(allocator, outline, scale, pad, .{});
    defer raster_result.deinit();

    // Same bbox + same padding rule -> identical bitmap geometry, so pixel grids line up.
    try std.testing.expectEqual(sdf_result.width, raster_result.width);
    try std.testing.expectEqual(sdf_result.height, raster_result.height);
    try std.testing.expectEqual(sdf_result.offset_x, raster_result.offset_x);
    try std.testing.expectEqual(sdf_result.offset_y, raster_result.offset_y);

    var mismatches: usize = 0;
    for (0..sdf_result.height) |y| {
        for (0..sdf_result.width) |x| {
            const idx = y * @as(usize, sdf_result.width) + x;
            const sdf_v = sdf_result.pixels[idx];
            const cov = raster_result.pixels[idx];
            if (sdf_v >= 160) {
                if (cov == 0) mismatches += 1;
            } else if (sdf_v <= 96) {
                if (cov != 0) mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "renderTextSdf: basic bitmap shape for 'AB'" {
    const allocator = std.testing.allocator;

    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const fonts = [_]font_mod.Font{font};

    // A large-enough pixel size that DejaVuSans stem widths exceed 2*spread somewhere,
    // so the SDF actually saturates to 255 well inside the glyph (thin strokes at small
    // sizes never get further than ~2-3px from a contour, which the ±16px spread band
    // could reasonably keep below the 200 threshold below).
    const pixel_size: f32 = 128.0;

    var layout = try shaper.layoutText(allocator, &fonts, "AB", .{ .pixel_size = pixel_size });
    defer layout.deinit();

    var bitmap = try renderTextSdf(allocator, &fonts, "AB", .{ .pixel_size = pixel_size, .spread = 8.0 });
    defer bitmap.deinit();

    const pad: f32 = 4.0;
    const expected_width: u32 = @intFromFloat(@ceil(layout.total_width + pad * 2));
    const expected_height: u32 = @intFromFloat(@ceil(layout.total_height + pad * 2));
    try std.testing.expectEqual(expected_width, bitmap.width);
    try std.testing.expectEqual(expected_height, bitmap.height);

    var has_inside = false;
    var has_outside = false;
    for (bitmap.pixels) |px| {
        if (px >= 200) has_inside = true;
        if (px <= 50) has_outside = true;
    }
    try std.testing.expect(has_inside);
    try std.testing.expect(has_outside);
}

test "generateGlyphSdf and renderTextSdf: empty outline does not crash" {
    const allocator = std.testing.allocator;

    var empty_contours = [_]glyph_mod.Contour{};
    const outline = glyph_mod.GlyphOutline{
        .contours = empty_contours[0..],
        .x_min = 0,
        .y_min = 0,
        .x_max = 0,
        .y_max = 0,
        .allocator = allocator,
    };
    var result = try generateGlyphSdf(allocator, outline, 0.1, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 0), result.width);
    try std.testing.expectEqual(@as(u32, 0), result.height);

    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const fonts = [_]font_mod.Font{font};

    var bitmap = try renderTextSdf(allocator, &fonts, " ", .{ .pixel_size = 48.0 });
    defer bitmap.deinit();
}

fn testSquareOutline(contours: *[1]glyph_mod.Contour, points: *[4]glyph_mod.Point, allocator: std.mem.Allocator) glyph_mod.GlyphOutline {
    points.* = .{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 400, .y = 0, .on_curve = true },
        .{ .x = 400, .y = 400, .on_curve = true },
        .{ .x = 0, .y = 400, .on_curve = true },
    };
    contours.* = .{.{ .points = points }};
    return .{
        .contours = contours,
        .x_min = 0,
        .y_min = 0,
        .x_max = 400,
        .y_max = 400,
        .allocator = allocator,
    };
}

test "generateGlyphSdf: spread=0 is rejected (panic repro)" {
    const allocator = std.testing.allocator;
    var points: [4]glyph_mod.Point = undefined;
    var contours: [1]glyph_mod.Contour = undefined;
    const outline = testSquareOutline(&contours, &points, allocator);

    try std.testing.expectError(error.InvalidSdfSpread, generateGlyphSdf(allocator, outline, 0.1, .{ .spread = 0 }));
}

test "generateGlyphSdf: negative spread is rejected (panic repro)" {
    const allocator = std.testing.allocator;
    var points: [4]glyph_mod.Point = undefined;
    var contours: [1]glyph_mod.Contour = undefined;
    const outline = testSquareOutline(&contours, &points, allocator);

    try std.testing.expectError(error.InvalidSdfSpread, generateGlyphSdf(allocator, outline, 0.1, .{ .spread = -4.0 }));
}

test "renderTextSdf: --variation coords change the SDF output" {
    if (comptime !ft.enable_variable) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // Same fixture/axis as font.zig's "Variable Font gvar apply deltas" test: a single
    // "wght" axis, normalized coord 1.0 is the bold extreme.
    const font_data = @embedFile("../fixture/SourceSans3VF-Subset.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const fonts = [_]font_mod.Font{font};

    var bitmap_default = try renderTextSdf(allocator, &fonts, "A", .{ .pixel_size = 96.0, .spread = 8.0 });
    defer bitmap_default.deinit();

    const normalized = [_]f32{1.0};
    var bitmap_bold = try renderTextSdf(allocator, &fonts, "A", .{
        .pixel_size = 96.0,
        .spread = 8.0,
        .normalized_coords = &normalized,
    });
    defer bitmap_bold.deinit();

    var differs = bitmap_default.width != bitmap_bold.width or bitmap_default.height != bitmap_bold.height;
    if (!differs) {
        for (bitmap_default.pixels, bitmap_bold.pixels) |a, b| {
            if (a != b) {
                differs = true;
                break;
            }
        }
    }
    try std.testing.expect(differs);
}

test "renderTextSdf: vertical layout basic bitmap shape for 'AB'" {
    if (comptime !ft.enable_vertical) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const fonts = [_]font_mod.Font{font};

    const pixel_size: f32 = 128.0;

    var layout = try shaper.layoutText(allocator, &fonts, "AB", .{ .pixel_size = pixel_size, .vertical = true });
    defer layout.deinit();

    var bitmap = try renderTextSdf(allocator, &fonts, "AB", .{ .pixel_size = pixel_size, .spread = 8.0, .vertical = true });
    defer bitmap.deinit();

    const pad: f32 = 4.0;
    const expected_width: u32 = @intFromFloat(@ceil(layout.total_width + pad * 2));
    const expected_height: u32 = @intFromFloat(@ceil(layout.total_height + pad * 2));
    try std.testing.expectEqual(expected_width, bitmap.width);
    try std.testing.expectEqual(expected_height, bitmap.height);

    var has_inside = false;
    var has_outside = false;
    for (bitmap.pixels) |px| {
        if (px >= 200) has_inside = true;
        if (px <= 50) has_outside = true;
    }
    try std.testing.expect(has_inside);
    try std.testing.expect(has_outside);
}

test "generateGlyphSdf: matches rasterizeGlyph inside/outside for CFF font (SourceSans3 'A')" {
    if (comptime !ft.enable_cff) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const font_data = @embedFile("../fixture/SourceSans3-Regular.otf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId('A');
    var outline = (try font.getGlyphOutline(allocator, glyph_id)).?;
    defer outline.deinit();

    const scale = 64.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    const spread: f32 = 8.0;
    const pad: u32 = @intFromFloat(@ceil(spread) + 1.0); // matches sdf.zig's internal padding rule

    var sdf_result = try generateGlyphSdf(allocator, outline, scale, .{ .spread = spread });
    defer sdf_result.deinit();

    var raster_result = try rasterizer_mod.rasterizeGlyph(allocator, outline, scale, pad, .{});
    defer raster_result.deinit();

    try std.testing.expectEqual(sdf_result.width, raster_result.width);
    try std.testing.expectEqual(sdf_result.height, raster_result.height);
    try std.testing.expectEqual(sdf_result.offset_x, raster_result.offset_x);
    try std.testing.expectEqual(sdf_result.offset_y, raster_result.offset_y);

    var mismatches: usize = 0;
    for (0..sdf_result.height) |y| {
        for (0..sdf_result.width) |x| {
            const idx = y * @as(usize, sdf_result.width) + x;
            const sdf_v = sdf_result.pixels[idx];
            const cov = raster_result.pixels[idx];
            if (sdf_v >= 160) {
                if (cov == 0) mismatches += 1;
            } else if (sdf_v <= 96) {
                if (cov != 0) mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}
