const std = @import("std");
const parser = @import("../parser.zig");
const ivs = @import("item_variation_store.zig");
const ft = @import("../../features.zig").features;

pub const ColorLayer = struct {
    glyph_id: u16,
    palette_index: u16,
};

pub const BaseGlyphRecord = struct {
    glyph_id: u16,
    first_layer_idx: u16,
    num_layers: u16,
};

pub const ExtendMode = enum(u8) {
    pad = 0,
    repeat = 1,
    reflect = 2,
    _,
};

pub const ColorStop = struct {
    stop_offset: f32,
    palette_index: u16,
    alpha: f32,
};

pub const ColorLine = struct {
    extend: ExtendMode,
    stops: []ColorStop,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ColorLine) void {
        self.allocator.free(self.stops);
    }
};

pub const ClipBox = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

pub const CompositeMode = enum(u8) {
    clear = 0,
    src = 1,
    dest = 2,
    src_over = 3,
    dest_over = 4,
    src_in = 5,
    dest_in = 6,
    src_out = 7,
    dest_out = 8,
    src_atop = 9,
    dest_atop = 10,
    xor = 11,
    plus = 12,
    screen = 13,
    overlay = 14,
    darken = 15,
    lighten = 16,
    color_dodge = 17,
    color_burn = 18,
    hard_light = 19,
    soft_light = 20,
    difference = 21,
    exclusion = 22,
    multiply = 23,
    hsl_hue = 24,
    hsl_saturation = 25,
    hsl_color = 26,
    hsl_luminosity = 27,
    _,
};

pub const PaintColrLayers = struct {
    num_layers: u8,
    first_layer_index: u32,
};

pub const PaintSolid = struct {
    palette_index: u16,
    alpha: f32,
};

pub const PaintLinearGradient = struct {
    color_line_offset: u32,
    x0: i16,
    y0: i16,
    x1: i16,
    y1: i16,
    x2: i16,
    y2: i16,
    is_var: bool,
};

pub const PaintRadialGradient = struct {
    color_line_offset: u32,
    x0: i16,
    y0: i16,
    radius0: u16,
    x1: i16,
    y1: i16,
    radius1: u16,
    is_var: bool,
};

pub const PaintSweepGradient = struct {
    color_line_offset: u32,
    center_x: i16,
    center_y: i16,
    start_angle: f32,
    end_angle: f32,
    is_var: bool,
};

pub const PaintGlyph = struct {
    paint_offset: u32,
    glyph_id: u16,
};

pub const PaintColrGlyph = struct {
    glyph_id: u16,
};

pub const PaintTransform = struct {
    paint_offset: u32,
    xx: f32,
    yx: f32,
    xy: f32,
    yy: f32,
    dx: f32,
    dy: f32,
};

pub const PaintTranslate = struct {
    paint_offset: u32,
    dx: i16,
    dy: i16,
};

pub const PaintScale = struct {
    paint_offset: u32,
    scale_x: f32,
    scale_y: f32,
};

pub const PaintScaleAroundCenter = struct {
    paint_offset: u32,
    scale_x: f32,
    scale_y: f32,
    center_x: i16,
    center_y: i16,
};

pub const PaintScaleUniform = struct {
    paint_offset: u32,
    scale: f32,
};

pub const PaintScaleUniformAroundCenter = struct {
    paint_offset: u32,
    scale: f32,
    center_x: i16,
    center_y: i16,
};

pub const PaintRotate = struct {
    paint_offset: u32,
    angle: f32,
};

pub const PaintRotateAroundCenter = struct {
    paint_offset: u32,
    angle: f32,
    center_x: i16,
    center_y: i16,
};

pub const PaintSkew = struct {
    paint_offset: u32,
    x_skew_angle: f32,
    y_skew_angle: f32,
};

pub const PaintSkewAroundCenter = struct {
    paint_offset: u32,
    x_skew_angle: f32,
    y_skew_angle: f32,
    center_x: i16,
    center_y: i16,
};

pub const PaintComposite = struct {
    source_paint_offset: u32,
    mode: CompositeMode,
    backdrop_paint_offset: u32,
};

pub const Paint = union(enum) {
    colr_layers: PaintColrLayers,
    solid: PaintSolid,
    linear_gradient: PaintLinearGradient,
    radial_gradient: PaintRadialGradient,
    sweep_gradient: PaintSweepGradient,
    glyph: PaintGlyph,
    colr_glyph: PaintColrGlyph,
    transform: PaintTransform,
    translate: PaintTranslate,
    scale: PaintScale,
    scale_around_center: PaintScaleAroundCenter,
    scale_uniform: PaintScaleUniform,
    scale_uniform_around_center: PaintScaleUniformAroundCenter,
    rotate: PaintRotate,
    rotate_around_center: PaintRotateAroundCenter,
    skew: PaintSkew,
    skew_around_center: PaintSkewAroundCenter,
    composite: PaintComposite,
};

