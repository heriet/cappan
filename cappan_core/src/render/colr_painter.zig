const std = @import("std");
const colr_mod = @import("../font/table/colr.zig");
const cpal_mod = @import("../font/table/cpal.zig");
const font_mod = @import("../font/font.zig");
const rgba_bitmap_mod = @import("rgba_bitmap.zig");
const gradient_mod = @import("gradient.zig");
const composite_mod = @import("composite.zig");
const rasterizer_mod = @import("../raster/rasterizer.zig");
const scanline_mod = @import("../raster/scanline.zig");

const MAX_RECURSION_DEPTH = 16;

pub const Affine2x3 = struct {
    xx: f32 = 1,
    yx: f32 = 0,
    xy: f32 = 0,
    yy: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,

    pub const identity: Affine2x3 = .{};

    pub fn multiply(a: Affine2x3, b: Affine2x3) Affine2x3 {
        return .{
            .xx = a.xx * b.xx + a.xy * b.yx,
            .yx = a.yx * b.xx + a.yy * b.yx,
            .xy = a.xx * b.xy + a.xy * b.yy,
            .yy = a.yx * b.xy + a.yy * b.yy,
            .dx = a.xx * b.dx + a.xy * b.dy + a.dx,
            .dy = a.yx * b.dx + a.yy * b.dy + a.dy,
        };
    }

    pub fn transformPoint(self: Affine2x3, x: f32, y: f32) [2]f32 {
        return .{
            self.xx * x + self.xy * y + self.dx,
            self.yx * x + self.yy * y + self.dy,
        };
    }

    pub fn aroundCenter(op: Affine2x3, cx: f32, cy: f32) Affine2x3 {
        if (cx == 0 and cy == 0) return op;
        const pre = Affine2x3{ .dx = -cx, .dy = -cy };
        const mid = op.multiply(pre);
        return (Affine2x3{ .dx = cx, .dy = cy }).multiply(mid);
    }

    pub fn inverse(self: Affine2x3) ?Affine2x3 {
        const det = self.xx * self.yy - self.xy * self.yx;
        if (@abs(det) < 1e-10) return null;
        const inv_det = 1.0 / det;
        return .{
            .xx = self.yy * inv_det,
            .yx = -self.yx * inv_det,
            .xy = -self.xy * inv_det,
            .yy = self.xx * inv_det,
            .dx = (self.xy * self.dy - self.yy * self.dx) * inv_det,
            .dy = (self.yx * self.dx - self.xx * self.dy) * inv_det,
        };
    }
};

pub const PaintContext = struct {
    allocator: std.mem.Allocator,
    colr: colr_mod.ColrTable,
    cpal: ?cpal_mod.CpalTable,
    font: *const font_mod.Font,
    scale: f32,
    fg_color: rgba_bitmap_mod.Color,
    palette_idx: u16,
    raster_options: scanline_mod.RasterOptions,
    clip_width: u32,
    clip_height: u32,
    clip_offset_x: f32,
    clip_offset_y: f32,
    eval_budget: *u32,
};

pub const RenderResult = struct {
    bitmap: rgba_bitmap_mod.RgbaBitmap,
    offset_x: f32,
    offset_y: f32,

    pub fn deinit(self: *RenderResult) void {
        self.bitmap.deinit();
    }
};

