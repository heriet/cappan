const std = @import("std");
const outline_mod = @import("outline.zig");
const analytical_mod = @import("analytical.zig");

pub const Edge = struct {
    y_top: f32,
    y_bottom: f32,
    x_at_y_top: f32,
    dx_per_dy: f32,
    direction: i8, // +1 downward, -1 upward
};

pub const AntiAliasLevel = enum(u6) {
    aa_4 = 4,
    aa_8 = 8,
    aa_16 = 16,
    aa_32 = 32,

    pub fn toSampleCount(self: AntiAliasLevel) usize {
        return @intFromEnum(self);
    }
};

pub const SamplePattern = enum {
    regular,
    rotated_grid,
};

/// Per-row adaptive AA: each row is first sampled at `low_level`; if that row's
/// coverage shows partial (non-0/non-max) values anywhere -- i.e. an edge crosses
/// it -- the row is re-sampled at `high_level` and the edge pixels use the finer
/// result (flat interior/exterior pixels keep the cheap low-resolution verdict).
///
/// This is a *row*-granularity decision, not a pixel- or tile-granularity one.
/// For inputs with large flat regions (a filled rectangle, a wide fill area) most
/// rows are either all-empty or all-full and stay cheap. For small glyph-sized
/// inputs, nearly every row an edge touches also has other edges on it, so nearly
/// every row ends up re-sampled at `high_level` *in addition to* the initial
/// `low_level` pass -- i.e. it can cost more than simply using `high_level`
/// (or even a non-adaptive fixed level) directly. Prefer a fixed `aa_level`
/// for glyph rendering; this option is best suited to inputs with substantial
/// flat coverage.
pub const AdaptiveOptions = struct {
    low_level: AntiAliasLevel = .aa_4,
    high_level: AntiAliasLevel = .aa_32,
};

pub const RasterMethod = enum {
    supersampling,
    analytical,
};

pub const RasterOptions = struct {
    aa_level: AntiAliasLevel = .aa_8,
    sample_pattern: SamplePattern = .regular,
    adaptive: ?AdaptiveOptions = null,
    method: RasterMethod = .supersampling,
    embolden_strength: f32 = 0.0,
};

fn sampleXOffset(pattern: SamplePattern, sample_idx: usize, sample_count: usize) f32 {
    return switch (pattern) {
        .regular => 0.0,
        .rotated_grid => blk: {
            var reversed: usize = 0;
            var bits = sample_idx;
            var remaining = sample_count;
            while (remaining > 1) {
                remaining >>= 1;
                reversed = (reversed << 1) | (bits & 1);
                bits >>= 1;
            }
            break :blk (@as(f32, @floatFromInt(reversed)) + 0.5) / @as(f32, @floatFromInt(sample_count));
        },
    };
}

/// Shared by buildEdges (fresh allocation) and the scratch-reuse path in
/// rasterize (existing list cleared and refilled): both must run this exact
/// same filter/compute logic to stay byte-identical to each other.
fn buildEdgesInto(list: *std.ArrayList(Edge), allocator: std.mem.Allocator, segments: []const outline_mod.Segment) !void {
    list.clearRetainingCapacity();

    for (segments) |seg| {
        // Skip any segment with a non-finite coordinate (NaN or +/-inf) before
        // anything else. This isn't reachable from well-formed font outlines
        // (glyph coordinates are always finite), but it's cheap defense for this
        // pub API: a NaN intersection x would make the span-walk's equal-x
        // grouping loop (`intersections[idx].x == group_x`) never advance --
        // NaN != NaN is always true, so `idx` never reaches `.items.len` and
        // rasterizeRowCoverage hangs forever. An infinite endpoint produces
        // dx_per_dy = inf/inf = NaN below, hitting the same hang, and separately
        // a non-finite x downstream would violate @intFromFloat's safety
        // contract in spanStartPixel/spanEndPixel (undefined behavior, not just
        // a wrong answer). Filtering here, before any arithmetic on the
        // coordinates, prevents both.
        if (!std.math.isFinite(seg.x0) or !std.math.isFinite(seg.y0) or
            !std.math.isFinite(seg.x1) or !std.math.isFinite(seg.y1)) continue;

        // Skip near-horizontal edges
        const dy = seg.y1 - seg.y0;
        if (@abs(dy) < 0.001) continue;

        var y_top: f32 = undefined;
        var y_bottom: f32 = undefined;
        var x_at_top: f32 = undefined;
        var direction: i8 = undefined;

        if (seg.y0 < seg.y1) {
            // Going down
            y_top = seg.y0;
            y_bottom = seg.y1;
            x_at_top = seg.x0;
            direction = 1;
        } else {
            // Going up
            y_top = seg.y1;
            y_bottom = seg.y0;
            x_at_top = seg.x1;
            direction = -1;
        }

        // dx_per_dy: for downward edges (direction=1), x_at_top is x0 and we walk forward in y.
        // For upward edges (direction=-1), x_at_top is x1 and we walk forward in y from y1 to y0.
        // In both cases, (x1-x0)/dy gives the correct slope when walking from y_top to y_bottom.
        const dx_per_dy = (seg.x1 - seg.x0) / dy;

        try list.append(allocator, .{
            .y_top = y_top,
            .y_bottom = y_bottom,
            .x_at_y_top = x_at_top,
            .dx_per_dy = dx_per_dy,
            .direction = direction,
        });
    }
}