pub const ColrTable = struct {
    data: []const u8,
    version: u16,
    num_base_glyphs: u16,
    base_glyph_offset: u32,
    layer_offset: u32,
    num_layers: u16,
    // v1 fields
    base_glyph_list_offset: u32,
    layer_list_offset: u32,
    clip_list_offset: u32,
    var_index_map_offset: u32,
    item_variation_store_offset: u32,

    pub fn findBaseGlyph(self: ColrTable, glyph_id: u16) ?BaseGlyphRecord {
        var lo: u32 = 0;
        var hi: u32 = self.num_base_glyphs;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const offset = std.math.add(u32, self.base_glyph_offset, mid * 6) catch return null;
            const offset_usize: usize = @intCast(offset);
            const id = parser.readU16(self.data, offset_usize) catch return null;
            if (id < glyph_id) {
                lo = mid + 1;
            } else if (id > glyph_id) {
                hi = mid;
            } else {
                return BaseGlyphRecord{
                    .glyph_id = id,
                    .first_layer_idx = parser.readU16(self.data, offset_usize + 2) catch return null,
                    .num_layers = parser.readU16(self.data, offset_usize + 4) catch return null,
                };
            }
        }
        return null;
    }

    pub fn getLayer(self: ColrTable, layer_idx: u16) ?ColorLayer {
        if (layer_idx >= self.num_layers) return null;
        const offset = std.math.add(u32, self.layer_offset, @as(u32, layer_idx) * 4) catch return null;
        const offset_usize: usize = @intCast(offset);
        return ColorLayer{
            .glyph_id = parser.readU16(self.data, offset_usize) catch return null,
            .palette_index = parser.readU16(self.data, offset_usize + 2) catch return null,
        };
    }

    /// Find the absolute paint offset for a v1 base glyph, or null if not found.
    pub fn findBaseGlyphV1Paint(self: ColrTable, glyph_id: u16) ?u32 {
        if (comptime !ft.enable_colr_v1) return null;
        if (self.version < 1 or self.base_glyph_list_offset == 0) return null;
        const list_off: usize = @intCast(self.base_glyph_list_offset);
        const num_records = parser.readU32(self.data, list_off) catch return null;
        // Binary search over BaseGlyphPaintRecord (6 bytes each: u16 glyphID + u32 paintOffset)
        var lo: u32 = 0;
        var hi: u32 = num_records;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const prod = std.math.mul(usize, @as(usize, mid), 6) catch return null;
            const rec_off = std.math.add(usize, std.math.add(usize, list_off, 4) catch return null, prod) catch return null;
            const id = parser.readU16(self.data, rec_off) catch return null;
            if (id < glyph_id) {
                lo = mid + 1;
            } else if (id > glyph_id) {
                hi = mid;
            } else {
                const paint_rel = parser.readU32(self.data, rec_off + 2) catch return null;
                return std.math.add(u32, self.base_glyph_list_offset, paint_rel) catch return null;
            }
        }
        return null;
    }

    /// Return the absolute paint offset for a given layer index, or null.
    pub fn getLayerListPaint(self: ColrTable, layer_index: u32) ?u32 {
        if (comptime !ft.enable_colr_v1) return null;
        if (self.layer_list_offset == 0) return null;
        const list_off: usize = @intCast(self.layer_list_offset);
        const num_layers = parser.readU32(self.data, list_off) catch return null;
        if (layer_index >= num_layers) return null;
        const prod = std.math.mul(usize, @as(usize, layer_index), 4) catch return null;
        const entry_off = std.math.add(usize, std.math.add(usize, list_off, 4) catch return null, prod) catch return null;
        const paint_rel = parser.readU32(self.data, entry_off) catch return null;
        return std.math.add(u32, self.layer_list_offset, paint_rel) catch return null;
    }

    fn readRelOffset(self: ColrTable, base: u32, field_off: usize) ?u32 {
        const rel = parser.readU24(self.data, field_off) catch return null;
        return std.math.add(u32, base, rel) catch return null;
    }

    // A truncated varIndexBase is treated as 'no variation' so that fonts that
    // rendered before variation support keep rendering (deltas simply stay 0).
    fn readVarIndexBase(self: ColrTable, offset: usize) u32 {
        return parser.readU32(self.data, offset) catch 0xFFFFFFFF;
    }

    fn varDeltaInt(self: ColrTable, var_index_base: u32, sub: u32, coords: []const f32) i32 {
        if (comptime !ft.enable_variable) return 0;
        if (coords.len == 0) return 0;
        if (self.item_variation_store_offset == 0) return 0;
        if (var_index_base == 0xFFFFFFFF) return 0;
        const var_index = std.math.add(u32, var_index_base, sub) catch return 0;
        return ivs.getDeltaForVarIndex(
            self.data,
            self.var_index_map_offset,
            self.item_variation_store_offset,
            var_index,
            coords,
        ) catch return 0;
    }

    fn varDeltaRaw(self: ColrTable, var_index_base: u32, sub: u32, coords: []const f32) f32 {
        return @floatFromInt(self.varDeltaInt(var_index_base, sub, coords));
    }

    fn addI16(self: ColrTable, raw: i16, var_index_base: u32, sub: u32, coords: []const f32) i16 {
        // i64: raw + delta can exceed i32 when the delta is at the i32 extremes.
        const adjusted = @as(i64, raw) + self.varDeltaInt(var_index_base, sub, coords);
        return @intCast(std.math.clamp(adjusted, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    fn addU16(self: ColrTable, raw: u16, var_index_base: u32, sub: u32, coords: []const f32) u16 {
        const adjusted = @as(i64, raw) + self.varDeltaInt(var_index_base, sub, coords);
        return @intCast(std.math.clamp(adjusted, 0, std.math.maxInt(u16)));
    }

    fn addF2Dot14(self: ColrTable, raw: f32, var_index_base: u32, sub: u32, coords: []const f32) f32 {
        return raw + self.varDeltaRaw(var_index_base, sub, coords) / 16384.0;
    }

    fn addFixed(self: ColrTable, raw: f32, var_index_base: u32, sub: u32, coords: []const f32) f32 {
        return raw + self.varDeltaRaw(var_index_base, sub, coords) / 65536.0;
    }

    /// Parse a Paint record at the given absolute offset.
    pub fn readPaint(self: ColrTable, abs_offset: u32, coords: []const f32) ?Paint {
        if (comptime !ft.enable_colr_v1) return null;
        const off: usize = @intCast(abs_offset);
        if (off > std.math.maxInt(usize) - 24) return null;
        const fmt = parser.readU8(self.data, off) catch return null;
        switch (fmt) {
            // PaintColrLayers
            1 => {
                const num_layers = parser.readU8(self.data, off + 1) catch return null;
                const first_idx = parser.readU32(self.data, off + 2) catch return null;
                return Paint{ .colr_layers = .{
                    .num_layers = num_layers,
                    .first_layer_index = first_idx,
                } };
            },
            // PaintSolid, PaintVarSolid
            2, 3 => {
                const pal_idx = parser.readU16(self.data, off + 1) catch return null;
                var alpha = parser.readF2Dot14(self.data, off + 3) catch return null;
                if (fmt == 3) {
                    const vb = self.readVarIndexBase(off + 5);
                    alpha = self.addF2Dot14(alpha, vb, 0, coords);
                }
                return Paint{ .solid = .{
                    .palette_index = pal_idx,
                    .alpha = alpha,
                } };
            },
            // PaintLinearGradient, PaintVarLinearGradient
            4, 5 => {
                const cl_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var x0 = parser.readI16(self.data, off + 4) catch return null;
                var y0 = parser.readI16(self.data, off + 6) catch return null;
                var x1 = parser.readI16(self.data, off + 8) catch return null;
                var y1 = parser.readI16(self.data, off + 10) catch return null;
                var x2 = parser.readI16(self.data, off + 12) catch return null;
                var y2 = parser.readI16(self.data, off + 14) catch return null;
                if (fmt == 5) {
                    const vb = self.readVarIndexBase(off + 16);
                    x0 = self.addI16(x0, vb, 0, coords);
                    y0 = self.addI16(y0, vb, 1, coords);
                    x1 = self.addI16(x1, vb, 2, coords);
                    y1 = self.addI16(y1, vb, 3, coords);
                    x2 = self.addI16(x2, vb, 4, coords);
                    y2 = self.addI16(y2, vb, 5, coords);
                }
                return Paint{ .linear_gradient = .{
                    .color_line_offset = cl_abs,
                    .x0 = x0,
                    .y0 = y0,
                    .x1 = x1,
                    .y1 = y1,
                    .x2 = x2,
                    .y2 = y2,
                    .is_var = (fmt == 5),
                } };
            },
            // PaintRadialGradient, PaintVarRadialGradient
            6, 7 => {
                const cl_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var x0 = parser.readI16(self.data, off + 4) catch return null;
                var y0 = parser.readI16(self.data, off + 6) catch return null;
                var r0 = parser.readU16(self.data, off + 8) catch return null;
                var x1 = parser.readI16(self.data, off + 10) catch return null;
                var y1 = parser.readI16(self.data, off + 12) catch return null;
                var r1 = parser.readU16(self.data, off + 14) catch return null;
                if (fmt == 7) {
                    const vb = self.readVarIndexBase(off + 16);
                    x0 = self.addI16(x0, vb, 0, coords);
                    y0 = self.addI16(y0, vb, 1, coords);
                    r0 = self.addU16(r0, vb, 2, coords);
                    x1 = self.addI16(x1, vb, 3, coords);
                    y1 = self.addI16(y1, vb, 4, coords);
                    r1 = self.addU16(r1, vb, 5, coords);
                }
                return Paint{ .radial_gradient = .{
                    .color_line_offset = cl_abs,
                    .x0 = x0,
                    .y0 = y0,
                    .radius0 = r0,
                    .x1 = x1,
                    .y1 = y1,
                    .radius1 = r1,
                    .is_var = (fmt == 7),
                } };
            },
            // PaintSweepGradient, PaintVarSweepGradient
            8, 9 => {
                const cl_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var cx = parser.readI16(self.data, off + 4) catch return null;
                var cy = parser.readI16(self.data, off + 6) catch return null;
                var start_ang = parser.readF2Dot14(self.data, off + 8) catch return null;
                var end_ang = parser.readF2Dot14(self.data, off + 10) catch return null;
                if (fmt == 9) {
                    const vb = self.readVarIndexBase(off + 12);
                    cx = self.addI16(cx, vb, 0, coords);
                    cy = self.addI16(cy, vb, 1, coords);
                    start_ang = self.addF2Dot14(start_ang, vb, 2, coords);
                    end_ang = self.addF2Dot14(end_ang, vb, 3, coords);
                }
                return Paint{ .sweep_gradient = .{
                    .color_line_offset = cl_abs,
                    .center_x = cx,
                    .center_y = cy,
                    .start_angle = start_ang,
                    .end_angle = end_ang,
                    .is_var = (fmt == 9),
                } };
            },
            // PaintGlyph
            10 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                const gid = parser.readU16(self.data, off + 4) catch return null;
                return Paint{ .glyph = .{
                    .paint_offset = paint_abs,
                    .glyph_id = gid,
                } };
            },
            // PaintColrGlyph
            11 => {
                const gid = parser.readU16(self.data, off + 1) catch return null;
                return Paint{ .colr_glyph = .{ .glyph_id = gid } };
            },
            // PaintTransform, PaintVarTransform
            12, 13 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                const xform_off: usize = @intCast(self.readRelOffset(abs_offset, off + 4) orelse return null);
                var xx = parser.readFixed(self.data, xform_off) catch return null;
                var yx = parser.readFixed(self.data, xform_off + 4) catch return null;
                var xy = parser.readFixed(self.data, xform_off + 8) catch return null;
                var yy = parser.readFixed(self.data, xform_off + 12) catch return null;
                var dx = parser.readFixed(self.data, xform_off + 16) catch return null;
                var dy = parser.readFixed(self.data, xform_off + 20) catch return null;
                if (fmt == 13) {
                    const vb = self.readVarIndexBase(xform_off + 24);
                    xx = self.addFixed(xx, vb, 0, coords);
                    yx = self.addFixed(yx, vb, 1, coords);
                    xy = self.addFixed(xy, vb, 2, coords);
                    yy = self.addFixed(yy, vb, 3, coords);
                    dx = self.addFixed(dx, vb, 4, coords);
                    dy = self.addFixed(dy, vb, 5, coords);
                }
                return Paint{ .transform = .{
                    .paint_offset = paint_abs,
                    .xx = xx,
                    .yx = yx,
                    .xy = xy,
                    .yy = yy,
                    .dx = dx,
                    .dy = dy,
                } };
            },
            // PaintTranslate, PaintVarTranslate
            14, 15 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var dx = parser.readI16(self.data, off + 4) catch return null;
                var dy = parser.readI16(self.data, off + 6) catch return null;
                if (fmt == 15) {
                    const vb = self.readVarIndexBase(off + 8);
                    dx = self.addI16(dx, vb, 0, coords);
                    dy = self.addI16(dy, vb, 1, coords);
                }
                return Paint{ .translate = .{
                    .paint_offset = paint_abs,
                    .dx = dx,
                    .dy = dy,
                } };
            },
            // PaintScale, PaintVarScale
            16, 17 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var sx = parser.readF2Dot14(self.data, off + 4) catch return null;
                var sy = parser.readF2Dot14(self.data, off + 6) catch return null;
                if (fmt == 17) {
                    const vb = self.readVarIndexBase(off + 8);
                    sx = self.addF2Dot14(sx, vb, 0, coords);
                    sy = self.addF2Dot14(sy, vb, 1, coords);
                }
                return Paint{ .scale = .{
                    .paint_offset = paint_abs,
                    .scale_x = sx,
                    .scale_y = sy,
                } };
            },
            // PaintScaleAroundCenter, PaintVarScaleAroundCenter
            18, 19 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var sx = parser.readF2Dot14(self.data, off + 4) catch return null;
                var sy = parser.readF2Dot14(self.data, off + 6) catch return null;
                var cx = parser.readI16(self.data, off + 8) catch return null;
                var cy = parser.readI16(self.data, off + 10) catch return null;
                if (fmt == 19) {
                    const vb = self.readVarIndexBase(off + 12);
                    sx = self.addF2Dot14(sx, vb, 0, coords);
                    sy = self.addF2Dot14(sy, vb, 1, coords);
                    cx = self.addI16(cx, vb, 2, coords);
                    cy = self.addI16(cy, vb, 3, coords);
                }
                return Paint{ .scale_around_center = .{
                    .paint_offset = paint_abs,
                    .scale_x = sx,
                    .scale_y = sy,
                    .center_x = cx,
                    .center_y = cy,
                } };
            },
            // PaintScaleUniform, PaintVarScaleUniform
            20, 21 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var s = parser.readF2Dot14(self.data, off + 4) catch return null;
                if (fmt == 21) {
                    const vb = self.readVarIndexBase(off + 6);
                    s = self.addF2Dot14(s, vb, 0, coords);
                }
                return Paint{ .scale_uniform = .{
                    .paint_offset = paint_abs,
                    .scale = s,
                } };
            },
            // PaintScaleUniformAroundCenter, PaintVarScaleUniformAroundCenter
            22, 23 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var s = parser.readF2Dot14(self.data, off + 4) catch return null;
                var cx = parser.readI16(self.data, off + 6) catch return null;
                var cy = parser.readI16(self.data, off + 8) catch return null;
                if (fmt == 23) {
                    const vb = self.readVarIndexBase(off + 10);
                    s = self.addF2Dot14(s, vb, 0, coords);
                    cx = self.addI16(cx, vb, 1, coords);
                    cy = self.addI16(cy, vb, 2, coords);
                }
                return Paint{ .scale_uniform_around_center = .{
                    .paint_offset = paint_abs,
                    .scale = s,
                    .center_x = cx,
                    .center_y = cy,
                } };
            },
            // PaintRotate, PaintVarRotate
            24, 25 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var angle = parser.readF2Dot14(self.data, off + 4) catch return null;
                if (fmt == 25) {
                    const vb = self.readVarIndexBase(off + 6);
                    angle = self.addF2Dot14(angle, vb, 0, coords);
                }
                return Paint{ .rotate = .{
                    .paint_offset = paint_abs,
                    .angle = angle,
                } };
            },
            // PaintRotateAroundCenter, PaintVarRotateAroundCenter
            26, 27 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var angle = parser.readF2Dot14(self.data, off + 4) catch return null;
                var cx = parser.readI16(self.data, off + 6) catch return null;
                var cy = parser.readI16(self.data, off + 8) catch return null;
                if (fmt == 27) {
                    const vb = self.readVarIndexBase(off + 10);
                    angle = self.addF2Dot14(angle, vb, 0, coords);
                    cx = self.addI16(cx, vb, 1, coords);
                    cy = self.addI16(cy, vb, 2, coords);
                }
                return Paint{ .rotate_around_center = .{
                    .paint_offset = paint_abs,
                    .angle = angle,
                    .center_x = cx,
                    .center_y = cy,
                } };
            },
            // PaintSkew, PaintVarSkew
            28, 29 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var xs = parser.readF2Dot14(self.data, off + 4) catch return null;
                var ys = parser.readF2Dot14(self.data, off + 6) catch return null;
                if (fmt == 29) {
                    const vb = self.readVarIndexBase(off + 8);
                    xs = self.addF2Dot14(xs, vb, 0, coords);
                    ys = self.addF2Dot14(ys, vb, 1, coords);
                }
                return Paint{ .skew = .{
                    .paint_offset = paint_abs,
                    .x_skew_angle = xs,
                    .y_skew_angle = ys,
                } };
            },
            // PaintSkewAroundCenter, PaintVarSkewAroundCenter
            30, 31 => {
                const paint_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                var xs = parser.readF2Dot14(self.data, off + 4) catch return null;
                var ys = parser.readF2Dot14(self.data, off + 6) catch return null;
                var cx = parser.readI16(self.data, off + 8) catch return null;
                var cy = parser.readI16(self.data, off + 10) catch return null;
                if (fmt == 31) {
                    const vb = self.readVarIndexBase(off + 12);
                    xs = self.addF2Dot14(xs, vb, 0, coords);
                    ys = self.addF2Dot14(ys, vb, 1, coords);
                    cx = self.addI16(cx, vb, 2, coords);
                    cy = self.addI16(cy, vb, 3, coords);
                }
                return Paint{ .skew_around_center = .{
                    .paint_offset = paint_abs,
                    .x_skew_angle = xs,
                    .y_skew_angle = ys,
                    .center_x = cx,
                    .center_y = cy,
                } };
            },
            // PaintComposite
            32 => {
                const src_abs = self.readRelOffset(abs_offset, off + 1) orelse return null;
                const mode_byte = parser.readU8(self.data, off + 4) catch return null;
                const backdrop_abs = self.readRelOffset(abs_offset, off + 5) orelse return null;
                return Paint{ .composite = .{
                    .source_paint_offset = src_abs,
                    .mode = @enumFromInt(mode_byte),
                    .backdrop_paint_offset = backdrop_abs,
                } };
            },
            else => return null,
        }
    }

    /// Parse a ColorLine at the given absolute offset.
    pub fn readColorLine(self: ColrTable, allocator: std.mem.Allocator, abs_offset: u32, is_var: bool, coords: []const f32) !ColorLine {
        if (comptime !ft.enable_colr_v1) {
            return ColorLine{
                .extend = .pad,
                .stops = try allocator.alloc(ColorStop, 0),
                .allocator = allocator,
            };
        }
        const off: usize = @intCast(abs_offset);
        const extend_byte = try parser.readU8(self.data, off);
        const num_stops = try parser.readU16(self.data, off + 1);
        if (num_stops > 256) return error.InvalidColorLine;
        const stops = try allocator.alloc(ColorStop, num_stops);
        errdefer allocator.free(stops);
        const stride: usize = if (is_var) 10 else 6;
        for (0..num_stops) |i| {
            const base_off = std.math.add(usize, off, 3) catch return error.InvalidColorLine;
            const stop_off = std.math.add(usize, base_off, i * stride) catch return error.InvalidColorLine;
            var stop_offset = try parser.readF2Dot14(self.data, stop_off);
            var alpha = try parser.readF2Dot14(self.data, stop_off + 4);
            if (is_var) {
                const vb = self.readVarIndexBase(stop_off + 6);
                stop_offset = self.addF2Dot14(stop_offset, vb, 0, coords);
                alpha = self.addF2Dot14(alpha, vb, 1, coords);
            }
            stops[i] = .{
                .stop_offset = stop_offset,
                .palette_index = try parser.readU16(self.data, stop_off + 2),
                .alpha = alpha,
            };
        }
        return ColorLine{
            .extend = @enumFromInt(extend_byte),
            .stops = stops,
            .allocator = allocator,
        };
    }

    /// Return the ClipBox for a glyph, or null if not found.
    pub fn getClipBox(self: ColrTable, glyph_id: u16) ?ClipBox {
        if (comptime !ft.enable_colr_v1) return null;
        if (self.clip_list_offset == 0) return null;
        const list_off: usize = @intCast(self.clip_list_offset);
        const fmt = parser.readU8(self.data, list_off) catch return null;
        if (fmt != 1 and fmt != 2) return null;
        const num_clips = parser.readU32(self.data, list_off + 1) catch return null;
        // Binary search ClipRecord array (7 bytes each: u16 start, u16 end, Offset24 clipBox)
        var lo: u32 = 0;
        var hi: u32 = num_clips;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const prod = std.math.mul(usize, @as(usize, mid), 7) catch return null;
            const rec_off = std.math.add(usize, std.math.add(usize, list_off, 5) catch return null, prod) catch return null;
            const start_gid = parser.readU16(self.data, rec_off) catch return null;
            const end_gid = parser.readU16(self.data, rec_off + 2) catch return null;
            if (glyph_id < start_gid) {
                hi = mid;
            } else if (glyph_id > end_gid) {
                lo = mid + 1;
            } else {
                const box_rel = parser.readU24(self.data, rec_off + 4) catch return null;
                const box_abs: usize = @intCast(std.math.add(u32, self.clip_list_offset, box_rel) catch return null);
                const format = parser.readU8(self.data, box_abs) catch return null;
                if (format > 2) return null;
                const x_min = parser.readI16(self.data, box_abs + 1) catch return null;
                const y_min = parser.readI16(self.data, box_abs + 3) catch return null;
                const x_max = parser.readI16(self.data, box_abs + 5) catch return null;
                const y_max = parser.readI16(self.data, box_abs + 7) catch return null;
                return ClipBox{
                    .x_min = x_min,
                    .y_min = y_min,
                    .x_max = x_max,
                    .y_max = y_max,
                };
            }
        }
        return null;
    }
};

