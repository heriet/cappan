const std = @import("std");
const glyph_mod = @import("../font/glyph.zig");
const outline_mod = @import("outline.zig");
const font_mod = @import("../font/font.zig");
const shaper = @import("../layout/shaper.zig");
const rgba_mod = @import("../render/rgba_bitmap.zig");
const rasterizer_mod = @import("rasterizer.zig");
const glyph_cache_mod = @import("glyph_cache.zig");
const sdf_mod = @import("sdf.zig");
const ft = @import("../features.zig").features;

const ch_r: u3 = 0b001;
const ch_g: u3 = 0b010;
const ch_b: u3 = 0b100;
pub const color_magenta: u3 = ch_r | ch_b;
pub const color_yellow: u3 = ch_r | ch_g;
pub const color_cyan: u3 = ch_g | ch_b;
const color_white: u3 = ch_r | ch_g | ch_b;

pub const MtsdfResult = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MtsdfResult) void {
        self.allocator.free(self.pixels);
    }
};

const PreparedSegment = struct {
    x0: f32,
    y0: f32,
    abx: f32,
    aby: f32,
    ab_len_sq: f32,
    min_y: f32,
    max_y: f32,
    wind_sign: i32,
    slope: f32,
    bx0: f32,
    bx1: f32,
    channels: u3,
    is_group_start: bool,
    is_group_end: bool,
};

fn emptyMtsdfResult(allocator: std.mem.Allocator) MtsdfResult {
    return .{ .pixels = &.{}, .width = 0, .height = 0, .offset_x = 0, .offset_y = 0, .allocator = allocator };
}

fn median3(a: u8, b: u8, c: u8) u8 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

fn contourArea(runs: []const outline_mod.EdgeRun) f32 {
    var area2: f32 = 0;
    for (runs) |run| {
        for (run.segments) |seg| {
            area2 += seg.x0 * seg.y1 - seg.x1 * seg.y0;
        }
    }
    return area2 * 0.5;
}

fn windingAt(runs: []const outline_mod.EdgeRun, px: f32, py: f32) i32 {
    var winding: i32 = 0;
    for (runs) |run| {
        for (run.segments) |seg| {
            const min_y = @min(seg.y0, seg.y1);
            const max_y = @max(seg.y0, seg.y1);
            if (py >= min_y and py < max_y) {
                const slope = if (seg.y1 != seg.y0) (seg.x1 - seg.x0) / (seg.y1 - seg.y0) else 0.0;
                const x_int = seg.x0 + (py - seg.y0) * slope;
                if (x_int > px) winding += if (seg.y1 > seg.y0) 1 else -1;
            }
        }
    }
    return winding;
}

fn reverseRunSegments(segs: []outline_mod.Segment) void {
    std.mem.reverse(outline_mod.Segment, segs);
    for (segs) |*seg| {
        std.mem.swap(f32, &seg.x0, &seg.x1);
        std.mem.swap(f32, &seg.y0, &seg.y1);
    }
}

fn reverseContourRuns(runs: []outline_mod.EdgeRun) void {
    std.mem.reverse(outline_mod.EdgeRun, runs);
    for (runs) |*run| {
        reverseRunSegments(run.segments);
        const old_start = run.dir_start;
        run.dir_start = .{ -run.dir_end[0], -run.dir_end[1] };
        run.dir_end = .{ -old_start[0], -old_start[1] };
    }
}

fn normalizeContourOrientations(contours: []const []outline_mod.EdgeRun) void {
    for (contours, 0..) |runs, i| {
        if (runs.len == 0) continue;
        var rx: f32 = 0;
        var ry: f32 = 0;
        var found = false;
        for (runs) |run| {
            if (run.segments.len > 0) {
                const seg = run.segments[0];
                rx = (seg.x0 + seg.x1) * 0.5;
                ry = (seg.y0 + seg.y1) * 0.5;
                found = true;
                break;
            }
        }
        if (!found) continue;

        var depth: usize = 0;
        for (contours, 0..) |other, j| {
            if (i == j) continue;
            if (windingAt(other, rx, ry) != 0) depth += 1;
        }
        const should_be_positive = (depth % 2) == 0;
        const area = contourArea(runs);
        if ((should_be_positive and area < 0) or (!should_be_positive and area > 0)) {
            reverseContourRuns(runs);
        }
    }
}

