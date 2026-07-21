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

    /// log2 of the sample count (4/8/16/32 -> 2/3/4/5); see quantizeToU8's
    /// doc for why this makes quantization an exact right shift.
    pub fn log2SampleCount(self: AntiAliasLevel) u5 {
        return @intCast(@ctz(@intFromEnum(self)));
    }
};

/// Sub-scanline x sample position for `.supersampling`. `.regular`
/// point-samples every sub-scanline at the pixel's *left edge* (x_offset = 0)
/// -- this is why plain supersampling has no horizontal antialiasing on
/// vertical edges (a vertical edge inside a pixel column is either fully in
/// or fully out of every sub-scanline's sample, however many rows are
/// sampled) and a systematic up-to-1px rightward bias versus true coverage.
/// `.rotated_grid` varies the x offset per sub-scanline and partially
/// mitigates this, but still isn't exact coverage.
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

/// `analytical` computes the exact area-coverage integral of each pixel cell
/// against the outline -- the same convention FreeType's FT_RENDER_MODE_NORMAL
/// and stb_truetype use, and the reason it's the default (see RasterOptions).
/// `supersampling` point-samples the outline at a finite number of
/// sub-scanline positions per row instead; it's an explicit opt-in for callers
/// who want that specific (regular/rotated_grid, aa_level, adaptive) sampling
/// behavior rather than exact coverage -- see `aa_level`/`sample_pattern`/
/// `adaptive`'s docs, all of which only affect this method.
pub const RasterMethod = enum {
    supersampling,
    analytical,
};