pub fn renderColrV1Glyph(
    allocator: std.mem.Allocator,
    font: *const font_mod.Font,
    colr: colr_mod.ColrTable,
    cpal: ?cpal_mod.CpalTable,
    glyph_id: u16,
    scale: f32,
    fg_color: rgba_bitmap_mod.Color,
    raster_options: scanline_mod.RasterOptions,
) !?RenderResult {
    if (!(scale > 0.0)) return null;
    const paint_offset = colr.findBaseGlyphV1Paint(glyph_id) orelse return null;

    // Get bounding box: prefer ClipBox, fall back to font head bbox
    const clip_box = colr.getClipBox(glyph_id);
    const bbox_x_min = if (clip_box) |c| c.x_min else font.head.x_min;
    const bbox_y_min = if (clip_box) |c| c.y_min else font.head.y_min;
    const bbox_x_max = if (clip_box) |c| c.x_max else font.head.x_max;
    const bbox_y_max = if (clip_box) |c| c.y_max else font.head.y_max;

    const x_min_px = @as(f32, @floatFromInt(bbox_x_min)) * scale;
    const y_min_px = @as(f32, @floatFromInt(bbox_y_min)) * scale;
    const x_max_px = @as(f32, @floatFromInt(bbox_x_max)) * scale;
    const y_max_px = @as(f32, @floatFromInt(bbox_y_max)) * scale;

    const w_f = @ceil(x_max_px - x_min_px) + 2.0;
    const h_f = @ceil(y_max_px - y_min_px) + 2.0;

    if (!(w_f > 0 and h_f > 0 and w_f <= 4096 and h_f <= 4096)) return null;

    const clip_width: u32 = @intFromFloat(w_f);
    const clip_height: u32 = @intFromFloat(h_f);

    const clip_offset_x = -x_min_px + 1.0;
    const clip_offset_y = y_max_px + 1.0;

    var eval_budget: u32 = 4096;
    const ctx = PaintContext{
        .allocator = allocator,
        .colr = colr,
        .cpal = cpal,
        .font = font,
        .scale = scale,
        .fg_color = fg_color,
        .palette_idx = 0,
        .raster_options = raster_options,
        .clip_width = clip_width,
        .clip_height = clip_height,
        .clip_offset_x = clip_offset_x,
        .clip_offset_y = clip_offset_y,
        .eval_budget = &eval_budget,
    };

    const bitmap = (try evaluatePaint(&ctx, paint_offset, Affine2x3.identity, 0)) orelse return null;
    return RenderResult{
        .bitmap = bitmap,
        .offset_x = clip_offset_x,
        .offset_y = clip_offset_y,
    };
}

fn evaluatePaint(
    ctx: *const PaintContext,
    paint_offset: u32,
    transform: Affine2x3,
    depth: u32,
) anyerror!?rgba_bitmap_mod.RgbaBitmap {
    if (depth >= MAX_RECURSION_DEPTH) return null;
    if (ctx.eval_budget.* == 0) return null;
    ctx.eval_budget.* -= 1;
    const paint = ctx.colr.readPaint(paint_offset) orelse return null;
    return switch (paint) {
        .colr_layers => |p| try evalColrLayers(ctx, p, transform, depth),
        .solid => |p| try evalSolid(ctx, p),
        .linear_gradient => |p| try evalLinearGradient(ctx, p, transform),
        .radial_gradient => |p| try evalRadialGradient(ctx, p, transform),
        .sweep_gradient => |p| try evalSweepGradient(ctx, p, transform),
        .glyph => |p| try evalGlyph(ctx, p, transform, depth),
        .colr_glyph => |p| try evalColrGlyph(ctx, p, transform, depth),
        .transform => |p| try evalTransform(ctx, p, transform, depth),
        .translate => |p| try evalTranslate(ctx, p, transform, depth),
        .scale => |p| try evalGenericScale(ctx, p.paint_offset, p.scale_x, p.scale_y, 0, 0, transform, depth),
        .scale_around_center => |p| try evalGenericScale(ctx, p.paint_offset, p.scale_x, p.scale_y, p.center_x, p.center_y, transform, depth),
        .scale_uniform => |p| try evalGenericScale(ctx, p.paint_offset, p.scale, p.scale, 0, 0, transform, depth),
        .scale_uniform_around_center => |p| try evalGenericScale(ctx, p.paint_offset, p.scale, p.scale, p.center_x, p.center_y, transform, depth),
        .rotate => |p| try evalGenericRotate(ctx, p.paint_offset, p.angle, 0, 0, transform, depth),
        .rotate_around_center => |p| try evalGenericRotate(ctx, p.paint_offset, p.angle, p.center_x, p.center_y, transform, depth),
        .skew => |p| try evalGenericSkew(ctx, p.paint_offset, p.x_skew_angle, p.y_skew_angle, 0, 0, transform, depth),
        .skew_around_center => |p| try evalGenericSkew(ctx, p.paint_offset, p.x_skew_angle, p.y_skew_angle, p.center_x, p.center_y, transform, depth),
        .composite => |p| try evalComposite(ctx, p, transform, depth),
    };
}