pub fn buildEdges(allocator: std.mem.Allocator, segments: []const outline_mod.Segment) ![]Edge {
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);
    try buildEdgesInto(&edges, allocator, segments);
    return edges.toOwnedSlice(allocator);
}

pub const Intersection = struct {
    x: f32,
    direction: i8,
};

fn compareIntersections(_: void, a: Intersection, b: Intersection) bool {
    return a.x < b.x;
}

fn compareEdgesByYTop(_: void, a: Edge, b: Edge) bool {
    return a.y_top < b.y_top;
}

/// Active Edge Table cursor over a y_top-sorted edge list (`sorted`). `advance`
/// moves the active set to whatever it should be for sub-scanline `sub_y`:
/// edges with `y_top <= sub_y` get activated (via the monotonic `next` cursor,
/// no rescan of already-activated edges), and any active edge with
/// `y_bottom <= sub_y` gets deactivated (swap-removed). This is exactly the
/// original per-subscanline predicate `sub_y >= edge.y_top and sub_y <
/// edge.y_bottom`, split into "activate when y_top <= sub_y" / "keep while
/// sub_y < y_bottom" -- an edge is active after `advance(sub_y)` iff that
/// predicate holds for `sub_y`. The AET only changes *which edges get
/// considered* at each sub-scanline (a search-space filter); it does not
/// change how any edge's x-intersection is computed (see rasterizeRowCoverage).
const SupersampleContext = struct {
    sorted: []Edge,
    next: usize = 0,
    active: *std.ArrayList(Edge),
    last_sub_y: f32 = -std.math.floatMax(f32),

    fn advance(self: *SupersampleContext, allocator: std.mem.Allocator, sub_y: f32) !void {
        if (sub_y < self.last_sub_y) {
            // Backward seek: only reachable from adaptive's high-resolution pass
            // re-walking a row the low-resolution pass already advanced past.
            // Rebuilding from the front costs at most O(E) for the row being
            // re-walked, the same bound the pre-AET per-subscanline full rescan
            // always paid every subscanline, so this is never worse.
            self.next = 0;
            self.active.clearRetainingCapacity();
        }
        self.last_sub_y = sub_y;

        while (self.next < self.sorted.len and self.sorted[self.next].y_top <= sub_y) : (self.next += 1) {
            try self.active.append(allocator, self.sorted[self.next]);
        }

        var i: usize = 0;
        while (i < self.active.items.len) {
            if (self.active.items[i].y_bottom <= sub_y) {
                _ = self.active.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// Smallest px such that `xs < @floatFromInt(px) + x_offset` -- the exact
/// predicate the original per-pixel walk uses (`intersection.x < px_left`),
/// evaluated at a span's opening x. Starts from a floor-based candidate purely
/// as a fast path and then corrects against the *exact* predicate (typically 0,
/// occasionally 1 iteration either way, from f32 rounding in `xs - x_offset`
/// vs. `px + x_offset`); the final value is always confirmed by the same
/// comparison the original algorithm made, so this cannot disagree with it.
// @intFromFloat into i64 is checked-illegal-behavior for a float outside
// [-2^63, 2^63); clamping to +/-2^31 first (far beyond any real bitmap
// dimension -- rasterizer.zig's glyphBitmapGeometry already rejects glyph
// bitmaps over 16384px) keeps the cast always in-range. Coordinates coming
// from bbox-consistent glyph rendering never approach this bound, so the
// clamp is a no-op there and this is purely a pub-API guard against a
// huge-but-finite f32 (not otherwise excluded by the NaN/inf filter in
// buildEdgesInto) reaching the cast.
const span_pixel_bound: f32 = 2147483648.0; // 2^31

/// Smallest px such that `xs < @floatFromInt(px) + x_offset` -- the exact
/// predicate the original per-pixel walk uses (`intersection.x < px_left`),
/// evaluated at a span's opening x. Starts from a floor-based candidate purely
/// as a fast path and then corrects against the *exact* predicate (typically 0,
/// occasionally 1 iteration either way, from f32 rounding in `xs - x_offset`
/// vs. `px + x_offset`); the final value is always confirmed by the same
/// comparison the original algorithm made, so this cannot disagree with it.
// Correction loops are capped: for bitmap-bounded coordinates (well below f32's
// 2^24 integer-precision limit) the floor candidate is off by at most 1, so the
// cap never binds. For pathological huge-but-finite coordinates the increments
// can stall below f32 precision (@floatFromInt(px) stops changing), which would
// otherwise loop unboundedly; a capped result lands far outside any real bitmap
// and fillSpan's clamp turns it into "no coverage" -- exactly what the original
// per-pixel walk produced for an intersection beyond the bitmap.
const span_correction_cap: u8 = 2;

fn spanStartPixel(xs: f32, x_offset: f32) i64 {
    const floor_val = @min(@max(@floor(xs - x_offset), -span_pixel_bound), span_pixel_bound);
    var px_start: i64 = @intFromFloat(floor_val);
    px_start += 1;
    var guard: u8 = 0;
    while (guard < span_correction_cap and px_start > 0 and xs < @as(f32, @floatFromInt(px_start - 1)) + x_offset) : (guard += 1) px_start -= 1;
    guard = 0;
    while (guard < span_correction_cap and !(xs < @as(f32, @floatFromInt(px_start)) + x_offset)) : (guard += 1) px_start += 1;
    return px_start;
}

/// Largest px such that `@floatFromInt(px) + x_offset <= xe` -- same fast-path-
/// then-exact-correction shape as spanStartPixel, for a span's closing x.
fn spanEndPixel(xe: f32, x_offset: f32) i64 {
    const floor_val = @min(@max(@floor(xe - x_offset), -span_pixel_bound), span_pixel_bound);
    var px_end: i64 = @intFromFloat(floor_val);
    var guard: u8 = 0;
    while (guard < span_correction_cap and @as(f32, @floatFromInt(px_end + 1)) + x_offset <= xe) : (guard += 1) px_end += 1;
    guard = 0;
    while (guard < span_correction_cap and px_end >= 0 and !(@as(f32, @floatFromInt(px_end)) + x_offset <= xe)) : (guard += 1) px_end -= 1;
    return px_end;
}

fn fillSpan(coverage: []u16, px_start_raw: i64, px_end_raw: i64) void {
    const w_i64: i64 = @intCast(coverage.len);
    const px_start = @max(@as(i64, 0), px_start_raw);
    const px_end = @min(w_i64 - 1, px_end_raw);
    if (px_start > px_end) return;
    var px: usize = @intCast(px_start);
    const px_max: usize = @intCast(px_end);
    while (px <= px_max) : (px += 1) {
        coverage[px] += 1;
    }
}

fn rasterizeRowCoverage(
    coverage: []u16,
    y: usize,
    n: usize,
    pattern: SamplePattern,
    ctx: *SupersampleContext,
    intersections: *std.ArrayList(Intersection),
    allocator: std.mem.Allocator,
) !void {
    @memset(coverage, 0);
    for (0..n) |s| {
        const sub_y = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, @floatFromInt(n));
        const x_offset = sampleXOffset(pattern, s, n);

        try ctx.advance(allocator, sub_y);

        intersections.clearRetainingCapacity();
        for (ctx.active.items) |edge| {
            // Exact per-line formula, recomputed in full for every sub-scanline --
            // deliberately NOT an incremental update (x += slope * delta_y).
            // Incremental accumulation would drift from this formula's rounding by
            // a different (path-dependent) amount every step, breaking byte
            // identity with the pre-AET output. The AET's speedup comes entirely
            // from `ctx.active` being a subset of all edges, not from cheapening
            // this computation.
            const x = edge.x_at_y_top + (sub_y - edge.y_top) * edge.dx_per_dy;
            try intersections.append(allocator, .{ .x = x, .direction = edge.direction });
        }

        std.mem.sort(Intersection, intersections.items, {}, compareIntersections);

        // Span-fill walk, equivalent to the original per-pixel walk ("consume
        // every intersection with x < px_left, coverage[px] += 1 iff the
        // resulting winding != 0"): walk the x-sorted intersections, grouping
        // consecutive equal-x ones (a correct sort always keeps tied keys
        // contiguous, regardless of which order this run's AET-active-order-
        // dependent input handed to std.mem.sort -- it is not stable) and
        // applying each group's combined direction as one step. This is safe
        // because the original's `x < px_left` test can only ever consume an
        // equal-x group atomically: identical x means identical truth value for
        // every px_left, so no px_left can observe a state "mid-group" -- and
        // integer addition of the group's directions is commutative, so which
        // internal order the tied members were summed in cannot change the
        // resulting winding value either. A span [xs, xe] with `xs < px_left <=
        // xe` gets +1 (see spanStartPixel/spanEndPixel), which is exactly the
        // set of px_left values whose accumulated-so-far winding (i.e. summing
        // only intersections with x strictly less than px_left) is nonzero.
        // Nested contours whose winding flips sign without passing through 0
        // (e.g. +1 -> -1 from a single group) keep the span open -- it only
        // closes when winding returns to exactly 0, matching the original
        // `winding != 0` coverage test exactly.
        var winding: i32 = 0;
        var span_open = false;
        var span_start_x: f32 = undefined;
        var idx: usize = 0;
        while (idx < intersections.items.len) {
            const group_x = intersections.items[idx].x;
            const winding_before = winding;
            while (idx < intersections.items.len and intersections.items[idx].x == group_x) : (idx += 1) {
                winding += intersections.items[idx].direction;
            }
            if (winding_before == 0 and winding != 0) {
                span_open = true;
                span_start_x = group_x;
            } else if (winding_before != 0 and winding == 0) {
                span_open = false;
                fillSpan(coverage, spanStartPixel(span_start_x, x_offset), spanEndPixel(group_x, x_offset));
            }
        }
        if (span_open) {
            // Unclosed at the end of this sub-scanline (winding never returns to
            // 0, e.g. malformed/self-intersecting geometry): the original loop
            // freezes `winding` for every remaining pixel once intersections run
            // out, so extend the span through the last column.
            fillSpan(coverage, spanStartPixel(span_start_x, x_offset), @as(i64, @intCast(coverage.len)) - 1);
        }
    }
}

/// Optional scratch buffers threaded through from rasterizer.zig's
/// RasterScratch, reused across calls instead of allocated fresh each time.
/// `cells` is analytical.zig's scratch, forwarded here rather than at
/// rasterizer.zig, since this function is the single dispatch point for both
/// raster methods.
pub const RasterizeScratch = struct {
    edges: *std.ArrayList(Edge),
    active: *std.ArrayList(Edge),
    intersections: *std.ArrayList(Intersection),
    coverage: *std.ArrayList(u16),
    coverage_high: *std.ArrayList(u16),
    cells: *std.ArrayList(analytical_mod.Cell),
};

pub fn rasterize(
    allocator: std.mem.Allocator,
    segments: []const outline_mod.Segment,
    width: u32,
    height: u32,
    options: RasterOptions,
    scratch: ?RasterizeScratch,
) ![]u8 {
    if (options.method == .analytical) {
        return analytical_mod.rasterize(allocator, segments, width, height, if (scratch) |s| s.cells else null);
    }

    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    var local_edges: std.ArrayList(Edge) = .empty;
    defer local_edges.deinit(allocator);
    const edges_list: *std.ArrayList(Edge) = if (scratch) |s| s.edges else &local_edges;
    try buildEdgesInto(edges_list, allocator, segments);

    if (edges_list.items.len == 0) return pixels;

    std.mem.sort(Edge, edges_list.items, {}, compareEdgesByYTop);

    var local_active: std.ArrayList(Edge) = .empty;
    defer local_active.deinit(allocator);
    const active_list: *std.ArrayList(Edge) = if (scratch) |s| s.active else &local_active;
    active_list.clearRetainingCapacity();
    var ctx: SupersampleContext = .{ .sorted = edges_list.items, .active = active_list };

    var local_intersections: std.ArrayList(Intersection) = .empty;
    defer local_intersections.deinit(allocator);
    const intersections_list: *std.ArrayList(Intersection) = if (scratch) |s| s.intersections else &local_intersections;

    const w = @as(usize, width);

    var local_coverage: std.ArrayList(u16) = .empty;
    defer local_coverage.deinit(allocator);
    const coverage_list: *std.ArrayList(u16) = if (scratch) |s| s.coverage else &local_coverage;
    try coverage_list.resize(allocator, w);
    const coverage = coverage_list.items;

    if (options.adaptive) |adaptive_opts| {
        const low_n = adaptive_opts.low_level.toSampleCount();
        const high_n = adaptive_opts.high_level.toSampleCount();

        var local_coverage_high: std.ArrayList(u16) = .empty;
        defer local_coverage_high.deinit(allocator);
        const coverage_high_list: *std.ArrayList(u16) = if (scratch) |s| s.coverage_high else &local_coverage_high;
        try coverage_high_list.resize(allocator, w);
        const coverage_high = coverage_high_list.items;

        for (0..height) |y| {
            try rasterizeRowCoverage(coverage, y, low_n, options.sample_pattern, &ctx, intersections_list, allocator);

            var has_edge = false;
            for (0..w) |px| {
                if (coverage[px] > 0 and coverage[px] < @as(u16, @intCast(low_n))) {
                    has_edge = true;
                    break;
                }
            }

            if (has_edge) {
                try rasterizeRowCoverage(coverage_high, y, high_n, options.sample_pattern, &ctx, intersections_list, allocator);
                for (0..w) |px| {
                    if (coverage[px] > 0 and coverage[px] < @as(u16, @intCast(low_n))) {
                        pixels[y * w + px] = @as(u8, @intCast(@min(coverage_high[px] * 255 / @as(u16, @intCast(high_n)), 255)));
                    } else {
                        pixels[y * w + px] = if (coverage[px] == 0) 0 else 255;
                    }
                }
            } else {
                for (0..w) |px| {
                    pixels[y * w + px] = if (coverage[px] == 0) 0 else 255;
                }
            }
        }
    } else {
        const n = options.aa_level.toSampleCount();
        for (0..height) |y| {
            try rasterizeRowCoverage(coverage, y, n, options.sample_pattern, &ctx, intersections_list, allocator);
            for (0..w) |px| {
                const value = @as(u8, @intCast(@min(coverage[px] * 255 / @as(u16, @intCast(n)), 255)));
                pixels[y * w + px] = value;
            }
        }
    }

    return pixels;
}

test "rasterize a simple triangle" {
    // Triangle covering roughly the center of a 16x16 bitmap
    const segments = [_]outline_mod.Segment{
        .{ .x0 = 8, .y0 = 2, .x1 = 14, .y1 = 14 },
        .{ .x0 = 14, .y0 = 14, .x1 = 2, .y1 = 14 },
        .{ .x0 = 2, .y0 = 14, .x1 = 8, .y1 = 2 },
    };

    const pixels = try rasterize(std.testing.allocator, &segments, 16, 16, .{}, null);
    defer std.testing.allocator.free(pixels);

    // Center pixels should have non-zero coverage
    try std.testing.expect(pixels[8 * 16 + 8] > 0);

    // Corner pixels should be zero (outside triangle)
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
}

// --- Reference implementation for T1 (byte-for-byte pre-AET/span-fill
// equivalence). This is a verbatim port of rasterize()'s row-coverage
// algorithm as it existed before the AET + span-fill refactor: a fresh full
// edge list, a per-subscanline full rescan of every edge (no active-edge-
// table cursor), and a per-pixel walk that consumes intersections with
// `x < px_left` one at a time. It deliberately does not call
// buildEdgesInto/SupersampleContext/spanStartPixel/spanEndPixel/fillSpan, so
// it cannot share a bug with the code under test. Test-only.

fn referenceBuildEdges(allocator: std.mem.Allocator, segments: []const outline_mod.Segment) ![]Edge {
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);

    for (segments) |seg| {
        const dy = seg.y1 - seg.y0;
        if (@abs(dy) < 0.001) continue;

        var y_top: f32 = undefined;
        var y_bottom: f32 = undefined;
        var x_at_top: f32 = undefined;
        var direction: i8 = undefined;

        if (seg.y0 < seg.y1) {
            y_top = seg.y0;
            y_bottom = seg.y1;
            x_at_top = seg.x0;
            direction = 1;
        } else {
            y_top = seg.y1;
            y_bottom = seg.y0;
            x_at_top = seg.x1;
            direction = -1;
        }

        const dx_per_dy = (seg.x1 - seg.x0) / dy;

        try edges.append(allocator, .{
            .y_top = y_top,
            .y_bottom = y_bottom,
            .x_at_y_top = x_at_top,
            .dx_per_dy = dx_per_dy,
            .direction = direction,
        });
    }

    return edges.toOwnedSlice(allocator);
}

fn referenceRasterizeRowCoverage(
    coverage: []u16,
    y: usize,
    n: usize,
    pattern: SamplePattern,
    edges: []const Edge,
    intersections: *std.ArrayList(Intersection),
    allocator: std.mem.Allocator,
) !void {
    @memset(coverage, 0);
    for (0..n) |s| {
        const sub_y = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, @floatFromInt(n));
        const x_offset = sampleXOffset(pattern, s, n);

        intersections.clearRetainingCapacity();
        for (edges) |edge| {
            if (sub_y >= edge.y_top and sub_y < edge.y_bottom) {
                const x = edge.x_at_y_top + (sub_y - edge.y_top) * edge.dx_per_dy;
                try intersections.append(allocator, .{ .x = x, .direction = edge.direction });
            }
        }

        std.mem.sort(Intersection, intersections.items, {}, compareIntersections);

        var winding: i32 = 0;
        var ix_idx: usize = 0;
        for (0..coverage.len) |px| {
            const px_left = @as(f32, @floatFromInt(px)) + x_offset;
            while (ix_idx < intersections.items.len and intersections.items[ix_idx].x < px_left) {
                winding += intersections.items[ix_idx].direction;
                ix_idx += 1;
            }
            if (winding != 0) {
                coverage[px] += 1;
            }
        }
    }
}

fn referenceRasterize(
    allocator: std.mem.Allocator,
    segments: []const outline_mod.Segment,
    width: u32,
    height: u32,
    options: RasterOptions,
) ![]u8 {
    if (options.method == .analytical) {
        return analytical_mod.rasterize(allocator, segments, width, height, null);
    }

    const pixels = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    const edges = try referenceBuildEdges(allocator, segments);
    defer allocator.free(edges);

    if (edges.len == 0) return pixels;

    var intersections: std.ArrayList(Intersection) = .empty;
    defer intersections.deinit(allocator);

    const w = @as(usize, width);
    const coverage = try allocator.alloc(u16, w);
    defer allocator.free(coverage);

    if (options.adaptive) |adaptive_opts| {
        const low_n = adaptive_opts.low_level.toSampleCount();
        const high_n = adaptive_opts.high_level.toSampleCount();
        const coverage_high = try allocator.alloc(u16, w);
        defer allocator.free(coverage_high);

        for (0..height) |y| {
            try referenceRasterizeRowCoverage(coverage, y, low_n, options.sample_pattern, edges, &intersections, allocator);

            var has_edge = false;
            for (0..w) |px| {
                if (coverage[px] > 0 and coverage[px] < @as(u16, @intCast(low_n))) {
                    has_edge = true;
                    break;
                }
            }

            if (has_edge) {
                try referenceRasterizeRowCoverage(coverage_high, y, high_n, options.sample_pattern, edges, &intersections, allocator);
                for (0..w) |px| {
                    if (coverage[px] > 0 and coverage[px] < @as(u16, @intCast(low_n))) {
                        pixels[y * w + px] = @as(u8, @intCast(@min(coverage_high[px] * 255 / @as(u16, @intCast(high_n)), 255)));
                    } else {
                        pixels[y * w + px] = if (coverage[px] == 0) 0 else 255;
                    }
                }
            } else {
                for (0..w) |px| {
                    pixels[y * w + px] = if (coverage[px] == 0) 0 else 255;
                }
            }
        }
    } else {
        const n = options.aa_level.toSampleCount();
        for (0..height) |y| {
            try referenceRasterizeRowCoverage(coverage, y, n, options.sample_pattern, edges, &intersections, allocator);
            for (0..w) |px| {
                const value = @as(u8, @intCast(@min(coverage[px] * 255 / @as(u16, @intCast(n)), 255)));
                pixels[y * w + px] = value;
            }
        }
    }

    return pixels;
}

const test_shape_triangle = [_]outline_mod.Segment{
    .{ .x0 = 8, .y0 = 2, .x1 = 14, .y1 = 14 },
    .{ .x0 = 14, .y0 = 14, .x1 = 2, .y1 = 14 },
    .{ .x0 = 2, .y0 = 14, .x1 = 8, .y1 = 2 },
};

const test_shape_rect_integer = [_]outline_mod.Segment{
    .{ .x0 = 4, .y0 = 3, .x1 = 4, .y1 = 13 },
    .{ .x0 = 4, .y0 = 13, .x1 = 12, .y1 = 13 },
    .{ .x0 = 12, .y0 = 13, .x1 = 12, .y1 = 3 },
    .{ .x0 = 12, .y0 = 3, .x1 = 4, .y1 = 3 },
};

const test_shape_overlap_squares = [_]outline_mod.Segment{
    // square A
    .{ .x0 = 2, .y0 = 2, .x1 = 10, .y1 = 2 },
    .{ .x0 = 10, .y0 = 2, .x1 = 10, .y1 = 10 },
    .{ .x0 = 10, .y0 = 10, .x1 = 2, .y1 = 10 },
    .{ .x0 = 2, .y0 = 10, .x1 = 2, .y1 = 2 },
    // square B, same winding handedness as A -- the overlap region (roughly
    // x/y in [6,10]) has winding magnitude 2, not 0.
    .{ .x0 = 6, .y0 = 6, .x1 = 14, .y1 = 6 },
    .{ .x0 = 14, .y0 = 6, .x1 = 14, .y1 = 14 },
    .{ .x0 = 14, .y0 = 14, .x1 = 6, .y1 = 14 },
    .{ .x0 = 6, .y0 = 14, .x1 = 6, .y1 = 6 },
};

const test_shape_nested_hole = [_]outline_mod.Segment{
    // outer square
    .{ .x0 = 2, .y0 = 2, .x1 = 14, .y1 = 2 },
    .{ .x0 = 14, .y0 = 2, .x1 = 14, .y1 = 14 },
    .{ .x0 = 14, .y0 = 14, .x1 = 2, .y1 = 14 },
    .{ .x0 = 2, .y0 = 14, .x1 = 2, .y1 = 2 },
    // inner square, opposite winding handedness from the outer one -- cuts a
    // hole (winding returns to 0 inside it) instead of doubling up.
    .{ .x0 = 5, .y0 = 5, .x1 = 5, .y1 = 11 },
    .{ .x0 = 5, .y0 = 11, .x1 = 11, .y1 = 11 },
    .{ .x0 = 11, .y0 = 11, .x1 = 11, .y1 = 5 },
    .{ .x0 = 11, .y0 = 5, .x1 = 5, .y1 = 5 },
};

// Vertical edges at x = 4.125 and x = 11.375: these are exactly px + the
// aa_4 rotated-grid sample offsets 0.125 and 0.375 for px=4 and px=11
// respectively (see sampleXOffset's bit-reversed aa_4 outputs: 0.125, 0.625,
// 0.375, 0.875), so spanStartPixel/spanEndPixel's boundary predicate
// (`xs < px + x_offset`) is forced to resolve an exact tie rather than a
// nearby value for at least one sub-scanline sample under rotated_grid.
const test_shape_rect_rotated_boundary = [_]outline_mod.Segment{
    .{ .x0 = 4.125, .y0 = 2, .x1 = 4.125, .y1 = 14 },
    .{ .x0 = 4.125, .y0 = 14, .x1 = 11.375, .y1 = 14 },
    .{ .x0 = 11.375, .y0 = 14, .x1 = 11.375, .y1 = 2 },
    .{ .x0 = 11.375, .y0 = 2, .x1 = 4.125, .y1 = 2 },
};

test "T1/T2: rasterize matches pre-AET reference across shapes x aa levels x patterns x adaptive" {
    const allocator = std.testing.allocator;
    const shapes = [_][]const outline_mod.Segment{
        &test_shape_triangle,
        &test_shape_rect_integer,
        &test_shape_overlap_squares,
        &test_shape_nested_hole,
        &test_shape_rect_rotated_boundary,
    };
    const aa_levels = [_]AntiAliasLevel{ .aa_4, .aa_8, .aa_32 };
    const patterns = [_]SamplePattern{ .regular, .rotated_grid };
    // null = adaptive off, .{} = adaptive on with defaults (low=aa_4/high=aa_32).
    // Every shape above leaves rows 0-1 and 15 fully edge-free alongside rows
    // that do have edges, so this matrix also exercises adaptive's
    // has_edge=false path on every (shape, pattern) combination (T2).
    const adaptive_variants = [_]?AdaptiveOptions{ null, .{} };

    const width: u32 = 16;
    const height: u32 = 16;

    for (shapes) |segments| {
        for (aa_levels) |aa| {
            for (patterns) |pattern| {
                for (adaptive_variants) |adaptive| {
                    const options: RasterOptions = .{
                        .aa_level = aa,
                        .sample_pattern = pattern,
                        .adaptive = adaptive,
                    };

                    const got = try rasterize(allocator, segments, width, height, options, null);
                    defer allocator.free(got);

                    const want = try referenceRasterize(allocator, segments, width, height, options);
                    defer allocator.free(want);

                    try std.testing.expectEqualSlices(u8, want, got);
                }
            }
        }
    }
}

test "T3: RasterScratch reused across a mixed sequence matches scratch-less output" {
    const allocator = std.testing.allocator;
    const font_mod = @import("../font/font.zig");
    const rasterizer_mod = @import("rasterizer.zig");

    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId(0x0041); // 'A'
    const outline_opt = try font.getGlyphOutline(allocator, glyph_id);
    try std.testing.expect(outline_opt != null);
    var outline = outline_opt.?;
    defer outline.deinit();

    const units_per_em = @as(f32, @floatFromInt(font.getUnitsPerEm()));

    const Step = struct {
        size: f32,
        method: RasterMethod,
    };
    // supersampling small -> analytical large -> supersampling large -> analytical small:
    // deliberately alternates method and size so the scratch's buffers are
    // grown, shrunk, and switched between the two producers' shapes in sequence.
    const steps = [_]Step{
        .{ .size = 16, .method = .supersampling },
        .{ .size = 160, .method = .analytical },
        .{ .size = 160, .method = .supersampling },
        .{ .size = 16, .method = .analytical },
    };

    var scratch: rasterizer_mod.RasterScratch = .{};
    defer scratch.deinit(allocator);

    for (steps) |step| {
        const scale = step.size / units_per_em;
        const options: RasterOptions = .{ .method = step.method };

        var with_scratch = try rasterizer_mod.rasterizeGlyphWithScratch(allocator, outline, scale, 1, options, &scratch);
        defer with_scratch.deinit();

        var without_scratch = try rasterizer_mod.rasterizeGlyph(allocator, outline, scale, 1, options);
        defer without_scratch.deinit();

        try std.testing.expectEqual(without_scratch.width, with_scratch.width);
        try std.testing.expectEqual(without_scratch.height, with_scratch.height);
        try std.testing.expectEqualSlices(u8, without_scratch.pixels, with_scratch.pixels);
    }
}

test "T4: non-finite segment coordinates do not hang or panic" {
    const allocator = std.testing.allocator;
    const nan_f: f32 = std.math.nan(f32);
    const inf_f: f32 = std.math.inf(f32);

    // A mix of NaN- and inf-tainted segments alongside a normal well-formed
    // triangle, for both raster methods. Without FIX 1 (the non-finite filter
    // in buildEdgesInto), the supersampling path here hangs forever: a NaN
    // intersection x makes the span-walk's equal-x grouping loop never
    // advance `idx` (NaN == NaN is always false), so the outer while loop
    // never terminates. This test is that regression's guard.
    const segments = [_]outline_mod.Segment{
        .{ .x0 = nan_f, .y0 = 0, .x1 = 5, .y1 = 10 },
        .{ .x0 = 0, .y0 = inf_f, .x1 = 5, .y1 = 10 },
        .{ .x0 = 2, .y0 = 2, .x1 = -inf_f, .y1 = 12 },
        .{ .x0 = 8, .y0 = 2, .x1 = 14, .y1 = 14 },
        .{ .x0 = 14, .y0 = 14, .x1 = 2, .y1 = 14 },
        .{ .x0 = 2, .y0 = 14, .x1 = 8, .y1 = 2 },
    };

    const methods = [_]RasterMethod{ .supersampling, .analytical };
    for (methods) |method| {
        const options: RasterOptions = .{ .method = method };
        const pixels = try rasterize(allocator, &segments, 16, 16, options, null);
        defer allocator.free(pixels);
        try std.testing.expectEqual(@as(usize, 16 * 16), pixels.len);
    }
}