pub const RasterOptions = struct {
    /// supersampling-only: sub-scanline count per row.
    aa_level: AntiAliasLevel = .aa_8,
    /// supersampling-only: see SamplePattern.
    sample_pattern: SamplePattern = .regular,
    /// supersampling-only: per-row low/high refinement (see AdaptiveOptions).
    adaptive: ?AdaptiveOptions = null,
    /// Default `.analytical` -- see RasterMethod for the comparison and why.
    method: RasterMethod = .analytical,
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
        // accumulateRowDelta hangs forever. An infinite endpoint produces
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

/// The y of sub-scanline `s` (of `n` total) within row `y` -- the single
/// formula every per-subsample computation and row-level bound
/// (SupersampleContext.rowActivity's head/last, s=0 and s=n-1 respectively)
/// must agree on, so there is exactly one place that can get the sub-pixel-
/// center +0.5 offset wrong.
fn subScanlineY(y: usize, s: usize, n: usize) f32 {
    return @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, @floatFromInt(n));
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
/// change how any edge's x-intersection is computed (see accumulateRowDelta).
const SupersampleContext = struct {
    sorted: []Edge,
    next: usize = 0,
    active: *std.ArrayList(Edge),
    last_sub_y: f32 = -std.math.floatMax(f32),

    const RowActivity = enum { empty, static, changing };

    fn advance(self: *SupersampleContext, allocator: std.mem.Allocator, sub_y: f32) !void {
        if (sub_y < self.last_sub_y) {
            // Backward seek: see rowActivity's doc for when/why this happens
            // and why it's always safe. Rebuilding from the front costs at
            // most O(E) for the row being re-walked, the same bound the
            // pre-AET per-subscanline full rescan always paid every
            // subscanline, so this is never worse.
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

    /// Classifies what can happen to the active set across all of row `y`'s
    /// `n` sub-scanlines, from this context's current state through the
    /// row's last sub-scanline -- the single check callers use to decide how
    /// cheaply the row can be processed (S4/S6):
    ///
    ///   .empty    - nothing is active and nothing upcoming starts within the
    ///               row: winding is provably 0 for every sub_y and every px,
    ///               so the row needs no work at all.
    ///   .static   - the active set is nonempty but provably *unchanged* for
    ///               the whole row (no activation, no deactivation): one
    ///               advance() at the row's head is equivalent to one at
    ///               every sub_y in the row, so the rest can reuse it as-is.
    ///   .changing - anything else; every sub-scanline needs its own
    ///               advance() call, exactly like the pre-S6 code.
    ///
    /// A pending backward seek (this row's own head sub_y is *before*
    /// `last_sub_y`) unconditionally reports .changing, regardless of what
    /// the active/next checks below would otherwise say. This is the one
    /// case that needs care, and the only place its reasoning lives: it only
    /// happens from the adaptive high pass re-walking a row the low pass
    /// already advanced past (see advance()'s backward-seek branch), and
    /// when it does, `active`/`next` reflect wherever the low pass's *own*
    /// traversal stopped -- not a valid predictor for "what's active/
    /// upcoming near this (earlier) row's head". An edge fully activated-
    /// and-deactivated by the low pass within this same row would be
    /// invisible to both checks below, even though a correct backward-seek
    /// rebuild finds it active again at head. Reporting .changing here
    /// forces the always-correct per-subsample path instead of risking a
    /// wrong .empty/.static verdict from stale state.
    fn rowActivity(self: *const SupersampleContext, y: usize, n: usize) RowActivity {
        const head = subScanlineY(y, 0, n);
        const last = subScanlineY(y, n - 1, n);

        if (head < self.last_sub_y) return .changing;

        const will_activate = self.next < self.sorted.len and self.sorted[self.next].y_top <= last;
        var will_deactivate = false;
        for (self.active.items) |edge| {
            if (edge.y_bottom <= last) {
                will_deactivate = true;
                break;
            }
        }
        if (will_activate or will_deactivate) return .changing;
        return if (self.active.items.len == 0) .empty else .static;
    }
};

// @intFromFloat into i64 is checked-illegal-behavior for a float outside
// [-2^63, 2^63); clamping to +/-2^31 first (far beyond any real bitmap
// dimension -- rasterizer.zig's glyphBitmapGeometry already rejects glyph
// bitmaps over 16384px) keeps the cast always in-range. Coordinates coming
// from bbox-consistent glyph rendering never approach this bound, so the
// clamp is a no-op there and this is purely a pub-API guard against a
// huge-but-finite f32 (not otherwise excluded by the NaN/inf filter in
// buildEdgesInto) reaching the cast.
const span_pixel_bound: f32 = 2147483648.0; // 2^31

// Correction loops are capped: for bitmap-bounded coordinates (well below f32's
// 2^24 integer-precision limit) the floor candidate is off by at most 1, so the
// cap never binds. For pathological huge-but-finite coordinates the increments
// can stall below f32 precision (@floatFromInt(px) stops changing), which would
// otherwise loop unboundedly; a capped result lands far outside any real bitmap
// and fillSpanDelta's clamp turns it into "no coverage" -- exactly what the original
// per-pixel walk produced for an intersection beyond the bitmap.
const span_correction_cap: u8 = 2;

/// Smallest px such that `xs < @floatFromInt(px) + x_offset` -- the exact
/// predicate the original per-pixel walk uses (`intersection.x < px_left`),
/// evaluated at a span's opening x. Starts from a floor-based candidate purely
/// as a fast path and then corrects against the *exact* predicate (typically 0,
/// occasionally 1 iteration either way, from f32 rounding in `xs - x_offset`
/// vs. `px + x_offset`); the final value is always confirmed by the same
/// comparison the original algorithm made, so this cannot disagree with it.
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

/// S1: delta-array equivalent of the original coverage[a..b] += 1 direct fill.
/// Instead of touching every pixel in a span (cost proportional to span
/// width), records the span as a +1/-1 pair at its boundaries; a prefix sum
/// over `delta` afterward yields exactly the same per-pixel counts the direct
/// fill would have produced (interval-delta-array trick). `delta` must have
/// length width+1: a span whose already-clamped px_end reaches width-1 writes
/// delta[width], one slot past the `width` pixels the prefix sum reads.
///
/// Crucially, **all n sub-scanlines of a row accumulate into the same delta
/// buffer** before any prefix sum happens (see accumulateRowDelta), rather
/// than each sub-scanline producing its own coverage delta that gets summed
/// separately. This is still exact: the final per-pixel count is
/// Σ_s indicator_s(px), and integer addition is commutative/associative, so
/// summing every sub-scanline's +1/-1 pairs into one array first and prefix-
/// summing once at the end equals prefix-summing each sub-scanline's pairs
/// separately and then summing those -- both compute the same Σ_s.
fn fillSpanDelta(delta: []i16, width: usize, px_start_raw: i64, px_end_raw: i64) void {
    const w_i64: i64 = @intCast(width);
    const px_start = @max(@as(i64, 0), px_start_raw);
    const px_end = @min(w_i64 - 1, px_end_raw);
    if (px_start > px_end) return;
    const a: usize = @intCast(px_start);
    const b: usize = @intCast(px_end);
    delta[a] += 1;
    delta[b + 1] -= 1;
}

/// S2: sorts `items` by `.x` ascending, matching compareIntersections exactly.
/// For the common case (len <= 16 -- almost always true for glyph-sized
/// inputs and typical AET active-set sizes) a direct insertion sort avoids
/// std.mem.sort's introsort dispatch/pivot-selection overhead, which
/// dominates at these tiny n. Falls back to std.mem.sort above that
/// threshold. Insertion sort's relative order of equal-x keys can differ from
/// std.mem.sort's, but per the equal-x grouping argument in
/// accumulateRowDelta, any correct ascending-by-x order (whatever it does
/// with ties) yields byte-identical coverage, so this substitution cannot
/// change output.
fn sortIntersections(items: []Intersection) void {
    if (items.len <= 16) {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const key = items[i];
            var j: usize = i;
            while (j > 0 and key.x < items[j - 1].x) : (j -= 1) {
                items[j] = items[j - 1];
            }
            items[j] = key;
        }
        return;
    }
    std.mem.sort(Intersection, items, {}, compareIntersections);
}

/// S1+S6: builds `delta` (see fillSpanDelta) for one row at sample count `n`,
/// given `verdict` (the caller's already-computed
/// `ctx.rowActivity(y, n)`; see SupersampleContext.rowActivity -- callers
/// skip calling this function entirely for `.empty` rows, so `verdict` here
/// is always `.static` or `.changing`).
///
/// Does not memset `delta` itself: it relies on the "clear-on-read" invariant
/// every consumer of `delta` maintains (S5 -- see prefixSumToCoverage and
/// rasterize()'s fused prefix-sum loops), so `delta` is guaranteed all-zero
/// on entry here regardless of whether this is the first row (rasterize()'s
/// one-time initial memset) or a later one (the previous row/pass's consumer
/// zeroed everything it touched on its way out).
fn accumulateRowDelta(
    delta: []i16,
    y: usize,
    n: usize,
    pattern: SamplePattern,
    verdict: SupersampleContext.RowActivity,
    ctx: *SupersampleContext,
    intersections: *std.ArrayList(Intersection),
    allocator: std.mem.Allocator,
) !void {
    const width = delta.len - 1;

    if (verdict == .static) {
        // Proven by rowActivity: zero activations and zero deactivations
        // through this row's last sub-scanline, so the per-subsample
        // advance() calls this skips would only ever update last_sub_y -- do
        // just that, once, up front. Leaving last_sub_y at the row's head
        // (not its tail) is safe for every later advance() call too: sub_y is
        // monotonically increasing across the whole rasterize() call, and no
        // future call's sub_y can ever land strictly between this row's head
        // and tail from a different context, so it cannot change any future
        // backward-seek decision.
        ctx.last_sub_y = subScanlineY(y, 0, n);
    }

    for (0..n) |s| {
        const sub_y = subScanlineY(y, s, n);
        const x_offset = sampleXOffset(pattern, s, n);

        if (verdict == .changing) {
            try ctx.advance(allocator, sub_y);
        }
        // else (.static): the active set can't change across this row -- see
        // the verdict==.static branch above.

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

        sortIntersections(intersections.items);

        // Span-fill walk, equivalent to the original per-pixel walk ("consume
        // every intersection with x < px_left, coverage[px] += 1 iff the
        // resulting winding != 0"): walk the x-sorted intersections, grouping
        // consecutive equal-x ones (a correct sort always keeps tied keys
        // contiguous, regardless of which order this run's AET-active-order-
        // dependent input handed to the sort -- see sortIntersections) and
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
                fillSpanDelta(delta, width, spanStartPixel(span_start_x, x_offset), spanEndPixel(group_x, x_offset));
            }
        }
        if (span_open) {
            // Unclosed at the end of this sub-scanline (winding never returns to
            // 0, e.g. malformed/self-intersecting geometry): the original loop
            // freezes `winding` for every remaining pixel once intersections run
            // out, so extend the span through the last column.
            fillSpanDelta(delta, width, spanStartPixel(span_start_x, x_offset), @as(i64, @intCast(width)) - 1);
        }
    }
}

