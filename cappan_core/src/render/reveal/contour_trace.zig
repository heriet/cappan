const std = @import("std");
const outline_mod = @import("../../raster/outline.zig");

pub const Segment = outline_mod.Segment;

pub const ContourOrdering = enum {
    font_order,
    stroke_heuristic,
    area_priority,
    writing_order,
};

pub const ContourTraceOptions = struct {
    ordering: ContourOrdering = .font_order,
};

pub const AnimContour = struct {
    segments: []Segment,
    cumulative_lengths: []f32,
    total_length: f32,
    global_offset: f32,
};

pub const GlyphAnimation = struct {
    contours: []AnimContour,
    total_length: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GlyphAnimation) void {
        for (self.contours) |c| {
            self.allocator.free(c.segments);
            self.allocator.free(c.cumulative_lengths);
        }
        self.allocator.free(self.contours);
    }
};

/// Returns the Euclidean length of a segment.
pub fn segmentLength(seg: Segment) f32 {
    const dx = seg.x1 - seg.x0;
    const dy = seg.y1 - seg.y0;
    return @sqrt(dx * dx + dy * dy);
}

/// Returns the first portion [0, t] of a segment via linear interpolation.
pub fn splitSegment(seg: Segment, t: f32) Segment {
    const x1_new = seg.x0 + (seg.x1 - seg.x0) * t;
    const y1_new = seg.y0 + (seg.y1 - seg.y0) * t;
    return .{ .x0 = seg.x0, .y0 = seg.y0, .x1 = x1_new, .y1 = y1_new };
}

/// Shoelace formula on segments to compute signed area.
pub fn computeSignedArea(segments: []const Segment) f32 {
    var sum: f32 = 0.0;
    for (segments) |seg| {
        sum += seg.x0 * seg.y1 - seg.x1 * seg.y0;
    }
    return 0.5 * sum;
}

/// Compute the centroid (average position) of all segment start points in a contour.
fn computeCentroid(segments: []const Segment) struct { x: f32, y: f32 } {
    if (segments.len == 0) return .{ .x = 0, .y = 0 };
    var sum_x: f32 = 0;
    var sum_y: f32 = 0;
    for (segments) |seg| {
        sum_x += seg.x0;
        sum_y += seg.y0;
    }
    const n: f32 = @floatFromInt(segments.len);
    return .{ .x = sum_x / n, .y = sum_y / n };
}

/// Find the start point of a contour (first on-curve point, or midpoint fallback).
fn findStartPoint(points: []const outline_mod.ScaledPoint) struct { x: f32, y: f32 } {
    // Find first on-curve point
    for (points) |p| {
        if (p.on_curve) return .{ .x = p.x, .y = p.y };
    }
    // Fallback: midpoint of first two points (matches flattenContour logic)
    if (points.len >= 2) {
        return .{
            .x = (points[0].x + points[1].x) * 0.5,
            .y = (points[0].y + points[1].y) * 0.5,
        };
    }
    if (points.len == 1) return .{ .x = points[0].x, .y = points[0].y };
    return .{ .x = 0, .y = 0 };
}

