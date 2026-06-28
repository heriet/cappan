const std = @import("std");
const parser = @import("../parser.zig");

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
        if (self.layer_list_offset == 0) return null;
        const list_off: usize = @intCast(self.layer_list_offset);
        const num_layers = parser.readU32(self.data, list_off) catch return null;
        if (layer_index >= num_layers) return null;
        const prod = std.math.mul(usize, @as(usize, layer_index), 4) catch return null;
        const entry_off = std.math.add(usize, std.math.add(usize, list_off, 4) catch return null, prod) catch return null;
        const paint_rel = parser.readU32(self.data, entry_off) catch return null;
        return std.math.add(u32, self.layer_list_offset, paint_rel) catch return null;
    }

    /// Parse a Paint record at the given absolute offset.
    pub fn readPaint(self: ColrTable, abs_offset: u32) ?Paint {
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
                const alpha = parser.readF2Dot14(self.data, off + 3) catch return null;
                return Paint{ .solid = .{
                    .palette_index = pal_idx,
                    .alpha = alpha,
                } };
            },
            // PaintLinearGradient, PaintVarLinearGradient
            4, 5 => {
                const cl_rel = parser.readU24(self.data, off + 1) catch return null;
                const cl_abs: u32 = std.math.add(u32, abs_offset, cl_rel) catch return null;
                const x0 = parser.readI16(self.data, off + 4) catch return null;
                const y0 = parser.readI16(self.data, off + 6) catch return null;
                const x1 = parser.readI16(self.data, off + 8) catch return null;
                const y1 = parser.readI16(self.data, off + 10) catch return null;
                const x2 = parser.readI16(self.data, off + 12) catch return null;
                const y2 = parser.readI16(self.data, off + 14) catch return null;
                return Paint{ .linear_gradient = .{
                    .color_line_offset = cl_abs,
                    .x0 = x0, .y0 = y0,
                    .x1 = x1, .y1 = y1,
                    .x2 = x2, .y2 = y2,
                    .is_var = (fmt == 5),
                } };
            },
            // PaintRadialGradient, PaintVarRadialGradient
            6, 7 => {
                const cl_rel = parser.readU24(self.data, off + 1) catch return null;
                const cl_abs: u32 = std.math.add(u32, abs_offset, cl_rel) catch return null;
                const x0 = parser.readI16(self.data, off + 4) catch return null;
                const y0 = parser.readI16(self.data, off + 6) catch return null;
                const r0 = parser.readU16(self.data, off + 8) catch return null;
                const x1 = parser.readI16(self.data, off + 10) catch return null;
                const y1 = parser.readI16(self.data, off + 12) catch return null;
                const r1 = parser.readU16(self.data, off + 14) catch return null;
                return Paint{ .radial_gradient = .{
                    .color_line_offset = cl_abs,
                    .x0 = x0, .y0 = y0, .radius0 = r0,
                    .x1 = x1, .y1 = y1, .radius1 = r1,
                    .is_var = (fmt == 7),
                } };
            },
            // PaintSweepGradient, PaintVarSweepGradient
            8, 9 => {
                const cl_rel = parser.readU24(self.data, off + 1) catch return null;
                const cl_abs: u32 = std.math.add(u32, abs_offset, cl_rel) catch return null;
                const cx = parser.readI16(self.data, off + 4) catch return null;
                const cy = parser.readI16(self.data, off + 6) catch return null;
                const start_ang = parser.readF2Dot14(self.data, off + 8) catch return null;
                const end_ang = parser.readF2Dot14(self.data, off + 10) catch return null;
                return Paint{ .sweep_gradient = .{
                    .color_line_offset = cl_abs,
                    .center_x = cx, .center_y = cy,
                    .start_angle = start_ang, .end_angle = end_ang,
                    .is_var = (fmt == 9),
                } };
            },
            // PaintGlyph
            10 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
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
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const xform_rel = parser.readU24(self.data, off + 4) catch return null;
                const xform_off: usize = @intCast(std.math.add(u32, abs_offset, xform_rel) catch return null);
                const xx = parser.readFixed(self.data, xform_off) catch return null;
                const yx = parser.readFixed(self.data, xform_off + 4) catch return null;
                const xy = parser.readFixed(self.data, xform_off + 8) catch return null;
                const yy = parser.readFixed(self.data, xform_off + 12) catch return null;
                const dx = parser.readFixed(self.data, xform_off + 16) catch return null;
                const dy = parser.readFixed(self.data, xform_off + 20) catch return null;
                return Paint{ .transform = .{
                    .paint_offset = paint_abs,
                    .xx = xx, .yx = yx,
                    .xy = xy, .yy = yy,
                    .dx = dx, .dy = dy,
                } };
            },
            // PaintTranslate, PaintVarTranslate
            14, 15 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const dx = parser.readI16(self.data, off + 4) catch return null;
                const dy = parser.readI16(self.data, off + 6) catch return null;
                return Paint{ .translate = .{
                    .paint_offset = paint_abs,
                    .dx = dx, .dy = dy,
                } };
            },
            // PaintScale, PaintVarScale
            16, 17 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const sx = parser.readF2Dot14(self.data, off + 4) catch return null;
                const sy = parser.readF2Dot14(self.data, off + 6) catch return null;
                return Paint{ .scale = .{
                    .paint_offset = paint_abs,
                    .scale_x = sx, .scale_y = sy,
                } };
            },
            // PaintScaleAroundCenter, PaintVarScaleAroundCenter
            18, 19 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const sx = parser.readF2Dot14(self.data, off + 4) catch return null;
                const sy = parser.readF2Dot14(self.data, off + 6) catch return null;
                const cx = parser.readI16(self.data, off + 8) catch return null;
                const cy = parser.readI16(self.data, off + 10) catch return null;
                return Paint{ .scale_around_center = .{
                    .paint_offset = paint_abs,
                    .scale_x = sx, .scale_y = sy,
                    .center_x = cx, .center_y = cy,
                } };
            },
            // PaintScaleUniform, PaintVarScaleUniform
            20, 21 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const s = parser.readF2Dot14(self.data, off + 4) catch return null;
                return Paint{ .scale_uniform = .{
                    .paint_offset = paint_abs,
                    .scale = s,
                } };
            },
            // PaintScaleUniformAroundCenter, PaintVarScaleUniformAroundCenter
            22, 23 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const s = parser.readF2Dot14(self.data, off + 4) catch return null;
                const cx = parser.readI16(self.data, off + 6) catch return null;
                const cy = parser.readI16(self.data, off + 8) catch return null;
                return Paint{ .scale_uniform_around_center = .{
                    .paint_offset = paint_abs,
                    .scale = s,
                    .center_x = cx, .center_y = cy,
                } };
            },
            // PaintRotate, PaintVarRotate
            24, 25 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const angle = parser.readF2Dot14(self.data, off + 4) catch return null;
                return Paint{ .rotate = .{
                    .paint_offset = paint_abs,
                    .angle = angle,
                } };
            },
            // PaintRotateAroundCenter, PaintVarRotateAroundCenter
            26, 27 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const angle = parser.readF2Dot14(self.data, off + 4) catch return null;
                const cx = parser.readI16(self.data, off + 6) catch return null;
                const cy = parser.readI16(self.data, off + 8) catch return null;
                return Paint{ .rotate_around_center = .{
                    .paint_offset = paint_abs,
                    .angle = angle,
                    .center_x = cx, .center_y = cy,
                } };
            },
            // PaintSkew, PaintVarSkew
            28, 29 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const xs = parser.readF2Dot14(self.data, off + 4) catch return null;
                const ys = parser.readF2Dot14(self.data, off + 6) catch return null;
                return Paint{ .skew = .{
                    .paint_offset = paint_abs,
                    .x_skew_angle = xs, .y_skew_angle = ys,
                } };
            },
            // PaintSkewAroundCenter, PaintVarSkewAroundCenter
            30, 31 => {
                const paint_rel = parser.readU24(self.data, off + 1) catch return null;
                const paint_abs: u32 = std.math.add(u32, abs_offset, paint_rel) catch return null;
                const xs = parser.readF2Dot14(self.data, off + 4) catch return null;
                const ys = parser.readF2Dot14(self.data, off + 6) catch return null;
                const cx = parser.readI16(self.data, off + 8) catch return null;
                const cy = parser.readI16(self.data, off + 10) catch return null;
                return Paint{ .skew_around_center = .{
                    .paint_offset = paint_abs,
                    .x_skew_angle = xs, .y_skew_angle = ys,
                    .center_x = cx, .center_y = cy,
                } };
            },
            // PaintComposite
            32 => {
                const src_rel = parser.readU24(self.data, off + 1) catch return null;
                const src_abs: u32 = std.math.add(u32, abs_offset, src_rel) catch return null;
                const mode_byte = parser.readU8(self.data, off + 4) catch return null;
                const backdrop_rel = parser.readU24(self.data, off + 5) catch return null;
                const backdrop_abs: u32 = std.math.add(u32, abs_offset, backdrop_rel) catch return null;
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
    pub fn readColorLine(self: ColrTable, allocator: std.mem.Allocator, abs_offset: u32, is_var: bool) !ColorLine {
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
            stops[i] = .{
                .stop_offset = try parser.readF2Dot14(self.data, stop_off),
                .palette_index = try parser.readU16(self.data, stop_off + 2),
                .alpha = try parser.readF2Dot14(self.data, stop_off + 4),
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

    if (version == 1 and data.len >= 26) {
        base_glyph_list_offset = parser.readU32(data, 14) catch 0;
        layer_list_offset = parser.readU32(data, 18) catch 0;
        clip_list_offset = parser.readU32(data, 22) catch 0;
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
    };
}

test "colr parse does not crash on missing table" {
    const result = parse(&[_]u8{0} ** 5);
    try std.testing.expectError(error.UnexpectedEof, result);
}

test "colr v1 parse header" {
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
    const paint = table.readPaint(26).?;
    try std.testing.expectEqual(@as(u16, 5), paint.solid.palette_index);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), paint.solid.alpha, 0.001);
}

