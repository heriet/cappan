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

pub const StemHint = struct {
    position: f32,
    width: f32,
};

pub const BlueZones = struct {
    blue_values: [14]f32 = .{0} ** 14,
    blue_count: u8 = 0,
    other_blues: [10]f32 = .{0} ** 10,
    other_count: u8 = 0,
    blue_scale: f32 = 0.039625,
    blue_shift: f32 = 7,
    blue_fuzz: f32 = 1,
    std_hw: f32 = 0,
    std_vw: f32 = 0,
    snap_h: [12]f32 = .{0} ** 12,
    snap_h_count: u8 = 0,
    snap_v: [12]f32 = .{0} ** 12,
    snap_v_count: u8 = 0,
};

pub const HintMaskEntry = struct {
    data: [12]u8,
    point_index: u32,
    contour_index: u32,
    is_counter: bool,
};

pub const HintData = struct {
    h_stems: []StemHint,
    v_stems: []StemHint,
    masks: []HintMaskEntry,
    blue_zones: ?BlueZones = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HintData) void {
        self.allocator.free(self.h_stems);
        self.allocator.free(self.v_stems);
        self.allocator.free(self.masks);
    }
};

pub const GlyphOutline = struct {
    contours: []Contour,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    hints: ?HintData = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GlyphOutline) void {
        if (self.hints) |*h| h.deinit();
        for (self.contours) |contour| {
            self.allocator.free(contour.points);
        }
        self.allocator.free(self.contours);
    }
};
