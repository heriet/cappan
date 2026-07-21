const std = @import("std");
const outline_mod = @import("outline.zig");

// pub: rasterizer.zig's RasterScratch holds a scratch `std.ArrayList(Cell)` (reused
// across rasterize() calls instead of allocated fresh every time), threaded through
// via scanline.zig's RasterizeScratch (the single dispatch point for both raster
// methods).
pub const Cell = struct {
    cover: f32 = 0,
    area: f32 = 0,
};

/// Row-band height for the NON-SCRATCH path: `cells` is accumulated and
/// integrated one band of `band_h` rows at a time instead of the whole W*H
/// image at once, bounding the per-call buffer to `w * band_h`. A phase-level
/// profile found alloc+memset at 82.8% of non-scratch analytical's per-glyph
/// cost at 128px, and 32-row banding recovers ~2.3x there; 16 loses to
/// redundant re-walking of band-spanning segments, 64 halves the win.
///
/// With a caller-provided scratch the buffer already persists across calls,
/// so allocation isn't a cost at all and banding is pure overhead (measured
/// +15-18% at 64-128px from segment re-walks and per-band memsets; the
/// cache-residency hope did not materialize). The scratch path therefore uses
/// one full-height band, i.e. the pre-banding behavior. Output is
/// byte-identical for ANY band split (verified: identical checksums across
/// band_h 16/32/64/full) -- band size is purely a performance knob, so the
/// two paths differing here cannot diverge in output.
const band_h: usize = 32;

pub fn rasterize(
    allocator: std.mem.Allocator,
    segments: []const outline_mod.Segment,
    width: u32,
    height: u32,
    cells_scratch: ?*std.ArrayList(Cell),
) ![]u8 {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    // No memset: the band loop's reconstruction pass writes every pixel
    // (bands tile [0, h) and the inner loop covers all of [0, w)), and the
    // w/h == 0 early return below returns a zero-length buffer.
    const pixels = try allocator.alloc(u8, w * h);
    errdefer allocator.free(pixels);

    if (w == 0 or h == 0) return pixels;

    // Scratch path: one full-height band; non-scratch: small bands -- see
    // band_h's doc for the measured tradeoff.
    const effective_band_h: usize = if (cells_scratch != null) h else @min(band_h, h);

    var local_cells: std.ArrayList(Cell) = .empty;
    defer local_cells.deinit(allocator);
    const cells_list: *std.ArrayList(Cell) = cells_scratch orelse &local_cells;
    try cells_list.resize(allocator, w * effective_band_h);
    const band_cells = cells_list.items;

    var band_start: usize = 0;
    while (band_start < h) : (band_start += effective_band_h) {
        const band_rows = @min(effective_band_h, h - band_start);
        const band_slice = band_cells[0 .. w * band_rows];
        @memset(band_slice, .{});

        // Segments are walked in original array order, every band -- see
        // renderLine's doc for why this preserves f32-addition-order byte
        // identity. The y-range pre-check below is a pure optimization (skip
        // entering renderLine's row-walk at all when this segment's *whole*
        // unclipped y-span can't reach this band); it uses strict `<`/`>` so
        // it only ever skips segments renderLine's own per-row band check
        // would also have produced zero writes for -- never a false skip.
        const band_lo_f: f32 = @floatFromInt(band_start);
        const band_hi_f: f32 = @floatFromInt(band_start + band_rows);
        for (segments) |seg| {
            const seg_lo = @min(seg.y0, seg.y1);
            const seg_hi = @max(seg.y0, seg.y1);
            if (seg_hi < band_lo_f or seg_lo > band_hi_f) continue;
            renderLine(band_slice, w, h, seg.x0, seg.y0, seg.x1, seg.y1, band_start, band_start + band_rows);
        }

        // Coverage reconstruction: add this cell's own `cover` to `acc`
        // BEFORE reading out this cell's coverage, and SUBTRACT `area * 0.5`.
        //
        // Derivation (nonzero-winding average over the full row height): for
        // the sub-portion of the row where the crossing has already moved
        // past this cell into a later column, this cell is fully on the
        // "post-crossing" side, contributing that sub-portion's dy directly
        // -- and `cover` already includes it, since cover sums to the full
        // row height across every column an edge visits in a row. Averaging
        // gives cell_avg_winding = (acc_before + cover) - area/2, i.e.
        // exactly acc-after-adding-cover minus half the area term.
        //
        // The read-before-update, add-area form is wrong: it coincides with
        // this only when a crossing stays in one column for the whole row
        // (straight near-vertical edges), and diverges for flattened curve
        // segments, whose slope makes most row-crossings span 2+ columns.
        // Guarded by the circle regression test below.
        for (0..band_rows) |y_rel| {
            var acc: f32 = 0;
            for (0..w) |x| {
                const cell = band_slice[y_rel * w + x];
                acc += cell.cover;
                const coverage = @abs(acc - cell.area * 0.5);
                pixels[(band_start + y_rel) * w + x] = @intFromFloat(@min(coverage * 255.0, 255.0));
            }
        }
    }

    return pixels;
}