/// Build animation data from scaled contours.
/// Each contour is flattened into segments (owned by the returned GlyphAnimation).
pub fn buildAnimation(
    allocator: std.mem.Allocator,
    scaled_contours: []const []const outline_mod.ScaledPoint,
    options: ContourTraceOptions,
) !GlyphAnimation {
    const n = scaled_contours.len;

    // Step 1: Flatten all contours into a temporary array
    const flat_segs = try allocator.alloc([]Segment, n);
    var flat_count: usize = 0;
    errdefer {
        for (flat_segs[0..flat_count]) |s| allocator.free(s);
        allocator.free(flat_segs);
    }

    for (scaled_contours, 0..) |pts, i| {
        flat_segs[i] = try outline_mod.flattenContour(allocator, pts);
        flat_count += 1;
    }

    // Step 2: Build index array [0, 1, 2, ..., n-1]
    const indices = try allocator.alloc(usize, n);
    defer allocator.free(indices);
    for (0..n) |i| indices[i] = i;

    // Step 3: Sort indices based on ordering mode
    switch (options.ordering) {
        .font_order => {
            // No sorting needed
        },
        .stroke_heuristic => {
            const StrokeCtx = struct {
                contours: []const []const outline_mod.ScaledPoint,
                fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    const pa = findStartPoint(ctx.contours[a]);
                    const pb = findStartPoint(ctx.contours[b]);
                    // Sort by y ascending, with 1.0px tolerance
                    if (@abs(pa.y - pb.y) > 1.0) return pa.y < pb.y;
                    // Same row: sort by x ascending
                    return pa.x < pb.x;
                }
            };
            std.mem.sort(usize, indices, StrokeCtx{ .contours = scaled_contours }, StrokeCtx.lessThan);
        },
        .area_priority => {
            // Compute areas for all contours
            const areas = try allocator.alloc(f32, n);
            defer allocator.free(areas);
            for (0..n) |i| {
                areas[i] = computeSignedArea(flat_segs[i]);
            }
            const AreaCtx = struct {
                areas: []const f32,
                fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    // Largest absolute area first (descending)
                    return @abs(ctx.areas[a]) > @abs(ctx.areas[b]);
                }
            };
            std.mem.sort(usize, indices, AreaCtx{ .areas = areas }, AreaCtx.lessThan);
        },
        .writing_order => {
            const WritingCtx = struct {
                flat_segs: []const []const Segment,
                fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    const ca = computeCentroid(ctx.flat_segs[a]);
                    const cb = computeCentroid(ctx.flat_segs[b]);
                    // Primary: left-to-right (x ascending), with tolerance for same column
                    if (@abs(ca.x - cb.x) > 5.0) return ca.x < cb.x;
                    // Secondary: top-to-bottom (y ascending)
                    return ca.y < cb.y;
                }
            };
            std.mem.sort(usize, indices, WritingCtx{ .flat_segs = flat_segs }, WritingCtx.lessThan);
        },
    }

    // Step 4: Build AnimContour array in sorted order
    const contours = try allocator.alloc(AnimContour, n);
    errdefer allocator.free(contours);

    var global_offset: f32 = 0.0;
    var total_animation_length: f32 = 0.0;
    var num_initialized: usize = 0;

    errdefer {
        for (contours[0..num_initialized]) |c| {
            allocator.free(c.segments);
            allocator.free(c.cumulative_lengths);
        }
    }

    for (indices) |orig_idx| {
        const segments = flat_segs[orig_idx];

        const cumulative_lengths = try allocator.alloc(f32, segments.len);
        errdefer allocator.free(cumulative_lengths);

        var running: f32 = 0.0;
        for (segments, 0..) |seg, j| {
            running += segmentLength(seg);
            cumulative_lengths[j] = running;
        }

        const contour_total = running;

        contours[num_initialized] = .{
            .segments = segments,
            .cumulative_lengths = cumulative_lengths,
            .total_length = contour_total,
            .global_offset = global_offset,
        };
        num_initialized += 1;

        global_offset += contour_total;
        total_animation_length += contour_total;
    }

    // Step 5: Transfer ownership - prevent errdefer from freeing segments
    flat_count = 0;
    allocator.free(flat_segs);

    return .{
        .contours = contours,
        .total_length = total_animation_length,
        .allocator = allocator,
    };
}

