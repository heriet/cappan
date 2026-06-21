const rgba_bitmap_mod = @import("rgba_bitmap.zig");
const stroker_mod = @import("../raster/stroker.zig");

pub const Color = rgba_bitmap_mod.Color;
pub const LineJoin = stroker_mod.LineJoin;
pub const StrokePosition = stroker_mod.StrokePosition;

pub const StrokeWidth = union(enum) {
    px: f32,
    em: f32,

    pub fn resolveToPixels(self: StrokeWidth, pixel_size: f32) f32 {
        return switch (self) {
            .px => |v| v,
            .em => |v| v * pixel_size,
        };
    }
};

pub const FillPaint = struct {
    color: Color,
    opacity: f32 = 1.0,
    time_weight: f32 = 1.0,
};

pub const StrokePaint = struct {
    color: Color,
    width: StrokeWidth = .{ .px = 1.0 },
    opacity: f32 = 1.0,
    join: LineJoin = .round,
    position: StrokePosition = .outside,
    miter_limit: f32 = 4.0,
    time_weight: f32 = 1.0,
};

pub const PaintOperation = union(enum) {
    fill: FillPaint,
    stroke: StrokePaint,

    pub fn timeWeight(self: PaintOperation) f32 {
        return switch (self) {
            .fill => |f| f.time_weight,
            .stroke => |s| s.time_weight,
        };
    }
};

test "stroke width resolves to pixels" {
    const std = @import("std");
    try std.testing.expectEqual(@as(f32, 3.0), (StrokeWidth{ .px = 3.0 }).resolveToPixels(16.0));
    try std.testing.expectEqual(@as(f32, 8.0), (StrokeWidth{ .em = 0.5 }).resolveToPixels(16.0));
}