/// Walks the segment exactly as the pre-banding version did -- identical
/// t_start/t_end vertical clip against the *full* image height `h` (not the
/// band), identical row-stepping recurrence for cur_x/cur_y, identical
/// row-end/row-top computation -- with exactly two differences, both
/// non-numeric: (1) a row's `renderRowSegment` call is skipped when that
/// row falls outside [band_start, band_end), and (2) when it isn't skipped,
/// the row index passed in is band-relative (iy - band_start) to match
/// `cells` being a band-sized slice, not the full `w * h` image. No arithmetic that ends up in a written cell's cover/area changes:
/// every f32 add a written cell receives is bit-for-bit the value the
/// non-banded version would have computed for that same row, and (per
/// rasterize()'s outer loop) happens in the same original segment order --
/// the two properties f32 addition's non-associativity requires for byte
/// identity.
///
/// Cost note: a segment spanning multiple bands gets walked again (from its
/// own start, not resumed) on each band's pass, wasting the walk for rows
/// outside that pass's band. Flattened curve chords are short (~0.6-6px, see
/// outline.zig's flattening tolerance) so this touches at most 2 bands in
/// practice; genuinely long straight edges (e.g. a full-height stem) do get
/// re-walked once per band (O(bands) instead of O(1) row-steps for that one
/// segment). Measured, this stays well below the allocation cost the banding
/// removes (see band_h's doc for the numbers).
fn renderLine(cells: []Cell, w: usize, h: usize, x0: f32, y0: f32, x1: f32, y1: f32, band_start: usize, band_end: usize) void {
    const dy = y1 - y0;
    if (@abs(dy) < 1e-7) return;

    const dx = x1 - x0;
    const h_f: f32 = @floatFromInt(h);

    var t_start: f32 = 0;
    var t_end: f32 = 1;

    if (dy > 0) {
        if (y0 >= h_f or y1 <= 0) return;
        if (y0 < 0) t_start = -y0 / dy;
        if (y1 > h_f) t_end = (h_f - y0) / dy;
    } else {
        if (y1 >= h_f or y0 <= 0) return;
        if (y0 > h_f) t_start = (h_f - y0) / dy;
        if (y1 < 0) t_end = -y0 / dy;
    }

    if (t_start >= t_end) return;

    const cx0 = x0 + t_start * dx;
    const cy0 = y0 + t_start * dy;
    const cy1 = y0 + t_end * dy;

    const slope = dx / dy;
    var cur_x = cx0;
    var cur_y = cy0;

    if (dy > 0) {
        while (cur_y < cy1 - 1e-7) {
            const iy: usize = @intFromFloat(@floor(cur_y));
            if (iy >= h) break;

            const row_end = @min(@as(f32, @floatFromInt(iy + 1)), cy1);
            const end_x = cur_x + (row_end - cur_y) * slope;

            if (iy >= band_start and iy < band_end) {
                renderRowSegment(cells, w, iy - band_start, cur_x, cur_y, end_x, row_end);
            }

            cur_x = end_x;
            cur_y = row_end;
        }
    } else {
        while (cur_y > cy1 + 1e-7) {
            const floor_y = @floor(cur_y);
            const iy_f: f32 = if (cur_y == floor_y) floor_y - 1.0 else floor_y;
            if (iy_f < 0) break;
            const iy: usize = @intFromFloat(iy_f);
            if (iy >= h) {
                const row_top: f32 = @floatFromInt(iy);
                cur_x += (row_top - cur_y) * slope;
                cur_y = row_top;
                continue;
            }

            const row_top = @max(@as(f32, @floatFromInt(iy)), cy1);
            const end_x = cur_x + (row_top - cur_y) * slope;

            if (iy >= band_start and iy < band_end) {
                renderRowSegment(cells, w, iy - band_start, cur_x, cur_y, end_x, row_top);
            }

            cur_x = end_x;
            cur_y = row_top;
        }
    }
}