/// Extract partial segments up to the given progress [0.0, 1.0].
/// Returns an owned slice of segments. Caller must free with allocator.free().
pub fn getPartialSegments(
    allocator: std.mem.Allocator,
    animation: GlyphAnimation,
    progress: f32,
) ![]Segment {
    if (animation.total_length <= 0.0 or progress <= 0.0) {
        return try allocator.alloc(Segment, 0);
    }

    const clamped = std.math.clamp(progress, 0.0, 1.0);
    const target_length = animation.total_length * clamped;

    var result: std.ArrayList(Segment) = .empty;
    errdefer result.deinit(allocator);

    for (animation.contours) |contour| {
        if (target_length <= contour.global_offset) {
            // Contour not yet reached
            break;
        }

        if (target_length >= contour.global_offset + contour.total_length) {
            // Include all segments of this contour
            try result.appendSlice(allocator, contour.segments);
            continue;
        }

        // Partial contour
        const local_target = target_length - contour.global_offset;

        // Find the segment index where cumulative_lengths[j] >= local_target
        var split_idx: usize = 0;
        for (contour.cumulative_lengths, 0..) |cum, j| {
            if (cum >= local_target) {
                split_idx = j;
                break;
            }
        }

        // Include all segments before split_idx
        if (split_idx > 0) {
            try result.appendSlice(allocator, contour.segments[0..split_idx]);
        }

        // Split the current segment at the fractional point
        const seg = contour.segments[split_idx];
        const prev_cum: f32 = if (split_idx > 0) contour.cumulative_lengths[split_idx - 1] else 0.0;
        const seg_len = segmentLength(seg);
        const t: f32 = if (seg_len > 0.0) (local_target - prev_cum) / seg_len else 0.0;
        const partial_seg = splitSegment(seg, std.math.clamp(t, 0.0, 1.0));
        try result.append(allocator, partial_seg);

        // Auto-close: add a segment from the endpoint of the last included segment
        // back to the contour start point, unless they are very close.
        const end_x = partial_seg.x1;
        const end_y = partial_seg.y1;
        const start_x = contour.segments[0].x0;
        const start_y = contour.segments[0].y0;
        const cdx = end_x - start_x;
        const cdy = end_y - start_y;
        const dist = @sqrt(cdx * cdx + cdy * cdy);
        if (dist >= 0.001) {
            try result.append(allocator, .{
                .x0 = end_x,
                .y0 = end_y,
                .x1 = start_x,
                .y1 = start_y,
            });
        }

        // Stop processing further contours
        break;
    }

    return result.toOwnedSlice(allocator);
}

test "segmentLength" {
    const seg = Segment{ .x0 = 0, .y0 = 0, .x1 = 3, .y1 = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), segmentLength(seg), 0.0001);
}

test "splitSegment" {
    const seg = Segment{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0 };

    // t=0.5
    const half = splitSegment(seg, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), half.x0, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), half.y0, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), half.x1, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), half.y1, 0.0001);

    // t=0 gives start point
    const zero = splitSegment(seg, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), zero.x1, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), zero.y1, 0.0001);

    // t=1 gives full segment
    const full = splitSegment(seg, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 10), full.x1, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), full.y1, 0.0001);
}

test "buildAnimation basic" {
    const points = [_]outline_mod.ScaledPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 10, .on_curve = true },
        .{ .x = 0, .y = 10, .on_curve = true },
    };
    const scaled_contours: [1][]const outline_mod.ScaledPoint = .{&points};
    var anim = try buildAnimation(std.testing.allocator, &scaled_contours, .{});
    defer anim.deinit();

    try std.testing.expectEqual(@as(usize, 1), anim.contours.len);

    // Perimeter of 10x10 square = 40
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), anim.total_length, 0.01);

    // cumulative_lengths is monotonically increasing
    const cum = anim.contours[0].cumulative_lengths;
    for (1..cum.len) |i| {
        try std.testing.expect(cum[i] > cum[i - 1]);
    }
}

test "getPartialSegments progress=0" {
    const points = [_]outline_mod.ScaledPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 10, .on_curve = true },
        .{ .x = 0, .y = 10, .on_curve = true },
    };
    const scaled_contours: [1][]const outline_mod.ScaledPoint = .{&points};
    var anim = try buildAnimation(std.testing.allocator, &scaled_contours, .{});
    defer anim.deinit();

    const segs = try getPartialSegments(std.testing.allocator, anim, 0.0);
    defer std.testing.allocator.free(segs);

    try std.testing.expectEqual(@as(usize, 0), segs.len);
}