pub fn parse(data: []const u8) !ColrTable {
    if (data.len < 14) return error.UnexpectedEof;
    const version = try parser.readU16(data, 0);
    if (version != 0 and version != 1) return error.UnsupportedVersion;
    const num_base_glyphs = try parser.readU16(data, 2);
    const base_glyph_offset = try parser.readU32(data, 4);
    const layer_offset = try parser.readU32(data, 8);
    const num_layers = try parser.readU16(data, 12);

    var base_glyph_list_offset: u32 = 0;
    var layer_list_offset: u32 = 0;
    var clip_list_offset: u32 = 0;
    var var_index_map_offset: u32 = 0;
    var item_variation_store_offset: u32 = 0;

    if (comptime ft.enable_colr_v1) {
        if (version == 1 and data.len >= 26) {
            base_glyph_list_offset = parser.readU32(data, 14) catch 0;
            layer_list_offset = parser.readU32(data, 18) catch 0;
            clip_list_offset = parser.readU32(data, 22) catch 0;
        }
        if (comptime ft.enable_variable) {
            if (version == 1 and data.len >= 34) {
                var_index_map_offset = parser.readU32(data, 26) catch 0;
                item_variation_store_offset = parser.readU32(data, 30) catch 0;
            }
        }
    }

    return ColrTable{
        .data = data,
        .version = version,
        .num_base_glyphs = num_base_glyphs,
        .base_glyph_offset = base_glyph_offset,
        .layer_offset = layer_offset,
        .num_layers = num_layers,
        .base_glyph_list_offset = base_glyph_list_offset,
        .layer_list_offset = layer_list_offset,
        .clip_list_offset = clip_list_offset,
        .var_index_map_offset = var_index_map_offset,
        .item_variation_store_offset = item_variation_store_offset,
    };
}