fn renderRowSegment(cells: []Cell, w: usize, cy: usize, x0_raw: f32, y0_raw: f32, x1_raw: f32, y1_raw: f32) void {
    const full_dy = y1_raw - y0_raw;
    if (@abs(full_dy) < 1e-10) return;

    const full_dx = x1_raw - x0_raw;
    const w_f: f32 = @floatFromInt(w);

    var x0 = x0_raw;
    var y0 = y0_raw;
    var x1 = x1_raw;
    var y1 = y1_raw;

    if (@abs(full_dx) > 1e-10) {
        const dy_per_dx = full_dy / full_dx;
        const x_lo = @min(x0, x1);
        const x_hi = @max(x0, x1);

        if (x_hi <= 0) {
            addCellContribution(cells, w, cy, 0, full_dy, 0, 0);
            return;
        }
        if (x_lo >= w_f) return;

        // Clipping at x=0 must not discard the clipped-off portion's winding:
        // everything at x<0 is left of every bitmap column, so its dy still
        // belongs in column 0 as cover-only (cx = -1), same as the x_hi <= 0
        // branch above. Dropping it breaks row cover closure and corrupts the
        // whole row, including pixels right of the shape.
        if (x0 < 0) {
            const y_at_zero = y0 + (0 - x0) * dy_per_dx;
            addCellContribution(cells, w, cy, -1, y_at_zero - y0, 0, 0);
            y0 = y_at_zero;
            x0 = 0;
        } else if (x1 < 0) {
            const y_at_zero = y1 + (0 - x1) * dy_per_dx;
            addCellContribution(cells, w, cy, -1, y1 - y_at_zero, 0, 0);
            y1 = y_at_zero;
            x1 = 0;
        }

        if (x0 > w_f) {
            y0 += (w_f - x0) * dy_per_dx;
            x0 = w_f;
        } else if (x1 > w_f) {
            y1 += (w_f - x1) * dy_per_dx;
            x1 = w_f;
        }

        if (x0 <= 0 and x1 <= 0) {
            addCellContribution(cells, w, cy, 0, y1 - y0, 0, 0);
            return;
        }
    }

    const dy = y1 - y0;
    if (@abs(dy) < 1e-10) return;

    const dx = x1 - x0;

    if (@abs(dx) < 1e-10) {
        // Vertical segments skip the clipping block above (full_dx ~ 0), so
        // x0 may be anywhere: left of the bitmap it's cover-only in column 0
        // (clamping ix while passing the raw negative x0 into the area term
        // would credit column 0 with a bogus negative area); at or past the
        // right edge it contributes nothing.
        if (x0 < 0) {
            addCellContribution(cells, w, cy, -1, dy, 0, 0);
            return;
        }
        if (x0 >= w_f) return;
        const ix: i32 = @intFromFloat(@floor(x0));
        addCellContribution(cells, w, cy, ix, dy, x0, x0);
        return;
    }

    const dy_per_dx = dy / dx;
    var cur_x = x0;
    var cur_y = y0;

    if (dx > 0) {
        while (cur_x < x1 - 1e-7) {
            const ix: i32 = @intFromFloat(@floor(cur_x));
            const col_right: f32 = @floatFromInt(ix + 1);
            const next_x = @min(col_right, x1);
            const next_y = cur_y + (next_x - cur_x) * dy_per_dx;

            addCellContribution(cells, w, cy, ix, next_y - cur_y, cur_x, next_x);

            cur_x = next_x;
            cur_y = next_y;
        }
    } else {
        while (cur_x > x1 + 1e-7) {
            const floor_x = @floor(cur_x);
            const ix: i32 = if (cur_x == floor_x)
                @as(i32, @intFromFloat(floor_x)) - 1
            else
                @intFromFloat(floor_x);

            const col_left: f32 = @floatFromInt(ix);
            const next_x = @max(col_left, x1);
            const next_y = cur_y + (next_x - cur_x) * dy_per_dx;

            addCellContribution(cells, w, cy, ix, next_y - cur_y, cur_x, next_x);

            cur_x = next_x;
            cur_y = next_y;
        }
    }
}

