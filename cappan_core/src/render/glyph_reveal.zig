const std = @import("std");
const font_mod = @import("../font/font.zig");
const glyph_mod = @import("../font/glyph.zig");
const outline_mod = @import("../raster/outline.zig");
const scanline_mod = @import("../raster/scanline.zig");
const sweep_mod = @import("reveal/sweep.zig");
const fade_mod = @import("reveal/fade.zig");
const contour_trace_mod = @import("reveal/contour_trace.zig");
const medial_axis_mod = @import("reveal/medial_axis.zig");
const distance_field_mod = @import("reveal/distance_field.zig");
const extrema_wave_mod = @import("reveal/extrema_wave.zig");
const skeleton_grow_mod = @import("reveal/skeleton_grow.zig");
const tangent_flow_mod = @import("reveal/tangent_flow.zig");

pub const SweepDirection = sweep_mod.SweepDirection;
pub const SweepOptions = sweep_mod.SweepOptions;
pub const ContourTraceOptions = contour_trace_mod.ContourTraceOptions;
pub const ContourOrdering = contour_trace_mod.ContourOrdering;
pub const MedialAxisOptions = medial_axis_mod.MedialAxisOptions;
pub const DistanceFieldOptions = distance_field_mod.DistanceFieldOptions;
pub const ExtremaWaveOptions = extrema_wave_mod.ExtremaWaveOptions;
pub const SkeletonGrowOptions = skeleton_grow_mod.SkeletonGrowOptions;
pub const TangentFlowOptions = tangent_flow_mod.TangentFlowOptions;

pub const GlyphInfo = struct {
    glyph_id: u16,
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
    num_contours: u16,
};

pub const CustomReveal = struct {
    context: *anyopaque,
    revealFn: *const fn (
        context: *anyopaque,
        full_coverage: []const u8,
        output: []u8,
        width: u32,
        height: u32,
        glyph_info: GlyphInfo,
        progress: f32,
    ) void,
    deinitFn: ?*const fn (context: *anyopaque) void,
};

pub const RevealStrategy = union(enum) {
    contour_trace: contour_trace_mod.ContourTraceOptions,
    sweep: SweepOptions,
    fade: void,
    medial_axis: medial_axis_mod.MedialAxisOptions,
    distance_field: distance_field_mod.DistanceFieldOptions,
    extrema_wave: extrema_wave_mod.ExtremaWaveOptions,
    skeleton_grow: skeleton_grow_mod.SkeletonGrowOptions,
    tangent_flow: tangent_flow_mod.TangentFlowOptions,
    custom: CustomReveal,
};