fn writeU16(buf: []u8, off: usize, value: u16) void {
    buf[off] = @intCast(value >> 8);
    buf[off + 1] = @intCast(value & 0xFF);
}

fn writeI16(buf: []u8, off: usize, value: i16) void {
    writeU16(buf, off, @as(u16, @bitCast(value)));
}

fn writeU32(buf: []u8, off: usize, value: u32) void {
    buf[off] = @intCast((value >> 24) & 0xFF);
    buf[off + 1] = @intCast((value >> 16) & 0xFF);
    buf[off + 2] = @intCast((value >> 8) & 0xFF);
    buf[off + 3] = @intCast(value & 0xFF);
}

fn writeTestItemVariationStore(buf: []u8, store_off: usize, delta: i16) void {
    writeU16(buf, store_off, 1);
    writeU32(buf, store_off + 2, 28);
    writeU16(buf, store_off + 6, 1);
    writeU32(buf, store_off + 8, 16);

    const data_off = store_off + 16;
    writeU16(buf, data_off, 1);
    writeU16(buf, data_off + 2, 1);
    writeU16(buf, data_off + 4, 1);
    writeU16(buf, data_off + 6, 0);
    writeI16(buf, data_off + 8, delta);

    const region_off = store_off + 28;
    writeU16(buf, region_off, 1);
    writeU16(buf, region_off + 2, 1);
    writeU16(buf, region_off + 4, 0);
    writeU16(buf, region_off + 6, 0x4000);
    writeU16(buf, region_off + 8, 0x4000);
}