test "colr v1 readPaint colr layers" {
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
    };
    _ = table;
    const paint = table2.readPaint(26).?;
    try std.testing.expectEqual(@as(u8, 3), paint.colr_layers.num_layers);
    try std.testing.expectEqual(@as(u32, 7), paint.colr_layers.first_layer_index);
}

test "colr v1 readColorLine" {
    // ColorLine: extend=0, numStops=2, stop0=[F2Dot14 0.0, pal=0, alpha=1.0], stop1=[F2Dot14 1.0, pal=1, alpha=0.5]
    // F2Dot14 0.0 = 0x0000, 1.0 = 0x4000, 0.5 = 0x2000
    var buf = [_]u8{0} ** (3 + 2 * 6);
    buf[0] = 0; // extend = pad
    buf[1] = 0; // numStops hi
    buf[2] = 2; // numStops lo = 2
    // stop 0 at offset 3: stopOffset=0.0, pal=0, alpha=1.0
    buf[3] = 0x00; buf[4] = 0x00; // stopOffset = 0.0
    buf[5] = 0x00; buf[6] = 0x00; // paletteIndex = 0
    buf[7] = 0x40; buf[8] = 0x00; // alpha = 1.0
    // stop 1 at offset 9: stopOffset=1.0, pal=1, alpha=0.5
    buf[9] = 0x40; buf[10] = 0x00; // stopOffset = 1.0
    buf[11] = 0x00; buf[12] = 0x01; // paletteIndex = 1
    buf[13] = 0x20; buf[14] = 0x00; // alpha = 0.5

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
    };

    var cl = try table.readColorLine(std.testing.allocator, 0, false);
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