fn evalColrLayers(ctx: *const PaintContext, p: colr_mod.PaintColrLayers, transform: Affine2x3, depth: u32) !?rgba_bitmap_mod.RgbaBitmap {
    var result = try rgba_bitmap_mod.RgbaBitmap.init(ctx.allocator, ctx.clip_width, ctx.clip_height, rgba_bitmap_mod.Color.transparent);
    errdefer result.deinit();
    var i: u32 = 0;
    while (i < p.num_layers) : (i += 1) {
        const layer_idx = std.math.add(u32, p.first_layer_index, i) catch continue;
        const layer_offset = ctx.colr.getLayerListPaint(layer_idx) orelse continue;
        if (try evaluatePaint(ctx, layer_offset, transform, depth + 1)) |layer_bmp| {
            var layer = layer_bmp;
            defer layer.deinit();
            composite_mod.composite(&result, layer, .src_over);
        }
    }
    return result;
}

fn evalSolid(ctx: *const PaintContext, p: colr_mod.PaintSolid) !?rgba_bitmap_mod.RgbaBitmap {
    const base = resolveColor(ctx, p.palette_index);
    const a_f = @max(0.0, @min(1.0, p.alpha));
    const color = rgba_bitmap_mod.Color{
        .r = base.r,
        .g = base.g,
        .b = base.b,
        .a = @intFromFloat(@round(@as(f32, @floatFromInt(base.a)) * a_f)),
    };
    return try rgba_bitmap_mod.RgbaBitmap.init(ctx.allocator, ctx.clip_width, ctx.clip_height, color);
}

