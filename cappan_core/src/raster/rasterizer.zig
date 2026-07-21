const std = @import("std");
const glyph_mod = @import("../font/glyph.zig");
const outline_mod = @import("outline.zig");
const scanline_mod = @import("scanline.zig");
const analytical_mod = @import("analytical.zig");
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

/// Per-call temporary buffers, reusable across many rasterizeGlyphWithScratch
/// calls (glyph outline flattening + scanline AET/coverage state + analytical
/// cell grid) instead of allocating them fresh every call. Pass the same
/// `*RasterScratch` to consecutive calls (e.g. one per glyph in a run of text)
/// to amortize allocation; `RasterResult.pixels` is always a fresh allocation
/// regardless (the caller owns and frees it independently of the scratch's
/// lifetime).
pub const RasterScratch = struct {
    segments: std.ArrayList(outline_mod.Segment) = .empty,
    edges: std.ArrayList(scanline_mod.Edge) = .empty,
    intersections: std.ArrayList(scanline_mod.Intersection) = .empty,
    active: std.ArrayList(scanline_mod.Edge) = .empty,
    delta: std.ArrayList(i16) = .empty,
    coverage: std.ArrayList(u16) = .empty,
    /// analytical.zig's cell buffer, reused call-to-call across this
    /// scratch's lifetime. On the scratch path analytical.zig deliberately
    /// uses one full-height band (see its band_h doc), so this grows to
    /// `width * height` of the largest glyph seen; only the scratch-less
    /// path bands down to `width * band_h`.
    cells: std.ArrayList(analytical_mod.Cell) = .empty,

    pub fn deinit(self: *RasterScratch, allocator: std.mem.Allocator) void {
        self.segments.deinit(allocator);
        self.edges.deinit(allocator);
        self.intersections.deinit(allocator);
        self.active.deinit(allocator);
        self.delta.deinit(allocator);
        self.coverage.deinit(allocator);
        self.cells.deinit(allocator);
    }
};

pub const GlyphBitmapGeometry = struct {
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
};

/// Computes a glyph's bitmap dimensions and blit offset from its font-unit bbox.
/// `half_embolden` is 0.0 for callers that don't expand the bbox for stroke width
/// (e.g. sdf.zig, which never hints/embolds); `pad_f` is the padding in pixels on
/// every side. Shared by rasterizer.zig's prepareGlyphRasterization and
/// sdf.zig's generateGlyphSdf so the bbox/offset math has a single owner.
pub fn glyphBitmapGeometry(
    glyph_outline: glyph_mod.GlyphOutline,
    scale: f32,
    half_embolden: f32,
    pad_f: f32,
) error{InvalidGlyphDimensions}!GlyphBitmapGeometry {
    const x_min_px = @as(f32, @floatFromInt(glyph_outline.x_min)) * scale - half_embolden;
    const y_min_px = @as(f32, @floatFromInt(glyph_outline.y_min)) * scale - half_embolden;
    const x_max_px = @as(f32, @floatFromInt(glyph_outline.x_max)) * scale + half_embolden;
    const y_max_px = @as(f32, @floatFromInt(glyph_outline.y_max)) * scale + half_embolden;

    const glyph_width = @max(0.0, x_max_px - x_min_px);
    const glyph_height = @max(0.0, y_max_px - y_min_px);

    const max_dim: f32 = 16384.0;
    const w_f = @ceil(glyph_width + pad_f * 2);
    const h_f = @ceil(glyph_height + pad_f * 2);
    // w_f/h_f < 0 is reachable with a negative pad_f (e.g. a caller passing a negative
    // spread/padding value): @intFromFloat on a negative float into a u32 is a panic,
    // not a normal error, so this must be rejected before the cast below.
    const width: u32 = if (w_f > max_dim or w_f < 0 or w_f != w_f) return error.InvalidGlyphDimensions else @intFromFloat(w_f);
    const height: u32 = if (h_f > max_dim or h_f < 0 or h_f != h_f) return error.InvalidGlyphDimensions else @intFromFloat(h_f);

    return .{
        .width = width,
        .height = height,
        .offset_x = -x_min_px + pad_f,
        .offset_y = y_max_px + pad_f,
    };
}

const PreparedGlyphRasterization = struct {
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
    scaled: ?[][]outline_mod.ScaledPoint,
    segments: std.ArrayList(outline_mod.Segment),
    // False when `segments` aliases a scratch buffer (owned by the caller's
    // RasterScratch, freed on the scratch's own lifetime) rather than a
    // freshly-allocated list this struct must free itself.
    owns_segments: bool,
    allocator: std.mem.Allocator,

    fn deinit(self: *PreparedGlyphRasterization) void {
        if (self.scaled) |scaled| {
            outline_mod.freeScaledContours(self.allocator, scaled);
        }
        if (self.owns_segments) {
            self.segments.deinit(self.allocator);
        }
    }
};