test "colr parse does not crash on missing table" {
    const result = parse(&[_]u8{0} ** 5);
    try std.testing.expectError(error.UnexpectedEof, result);
}

test "colr v1 parse header" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;
    // Minimal v1 COLR header (26 bytes):
    // version=1 (u16), numBaseGlyphRecords=0 (u16), baseGlyphRecordsOffset=0 (u32),
    // layerRecordsOffset=0 (u32), numLayerRecords=0 (u16),
    // baseGlyphListOffset=100 (u32), layerListOffset=200 (u32), clipListOffset=300 (u32)
    var buf = [_]u8{0} ** 26;
    // version = 1
    buf[0] = 0;
    buf[1] = 1;
    // baseGlyphListOffset = 100 at offset 14
    buf[14] = 0;
    buf[15] = 0;
    buf[16] = 0;
    buf[17] = 100;
    // layerListOffset = 200 at offset 18
    buf[18] = 0;
    buf[19] = 0;
    buf[20] = 0;
    buf[21] = 200;
    // clipListOffset = 300 at offset 22
    buf[22] = 0;
    buf[23] = 0;
    buf[24] = 1;
    buf[25] = 44;
    const table = try parse(&buf);
    try std.testing.expectEqual(@as(u16, 1), table.version);
    try std.testing.expectEqual(@as(u32, 100), table.base_glyph_list_offset);
    try std.testing.expectEqual(@as(u32, 200), table.layer_list_offset);
    try std.testing.expectEqual(@as(u32, 300), table.clip_list_offset);
}