fn isCorner(a: [2]f32, b: [2]f32) bool {
    const dot = a[0] * b[0] + a[1] * b[1];
    const cross = a[0] * b[1] - a[1] * b[0];
    // msdfgen's default angle threshold is 3.0 radians; this detects direction
    // changes greater than about 8.1 degrees because sin(3.0) is near zero.
    return dot <= 0.0 or @abs(cross) > @sin(@as(f32, 3.0));
}

pub fn detectCorners(allocator: std.mem.Allocator, runs: []const outline_mod.EdgeRun) ![]usize {
    var corners: std.ArrayList(usize) = .empty;
    errdefer corners.deinit(allocator);
    if (runs.len == 0) return try corners.toOwnedSlice(allocator);
    for (runs, 0..) |run, i| {
        const next = runs[(i + 1) % runs.len];
        if (isCorner(run.dir_end, next.dir_start)) {
            try corners.append(allocator, (i + 1) % runs.len);
        }
    }
    return try corners.toOwnedSlice(allocator);
}

pub fn applyEdgeColoringSimple(runs: []outline_mod.EdgeRun, corners: []const usize) void {
    if (runs.len == 0) return;
    if (corners.len == 0) {
        for (runs) |*run| run.channels = color_white;
        return;
    }
    if (corners.len == 1) {
        // Teardrop: split the run cycle into thirds starting at the corner. Known
        // limitation vs msdfgen: a contour whose single corner sits on a single
        // run (runs.len < 3) is not subdivided at segment granularity, so all
        // runs land in group 0 and that contour's corner loses channel contrast
        // (degrades toward a binary edge, no crash).
        const colors = [_]u3{ color_magenta, color_yellow, color_cyan };
        const start = corners[0];
        for (0..runs.len) |step| {
            const idx = (start + step) % runs.len;
            const group = @min(@as(usize, 2), step * 3 / runs.len);
            runs[idx].channels = colors[group];
        }
        return;
    }

    for (0..corners.len) |ci| {
        const start = corners[ci];
        const end = corners[(ci + 1) % corners.len];
        var color: u3 = if (ci % 2 == 0) color_magenta else color_yellow;
        if (corners.len % 2 == 1 and ci == corners.len - 1) color = color_cyan;
        var idx = start;
        while (true) {
            runs[idx].channels = color;
            idx = (idx + 1) % runs.len;
            if (idx == end) break;
        }
    }
}

fn flattenColoredSegments(allocator: std.mem.Allocator, contours: []const []outline_mod.EdgeRun) ![]PreparedSegment {
    var count: usize = 0;
    for (contours) |runs| {
        for (runs) |run| count += run.segments.len;
    }
    const prepared = try allocator.alloc(PreparedSegment, count);
    errdefer allocator.free(prepared);

    var out: usize = 0;
    for (contours) |runs| {
        for (runs) |run| {
            for (run.segments, 0..) |seg, si| {
                const abx = seg.x1 - seg.x0;
                const aby = seg.y1 - seg.y0;
                const min_y = @min(seg.y0, seg.y1);
                const max_y = @max(seg.y0, seg.y1);
                prepared[out] = .{
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
                    .channels = run.channels,
                    .is_group_start = si == 0,
                    .is_group_end = si + 1 == run.segments.len,
                };
                out += 1;
            }
        }
    }
    return prepared;
}

/// dist_sq starts at spread_sq and only ever decreases (see generateGlyphMtsdf's
/// texel loop), so "no edge improved this channel within the spread band" is
/// exactly `dist_sq >= spread_sq` -- no separate `found` flag needed.
const ChannelNearest = struct {
    dist_sq: f32,
    signed_pseudo_dist: f32,
};

const SegmentProjection = struct {
    d_sq: f32, // true (clamped) squared distance — drives winner selection and the A channel
    t: f32,
    unclamped_t: f32,
    cx: f32,
    cy: f32,
};

