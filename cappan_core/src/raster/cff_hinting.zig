const std = @import("std");
const glyph_mod = @import("../font/glyph.zig");
const outline_mod = @import("outline.zig");

const ScaledStem = struct {
    orig_pos: f32,
    orig_width: f32,
    new_pos: f32,
    new_width: f32,
};

const MAX_STEMS = 96;

pub const HintMap = struct {
    h_stems: [MAX_STEMS]ScaledStem,
    v_stems: [MAX_STEMS]ScaledStem,
    h_count: usize,
    v_count: usize,
};

fn snapStemWidth(w: f32) f32 {
    return if (w < 1.0) 1.0 else @round(w);
}

fn scaleStem(stem: glyph_mod.StemHint, scale: f32) ScaledStem {
    const orig_pos = stem.position * scale;
    const orig_width = @abs(stem.width) * scale;
    const new_width = snapStemWidth(orig_width);
    const center = orig_pos + orig_width * 0.5;
    const snapped_center = @round(center * 2.0) / 2.0;
    return .{
        .orig_pos = orig_pos,
        .orig_width = orig_width,
        .new_pos = snapped_center - new_width * 0.5,
        .new_width = new_width,
    };
}

fn applyBlueZoneSnap(stem: *ScaledStem, bz: glyph_mod.BlueZones, scale: f32) void {
    const fuzz = bz.blue_fuzz * scale;
    const edge_bottom = stem.new_pos;
    const edge_top = stem.new_pos + stem.new_width;

    var zi: usize = 0;
    while (zi + 1 < bz.blue_count) : (zi += 2) {
        const zone_bottom = bz.blue_values[zi] * scale;
        const zone_top = bz.blue_values[zi + 1] * scale;
        if (zi == 0) {
            if (@abs(edge_bottom - zone_bottom) < fuzz or
                (edge_bottom >= zone_bottom and edge_bottom <= zone_top))
            {
                stem.new_pos = @round(zone_bottom);
                return;
            }
        } else {
            if (@abs(edge_top - zone_top) < fuzz or
                (edge_top >= zone_bottom and edge_top <= zone_top))
            {
                stem.new_pos = @round(zone_top) - stem.new_width;
                return;
            }
        }
    }

    zi = 0;
    while (zi + 1 < bz.other_count) : (zi += 2) {
        const zone_bottom = bz.other_blues[zi] * scale;
        const zone_top = bz.other_blues[zi + 1] * scale;
        if (@abs(edge_bottom - zone_bottom) < fuzz or
            (edge_bottom >= zone_bottom and edge_bottom <= zone_top))
        {
            stem.new_pos = @round(zone_bottom);
            return;
        }
    }
}

pub fn buildHintMap(
    h_stems: []const glyph_mod.StemHint,
    v_stems: []const glyph_mod.StemHint,
    blue_zones: ?glyph_mod.BlueZones,
    scale: f32,
) HintMap {
    var map: HintMap = .{
        .h_stems = undefined,
        .v_stems = undefined,
        .h_count = @min(h_stems.len, MAX_STEMS),
        .v_count = @min(v_stems.len, MAX_STEMS),
    };

    for (0..map.h_count) |i| {
        map.h_stems[i] = scaleStem(h_stems[i], scale);
        if (blue_zones) |bz| {
            applyBlueZoneSnap(&map.h_stems[i], bz, scale);
        }
    }

    for (0..map.v_count) |i| {
        map.v_stems[i] = scaleStem(v_stems[i], scale);
    }

    return map;
}

fn interpolateDelta(coord: f32, stems: []const ScaledStem, count: usize) f32 {
    if (count == 0) return 0.0;
    const s = stems[0..count];

    if (coord <= s[0].orig_pos) {
        return s[0].new_pos - s[0].orig_pos;
    }

    for (0..count) |i| {
        const orig_bottom = s[i].orig_pos;
        const orig_top = orig_bottom + s[i].orig_width;
        const new_bottom = s[i].new_pos;
        const new_top = new_bottom + s[i].new_width;
        const bottom_delta = new_bottom - orig_bottom;
        const top_delta = new_top - orig_top;

        if (coord >= orig_bottom and coord <= orig_top) {
            if (s[i].orig_width > 0.001) {
                const t = (coord - orig_bottom) / s[i].orig_width;
                return bottom_delta + (top_delta - bottom_delta) * t;
            }
            return bottom_delta;
        }

        if (i + 1 < count) {
            const next_bottom = s[i + 1].orig_pos;
            if (coord < next_bottom) {
                const gap = next_bottom - orig_top;
                if (gap > 0.001) {
                    const next_new_bottom = s[i + 1].new_pos;
                    const next_bottom_delta = next_new_bottom - next_bottom;
                    const t = (coord - orig_top) / gap;
                    return top_delta + (next_bottom_delta - top_delta) * t;
                }
                return top_delta;
            }
        }
    }

    const last = s[count - 1];
    return (last.new_pos + last.new_width) - (last.orig_pos + last.orig_width);
}

pub fn applyHints(
    contours: [][]outline_mod.ScaledPoint,
    hint_data: glyph_mod.HintData,
    scale: f32,
) void {
    const map = buildHintMap(hint_data.h_stems, hint_data.v_stems, hint_data.blue_zones, scale);

    for (contours) |contour| {
        for (contour) |*pt| {
            pt.y -= interpolateDelta(pt.y, &map.h_stems, map.h_count);
            pt.x += interpolateDelta(pt.x, &map.v_stems, map.v_count);
        }
    }
}

test "buildHintMap snaps stem width" {
    const stems = [_]glyph_mod.StemHint{
        .{ .position = 0, .width = 100 },
    };
    const map = buildHintMap(&stems, &.{}, null, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), map.h_stems[0].new_width, 0.01);
}

test "buildHintMap snaps thin stem to 1px" {
    const stems = [_]glyph_mod.StemHint{
        .{ .position = 0, .width = 30 },
    };
    const map = buildHintMap(&stems, &.{}, null, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), map.h_stems[0].new_width, 0.01);
}

test "interpolateDelta returns 0 with no stems" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), interpolateDelta(5.0, &.{}, 0), 0.001);
}

test "applyHints with no hint data does not crash" {
    var pts = [_]outline_mod.ScaledPoint{
        .{ .x = 1.0, .y = 2.0, .on_curve = true },
    };
    var contour = [_][]outline_mod.ScaledPoint{&pts};
    const hint_data = glyph_mod.HintData{
        .h_stems = &.{},
        .v_stems = &.{},
        .masks = &.{},
        .allocator = std.testing.allocator,
    };
    applyHints(&contour, hint_data, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pts[0].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), pts[0].y, 0.001);
}