fn addCellContribution(cells: []Cell, w: usize, cy: usize, cx: i32, dy: f32, x0: f32, x1: f32) void {
    if (cx >= @as(i32, @intCast(w))) return;

    const target_cx: usize = if (cx < 0) 0 else @intCast(cx);
    const cell = &cells[cy * w + target_cx];

    if (cx < 0) {
        cell.cover += dy;
    } else {
        const cx_f: f32 = @floatFromInt(cx);
        cell.cover += dy;
        cell.area += (x0 - cx_f + x1 - cx_f) * dy;
    }
}

test "analytical rasterize a simple triangle" {
    const segments = [_]outline_mod.Segment{
        .{ .x0 = 8, .y0 = 2, .x1 = 14, .y1 = 14 },
        .{ .x0 = 14, .y0 = 14, .x1 = 2, .y1 = 14 },
        .{ .x0 = 2, .y0 = 14, .x1 = 8, .y1 = 2 },
    };

    const pixels = try rasterize(std.testing.allocator, &segments, 16, 16, null);
    defer std.testing.allocator.free(pixels);

    try std.testing.expect(pixels[8 * 16 + 8] > 0);
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);
}

test "analytical rectangle coverage" {
    const segments = [_]outline_mod.Segment{
        .{ .x0 = 2.5, .y0 = 1, .x1 = 2.5, .y1 = 4 },
        .{ .x0 = 2.5, .y0 = 4, .x1 = 7.5, .y1 = 4 },
        .{ .x0 = 7.5, .y0 = 4, .x1 = 7.5, .y1 = 1 },
        .{ .x0 = 7.5, .y0 = 1, .x1 = 2.5, .y1 = 1 },
    };

    const pixels = try rasterize(std.testing.allocator, &segments, 10, 5, null);
    defer std.testing.allocator.free(pixels);

    try std.testing.expectEqual(@as(u8, 0), pixels[2 * 10 + 0]);
    try std.testing.expectEqual(@as(u8, 0), pixels[2 * 10 + 1]);

    try std.testing.expect(pixels[2 * 10 + 2] > 100 and pixels[2 * 10 + 2] < 150);

    try std.testing.expectEqual(@as(u8, 255), pixels[2 * 10 + 3]);
    try std.testing.expectEqual(@as(u8, 255), pixels[2 * 10 + 5]);

    try std.testing.expect(pixels[2 * 10 + 7] > 100 and pixels[2 * 10 + 7] < 150);

    try std.testing.expectEqual(@as(u8, 0), pixels[2 * 10 + 8]);
}

/// Nonzero-winding coverage of pixel (px,py) via dense sub-sample point
/// testing against `segments` directly -- an independent (no cell
/// accumulation, no cover/area) ground truth for a single pixel, used only by
/// the regression test below.
fn bruteForceCoverage(segments: []const outline_mod.Segment, px: usize, py: usize) f32 {
    const n: usize = 48; // 48x48 sub-samples: ~0.02px resolution, ample for the 20/255 tolerance
    var inside_count: usize = 0;
    const total: usize = n * n;
    for (0..n) |sy| {
        const y = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(n));
        for (0..n) |sx| {
            const x = @as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, @floatFromInt(n));
            var winding: i32 = 0;
            for (segments) |seg| {
                const y0 = seg.y0;
                const y1 = seg.y1;
                if (y0 == y1) continue;
                const lo = @min(y0, y1);
                const hi = @max(y0, y1);
                if (y < lo or y >= hi) continue;
                const t = (y - y0) / (y1 - y0);
                const cross_x = seg.x0 + t * (seg.x1 - seg.x0);
                if (cross_x > x) winding += if (y1 > y0) 1 else -1;
            }
            if (winding != 0) inside_count += 1;
        }
    }
    return @as(f32, @floatFromInt(inside_count)) / @as(f32, @floatFromInt(total));
}

/// Approximates a circle as `n` short straight segments -- deliberately many
/// short chords (rather than a handful of long ones) to match the segment
/// length/count a real flattened glyph curve produces (see flattenQuadBezier/
/// flattenCubicBezier's 0.25px tolerance in outline.zig), which is exactly
/// the shape of input that triggered the bug this guards.
fn circleSegments(buf: []outline_mod.Segment, cx: f32, cy: f32, r: f32) void {
    const n = buf.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a0 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const a1 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n));
        buf[i] = .{
            .x0 = cx + r * @cos(a0),
            .y0 = cy + r * @sin(a0),
            .x1 = cx + r * @cos(a1),
            .y1 = cy + r * @sin(a1),
        };
    }
}