/// Cheap half of the per-segment distance computation: no sqrt. Used to decide
/// (against already-known nearest/true-min values) whether this segment is worth
/// finalizing into a signed pseudo-distance at all.
fn projectToSegment(seg: PreparedSegment, px: f32, py: f32) SegmentProjection {
    const apx = px - seg.x0;
    const apy = py - seg.y0;
    var unclamped_t: f32 = 0.0;
    var t: f32 = 0.0;
    if (seg.ab_len_sq > 1e-12) {
        unclamped_t = (apx * seg.abx + apy * seg.aby) / seg.ab_len_sq;
        t = std.math.clamp(unclamped_t, 0.0, 1.0);
    }
    const cx = seg.x0 + t * seg.abx;
    const cy = seg.y0 + t * seg.aby;
    const dx = px - cx;
    const dy = py - cy;
    return .{ .d_sq = dx * dx + dy * dy, .t = t, .unclamped_t = unclamped_t, .cx = cx, .cy = cy };
}

/// The sqrt + pseudo-distance + side half, split out of the old single
/// segmentDistance so it only runs when `proj` actually improves at least one
/// RGB channel (see the texel loop): most bbox survivors don't, since the bbox
/// bound is intentionally loose (see the running `bound` comment below).
fn finalizeSignedPseudoDist(seg: PreparedSegment, proj: SegmentProjection, px: f32, py: f32) f32 {
    var dist = @sqrt(proj.d_sq);
    const at_start = proj.t == 0.0 and proj.unclamped_t < 0.0 and seg.is_group_start;
    const at_end = proj.t == 1.0 and proj.unclamped_t > 1.0 and seg.is_group_end;
    if ((at_start or at_end) and seg.ab_len_sq > 1e-12) {
        // Division, not a precomputed reciprocal multiply -- see sdf.zig's
        // PreparedSegment doc comment for why (bit-for-bit, not just
        // mathematically, matters for the SDF/MSDF byte-identity contract).
        dist = @abs(seg.abx * (py - seg.y0) - seg.aby * (px - seg.x0)) / @sqrt(seg.ab_len_sq);
    }
    const side = seg.abx * (py - proj.cy) - seg.aby * (px - proj.cx);
    // After orientation normalization (outer contours have positive shoelace
    // area in y-down screen coordinates, i.e. run clockwise on screen), the
    // inside lies on the right side of each directed edge, and the y-down cross
    // product `side` is positive exactly on that right side.
    const sign: f32 = if (side >= 0.0) 1.0 else -1.0;
    return sign * dist;
}