test "getPartialSegments progress=1" {
    const points = [_]outline_mod.ScaledPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 10, .on_curve = true },
        .{ .x = 0, .y = 10, .on_curve = true },
    };
    const scaled_contours: [1][]const outline_mod.ScaledPoint = .{&points};
    var anim = try buildAnimation(std.testing.allocator, &scaled_contours, .{});
    defer anim.deinit();

    const total_segs = anim.contours[0].segments.len;

    const segs = try getPartialSegments(std.testing.allocator, anim, 1.0);
    defer std.testing.allocator.free(segs);

    try std.testing.expectEqual(total_segs, segs.len);
}

test "getPartialSegments progress=0.5 with auto-close" {
    const points = [_]outline_mod.ScaledPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 0, .on_curve = true },
        .{ .x = 10, .y = 10, .on_curve = true },
        .{ .x = 0, .y = 10, .on_curve = true },
    };
    const scaled_contours: [1][]const outline_mod.ScaledPoint = .{&points};
    var anim = try buildAnimation(std.testing.allocator, &scaled_contours, .{});
    defer anim.deinit();

    const segs = try getPartialSegments(std.testing.allocator, anim, 0.5);
    defer std.testing.allocator.free(segs);

    try std.testing.expect(segs.len > 0);

    // The last segment's endpoint should match the first segment's start point (auto-close)
    const last = segs[segs.len - 1];
    const first = segs[0];
    try std.testing.expectApproxEqAbs(first.x0, last.x1, 0.001);
    try std.testing.expectApproxEqAbs(first.y0, last.y1, 0.001);
}

test "stroke_heuristic orders by position" {
    // Contour A: starts at (50, 50)
    const points_a = [_]outline_mod.ScaledPoint{
        .{ .x = 50, .y = 50, .on_curve = true },
        .{ .x = 60, .y = 50, .on_curve = true },
        .{ .x = 60, .y = 60, .on_curve = true },
        .{ .x = 50, .y = 60, .on_curve = true },
    };
    // Contour B: starts at (10, 10) - should come first
    const points_b = [_]outline_mod.ScaledPoint{
        .{ .x = 10, .y = 10, .on_curve = true },
        .{ .x = 20, .y = 10, .on_curve = true },
        .{ .x = 20, .y = 20, .on_curve = true },
        .{ .x = 10, .y = 20, .on_curve = true },
    };

    const contours: [2][]const outline_mod.ScaledPoint = .{ &points_a, &points_b };
    var anim = try buildAnimation(std.testing.allocator, &contours, .{ .ordering = .stroke_heuristic });
    defer anim.deinit();

    // First contour should be the one starting at (10,10) - smaller y, then smaller x
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), anim.contours[0].segments[0].x0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), anim.contours[0].segments[0].y0, 0.01);
}

test "area_priority orders by area descending" {
    // Large contour (100x100)
    const large = [_]outline_mod.ScaledPoint{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 100, .y = 0, .on_curve = true },
        .{ .x = 100, .y = 100, .on_curve = true },
        .{ .x = 0, .y = 100, .on_curve = true },
    };
    // Small contour (10x10) - put it first in font order
    const small = [_]outline_mod.ScaledPoint{
        .{ .x = 30, .y = 30, .on_curve = true },
        .{ .x = 40, .y = 30, .on_curve = true },
        .{ .x = 40, .y = 40, .on_curve = true },
        .{ .x = 30, .y = 40, .on_curve = true },
    };

    const contours: [2][]const outline_mod.ScaledPoint = .{ &small, &large };
    var anim = try buildAnimation(std.testing.allocator, &contours, .{ .ordering = .area_priority });
    defer anim.deinit();

    // Large contour should come first (higher absolute area)
    try std.testing.expect(anim.contours[0].total_length > anim.contours[1].total_length);
}

test "computeSignedArea" {
    // 10x10 square: vertices (0,0), (10,0), (10,10), (0,10)
    // Shoelace via segments: area should be ±100
    const segs = [_]Segment{
        .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0 },
        .{ .x0 = 10, .y0 = 0, .x1 = 10, .y1 = 10 },
        .{ .x0 = 10, .y0 = 10, .x1 = 0, .y1 = 10 },
        .{ .x0 = 0, .y0 = 10, .x1 = 0, .y1 = 0 },
    };
    const area = computeSignedArea(&segs);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), @abs(area), 0.01);
}

