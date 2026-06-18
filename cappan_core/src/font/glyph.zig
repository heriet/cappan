const std = @import("std");

pub const Point = struct {
    x: i16,
    y: i16,
    on_curve: bool,
    is_cubic: bool = false, // true for CFF cubic Bezier control points
};

pub const Contour = struct {
    points: []Point,
};

pub const GlyphOutline = struct {
    contours: []Contour,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GlyphOutline) void {
        for (self.contours) |contour| {
            self.allocator.free(contour.points);
        }
        self.allocator.free(self.contours);
    }
};