/// S1 (adaptive low pass) + S6 (has_edge fusion): prefix-sums `delta`
/// (already populated by accumulateRowDelta) into `coverage` as per-pixel
/// sub-scanline-coverage counts -- the same integer values direct fillSpan
/// increments used to produce, via one O(w) scan. The adaptive path needs
/// these materialized counts (not just quantized pixels) for its low/high
/// blend below.
///
/// Also clears `delta` back to all-zero as it goes (S5's "clear-on-read"
/// invariant -- see rasterize()'s one-time initial memset), and returns
/// whether any pixel's count was "partial" (0 < count < n): the adaptive
/// low pass's has_edge signal, computed for free in this same pass instead
/// of a separate scan over `coverage` afterward.
fn prefixSumToCoverage(coverage: []u16, delta: []i16, n: usize) bool {
    var acc: i32 = 0;
    var has_edge = false;
    for (0..coverage.len) |px| {
        acc += delta[px];
        delta[px] = 0;
        coverage[px] = @intCast(acc);
        if (acc > 0 and acc < @as(i32, @intCast(n))) has_edge = true;
    }
    delta[coverage.len] = 0; // fillSpanDelta's max index is width == coverage.len
    return has_edge;
}

/// S5: `(count * 255) >> shift` in place of `count * 255 / n`. `count` is
/// always in [0, n] here (a genuine sub-scanline coverage count), so this
/// non-negative-operand right shift is bit-for-bit the same as unsigned
/// division by the power-of-two `n = 1 << shift` -- not an approximation.
inline fn quantizeToU8(count: i32, shift: u5) u8 {
    const scaled = (count * 255) >> shift;
    return @intCast(@min(scaled, 255));
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
    /// S1 delta-array buffer (length width+1), shared by every row-processing
    /// call site (non-adaptive fused write, and both adaptive passes).
    delta: *std.ArrayList(i16),
    coverage: *std.ArrayList(u16),
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

    // S1: shared delta buffer, needed by every call site below (fused
    // non-adaptive write, and both adaptive passes). Length w+1 -- see
    // fillSpanDelta.
    var local_delta: std.ArrayList(i16) = .empty;
    defer local_delta.deinit(allocator);
    const delta_list: *std.ArrayList(i16) = if (scratch) |s| s.delta else &local_delta;
    try delta_list.resize(allocator, w + 1);
    const delta = delta_list.items;
    // S5: memset once per rasterize() call, not once per row. Every consumer
    // of `delta` below (prefixSumToCoverage, and the two fused prefix-sum
    // loops) clears every index it reads back to 0 as it goes
    // ("clear-on-read"), so `delta` is always all-zero by the time the next
    // row/pass populates it -- this one memset is the only place that has to
    // establish that invariant from scratch. It also means a prior
    // rasterize() call that errored out partway through (leaving some row's
    // delta only partially cleared) self-heals: this runs unconditionally,
    // before anything reads `delta`, regardless of what a previous call left
    // behind.
    @memset(delta, 0);

    if (options.adaptive) |adaptive_opts| {
        const low_n = adaptive_opts.low_level.toSampleCount();
        const high_n = adaptive_opts.high_level.toSampleCount();
        const high_shift = adaptive_opts.high_level.log2SampleCount();

        var local_coverage: std.ArrayList(u16) = .empty;
        defer local_coverage.deinit(allocator);
        const coverage_list: *std.ArrayList(u16) = if (scratch) |s| s.coverage else &local_coverage;
        try coverage_list.resize(allocator, w);
        const coverage = coverage_list.items;

        for (0..height) |y| {
            const verdict = ctx.rowActivity(y, low_n);
            // S4: a provably empty row needs no work at all -- pixels stays 0
            // (already zeroed at allocation). `coverage` is left stale here,
            // but the next non-empty row's prefixSumToCoverage rewrites every
            // one of its w entries before coverage is read again, so the
            // staleness is never observed.
            if (verdict == .empty) continue;

            try accumulateRowDelta(delta, y, low_n, options.sample_pattern, verdict, &ctx, intersections_list, allocator);
            const has_edge = prefixSumToCoverage(coverage, delta, low_n);

            if (has_edge) {
                // The high pass always re-walks this row from its (finer,
                // earlier) head, which is before wherever the low pass's
                // traversal just left ctx -- i.e. always a pending backward
                // seek, always .changing (see
                // SupersampleContext.rowActivity's doc); no rowActivity call
                // is needed to know that here.
                try accumulateRowDelta(delta, y, high_n, options.sample_pattern, .changing, &ctx, intersections_list, allocator);
                // S1+S5 fused finish: prefix-sum delta straight into the
                // blend decision, clearing delta back to zero as it goes,
                // instead of materializing a separate coverage_high buffer
                // first.
                var acc: i32 = 0;
                for (0..w) |px| {
                    acc += delta[px];
                    delta[px] = 0;
                    if (coverage[px] > 0 and coverage[px] < @as(u16, @intCast(low_n))) {
                        pixels[y * w + px] = quantizeToU8(acc, high_shift);
                    } else {
                        pixels[y * w + px] = if (coverage[px] == 0) 0 else 255;
                    }
                }
                delta[w] = 0; // fillSpanDelta's max index is width == w
            } else {
                for (0..w) |px| {
                    pixels[y * w + px] = if (coverage[px] == 0) 0 else 255;
                }
            }
        }
    } else {
        const n = options.aa_level.toSampleCount();
        const shift = options.aa_level.log2SampleCount();
        for (0..height) |y| {
            const verdict = ctx.rowActivity(y, n);
            if (verdict == .empty) {
                // S4: pixels is already zero-initialized at allocation, so a
                // provably-empty row needs no write at all.
                continue;
            }
            try accumulateRowDelta(delta, y, n, options.sample_pattern, verdict, &ctx, intersections_list, allocator);
            // S1+S5 fused finish: prefix-sum delta straight into quantized
            // pixels, clearing delta back to zero as it goes, one pass.
            var acc: i32 = 0;
            for (0..w) |px| {
                acc += delta[px];
                delta[px] = 0;
                pixels[y * w + px] = quantizeToU8(acc, shift);
            }
            delta[w] = 0; // fillSpanDelta's max index is width == w
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
    // The inverted (low>high) and equal (low==high) variants pin the degenerate
    // adaptive configs where the high pass's backward-seek relationship to the
    // low pass flips -- the one place rowActivity's fast paths interact with
    // advance()'s backward-seek rebuild differently than the default config.
    const adaptive_variants = [_]?AdaptiveOptions{
        null,
        .{},
        .{ .low_level = .aa_32, .high_level = .aa_4 },
        .{ .low_level = .aa_8, .high_level = .aa_8 },
    };

    const width: u32 = 16;
    const height: u32 = 16;

    for (shapes) |segments| {
        for (aa_levels) |aa| {
            for (patterns) |pattern| {
                for (adaptive_variants) |adaptive| {
                    // .method pinned explicitly: this test's whole point is
                    // comparing the supersampling implementation against its
                    // pre-AET oracle (referenceRasterize only implements the
                    // supersampling algorithm; for .analytical it just
                    // delegates to analytical_mod.rasterize same as
                    // production rasterize() does). Since RasterOptions{}'s
                    // default is now .analytical, leaving this implicit would
                    // make both sides call the identical analytical function
                    // and "pass" trivially, testing nothing.
                    const options: RasterOptions = .{
                        .method = .supersampling,
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
    // The trailing supersampling shrink-then-grow pair exercises the delta
    // buffer's resize-down/resize-up path specifically (the per-call memset
    // must cover regrown slots regardless of prior contents).
    const steps = [_]Step{
        .{ .size = 16, .method = .supersampling },
        .{ .size = 160, .method = .analytical },
        .{ .size = 160, .method = .supersampling },
        .{ .size = 16, .method = .analytical },
        .{ .size = 48, .method = .supersampling },
        .{ .size = 160, .method = .supersampling },
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

// T5: like T1, but against real glyph outlines instead of synthetic 16x16
// shapes, with adaptive AA on -- this is what actually caught a Phase S bug
// (S4/S6's row-level lookahead checks reading stale AET state right before
// an adaptive high-pass backward seek) that T1's small synthetic shapes
// never triggered: real glyph curves are far more likely to produce an edge
// that starts *and* ends within a single row's low-resolution sub-scanline
// range (fully consumed by the low pass before the high pass revisits that
// row), which is exactly the scenario the stale-state bug needed. Every
// glyph outline in "Hello café" at a realistic render size, each compared
// against referenceRasterize both via a bare rasterize() call and via
// rasterizeGlyphWithScratch sharing one RasterScratch across all glyphs (the
// production RowRenderer/renderText pattern).
test "T5: adaptive matches reference for real glyph outlines (bare + shared scratch)" {
    const allocator = std.testing.allocator;
    const font_mod = @import("../font/font.zig");
    const outline_mod2 = @import("outline.zig");
    const rasterizer_mod = @import("rasterizer.zig");

    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(allocator, font_data, null);
    defer font.deinit();

    const text = "Hello café";
    const scale = 48.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    // .method pinned explicitly, same reason as T1/T2: `.adaptive` only takes
    // effect under .supersampling, and referenceRasterize degenerates to a
    // trivial self-comparison under .analytical (RasterOptions{}'s new
    // default) -- see that test's comment for the full argument.
    const options: RasterOptions = .{ .method = .supersampling, .adaptive = .{} };

    var scratch: rasterizer_mod.RasterScratch = .{};
    defer scratch.deinit(allocator);

    var tested: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        const glyph_id = try font.getGlyphId(cp);
        const outline_opt = try font.getGlyphOutline(allocator, glyph_id);
        if (outline_opt == null) continue;
        var outline = outline_opt.?;
        defer outline.deinit();

        const geom = rasterizer_mod.glyphBitmapGeometry(outline, scale, 0.0, 1.0) catch continue;
        if (geom.width == 0 or geom.height == 0) continue;

        const scaled = try outline_mod2.scaleOutline(allocator, outline, scale, geom.offset_x, geom.offset_y);
        defer outline_mod2.freeScaledContours(allocator, scaled);
        var segments_list = try outline_mod2.flattenContours(allocator, scaled);
        defer segments_list.deinit(allocator);
        const segments = segments_list.items;

        const want = try referenceRasterize(allocator, segments, geom.width, geom.height, options);
        defer allocator.free(want);

        const got_bare = try rasterize(allocator, segments, geom.width, geom.height, options, null);
        defer allocator.free(got_bare);
        try std.testing.expectEqualSlices(u8, want, got_bare);

        var got_shared = try rasterizer_mod.rasterizeGlyphWithScratch(allocator, outline, scale, 1, options, &scratch);
        defer got_shared.deinit();
        try std.testing.expectEqualSlices(u8, want, got_shared.pixels);
        tested += 1;
    }
    // Guard against a vacuous pass: the per-glyph `continue`s above must not
    // end up skipping every glyph (e.g. a fixture or scale change).
    try std.testing.expect(tested >= 8);
}

// T6: pins RasterOptions{}'s default method to .analytical (the intentional
// default switch -- see RasterOptions/RasterMethod's doc comments), so an
// accidental flip back is caught immediately instead of only showing up as a
// diffuse quality/perf regression elsewhere.
test "T6: default RasterOptions method is analytical" {
    // rasterize() dispatches directly on options.method, so pinning the enum
    // default is sufficient to pin the default rendering path (T1-T5 cover
    // the behavior of each method under explicit selection).
    try std.testing.expectEqual(RasterMethod.analytical, (RasterOptions{}).method);
}