fn evalGlyph(ctx: *const PaintContext, p: colr_mod.PaintGlyph, transform: Affine2x3, depth: u32) anyerror!?rgba_bitmap_mod.RgbaBitmap {
    var child_bmp = (try evaluatePaint(ctx, p.paint_offset, transform, depth + 1)) orelse return null;
    defer child_bmp.deinit();

    const outline_opt = ctx.font.getGlyphOutline(ctx.allocator, p.glyph_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (outline_opt == null) return null;
    var outline = outline_opt.?;
    defer outline.deinit();

    var raster = try rasterizer_mod.rasterizeGlyph(ctx.allocator, outline, ctx.scale, 0, ctx.raster_options);
    defer raster.deinit();

    var result = try rgba_bitmap_mod.RgbaBitmap.init(ctx.allocator, ctx.clip_width, ctx.clip_height, rgba_bitmap_mod.Color.transparent);

    const inv = transform.inverse() orelse return result;

    var y: u32 = 0;
    while (y < ctx.clip_height) : (y += 1) {
        var x: u32 = 0;
        while (x < ctx.clip_width) : (x += 1) {
            const cx_f = @as(f32, @floatFromInt(x));
            const cy_f = @as(f32, @floatFromInt(y));

            const fx = (cx_f - ctx.clip_offset_x) / ctx.scale;
            const fy = (ctx.clip_offset_y - cy_f) / ctx.scale;
            const orig = inv.transformPoint(fx, fy);
            const rx_f = orig[0] * ctx.scale + raster.offset_x;
            const ry_f = raster.offset_y - orig[1] * ctx.scale;

            if (!(rx_f >= -1e6 and rx_f <= 1e6 and ry_f >= -1e6 and ry_f <= 1e6)) continue;

            const rx = @as(i32, @intFromFloat(@round(rx_f)));
            const ry = @as(i32, @intFromFloat(@round(ry_f)));

            var coverage: u8 = 0;
            if (rx >= 0 and ry >= 0) {
                const urx = @as(u32, @intCast(rx));
                const ury = @as(u32, @intCast(ry));
                if (urx < raster.width and ury < raster.height) {
                    coverage = raster.pixels[@as(usize, ury) * @as(usize, raster.width) + @as(usize, urx)];
                }
            }
            if (coverage == 0) continue;

            const idx = (@as(usize, y) * @as(usize, ctx.clip_width) + @as(usize, x)) * 4;
            if (idx + 3 >= child_bmp.pixels.len) continue;
            const child_a = @as(u16, child_bmp.pixels[idx + 3]) * @as(u16, coverage) / 255;
            result.pixels[idx] = child_bmp.pixels[idx];
            result.pixels[idx + 1] = child_bmp.pixels[idx + 1];
            result.pixels[idx + 2] = child_bmp.pixels[idx + 2];
            result.pixels[idx + 3] = @intCast(child_a);
        }
    }
    return result;
}

fn evalColrGlyph(ctx: *const PaintContext, p: colr_mod.PaintColrGlyph, transform: Affine2x3, depth: u32) !?rgba_bitmap_mod.RgbaBitmap {
    const paint_offset = ctx.colr.findBaseGlyphV1Paint(p.glyph_id) orelse return null;
    return try evaluatePaint(ctx, paint_offset, transform, depth + 1);
}

fn evalTransform(ctx: *const PaintContext, p: colr_mod.PaintTransform, transform: Affine2x3, depth: u32) !?rgba_bitmap_mod.RgbaBitmap {
    const local = Affine2x3{
        .xx = p.xx,
        .yx = p.yx,
        .xy = p.xy,
        .yy = p.yy,
        .dx = p.dx,
        .dy = p.dy,
    };
    const combined = transform.multiply(local);
    return try evaluatePaint(ctx, p.paint_offset, combined, depth + 1);
}

fn evalTranslate(ctx: *const PaintContext, p: colr_mod.PaintTranslate, transform: Affine2x3, depth: u32) !?rgba_bitmap_mod.RgbaBitmap {
    const local = Affine2x3{
        .dx = @as(f32, @floatFromInt(p.dx)),
        .dy = @as(f32, @floatFromInt(p.dy)),
    };
    const combined = transform.multiply(local);
    return try evaluatePaint(ctx, p.paint_offset, combined, depth + 1);
}

fn evalGenericScale(
    ctx: *const PaintContext,
    paint_offset: u32,
    sx: f32,
    sy: f32,
    center_x: i16,
    center_y: i16,
    transform: Affine2x3,
    depth: u32,
) !?rgba_bitmap_mod.RgbaBitmap {
    const cx = @as(f32, @floatFromInt(center_x));
    const cy = @as(f32, @floatFromInt(center_y));
    const m = (Affine2x3{ .xx = sx, .yy = sy }).aroundCenter(cx, cy);
    const combined = transform.multiply(m);
    return try evaluatePaint(ctx, paint_offset, combined, depth + 1);
}

fn evalGenericRotate(
    ctx: *const PaintContext,
    paint_offset: u32,
    angle_turns: f32,
    center_x: i16,
    center_y: i16,
    transform: Affine2x3,
    depth: u32,
) !?rgba_bitmap_mod.RgbaBitmap {
    const angle_rad = angle_turns * 2.0 * std.math.pi;
    const cos_a = @cos(angle_rad);
    const sin_a = @sin(angle_rad);
    const rot = Affine2x3{ .xx = cos_a, .xy = -sin_a, .yx = sin_a, .yy = cos_a };
    const cx = @as(f32, @floatFromInt(center_x));
    const cy = @as(f32, @floatFromInt(center_y));
    const m = rot.aroundCenter(cx, cy);
    const combined = transform.multiply(m);
    return try evaluatePaint(ctx, paint_offset, combined, depth + 1);
}

fn evalGenericSkew(
    ctx: *const PaintContext,
    paint_offset: u32,
    x_skew_turns: f32,
    y_skew_turns: f32,
    center_x: i16,
    center_y: i16,
    transform: Affine2x3,
    depth: u32,
) !?rgba_bitmap_mod.RgbaBitmap {
    const limit: f32 = 1e6;
    const x_tan = std.math.clamp(@tan(x_skew_turns * 2.0 * std.math.pi), -limit, limit);
    const y_tan = std.math.clamp(@tan(y_skew_turns * 2.0 * std.math.pi), -limit, limit);
    const skew = Affine2x3{ .xx = 1, .xy = x_tan, .yx = y_tan, .yy = 1 };
    const cx = @as(f32, @floatFromInt(center_x));
    const cy = @as(f32, @floatFromInt(center_y));
    const m = skew.aroundCenter(cx, cy);
    const combined = transform.multiply(m);
    return try evaluatePaint(ctx, paint_offset, combined, depth + 1);
}

fn evalLinearGradient(ctx: *const PaintContext, p: colr_mod.PaintLinearGradient, transform: Affine2x3) !?rgba_bitmap_mod.RgbaBitmap {
    var color_line = ctx.colr.readColorLine(ctx.allocator, p.color_line_offset, p.is_var) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer color_line.deinit();

    var result = try rgba_bitmap_mod.RgbaBitmap.init(ctx.allocator, ctx.clip_width, ctx.clip_height, rgba_bitmap_mod.Color.transparent);
    errdefer result.deinit();

    const pt0 = transformFontToPixel(ctx, transform, p.x0, p.y0);
    const pt1 = transformFontToPixel(ctx, transform, p.x1, p.y1);
    const pt2 = transformFontToPixel(ctx, transform, p.x2, p.y2);

    gradient_mod.fillLinearGradient(
        &result,
        null,
        color_line.stops,
        color_line.extend,
        pt0[0],
        pt0[1],
        pt1[0],
        pt1[1],
        pt2[0],
        pt2[1],
        ctx.cpal,
        ctx.palette_idx,
        ctx.fg_color,
    );
    return result;
}

fn evalRadialGradient(ctx: *const PaintContext, p: colr_mod.PaintRadialGradient, transform: Affine2x3) anyerror!?rgba_bitmap_mod.RgbaBitmap {
    var color_line = ctx.colr.readColorLine(ctx.allocator, p.color_line_offset, p.is_var) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer color_line.deinit();

    var result = try rgba_bitmap_mod.RgbaBitmap.init(ctx.allocator, ctx.clip_width, ctx.clip_height, rgba_bitmap_mod.Color.transparent);
    errdefer result.deinit();

    const x0 = @as(f32, @floatFromInt(p.x0));
    const y0 = @as(f32, @floatFromInt(p.y0));
    const r0 = @as(f32, @floatFromInt(p.radius0));
    const x1 = @as(f32, @floatFromInt(p.x1));
    const y1 = @as(f32, @floatFromInt(p.y1));
    const r1 = @as(f32, @floatFromInt(p.radius1));

    const inv = transform.inverse() orelse return result;

    var y: u32 = 0;
    while (y < ctx.clip_height) : (y += 1) {
        var x: u32 = 0;
        while (x < ctx.clip_width) : (x += 1) {
            const cx_f = @as(f32, @floatFromInt(x)) + 0.5;
            const cy_f = @as(f32, @floatFromInt(y)) + 0.5;
            const fx = (cx_f - ctx.clip_offset_x) / ctx.scale;
            const fy = (ctx.clip_offset_y - cy_f) / ctx.scale;
            const orig = inv.transformPoint(fx, fy);

            const t = gradient_mod.radialGradientParam(orig[0], orig[1], x0, y0, r0, x1, y1, r1) orelse continue;
            const gc = gradient_mod.interpolateColorLine(color_line.stops, color_line.extend, t, ctx.cpal, ctx.palette_idx, ctx.fg_color);
            if (gc.a > 0) {
                result.blendPixel(x, y, 255, gc);
            }
        }
    }
    return result;
}

fn evalSweepGradient(ctx: *const PaintContext, p: colr_mod.PaintSweepGradient, transform: Affine2x3) anyerror!?rgba_bitmap_mod.RgbaBitmap {
    var color_line = ctx.colr.readColorLine(ctx.allocator, p.color_line_offset, p.is_var) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer color_line.deinit();

    var result = try rgba_bitmap_mod.RgbaBitmap.init(ctx.allocator, ctx.clip_width, ctx.clip_height, rgba_bitmap_mod.Color.transparent);
    errdefer result.deinit();

    const cx = @as(f32, @floatFromInt(p.center_x));
    const cy = @as(f32, @floatFromInt(p.center_y));

    const inv = transform.inverse() orelse return result;

    var y: u32 = 0;
    while (y < ctx.clip_height) : (y += 1) {
        var x: u32 = 0;
        while (x < ctx.clip_width) : (x += 1) {
            const cx_f = @as(f32, @floatFromInt(x)) + 0.5;
            const cy_f = @as(f32, @floatFromInt(y)) + 0.5;
            const fx = (cx_f - ctx.clip_offset_x) / ctx.scale;
            const fy = (ctx.clip_offset_y - cy_f) / ctx.scale;
            const orig = inv.transformPoint(fx, fy);

            // Compute sweep angle in font-unit space (Y-up, standard math convention)
            const t = blk: {
                if (@abs(p.end_angle - p.start_angle) < 1e-6) break :blk @as(f32, 0.0);
                const angle_rad = std.math.atan2(orig[1] - cy, orig[0] - cx);
                var angle_turns = angle_rad / (2.0 * std.math.pi);
                angle_turns = angle_turns - @floor(angle_turns);
                break :blk (angle_turns - p.start_angle) / (p.end_angle - p.start_angle);
            };
            const gc = gradient_mod.interpolateColorLine(color_line.stops, color_line.extend, t, ctx.cpal, ctx.palette_idx, ctx.fg_color);
            if (gc.a > 0) {
                result.blendPixel(x, y, 255, gc);
            }
        }
    }
    return result;
}

fn evalComposite(ctx: *const PaintContext, p: colr_mod.PaintComposite, transform: Affine2x3, depth: u32) anyerror!?rgba_bitmap_mod.RgbaBitmap {
    var backdrop = (try evaluatePaint(ctx, p.backdrop_paint_offset, transform, depth + 1)) orelse
        try rgba_bitmap_mod.RgbaBitmap.init(ctx.allocator, ctx.clip_width, ctx.clip_height, rgba_bitmap_mod.Color.transparent);
    errdefer backdrop.deinit();
    if (try evaluatePaint(ctx, p.source_paint_offset, transform, depth + 1)) |source_bmp| {
        var source = source_bmp;
        defer source.deinit();
        composite_mod.composite(&backdrop, source, p.mode);
    }
    return backdrop;
}

fn resolveColor(ctx: *const PaintContext, palette_index: u16) rgba_bitmap_mod.Color {
    if (palette_index == 0xFFFF) return ctx.fg_color;
    if (ctx.cpal) |cpal| {
        if (cpal.getColor(ctx.palette_idx, palette_index)) |c| {
            return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
        }
    }
    return ctx.fg_color;
}

fn transformFontToPixel(ctx: *const PaintContext, transform: Affine2x3, font_x: i16, font_y: i16) [2]f32 {
    const fx = @as(f32, @floatFromInt(font_x));
    const fy = @as(f32, @floatFromInt(font_y));
    const tp = transform.transformPoint(fx, fy);
    return .{
        tp[0] * ctx.scale + ctx.clip_offset_x,
        ctx.clip_offset_y - tp[1] * ctx.scale,
    };
}

test "Affine2x3 multiply identity" {
    const a = Affine2x3.identity;
    const b = Affine2x3.identity;
    const c = a.multiply(b);
    try std.testing.expectApproxEqAbs(c.xx, 1.0, 1e-6);
    try std.testing.expectApproxEqAbs(c.yy, 1.0, 1e-6);
    try std.testing.expectApproxEqAbs(c.dx, 0.0, 1e-6);
    try std.testing.expectApproxEqAbs(c.dy, 0.0, 1e-6);
}

test "Affine2x3 multiply translation composition" {
    const t1 = Affine2x3{ .dx = 3.0, .dy = 4.0 };
    const t2 = Affine2x3{ .dx = 1.0, .dy = 2.0 };
    const result = t1.multiply(t2);
    try std.testing.expectApproxEqAbs(result.dx, 4.0, 1e-6);
    try std.testing.expectApproxEqAbs(result.dy, 6.0, 1e-6);
}

test "Affine2x3 transformPoint" {
    const m = Affine2x3{ .xx = 2.0, .yy = 3.0, .dx = 10.0, .dy = 20.0 };
    const p = m.transformPoint(5.0, 7.0);
    try std.testing.expectApproxEqAbs(p[0], 20.0, 1e-6); // 2*5 + 10
    try std.testing.expectApproxEqAbs(p[1], 41.0, 1e-6); // 3*7 + 20
}

test "Affine2x3 inverse" {
    const m = Affine2x3{ .xx = 2.0, .yy = 3.0, .dx = 10.0, .dy = 20.0 };
    const inv = m.inverse().?;
    const p = m.transformPoint(5.0, 7.0);
    const restored = inv.transformPoint(p[0], p[1]);
    try std.testing.expectApproxEqAbs(restored[0], 5.0, 1e-4);
    try std.testing.expectApproxEqAbs(restored[1], 7.0, 1e-4);
}

test "Affine2x3 inverse singular" {
    const m = Affine2x3{ .xx = 0, .xy = 0, .yx = 0, .yy = 0 };
    try std.testing.expect(m.inverse() == null);
}