pub const GlyphRevealContext = struct {
    allocator: std.mem.Allocator,
    strategy: RevealStrategy,
    animation: ?contour_trace_mod.GlyphAnimation,
    medial_axis_animation: ?medial_axis_mod.MedialAxisAnimation,
    reveal_map: ?[]f32,
    glyph_info: GlyphInfo,

    pub fn initFromOutline(
        allocator: std.mem.Allocator,
        strategy: RevealStrategy,
        glyph_info: GlyphInfo,
        coverage: []const u8,
        width: u32,
        height: u32,
        outline: ?glyph_mod.GlyphOutline,
        scale: f32,
        offset_x: f32,
        offset_y: f32,
    ) !GlyphRevealContext {
        var animation: ?contour_trace_mod.GlyphAnimation = null;
        if (strategy == .contour_trace) {
            if (outline) |o| {
                const scaled = try outline_mod.scaleOutline(allocator, o, scale, offset_x, offset_y);
                defer outline_mod.freeScaledContours(allocator, scaled);
                animation = try contour_trace_mod.buildAnimation(allocator, scaled, strategy.contour_trace);
            }
        }
        errdefer if (animation) |*anim| anim.deinit();

        var ma_animation: ?medial_axis_mod.MedialAxisAnimation = null;
        if (strategy == .medial_axis) {
            ma_animation = try medial_axis_mod.buildAnimation(allocator, coverage, width, height, strategy.medial_axis);
        }
        errdefer if (ma_animation) |*anim| anim.deinit();

        var reveal_map_data: ?[]f32 = null;
        if (strategy == .distance_field) {
            reveal_map_data = try distance_field_mod.buildRevealMap(allocator, coverage, width, height);
        }
        if (strategy == .extrema_wave) {
            if (outline) |o| {
                const scaled = try outline_mod.scaleOutline(allocator, o, scale, offset_x, offset_y);
                defer outline_mod.freeScaledContours(allocator, scaled);
                reveal_map_data = try extrema_wave_mod.buildRevealMap(allocator, scaled, coverage, width, height, strategy.extrema_wave);
            }
        }
        if (strategy == .skeleton_grow) {
            reveal_map_data = try skeleton_grow_mod.buildRevealMap(allocator, coverage, width, height);
        }
        if (strategy == .tangent_flow) {
            if (outline) |o| {
                const scaled = try outline_mod.scaleOutline(allocator, o, scale, offset_x, offset_y);
                defer outline_mod.freeScaledContours(allocator, scaled);
                reveal_map_data = try tangent_flow_mod.buildRevealMap(allocator, scaled, coverage, width, height, strategy.tangent_flow);
            }
        }
        errdefer if (reveal_map_data) |m| allocator.free(m);

        return .{
            .allocator = allocator,
            .strategy = strategy,
            .animation = animation,
            .medial_axis_animation = ma_animation,
            .reveal_map = reveal_map_data,
            .glyph_info = glyph_info,
        };
    }

    pub fn init(
        allocator: std.mem.Allocator,
        font: font_mod.Font,
        glyph_id: u16,
        pixel_size: f32,
        coverage: []const u8,
        width: u32,
        height: u32,
        strategy: RevealStrategy,
        padding: u32,
    ) !GlyphRevealContext {
        const scale = pixel_size / @as(f32, @floatFromInt(font.getUnitsPerEm()));

        const outline_opt = font.getGlyphOutline(allocator, glyph_id) catch null;
        var outline_mut: ?glyph_mod.GlyphOutline = outline_opt;
        defer if (outline_mut) |*o| o.deinit();

        const info: GlyphInfo = if (outline_opt) |outline| .{
            .glyph_id = glyph_id,
            .x_min = @as(f32, @floatFromInt(outline.x_min)) * scale,
            .y_min = @as(f32, @floatFromInt(outline.y_min)) * scale,
            .x_max = @as(f32, @floatFromInt(outline.x_max)) * scale,
            .y_max = @as(f32, @floatFromInt(outline.y_max)) * scale,
            .num_contours = @intCast(outline.contours.len),
        } else .{
            .glyph_id = glyph_id,
            .x_min = 0,
            .y_min = 0,
            .x_max = 0,
            .y_max = 0,
            .num_contours = 0,
        };

        var offset_x: f32 = 0;
        var offset_y: f32 = 0;
        if (outline_opt) |outline| {
            const x_min_px = @as(f32, @floatFromInt(outline.x_min)) * scale;
            const y_max_px = @as(f32, @floatFromInt(outline.y_max)) * scale;
            const pad_f = @as(f32, @floatFromInt(padding));
            offset_x = -x_min_px + pad_f;
            offset_y = y_max_px + pad_f;
        }

        return initFromOutline(allocator, strategy, info, coverage, width, height, outline_opt, scale, offset_x, offset_y);
    }

    pub fn apply(
        self: *const GlyphRevealContext,
        full_coverage: []const u8,
        output: []u8,
        width: u32,
        height: u32,
        progress: f32,
    ) !void {
        const pixel_count = @as(usize, width) * @as(usize, height);
        if (pixel_count == 0) return;

        const p = std.math.clamp(progress, 0.0, 1.0);

        switch (self.strategy) {
            .contour_trace => {
                if (self.animation) |anim| {
                    const partial = try contour_trace_mod.getPartialSegments(self.allocator, anim, p);
                    defer self.allocator.free(partial);
                    const raster_pixels = try scanline_mod.rasterize(self.allocator, partial, width, height);
                    defer self.allocator.free(raster_pixels);
                    @memcpy(output[0..pixel_count], raster_pixels);
                } else {
                    @memset(output[0..pixel_count], 0);
                }
            },
            .sweep => |opts| {
                sweep_mod.apply(full_coverage[0..pixel_count], output[0..pixel_count], width, height, p, opts);
            },
            .fade => {
                fade_mod.apply(full_coverage[0..pixel_count], output[0..pixel_count], p);
            },
            .medial_axis => {
                if (self.medial_axis_animation) |anim| {
                    medial_axis_mod.renderAtProgress(anim, full_coverage[0..pixel_count], output[0..pixel_count], width, height, p);
                } else {
                    @memset(output[0..pixel_count], 0);
                }
            },
            .distance_field, .extrema_wave, .skeleton_grow, .tangent_flow => {
                if (self.reveal_map) |rm| {
                    distance_field_mod.apply(full_coverage[0..pixel_count], output[0..pixel_count], rm, p);
                } else {
                    @memset(output[0..pixel_count], 0);
                }
            },
            .custom => |c| {
                c.revealFn(c.context, full_coverage[0..pixel_count], output[0..pixel_count], width, height, self.glyph_info, p);
            },
        }
    }

    pub fn deinit(self: *GlyphRevealContext) void {
        if (self.animation) |*anim| {
            anim.deinit();
        }
        if (self.medial_axis_animation) |*anim| {
            anim.deinit();
        }
        if (self.reveal_map) |m| {
            self.allocator.free(m);
        }
        switch (self.strategy) {
            .custom => |c| {
                if (c.deinitFn) |deinit_fn| {
                    deinit_fn(c.context);
                }
            },
            else => {},
        }
    }
};