test "colr v1 readPaint solid" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;
    // PaintSolid format 2: [format=2, paletteIndex_hi, paletteIndex_lo, alpha_hi, alpha_lo]
    // paletteIndex = 5, alpha = 0x4000 (F2Dot14 = 1.0)
    var buf = [_]u8{0} ** 26;
    buf[0] = 0; // version hi
    buf[1] = 1; // version = 1
    // rest of header is zero (v0 fields, v1 fields all 0)
    // Paint data starts at offset 26; we extend the buffer
    var paint_buf = [_]u8{0} ** 5;
    paint_buf[0] = 2; // format PaintSolid
    paint_buf[1] = 0; // paletteIndex hi
    paint_buf[2] = 5; // paletteIndex lo = 5
    paint_buf[3] = 0x40; // alpha hi (0x4000 / 16384 = 1.0)
    paint_buf[4] = 0x00; // alpha lo

    // Build a full buffer: header + paint
    var full_buf = [_]u8{0} ** 31;
    @memcpy(full_buf[0..26], &buf);
    @memcpy(full_buf[26..31], &paint_buf);

    const table = try parse(&full_buf);
    const paint = table.readPaint(26, &.{}).?;
    try std.testing.expectEqual(@as(u16, 5), paint.solid.palette_index);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), paint.solid.alpha, 0.001);
}

test "colr v1 PaintVarSolid applies alpha delta" {
    if (comptime !ft.enable_colr_v1 or !ft.enable_variable) return error.SkipZigTest;

    var buf = [_]u8{0} ** 86;
    writeU16(&buf, 0, 1);
    writeU32(&buf, 30, 48);

    buf[34] = 3;
    writeU16(&buf, 35, 5);
    writeU16(&buf, 37, 0x4000);
    writeU32(&buf, 39, 0);
    writeTestItemVariationStore(&buf, 48, -8192);

    const table = try parse(&buf);
    const unchanged = table.readPaint(34, &.{0.0}).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), unchanged.solid.alpha, 0.001);

    const moved = table.readPaint(34, &.{1.0}).?;
    try std.testing.expectEqual(@as(u16, 5), moved.solid.palette_index);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), moved.solid.alpha, 0.001);
}