pub fn generateGlyphMtsdf(
    allocator: std.mem.Allocator,
    outline: glyph_mod.GlyphOutline,
    scale: f32,
    options: sdf_mod.SdfOptions,
) !MtsdfResult {
    try sdf_mod.validateSpread(options.spread);
    if (outline.contours.len == 0) return emptyMtsdfResult(allocator);
    const spread = options.spread;
    const pad_f = sdf_mod.sdfPad(spread);
    const geom = try rasterizer_mod.glyphBitmapGeometry(outline, scale, 0.0, pad_f);
    if (geom.width == 0 or geom.height == 0) return emptyMtsdfResult(allocator);

    const scaled = try outline_mod.scaleOutline(allocator, outline, scale, geom.offset_x, geom.offset_y);
    defer outline_mod.freeScaledContours(allocator, scaled);

    const contour_decomposed = try allocator.alloc(outline_mod.DecomposedContour, scaled.len);
    // Count-guarded cleanup: registered before the fill loop so contours already
    // decomposed are freed even when a later decomposeContourEdges call fails.
    var decomposed_count: usize = 0;
    defer {
        for (contour_decomposed[0..decomposed_count]) |*dc| dc.deinit();
        allocator.free(contour_decomposed);
    }
    for (scaled, 0..) |contour, i| {
        contour_decomposed[i] = try outline_mod.decomposeContourEdges(allocator, contour);
        decomposed_count += 1;
    }

    const contour_runs = try allocator.alloc([]outline_mod.EdgeRun, contour_decomposed.len);
    defer allocator.free(contour_runs);
    for (contour_decomposed, 0..) |dc, i| contour_runs[i] = dc.runs;

    normalizeContourOrientations(contour_runs);
    for (contour_runs) |runs| {
        const corners = try detectCorners(allocator, runs);
        defer allocator.free(corners);
        applyEdgeColoringSimple(runs, corners);
    }

    const segments = try flattenColoredSegments(allocator, contour_runs);
    defer allocator.free(segments);

    const pixels = try allocator.alloc(u8, @as(usize, geom.width) * @as(usize, geom.height) * 4);
    errdefer allocator.free(pixels);

    const spread_x2 = 2.0 * spread;
    const spread_sq = spread * spread;

    for (0..geom.height) |py| {
        const p_y = @as(f32, @floatFromInt(py)) + 0.5;
        for (0..geom.width) |px| {
            const p_x = @as(f32, @floatFromInt(px)) + 0.5;
            var nearest = [_]ChannelNearest{
                .{ .dist_sq = spread_sq, .signed_pseudo_dist = 0 },
                .{ .dist_sq = spread_sq, .signed_pseudo_dist = 0 },
                .{ .dist_sq = spread_sq, .signed_pseudo_dist = 0 },
            };
            var true_min_dist_sq: f32 = spread_sq;
            var winding: i32 = 0;
            // Single running bbox-reject bound (max of true_min_dist_sq and the 3
            // channel dist_sq's), updated only when one of those four values
            // actually improves -- replacing the old per-segment, channel-masked
            // 4-way max recompute. This bound can only be >= the old channel-scoped
            // one (looser, since it ignores which channels the *current* segment
            // matches), which can only let *more* segments survive the bbox check,
            // never fewer -- and any segment that would have been rejected still
            // can't beat an already-better nearest[]/true_min value once it's
            // actually projected, so the winners (and thus the output bytes) are
            // unchanged.
            var bound: f32 = spread_sq;

            for (segments) |seg| {
                const dxb = @max(@max(seg.bx0 - p_x, 0.0), p_x - seg.bx1);
                const dyb = @max(@max(seg.min_y - p_y, 0.0), p_y - seg.max_y);
                if (dxb * dxb + dyb * dyb < bound) {
                    // Cheap projection first (no sqrt); only finalize into a signed
                    // pseudo-distance (sqrt + side test) when it would actually win
                    // an RGB channel -- true_min_dist_sq alone never needs it, since
                    // it only feeds the A channel once, after this loop.
                    const proj = projectToSegment(seg, p_x, p_y);
                    var updated = false;
                    if (proj.d_sq < true_min_dist_sq) {
                        true_min_dist_sq = proj.d_sq;
                        updated = true;
                    }
                    var improves_channel = false;
                    inline for (0..3) |c| {
                        if (seg.channels & (@as(u3, 1) << c) != 0 and proj.d_sq < nearest[c].dist_sq) improves_channel = true;
                    }
                    if (improves_channel) {
                        const signed_pseudo_dist = finalizeSignedPseudoDist(seg, proj, p_x, p_y);
                        inline for (0..3) |c| {
                            if (seg.channels & (@as(u3, 1) << c) != 0 and proj.d_sq < nearest[c].dist_sq) {
                                nearest[c] = .{ .dist_sq = proj.d_sq, .signed_pseudo_dist = signed_pseudo_dist };
                            }
                        }
                        updated = true;
                    }
                    if (updated) {
                        bound = true_min_dist_sq;
                        inline for (0..3) |c| {
                            if (nearest[c].dist_sq > bound) bound = nearest[c].dist_sq;
                        }
                    }
                }

                winding += sdf_mod.segmentWinding(seg, p_x, p_y);
            }

            const true_sign: f32 = if (winding != 0) 1.0 else -1.0;
            const a = sdf_mod.quantizeSignedDistance(true_sign * @sqrt(true_min_dist_sq), spread_x2);
            // A channel with no edge inside the spread band saturates to the
            // globally-signed extreme (inside -> 255, outside -> 0): that is that
            // channel's true field value there, and it keeps deep-interior texels
            // from tripping the sign-mismatch correction below.
            inline for (0..3) |c| {
                if (nearest[c].dist_sq >= spread_sq) nearest[c].signed_pseudo_dist = true_sign * spread;
            }
            var r = sdf_mod.quantizeSignedDistance(nearest[0].signed_pseudo_dist, spread_x2);
            var g = sdf_mod.quantizeSignedDistance(nearest[1].signed_pseudo_dist, spread_x2);
            var b = sdf_mod.quantizeSignedDistance(nearest[2].signed_pseudo_dist, spread_x2);
            if ((median3(r, g, b) >= 128) != (a >= 128)) {
                r = a;
                g = a;
                b = a;
            }
            const idx = (py * @as(usize, geom.width) + px) * 4;
            pixels[idx + 0] = r;
            pixels[idx + 1] = g;
            pixels[idx + 2] = b;
            pixels[idx + 3] = a;
        }
    }

    return .{ .pixels = pixels, .width = geom.width, .height = geom.height, .offset_x = geom.offset_x, .offset_y = geom.offset_y, .allocator = allocator };
}