test "fade strategy: progress 0.0 produces all zeros" {
    const rasterizer_mod = @import("../raster/rasterizer.zig");
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId('A');
    const outline_opt = try font.getGlyphOutline(std.testing.allocator, glyph_id);
    var outline_mut = outline_opt orelse return;
    defer outline_mut.deinit();

    const scale = 32.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    var raster = try rasterizer_mod.rasterizeGlyph(std.testing.allocator, outline_mut, scale, 4);
    defer raster.deinit();

    const output = try std.testing.allocator.alloc(u8, raster.pixels.len);
    defer std.testing.allocator.free(output);

    var ctx = try GlyphRevealContext.init(
        std.testing.allocator,
        font,
        glyph_id,
        32.0,
        raster.pixels,
        raster.width,
        raster.height,
        .fade,
        4,
    );
    defer ctx.deinit();

    try ctx.apply(raster.pixels, output, raster.width, raster.height, 0.0);
    for (output) |v| {
        try std.testing.expectEqual(@as(u8, 0), v);
    }

    try ctx.apply(raster.pixels, output, raster.width, raster.height, 1.0);
    try std.testing.expectEqualSlices(u8, raster.pixels, output);
}

test "sweep strategy: partial reveal" {
    const rasterizer_mod = @import("../raster/rasterizer.zig");
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId('A');
    const outline_opt = try font.getGlyphOutline(std.testing.allocator, glyph_id);
    var outline_mut = outline_opt orelse return;
    defer outline_mut.deinit();

    const scale = 32.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    var raster = try rasterizer_mod.rasterizeGlyph(std.testing.allocator, outline_mut, scale, 4);
    defer raster.deinit();

    const output = try std.testing.allocator.alloc(u8, raster.pixels.len);
    defer std.testing.allocator.free(output);

    var ctx = try GlyphRevealContext.init(
        std.testing.allocator,
        font,
        glyph_id,
        32.0,
        raster.pixels,
        raster.width,
        raster.height,
        .{ .sweep = .{ .direction = .left_to_right } },
        4,
    );
    defer ctx.deinit();

    try ctx.apply(raster.pixels, output, raster.width, raster.height, 0.5);

    var has_zero = false;
    var has_nonzero = false;
    for (output) |v| {
        if (v == 0) has_zero = true else has_nonzero = true;
    }
    try std.testing.expect(has_zero);
    try std.testing.expect(has_nonzero);
}

test "init and apply smoke test for all strategies" {
    const rasterizer_mod = @import("../raster/rasterizer.zig");
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    var font = try font_mod.Font.init(std.testing.allocator, font_data, null);
    defer font.deinit();

    const glyph_id = try font.getGlyphId('A');
    const outline_opt = try font.getGlyphOutline(std.testing.allocator, glyph_id);
    var outline_mut = outline_opt orelse return;
    defer outline_mut.deinit();

    const scale = 32.0 / @as(f32, @floatFromInt(font.getUnitsPerEm()));
    var raster = try rasterizer_mod.rasterizeGlyph(std.testing.allocator, outline_mut, scale, 4);
    defer raster.deinit();

    const output = try std.testing.allocator.alloc(u8, raster.pixels.len);
    defer std.testing.allocator.free(output);

    const strategies = [_]RevealStrategy{
        .{ .contour_trace = .{} },
        .{ .sweep = .{} },
        .fade,
        .{ .medial_axis = .{} },
        .{ .distance_field = .{} },
        .{ .extrema_wave = .{} },
        .{ .skeleton_grow = .{} },
        .{ .tangent_flow = .{} },
    };

    for (strategies) |strategy| {
        var ctx = try GlyphRevealContext.init(
            std.testing.allocator,
            font,
            glyph_id,
            32.0,
            raster.pixels,
            raster.width,
            raster.height,
            strategy,
            4,
        );
        defer ctx.deinit();

        try ctx.apply(raster.pixels, output, raster.width, raster.height, 0.5);
    }
}