test "colr v1 truncated PaintVarSolid varIndexBase keeps paint" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;

    var buf = [_]u8{0} ** 39;
    writeU16(&buf, 0, 1);
    buf[34] = 3;
    writeU16(&buf, 35, 5);
    writeU16(&buf, 37, 0x4000);

    const table = try parse(&buf);
    const paint = table.readPaint(34, &.{1.0}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 5), paint.solid.palette_index);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), paint.solid.alpha, 0.001);
}

test "colr v1 no variation when store offset zero" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;

    var buf = [_]u8{0} ** 43;
    writeU16(&buf, 0, 1);
    buf[34] = 3;
    writeU16(&buf, 35, 5);
    writeU16(&buf, 37, 0x4000);
    writeU32(&buf, 39, 0);

    const table = try parse(&buf);
    const paint = table.readPaint(34, &.{1.0}).?;
    try std.testing.expectEqual(@as(u16, 5), paint.solid.palette_index);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), paint.solid.alpha, 0.001);
}

test "colr v1 readPaint colr layers" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;
    // PaintColrLayers format 1: [format=1, numLayers=3, firstIdx u32 big-endian = 7]
    var full_buf = [_]u8{0} ** 33;
    // v1 header
    full_buf[0] = 0;
    full_buf[1] = 1;
    // paint at offset 26
    full_buf[26] = 1; // format
    full_buf[27] = 3; // numLayers = 3
    full_buf[28] = 0; // firstLayerIndex
    full_buf[29] = 0;
    full_buf[30] = 0;
    full_buf[31] = 7; // = 7

    const table = try parse(full_buf[0..26]);
    // Parse paint from a table that points to full_buf
    const table2 = ColrTable{
        .data = &full_buf,
        .version = 1,
        .num_base_glyphs = 0,
        .base_glyph_offset = 0,
        .layer_offset = 0,
        .num_layers = 0,
        .base_glyph_list_offset = 0,
        .layer_list_offset = 0,
        .clip_list_offset = 0,
        .var_index_map_offset = 0,
        .item_variation_store_offset = 0,
    };
    _ = table;
    const paint = table2.readPaint(26, &.{}).?;
    try std.testing.expectEqual(@as(u8, 3), paint.colr_layers.num_layers);
    try std.testing.expectEqual(@as(u32, 7), paint.colr_layers.first_layer_index);
}

test "colr v1 readColorLine" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;
    // ColorLine: extend=0, numStops=2, stop0=[F2Dot14 0.0, pal=0, alpha=1.0], stop1=[F2Dot14 1.0, pal=1, alpha=0.5]
    // F2Dot14 0.0 = 0x0000, 1.0 = 0x4000, 0.5 = 0x2000
    var buf = [_]u8{0} ** (3 + 2 * 6);
    buf[0] = 0; // extend = pad
    buf[1] = 0; // numStops hi
    buf[2] = 2; // numStops lo = 2
    // stop 0 at offset 3: stopOffset=0.0, pal=0, alpha=1.0
    buf[3] = 0x00;
    buf[4] = 0x00; // stopOffset = 0.0
    buf[5] = 0x00;
    buf[6] = 0x00; // paletteIndex = 0
    buf[7] = 0x40;
    buf[8] = 0x00; // alpha = 1.0
    // stop 1 at offset 9: stopOffset=1.0, pal=1, alpha=0.5
    buf[9] = 0x40;
    buf[10] = 0x00; // stopOffset = 1.0
    buf[11] = 0x00;
    buf[12] = 0x01; // paletteIndex = 1
    buf[13] = 0x20;
    buf[14] = 0x00; // alpha = 0.5

    const table = ColrTable{
        .data = &buf,
        .version = 1,
        .num_base_glyphs = 0,
        .base_glyph_offset = 0,
        .layer_offset = 0,
        .num_layers = 0,
        .base_glyph_list_offset = 0,
        .layer_list_offset = 0,
        .clip_list_offset = 0,
        .var_index_map_offset = 0,
        .item_variation_store_offset = 0,
    };

    var cl = try table.readColorLine(std.testing.allocator, 0, false, &.{});
    defer cl.deinit();

    try std.testing.expectEqual(ExtendMode.pad, cl.extend);
    try std.testing.expectEqual(@as(usize, 2), cl.stops.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cl.stops[0].stop_offset, 0.001);
    try std.testing.expectEqual(@as(u16, 0), cl.stops[0].palette_index);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cl.stops[0].alpha, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cl.stops[1].stop_offset, 0.001);
    try std.testing.expectEqual(@as(u16, 1), cl.stops[1].palette_index);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cl.stops[1].alpha, 0.001);
}

test "colr v1 findBaseGlyphV1Paint" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;
    // BaseGlyphList at offset 26 (base_glyph_list_offset = 26).
    // Layout:
    //   offset 26: numRecords = 3 (u32 BE)
    //   offset 30: Record 0: glyphID=5  (u16 BE), paintOffset=100 (u32 BE)
    //   offset 36: Record 1: glyphID=10 (u16 BE), paintOffset=200 (u32 BE)
    //   offset 42: Record 2: glyphID=20 (u16 BE), paintOffset=44  (u32 BE)
    var buf = [_]u8{0} ** 48;
    // numRecords = 3
    buf[26] = 0x00;
    buf[27] = 0x00;
    buf[28] = 0x00;
    buf[29] = 0x03;
    // Record 0: glyphID=5, paintOffset=100
    buf[30] = 0x00;
    buf[31] = 0x05;
    buf[32] = 0x00;
    buf[33] = 0x00;
    buf[34] = 0x00;
    buf[35] = 0x64;
    // Record 1: glyphID=10, paintOffset=200
    buf[36] = 0x00;
    buf[37] = 0x0A;
    buf[38] = 0x00;
    buf[39] = 0x00;
    buf[40] = 0x00;
    buf[41] = 0xC8;
    // Record 2: glyphID=20, paintOffset=44
    buf[42] = 0x00;
    buf[43] = 0x14;
    buf[44] = 0x00;
    buf[45] = 0x00;
    buf[46] = 0x00;
    buf[47] = 0x2C;

    const table = ColrTable{
        .data = &buf,
        .version = 1,
        .num_base_glyphs = 0,
        .base_glyph_offset = 0,
        .layer_offset = 0,
        .num_layers = 0,
        .base_glyph_list_offset = 26,
        .layer_list_offset = 0,
        .clip_list_offset = 0,
        .var_index_map_offset = 0,
        .item_variation_store_offset = 0,
    };

    // glyph 10 → base_glyph_list_offset + paintOffset = 26 + 200 = 226
    const paint10 = table.findBaseGlyphV1Paint(10);
    try std.testing.expect(paint10 != null);
    try std.testing.expectEqual(@as(u32, 226), paint10.?);

    // glyph 5 → 26 + 100 = 126
    const paint5 = table.findBaseGlyphV1Paint(5);
    try std.testing.expect(paint5 != null);
    try std.testing.expectEqual(@as(u32, 126), paint5.?);

    // glyph 99 → not found
    const paint99 = table.findBaseGlyphV1Paint(99);
    try std.testing.expect(paint99 == null);
}