// Regression guard for the reconstruction-formula bug documented at
// rasterize()'s coverage loop: without the fix, boundary coverage is off by
// 100+ levels (out of 255) wherever a row-crossing spans multiple columns --
// routine for the short chords a flattened curve produces. The 256-segment
// circle (~0.6px chords) matches real flattened-glyph segment lengths.
test "analytical circle boundary matches brute-force coverage" {
    const allocator = std.testing.allocator;
    const w: u32 = 64;
    const h: u32 = 64;

    var seg_buf: [256]outline_mod.Segment = undefined;
    circleSegments(&seg_buf, 32.0, 32.0, 24.0);
    const segments = seg_buf[0..];

    const pixels = try rasterize(allocator, segments, w, h, null);
    defer allocator.free(pixels);

    // Each row's rightmost partial (boundary) pixel must agree with the
    // independent brute-force sampler.
    var checked: usize = 0;
    var mismatches: usize = 0;
    for (10..54) |y| {
        var x: usize = w;
        while (x > 0) {
            x -= 1;
            const v = pixels[y * w + x];
            if (v > 0 and v < 255) {
                const brute = bruteForceCoverage(segments, x, y) * 255.0;
                if (@abs(@as(f32, @floatFromInt(v)) - brute) > 20.0) mismatches += 1;
                checked += 1;
                break;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    // Guard against a vacuous pass (no row finding a partial boundary pixel).
    try std.testing.expect(checked >= 20);
}

// Regression guard for renderRowSegment's x<0 clipping paths: the winding of
// any sub-segment clipped away at x<0 -- slanted row-crossings and vertical
// edges alike -- must still land in column 0 as cover-only. Before the fix,
// the triangle's x=0-crossing rows were off by 200+/255 across the whole row
// (including pixels right of the shape), and the second case's hole-interior
// pixel at column 0 rendered 255 instead of 0 (vertical x<0 edges leaked
// bogus negative area into column 0).
test "analytical x<0 clipped shapes match brute-force coverage" {
    const allocator = std.testing.allocator;

    // Triangle with a far-left vertex: both slanted edges cross x=0 mid-row.
    const tri = [_]outline_mod.Segment{
        .{ .x0 = -100, .y0 = 10, .x1 = 30, .y1 = 5 },
        .{ .x0 = 30, .y0 = 5, .x1 = 30, .y1 = 15 },
        .{ .x0 = 30, .y0 = 15, .x1 = -100, .y1 = 10 },
    };
    // Rect spanning the left edge, with a reversed-winding hole also spanning
    // it: two vertical edges at x<0 whose cover (but not area) must cancel in
    // column 0.
    const holed = [_]outline_mod.Segment{
        .{ .x0 = -10, .y0 = 1, .x1 = -10, .y1 = 9 },
        .{ .x0 = -10, .y0 = 9, .x1 = 15, .y1 = 9 },
        .{ .x0 = 15, .y0 = 9, .x1 = 15, .y1 = 1 },
        .{ .x0 = 15, .y0 = 1, .x1 = -10, .y1 = 1 },
        .{ .x0 = -5, .y0 = 3, .x1 = 5, .y1 = 3 },
        .{ .x0 = 5, .y0 = 3, .x1 = 5, .y1 = 7 },
        .{ .x0 = 5, .y0 = 7, .x1 = -5, .y1 = 7 },
        .{ .x0 = -5, .y0 = 7, .x1 = -5, .y1 = 3 },
    };

    const cases = [_]struct { segs: []const outline_mod.Segment, w: u32, h: u32 }{
        .{ .segs = &tri, .w = 40, .h = 20 },
        .{ .segs = &holed, .w = 20, .h = 10 },
    };
    for (cases) |case| {
        const pixels = try rasterize(allocator, case.segs, case.w, case.h, null);
        defer allocator.free(pixels);
        for (0..case.h) |y| {
            for (0..case.w) |x| {
                const want = bruteForceCoverage(case.segs, x, y) * 255.0;
                const got: f32 = @floatFromInt(pixels[y * case.w + x]);
                try std.testing.expect(@abs(got - want) <= 6.0);
            }
        }
    }
}