pub const MtsdfTextOptions = sdf_mod.SdfTextOptions;

pub fn renderTextMtsdf(
    allocator: std.mem.Allocator,
    fonts: []const font_mod.Font,
    text: []const u8,
    options: MtsdfTextOptions,
) !rgba_mod.RgbaBitmap {
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
        return try rgba_mod.RgbaBitmap.init(allocator, 1, 1, .transparent);
    }

    const bmp_width: u32 = @intFromFloat(bmp_width_f);
    const bmp_height: u32 = @intFromFloat(bmp_height_f);
    var bitmap = try rgba_mod.RgbaBitmap.init(allocator, bmp_width, bmp_height, .transparent);
    errdefer bitmap.deinit();

    const base_baseline_y = layout.baseBaselineY(pad);
    var cache: std.AutoHashMapUnmanaged(u32, MtsdfResult) = .empty;
    defer {
        var it = cache.valueIterator();
        while (it.next()) |entry| allocator.free(entry.pixels);
        cache.deinit(allocator);
    }

    for (layout.positions) |pos| {
        const cache_key = glyph_cache_mod.glyphCacheKeyU32(pos.font_index, pos.glyph_id);
        const mtsdf_glyph = blk: {
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
                const empty = emptyMtsdfResult(allocator);
                try cache.put(allocator, cache_key, empty);
                break :blk empty;
            }
            var outline = outline_opt.?;
            defer outline.deinit();
            const glyph_scale = options.pixel_size / @as(f32, @floatFromInt(glyph_font.getUnitsPerEm()));
            const generated = try generateGlyphMtsdf(allocator, outline, glyph_scale, .{ .spread = options.spread });
            errdefer allocator.free(generated.pixels);
            try cache.put(allocator, cache_key, generated);
            break :blk generated;
        };
        if (mtsdf_glyph.width == 0 or mtsdf_glyph.height == 0) continue;

        const bmp_x0 = pos.x_offset + pad - mtsdf_glyph.offset_x;
        const bmp_y0 = base_baseline_y + pos.y_offset - mtsdf_glyph.offset_y;
        const clip = sdf_mod.clipGlyphRect(bmp_x0, bmp_y0, bmp_width, bmp_height, mtsdf_glyph.width, mtsdf_glyph.height);

        // This is a documented MTSDF limitation: overlapping glyphs are max-blended
        // per channel, not recolored as one combined outline.
        var gy = clip.gy_start;
        while (gy < clip.gy_end) : (gy += 1) {
            const dy: u32 = @intCast(clip.dst_y0 + @as(i64, gy));
            var gx = clip.gx_start;
            while (gx < clip.gx_end) : (gx += 1) {
                const dx: u32 = @intCast(clip.dst_x0 + @as(i64, gx));
                const src_idx = (gy * @as(usize, mtsdf_glyph.width) + gx) * 4;
                const dst_idx = (@as(usize, dy) * @as(usize, bmp_width) + @as(usize, dx)) * 4;
                inline for (0..4) |c| {
                    if (mtsdf_glyph.pixels[src_idx + c] > bitmap.pixels[dst_idx + c]) bitmap.pixels[dst_idx + c] = mtsdf_glyph.pixels[src_idx + c];
                }
            }
        }
    }
    return bitmap;
}