fn prepareGlyphRasterization(
    allocator: std.mem.Allocator,
    glyph_outline: glyph_mod.GlyphOutline,
    scale: f32,
    padding: u32,
    raster_options: scanline_mod.RasterOptions,
    scale_offset_x: f32,
    comptime lcd_transform: bool,
    scratch: ?*RasterScratch,
) !PreparedGlyphRasterization {
    const embolden = @max(0.0, raster_options.embolden_strength);
    const half_embolden = embolden * 0.5;
    const pad_f = @as(f32, @floatFromInt(padding));

    const geom = try glyphBitmapGeometry(glyph_outline, scale, half_embolden, pad_f);
    const width = geom.width;
    const height = geom.height;
    const offset_x = geom.offset_x;
    const offset_y = geom.offset_y;

    if (width == 0 or height == 0) {
        return .{
            .width = width,
            .height = height,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .scaled = null,
            .segments = .empty,
            .owns_segments = true,
            .allocator = allocator,
        };
    }

    const outline_offset_x = if (comptime lcd_transform) scale_offset_x else offset_x;
    const scaled = try outline_mod.scaleOutline(allocator, glyph_outline, scale, outline_offset_x, offset_y);
    errdefer outline_mod.freeScaledContours(allocator, scaled);

    if (comptime ft.enable_hinting) {
        if (glyph_outline.hints) |hint_data| {
            cff_hinting_mod.applyHints(scaled, hint_data, scale);
        }
        if (embolden > 0.0) {
            try stem_darkening_mod.emboldenContours(allocator, scaled, embolden);
        }
    }

    if (comptime lcd_transform) {
        for (scaled) |contour_points| {
            for (contour_points) |*pt| {
                pt.x = pt.x * 3.0 + offset_x * 3.0;
            }
        }
    }

    // Flattening logic itself (per-contour flattenContour + concatenate) is
    // identical either way; only where the result lives differs. See
    // outline_mod.flattenContours, which the non-scratch path calls directly.
    var all_segments: std.ArrayList(outline_mod.Segment) = undefined;
    var owns_segments = true;
    if (scratch) |s| {
        s.segments.clearRetainingCapacity();
        for (scaled) |contour_points| {
            const segs = try outline_mod.flattenContour(allocator, contour_points);
            defer allocator.free(segs);
            try s.segments.appendSlice(allocator, segs);
        }
        all_segments = s.segments;
        owns_segments = false;
    } else {
        all_segments = try outline_mod.flattenContours(allocator, scaled);
    }

    return .{
        .width = width,
        .height = height,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .scaled = scaled,
        .segments = all_segments,
        .owns_segments = owns_segments,
        .allocator = allocator,
    };
}

/// Rasterize a single glyph outline at the given scale
pub fn rasterizeGlyph(
    allocator: std.mem.Allocator,
    glyph_outline: glyph_mod.GlyphOutline,
    scale: f32,
    padding: u32,
    raster_options: scanline_mod.RasterOptions,
) !RasterResult {
    return rasterizeGlyphWithScratch(allocator, glyph_outline, scale, padding, raster_options, null);
}

/// Same as rasterizeGlyph, but reuses `scratch`'s temporary buffers (outline
/// flattening, scanline AET/coverage state, analytical cell grid) instead of
/// allocating them fresh -- pass the same `*RasterScratch` across a run of
/// glyphs to amortize allocation. `scratch = null` is exactly rasterizeGlyph's
/// existing behavior (this is what rasterizeGlyph calls, so their output is
/// byte-identical for the same inputs).
pub fn rasterizeGlyphWithScratch(
    allocator: std.mem.Allocator,
    glyph_outline: glyph_mod.GlyphOutline,
    scale: f32,
    padding: u32,
    raster_options: scanline_mod.RasterOptions,
    scratch: ?*RasterScratch,
) !RasterResult {
    var prepared = try prepareGlyphRasterization(allocator, glyph_outline, scale, padding, raster_options, 0.0, false, scratch);
    defer prepared.deinit();

    if (prepared.width == 0 or prepared.height == 0) {
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

    // Rasterize
    const pixels = try scanline_mod.rasterize(allocator, prepared.segments.items, prepared.width, prepared.height, raster_options, scanlineScratchOf(scratch));

    return .{
        .pixels = pixels,
        .width = prepared.width,
        .height = prepared.height,
        .offset_x = prepared.offset_x,
        .offset_y = prepared.offset_y,
        .allocator = allocator,
    };
}

/// Builds the pointer-bundle scanline.zig's rasterize() expects from a
/// RasterScratch's owned ArrayLists (or null, unchanged, if there's no scratch).
fn scanlineScratchOf(scratch: ?*RasterScratch) ?scanline_mod.RasterizeScratch {
    const s = scratch orelse return null;
    return .{
        .edges = &s.edges,
        .active = &s.active,
        .intersections = &s.intersections,
        .delta = &s.delta,
        .coverage = &s.coverage,
        .cells = &s.cells,
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
    // LCD path is out of scope for scratch reuse (untouched): always null.
    var prepared = try prepareGlyphRasterization(allocator, glyph_outline, scale, padding, raster_options, 0.0, true, null);
    defer prepared.deinit();

    if (prepared.width == 0 or prepared.height == 0) {
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

    const wide_width = prepared.width * 3;

    const wide_pixels = try scanline_mod.rasterize(allocator, prepared.segments.items, wide_width, prepared.height, raster_options, null);
    defer allocator.free(wide_pixels);

    const pixel_count = @as(usize, prepared.width) * @as(usize, prepared.height);
    const r_cov = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(r_cov);
    const g_cov = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(g_cov);
    const b_cov = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(b_cov);

    for (0..prepared.height) |y| {
        for (0..@as(usize, prepared.width)) |x| {
            const dst = y * @as(usize, prepared.width) + x;
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
        .width = prepared.width,
        .height = prepared.height,
        .offset_x = prepared.offset_x,
        .offset_y = prepared.offset_y,
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