test "font_order preserves original order" {
    const points_a = [_]outline_mod.ScaledPoint{
        .{ .x = 50, .y = 50, .on_curve = true },
        .{ .x = 60, .y = 50, .on_curve = true },
        .{ .x = 60, .y = 60, .on_curve = true },
        .{ .x = 50, .y = 60, .on_curve = true },
    };
    const points_b = [_]outline_mod.ScaledPoint{
        .{ .x = 10, .y = 10, .on_curve = true },
        .{ .x = 20, .y = 10, .on_curve = true },
        .{ .x = 20, .y = 20, .on_curve = true },
        .{ .x = 10, .y = 20, .on_curve = true },
    };

    const contours: [2][]const outline_mod.ScaledPoint = .{ &points_a, &points_b };
    var anim = try buildAnimation(std.testing.allocator, &contours, .{ .ordering = .font_order });
    defer anim.deinit();

    // First contour should be the one starting at (50,50) - font order preserved
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), anim.contours[0].segments[0].x0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), anim.contours[0].segments[0].y0, 0.01);
}

test "writing_order: contours sorted by centroid position left-to-right then top-to-bottom" {
    const allocator = std.testing.allocator;

    // Contour 0: centered at roughly x=50, y=50 (top-left)
    const c0 = [_]outline_mod.ScaledPoint{
        .{ .x = 40, .y = 40, .on_curve = true },
        .{ .x = 60, .y = 40, .on_curve = true },
        .{ .x = 60, .y = 60, .on_curve = true },
        .{ .x = 40, .y = 60, .on_curve = true },
    };
    // Contour 1: centered at roughly x=150, y=50 (top-right)
    const c1 = [_]outline_mod.ScaledPoint{
        .{ .x = 140, .y = 40, .on_curve = true },
        .{ .x = 160, .y = 40, .on_curve = true },
        .{ .x = 160, .y = 60, .on_curve = true },
        .{ .x = 140, .y = 60, .on_curve = true },
    };
    // Contour 2: centered at roughly x=50, y=150 (bottom-left)
    const c2 = [_]outline_mod.ScaledPoint{
        .{ .x = 40, .y = 140, .on_curve = true },
        .{ .x = 60, .y = 140, .on_curve = true },
        .{ .x = 60, .y = 160, .on_curve = true },
        .{ .x = 40, .y = 160, .on_curve = true },
    };
    // Contour 3: centered at roughly x=150, y=150 (bottom-right)
    const c3 = [_]outline_mod.ScaledPoint{
        .{ .x = 140, .y = 140, .on_curve = true },
        .{ .x = 160, .y = 140, .on_curve = true },
        .{ .x = 160, .y = 160, .on_curve = true },
        .{ .x = 140, .y = 160, .on_curve = true },
    };

    // Input in reverse order: bottom-right, top-right, bottom-left, top-left
    const contours = [_][]const outline_mod.ScaledPoint{ &c3, &c1, &c2, &c0 };

    var anim = try buildAnimation(allocator, &contours, .{ .ordering = .writing_order });
    defer anim.deinit();

    // Expected order: c0(top-left), c2(bottom-left), c1(top-right), c3(bottom-right)
    // because x primary (left first), y secondary (top first within same x column)
    try std.testing.expectEqual(@as(usize, 4), anim.contours.len);

    // Verify ordering by checking segment positions
    // c0 segments are around (40-60, 40-60)
    try std.testing.expect(anim.contours[0].segments[0].x0 >= 39 and anim.contours[0].segments[0].x0 <= 61);
    // c2 segments are around (40-60, 140-160)
    try std.testing.expect(anim.contours[1].segments[0].y0 >= 139 and anim.contours[1].segments[0].y0 <= 161);
    // c1 segments are around (140-160, 40-60)
    try std.testing.expect(anim.contours[2].segments[0].x0 >= 139 and anim.contours[2].segments[0].x0 <= 161);
    // c3 segments are around (140-160, 140-160)
    try std.testing.expect(anim.contours[3].segments[0].x0 >= 139 and anim.contours[3].segments[0].x0 <= 161);
}