test "generateGlyphMtsdf: synthetic square colors and alpha" {
    const allocator = std.testing.allocator;
    var points: [4]glyph_mod.Point = undefined;
    var contours: [1]glyph_mod.Contour = undefined;
    const outline = sdf_mod.testSquareOutline(&contours, &points, allocator);

    var mtsdf = try generateGlyphMtsdf(allocator, outline, 0.1, .{ .spread = 8.0 });
    defer mtsdf.deinit();
    var sdf = try sdf_mod.generateGlyphSdf(allocator, outline, 0.1, .{ .spread = 8.0 });
    defer sdf.deinit();
    try std.testing.expectEqual(sdf.width, mtsdf.width);
    try std.testing.expectEqual(sdf.height, mtsdf.height);

    const cx: usize = mtsdf.width / 2;
    const cy: usize = mtsdf.height / 2;
    const center = (cy * @as(usize, mtsdf.width) + cx) * 4;
    try std.testing.expectEqual(@as(u8, 255), median3(mtsdf.pixels[center], mtsdf.pixels[center + 1], mtsdf.pixels[center + 2]));
    try std.testing.expectEqual(@as(u8, 0), median3(mtsdf.pixels[0], mtsdf.pixels[1], mtsdf.pixels[2]));
    for (sdf.pixels, 0..) |a, i| try std.testing.expectEqual(a, mtsdf.pixels[i * 4 + 3]);

    const scaled = try outline_mod.scaleOutline(allocator, outline, 0.1, mtsdf.offset_x, mtsdf.offset_y);
    defer outline_mod.freeScaledContours(allocator, scaled);
    var decomposed = try outline_mod.decomposeContourEdges(allocator, scaled[0]);
    defer decomposed.deinit();
    const runs = decomposed.runs;
    const corners = try detectCorners(allocator, runs);
    defer allocator.free(corners);
    try std.testing.expectEqual(@as(usize, 4), corners.len);
    applyEdgeColoringSimple(runs, corners);
    for (runs, 0..) |run, i| {
        const next = runs[(i + 1) % runs.len];
        try std.testing.expect(run.channels != next.channels);
        try std.testing.expect((run.channels & next.channels) != 0);
    }
}

test "generateGlyphMtsdf: square corner remains outside by median" {
    const allocator = std.testing.allocator;
    var points: [4]glyph_mod.Point = undefined;
    var contours: [1]glyph_mod.Contour = undefined;
    const outline = sdf_mod.testSquareOutline(&contours, &points, allocator);
    var mtsdf = try generateGlyphMtsdf(allocator, outline, 0.1, .{ .spread = 8.0 });
    defer mtsdf.deinit();
    const idx = (7 * @as(usize, mtsdf.width) + 7) * 4;
    try std.testing.expect(median3(mtsdf.pixels[idx], mtsdf.pixels[idx + 1], mtsdf.pixels[idx + 2]) < 128);
}

test "MTSDF edge coloring simple variants" {
    const allocator = std.testing.allocator;
    var runs = [_]outline_mod.EdgeRun{
        .{ .segments = &.{}, .dir_start = .{ 1, 0 }, .dir_end = .{ 1, 0 } },
        .{ .segments = &.{}, .dir_start = .{ 1, 0 }, .dir_end = .{ 1, 0 } },
        .{ .segments = &.{}, .dir_start = .{ 1, 0 }, .dir_end = .{ 1, 0 } },
        .{ .segments = &.{}, .dir_start = .{ 1, 0 }, .dir_end = .{ 1, 0 } },
    };
    const no_corners = try detectCorners(allocator, &runs);
    defer allocator.free(no_corners);
    try std.testing.expectEqual(@as(usize, 0), no_corners.len);
    applyEdgeColoringSimple(&runs, no_corners);
    for (runs) |run| try std.testing.expectEqual(color_white, run.channels);

    const one = [_]usize{0};
    applyEdgeColoringSimple(&runs, &one);
    var has_magenta = false;
    var has_yellow = false;
    var has_cyan = false;
    for (runs) |run| {
        has_magenta = has_magenta or run.channels == color_magenta;
        has_yellow = has_yellow or run.channels == color_yellow;
        has_cyan = has_cyan or run.channels == color_cyan;
    }
    try std.testing.expect(has_magenta and has_yellow and has_cyan);
    const four = [_]usize{ 0, 1, 2, 3 };
    applyEdgeColoringSimple(&runs, &four);
    for (runs, 0..) |run, i| try std.testing.expect(run.channels != runs[(i + 1) % runs.len].channels);
}

