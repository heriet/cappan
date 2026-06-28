const std = @import("std");
const os2_mod = @import("../font/table/os2.zig");
const glyph_mod = @import("../font/glyph.zig");

const MAX_AUTO_STEMS: usize = 32;

const Axis = enum { x, y };

const Extremum = struct {
    coord: i16,
    is_maximum: bool,
};

fn addBlueZone(bz: *glyph_mod.BlueZones, bottom: f32, top: f32) void {
    const idx = @as(usize, bz.blue_count);
    if (idx + 1 >= bz.blue_values.len) return;
    bz.blue_values[idx] = bottom;
    bz.blue_values[idx + 1] = top;
    bz.blue_count += 2;
}

pub fn inferBlueZones(
    os2: ?os2_mod.Os2Table,
    ascender: i16,
    descender: i16,
) glyph_mod.BlueZones {
    var bz: glyph_mod.BlueZones = .{};

    addBlueZone(&bz, -15, 0);

    if (os2) |o| {
        if (o.sx_height > 0) {
            const xh: f32 = @floatFromInt(o.sx_height);
            addBlueZone(&bz, xh - 15, xh);
        }
        if (o.s_cap_height > 0) {
            const ch: f32 = @floatFromInt(o.s_cap_height);
            addBlueZone(&bz, ch - 15, ch);
        }
        if (o.s_typo_ascender > 0) {
            const asc: f32 = @floatFromInt(o.s_typo_ascender);
            addBlueZone(&bz, asc - 15, asc);
        }
        if (o.s_typo_descender < 0) {
            const desc: f32 = @floatFromInt(o.s_typo_descender);
            bz.other_blues[0] = desc;
            bz.other_blues[1] = desc + 15;
            bz.other_count = 2;
        }
    } else {
        const asc: f32 = @floatFromInt(ascender);
        addBlueZone(&bz, asc - 15, asc);

        if (descender < 0) {
            const desc: f32 = @floatFromInt(descender);
            bz.other_blues[0] = desc;
            bz.other_blues[1] = desc + 15;
            bz.other_count = 2;
        }
    }

    bz.blue_fuzz = 1;
    bz.blue_scale = 0.039625;
    bz.blue_shift = 7;

    return bz;
}

fn findNearestOnCurve(points: []const glyph_mod.Point, start: usize, forward: bool, comptime axis: Axis) ?i16 {
    const n = points.len;
    var idx = start;
    var steps: usize = 0;
    while (steps < n) : (steps += 1) {
        idx = if (forward) (idx + 1) % n else (idx + n - 1) % n;
        if (points[idx].on_curve) return @field(points[idx], @tagName(axis));
    }
    return null;
}

fn collectAxisExtrema(
    points: []const glyph_mod.Point,
    extrema: *[256]Extremum,
    count: *usize,
    comptime axis: Axis,
) void {
    const n = points.len;
    if (n < 3) return;

    for (0..n) |i| {
        const curr = points[i];
        if (!curr.on_curve) continue;

        const prev_coord = findNearestOnCurve(points, i, false, axis) orelse continue;
        const next_coord = findNearestOnCurve(points, i, true, axis) orelse continue;
        const curr_coord = @field(curr, @tagName(axis));

        if (count.* >= 256) return;

        if (curr_coord >= prev_coord and curr_coord >= next_coord) {
            extrema[count.*] = .{ .coord = curr_coord, .is_maximum = true };
            count.* += 1;
        } else if (curr_coord <= prev_coord and curr_coord <= next_coord) {
            extrema[count.*] = .{ .coord = curr_coord, .is_maximum = false };
            count.* += 1;
        }
    }
}

fn detectStemsFromExtrema(
    extrema: []const Extremum,
    stems: *[MAX_AUTO_STEMS]glyph_mod.StemHint,
    count: *usize,
) void {
    var sorted: [256]Extremum = undefined;
    const n = @min(extrema.len, 256);
    @memcpy(sorted[0..n], extrema[0..n]);
    std.sort.insertion(Extremum, sorted[0..n], {}, struct {
        fn lessThan(_: void, a: Extremum, b: Extremum) bool {
            return a.coord < b.coord;
        }
    }.lessThan);

    var used: [256]bool = undefined;
    @memset(&used, false);

    for (0..n) |i| {
        if (used[i]) continue;
        if (sorted[i].is_maximum) continue;

        var best_j: ?usize = null;
        var best_dist: i32 = std.math.maxInt(i32);

        for (0..n) |j| {
            if (i == j or used[j]) continue;
            if (!sorted[j].is_maximum) continue;

            const dist = @as(i32, sorted[j].coord) - @as(i32, sorted[i].coord);
            if (dist <= 0) continue;

            if (dist < best_dist) {
                best_dist = dist;
                best_j = j;
            }
        }

        if (best_j) |j| {
            if (count.* < MAX_AUTO_STEMS) {
                const pos: f32 = @floatFromInt(sorted[i].coord);
                const width: f32 = @floatFromInt(best_dist);

                var duplicate = false;
                for (0..count.*) |k| {
                    if (@abs(stems[k].position - pos) < 5 and
                        @abs(stems[k].width - width) < 5)
                    {
                        duplicate = true;
                        break;
                    }
                }

                if (!duplicate) {
                    stems[count.*] = .{ .position = pos, .width = width };
                    count.* += 1;
                    used[i] = true;
                    used[j] = true;
                }
            }
        }
    }
}