test "colr v1 getLayerListPaint" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;
    // LayerList at offset 10 (layer_list_offset = 10).
    // Layout:
    //   offset 10: numLayers = 2 (u32 BE)
    //   offset 14: paintOffset[0] = 50 (u32 BE)
    //   offset 18: paintOffset[1] = 80 (u32 BE)
    var buf = [_]u8{0} ** 22;
    // numLayers = 2
    buf[10] = 0x00;
    buf[11] = 0x00;
    buf[12] = 0x00;
    buf[13] = 0x02;
    // paintOffset[0] = 50
    buf[14] = 0x00;
    buf[15] = 0x00;
    buf[16] = 0x00;
    buf[17] = 0x32;
    // paintOffset[1] = 80
    buf[18] = 0x00;
    buf[19] = 0x00;
    buf[20] = 0x00;
    buf[21] = 0x50;

    const table = ColrTable{
        .data = &buf,
        .version = 1,
        .num_base_glyphs = 0,
        .base_glyph_offset = 0,
        .layer_offset = 0,
        .num_layers = 0,
        .base_glyph_list_offset = 0,
        .layer_list_offset = 10,
        .clip_list_offset = 0,
        .var_index_map_offset = 0,
        .item_variation_store_offset = 0,
    };

    // layer 0 → layer_list_offset + paintOffset[0] = 10 + 50 = 60
    const p0 = table.getLayerListPaint(0);
    try std.testing.expect(p0 != null);
    try std.testing.expectEqual(@as(u32, 60), p0.?);

    // layer 1 → 10 + 80 = 90
    const p1 = table.getLayerListPaint(1);
    try std.testing.expect(p1 != null);
    try std.testing.expectEqual(@as(u32, 90), p1.?);

    // layer 2 → out of range
    const p2 = table.getLayerListPaint(2);
    try std.testing.expect(p2 == null);
}

test "colr v1 getClipBox" {
    if (comptime !ft.enable_colr_v1) return error.SkipZigTest;
    // ClipList at offset 10 (clip_list_offset = 10).
    // Layout:
    //   offset 10: format = 1 (u8)
    //   offset 11: numClips = 1 (u32 BE)
    //   offset 15: ClipRecord: startGlyph=5 (u16 BE), endGlyph=15 (u16 BE), clipBoxOffset=24 (Offset24 BE)
    //   offset 34 (= 10+24): ClipBox format=1, xMin=-100, yMin=-200, xMax=500, yMax=700
    var buf = [_]u8{0} ** 43;
    // ClipList header
    buf[10] = 0x01; // format = 1
    buf[11] = 0x00;
    buf[12] = 0x00;
    buf[13] = 0x00;
    buf[14] = 0x01; // numClips = 1
    // ClipRecord at offset 15
    buf[15] = 0x00;
    buf[16] = 0x05; // startGlyph = 5
    buf[17] = 0x00;
    buf[18] = 0x0F; // endGlyph = 15
    buf[19] = 0x00;
    buf[20] = 0x00;
    buf[21] = 0x18; // clipBoxOffset = 24 (Offset24 BE)
    // ClipBox at offset 34 (= clip_list_offset 10 + clipBoxOffset 24)
    buf[34] = 0x01; // ClipBox format = 1
    buf[35] = 0xFF;
    buf[36] = 0x9C; // xMin = -100 (i16 BE)
    buf[37] = 0xFF;
    buf[38] = 0x38; // yMin = -200 (i16 BE)
    buf[39] = 0x01;
    buf[40] = 0xF4; // xMax =  500 (i16 BE)
    buf[41] = 0x02;
    buf[42] = 0xBC; // yMax =  700 (i16 BE)

    const table = ColrTable{
        .data = &buf,
        .version = 1,
        .num_base_glyphs = 0,
        .base_glyph_offset = 0,
        .layer_offset = 0,
        .num_layers = 0,
        .base_glyph_list_offset = 0,
        .layer_list_offset = 0,
        .clip_list_offset = 10,
        .var_index_map_offset = 0,
        .item_variation_store_offset = 0,
    };

    // glyph 10 is in range [5, 15] → ClipBox should be found
    const box10 = table.getClipBox(10);
    try std.testing.expect(box10 != null);
    try std.testing.expectEqual(@as(i16, -100), box10.?.x_min);
    try std.testing.expectEqual(@as(i16, -200), box10.?.y_min);
    try std.testing.expectEqual(@as(i16, 500), box10.?.x_max);
    try std.testing.expectEqual(@as(i16, 700), box10.?.y_max);

    // glyph 20 is outside range → null
    const box20 = table.getClipBox(20);
    try std.testing.expect(box20 == null);
}