fn expectMtsdfMatchesCoverage(allocator: std.mem.Allocator, font_data: []const u8, cp: u21) !void {
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const glyph_id = try font.getGlyphId(cp);
    var outline = (try font.getGlyphOutline(allocator, glyph_id)).?;
    defer outline.deinit();
    const scale = 64.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    const spread: f32 = 8.0;
    const pad: u32 = @intFromFloat(sdf_mod.sdfPad(spread));
    var mtsdf = try generateGlyphMtsdf(allocator, outline, scale, .{ .spread = spread });
    defer mtsdf.deinit();
    var raster = try rasterizer_mod.rasterizeGlyph(allocator, outline, scale, pad, .{});
    defer raster.deinit();
    try std.testing.expectEqual(raster.width, mtsdf.width);
    try std.testing.expectEqual(raster.height, mtsdf.height);
    var mismatches: usize = 0;
    for (0..mtsdf.height) |y| {
        for (0..mtsdf.width) |x| {
            const i = y * @as(usize, mtsdf.width) + x;
            const m = median3(mtsdf.pixels[i * 4], mtsdf.pixels[i * 4 + 1], mtsdf.pixels[i * 4 + 2]);
            const cov = raster.pixels[i];
            if (m >= 160 and cov == 0) mismatches += 1;
            if (m <= 96 and cov != 0) mismatches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "generateGlyphMtsdf: TT DejaVu A matches raster coverage" {
    try expectMtsdfMatchesCoverage(std.testing.allocator, @embedFile("../fixture/DejaVuSans.ttf"), 'A');
}

test "generateGlyphMtsdf: CFF SourceSans3 A matches raster coverage" {
    if (comptime !ft.enable_cff) return error.SkipZigTest;
    try expectMtsdfMatchesCoverage(std.testing.allocator, @embedFile("../fixture/SourceSans3-Regular.otf"), 'A');
}

test "renderTextMtsdf: basic bitmap shape for AB" {
    const allocator = std.testing.allocator;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const fonts = [_]font_mod.Font{font};
    var bitmap = try renderTextMtsdf(allocator, &fonts, "AB", .{ .pixel_size = 128.0, .spread = 8.0 });
    defer bitmap.deinit();
    try std.testing.expect(bitmap.width > 0 and bitmap.height > 0);
    var has_inside = false;
    var has_outside = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        const m = median3(bitmap.pixels[i], bitmap.pixels[i + 1], bitmap.pixels[i + 2]);
        if (m >= 200) has_inside = true;
        if (m <= 50) has_outside = true;
    }
    try std.testing.expect(has_inside);
    try std.testing.expect(has_outside);
}

test "renderTextMtsdf: variation coords change output" {
    if (comptime !ft.enable_variable) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const font_data = @embedFile("../fixture/SourceSans3VF-Subset.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const fonts = [_]font_mod.Font{font};
    var bitmap_default = try renderTextMtsdf(allocator, &fonts, "A", .{ .pixel_size = 96.0, .spread = 8.0 });
    defer bitmap_default.deinit();
    // Same contract note as sdf.zig's equivalent test: apply avar directly to
    // this raw axis value, since normalized_coords expects final (already
    // avar-mapped) coordinates.
    var normalized = [_]f32{1.0};
    if (font.avar) |avar| try avar.mapNormalizedCoords(&normalized);
    var bitmap_bold = try renderTextMtsdf(allocator, &fonts, "A", .{ .pixel_size = 96.0, .spread = 8.0, .normalized_coords = &normalized });
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

test "generateGlyphMtsdf: 'O' counter (hole) stays outside" {
    try expectMtsdfMatchesCoverage(std.testing.allocator, @embedFile("../fixture/DejaVuSans.ttf"), 'O');
}

test "generateGlyphMtsdf: CFF 'O' counter (hole) stays outside" {
    if (comptime !ft.enable_cff) return error.SkipZigTest;
    try expectMtsdfMatchesCoverage(std.testing.allocator, @embedFile("../fixture/SourceSans3-Regular.otf"), 'O');
}

test "generateGlyphMtsdf: RGB channels genuinely diverge from a plain SDF" {
    // Regression guard for the inverted-side-sign bug: with the sign wrong, the
    // median/alpha error correction flattens nearly the whole spread band to
    // r=g=b (a plain SDF copied into three channels) and only a handful of
    // texels keep distinct channels. With the sign right, thousands of band
    // texels carry distinct per-channel pseudo-distances. Assert a floor well
    // above the broken state (measured: ~2350 divergent with the fix, ~30
    // without, DejaVu 'A' at 64px / spread 8).
    const allocator = std.testing.allocator;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const glyph_id = try font.getGlyphId('A');
    var outline = (try font.getGlyphOutline(allocator, glyph_id)).?;
    defer outline.deinit();
    const scale = 64.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    var mtsdf = try generateGlyphMtsdf(allocator, outline, scale, .{ .spread = 8.0 });
    defer mtsdf.deinit();

    var divergent: usize = 0;
    var i: usize = 0;
    while (i < mtsdf.pixels.len) : (i += 4) {
        const r = mtsdf.pixels[i];
        const g = mtsdf.pixels[i + 1];
        const b = mtsdf.pixels[i + 2];
        if (@max(r, @max(g, b)) - @min(r, @min(g, b)) > 32) divergent += 1;
    }
    try std.testing.expect(divergent > 500);
}

test "generateGlyphMtsdf: median reconstructs the corner sharper than the SDF" {
    // At a texel diagonally outside a square corner, the true shape distance is
    // the Chebyshev-ish corner distance the channel median reconstructs, while
    // the single-channel SDF only knows the (larger) Euclidean corner distance
    // and rounds the corner off. The median must therefore sit strictly closer
    // to the contour value (i.e. read higher) than the SDF byte there.
    const allocator = std.testing.allocator;
    var points: [4]glyph_mod.Point = undefined;
    var contours: [1]glyph_mod.Contour = undefined;
    const outline = sdf_mod.testSquareOutline(&contours, &points, allocator);
    var mtsdf = try generateGlyphMtsdf(allocator, outline, 0.1, .{ .spread = 8.0 });
    defer mtsdf.deinit();
    var sdf = try sdf_mod.generateGlyphSdf(allocator, outline, 0.1, .{ .spread = 8.0 });
    defer sdf.deinit();

    // Square spans [9,49]x[9,49]; texel (7,7) is ~1.5px diagonally outside the
    // (9,9) corner: pseudo-distances see 1.5px per axis, the SDF sees ~2.12px.
    const flat = 7 * @as(usize, mtsdf.width) + 7;
    const m = median3(mtsdf.pixels[flat * 4], mtsdf.pixels[flat * 4 + 1], mtsdf.pixels[flat * 4 + 2]);
    try std.testing.expect(m < 128); // still outside...
    try std.testing.expect(m > sdf.pixels[flat]); // ...but sharper than the SDF
}

test "renderTextMtsdf: vertical layout basic bitmap shape" {
    if (comptime !ft.enable_vertical) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();
    const fonts = [_]font_mod.Font{font};
    var bitmap = try renderTextMtsdf(allocator, &fonts, "AB", .{ .pixel_size = 128.0, .spread = 8.0, .vertical = true });
    defer bitmap.deinit();
    // Vertical stacking: taller than wide.
    try std.testing.expect(bitmap.height > bitmap.width);
    var has_inside = false;
    var has_outside = false;
    var i: usize = 0;
    while (i < bitmap.pixels.len) : (i += 4) {
        const m = median3(bitmap.pixels[i], bitmap.pixels[i + 1], bitmap.pixels[i + 2]);
        if (m >= 200) has_inside = true;
        if (m <= 50) has_outside = true;
    }
    try std.testing.expect(has_inside);
    try std.testing.expect(has_outside);
}

test "MtsdfResult rejects invalid spread" {
    const allocator = std.testing.allocator;
    var points: [4]glyph_mod.Point = undefined;
    var contours: [1]glyph_mod.Contour = undefined;
    const outline = sdf_mod.testSquareOutline(&contours, &points, allocator);
    try std.testing.expectError(error.InvalidSdfSpread, generateGlyphMtsdf(allocator, outline, 0.1, .{ .spread = 0 }));
}