pub fn generateHints(
    allocator: std.mem.Allocator,
    outline: glyph_mod.GlyphOutline,
    blue_zones: ?glyph_mod.BlueZones,
) !?glyph_mod.HintData {
    var y_extrema_buf: [256]Extremum = undefined;
    var x_extrema_buf: [256]Extremum = undefined;
    var y_count: usize = 0;
    var x_count: usize = 0;

    for (outline.contours) |contour| {
        if (contour.points.len < 3) continue;
        collectAxisExtrema(contour.points, &y_extrema_buf, &y_count, .y);
        collectAxisExtrema(contour.points, &x_extrema_buf, &x_count, .x);
    }

    if (y_count == 0 and x_count == 0) return null;

    var h_stems_buf: [MAX_AUTO_STEMS]glyph_mod.StemHint = undefined;
    var v_stems_buf: [MAX_AUTO_STEMS]glyph_mod.StemHint = undefined;
    var h_stem_count: usize = 0;
    var v_stem_count: usize = 0;

    detectStemsFromExtrema(y_extrema_buf[0..y_count], &h_stems_buf, &h_stem_count);
    detectStemsFromExtrema(x_extrema_buf[0..x_count], &v_stems_buf, &v_stem_count);

    if (h_stem_count == 0 and v_stem_count == 0) return null;

    const h_stems = try allocator.alloc(glyph_mod.StemHint, h_stem_count);
    errdefer allocator.free(h_stems);
    @memcpy(h_stems, h_stems_buf[0..h_stem_count]);

    const v_stems = try allocator.alloc(glyph_mod.StemHint, v_stem_count);
    errdefer allocator.free(v_stems);
    @memcpy(v_stems, v_stems_buf[0..v_stem_count]);

    const masks = try allocator.alloc(glyph_mod.HintMaskEntry, 0);

    return .{
        .h_stems = h_stems,
        .v_stems = v_stems,
        .masks = masks,
        .blue_zones = blue_zones,
        .allocator = allocator,
    };
}

test "generateHints with rectangular outline detects stems" {
    const allocator = std.testing.allocator;

    var points = [_]glyph_mod.Point{
        .{ .x = 0, .y = 0, .on_curve = true },
        .{ .x = 100, .y = 0, .on_curve = true },
        .{ .x = 100, .y = 200, .on_curve = true },
        .{ .x = 0, .y = 200, .on_curve = true },
    };
    var contours = [_]glyph_mod.Contour{
        .{ .points = &points },
    };
    const outline = glyph_mod.GlyphOutline{
        .contours = &contours,
        .x_min = 0,
        .y_min = 0,
        .x_max = 100,
        .y_max = 200,
        .allocator = allocator,
    };

    const result = try generateHints(allocator, outline, null);
    try std.testing.expect(result != null);
    var hint_data = result.?;
    defer hint_data.deinit();

    try std.testing.expect(hint_data.h_stems.len >= 1);
    try std.testing.expectApproxEqAbs(hint_data.h_stems[0].position, 0.0, 0.01);
    try std.testing.expectApproxEqAbs(hint_data.h_stems[0].width, 200.0, 0.01);

    try std.testing.expect(hint_data.v_stems.len >= 1);
    try std.testing.expectApproxEqAbs(hint_data.v_stems[0].position, 0.0, 0.01);
    try std.testing.expectApproxEqAbs(hint_data.v_stems[0].width, 100.0, 0.01);
}

test "generateHints with empty contour returns null" {
    const allocator = std.testing.allocator;

    const outline = glyph_mod.GlyphOutline{
        .contours = &[_]glyph_mod.Contour{},
        .x_min = 0,
        .y_min = 0,
        .x_max = 0,
        .y_max = 0,
        .allocator = allocator,
    };

    const result = try generateHints(allocator, outline, null);
    try std.testing.expect(result == null);
}

test "inferBlueZones with OS/2 sets baseline and x-height" {
    const os2 = os2_mod.Os2Table{
        .version = 4,
        .us_weight_class = 400,
        .s_typo_ascender = 800,
        .s_typo_descender = -200,
        .sx_height = 500,
        .s_cap_height = 700,
    };

    const bz = inferBlueZones(os2, 0, 0);

    try std.testing.expect(bz.blue_count >= 4);
    try std.testing.expectApproxEqAbs(bz.blue_values[0], -15.0, 0.01);
    try std.testing.expectApproxEqAbs(bz.blue_values[1], 0.0, 0.01);
    try std.testing.expectApproxEqAbs(bz.blue_values[2], 485.0, 0.01);
    try std.testing.expectApproxEqAbs(bz.blue_values[3], 500.0, 0.01);
}

test "inferBlueZones without OS/2 falls back to hhea" {
    const bz = inferBlueZones(null, 800, -200);

    try std.testing.expect(bz.blue_count == 4);
}
