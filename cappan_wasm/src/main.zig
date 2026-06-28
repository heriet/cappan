const std = @import("std");
const cappan = @import("cappan_core");
const scanline_mod = cappan.raster.scanline;
const ft = cappan.features.features;

const allocator = std.heap.wasm_allocator;

const embedded_font_data = @embedFile("asset/font/NotoSansJP-Regular.otf");

var current_font: ?cappan.font.Font = null;
var last_bitmap: ?cappan.render.rgba_bitmap.RgbaBitmap = null;
var current_renderer: if (ft.enable_incremental) ?cappan.render.incremental.IncrementalRenderer else void = if (ft.enable_incremental) null else {};
var paint_stack: std.ArrayListUnmanaged(cappan.render.paint.PaintOperation) = .empty;

export fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn wasm_init_font(font_ptr: [*]const u8, font_len: usize) i32 {
    wasm_free_animator();
    free_last_bitmap();
    if (current_font) |*f| f.deinit();
    current_font = cappan.font.Font.init(allocator, font_ptr[0..font_len], null) catch {
        current_font = null;
        return 0;
    };
    return 1;
}

export fn wasm_init_embedded_font() i32 {
    wasm_free_animator();
    free_last_bitmap();
    if (current_font) |*f| f.deinit();
    current_font = cappan.font.Font.init(allocator, embedded_font_data, null) catch {
        current_font = null;
        return 0;
    };
    return 1;
}

export fn wasm_free_font() void {
    wasm_free_animator();
    free_last_bitmap();
    if (current_font) |*f| {
        f.deinit();
        current_font = null;
    }
}

export fn wasm_paint_clear() void {
    paint_stack.clearRetainingCapacity();
}

export fn wasm_paint_add_fill(r: u8, g: u8, b: u8, opacity_pct: u32, time_weight_pct: u32) i32 {
    const opacity = @as(f32, @floatFromInt(opacity_pct)) / 100.0;
    const time_weight = @max(0.01, @as(f32, @floatFromInt(time_weight_pct)) / 100.0);
    paint_stack.append(allocator, .{ .fill = .{
        .color = .{ .r = r, .g = g, .b = b, .a = 255 },
        .opacity = opacity,
        .time_weight = time_weight,
    } }) catch return 0;
    return 1;
}

export fn wasm_paint_add_stroke(r: u8, g: u8, b: u8, width_x10: u32, opacity_pct: u32, join: u32, position: u32, time_weight_pct: u32) i32 {
    const width = @as(f32, @floatFromInt(width_x10)) / 10.0;
    const opacity = @as(f32, @floatFromInt(opacity_pct)) / 100.0;
    const time_weight = @max(0.01, @as(f32, @floatFromInt(time_weight_pct)) / 100.0);
    const line_join: cappan.render.paint.LineJoin = switch (join) {
        0 => .round,
        1 => .miter,
        2 => .bevel,
        else => .round,
    };
    const stroke_position: cappan.render.paint.StrokePosition = switch (position) {
        0 => .outside,
        1 => .center,
        2 => .inside,
        else => .outside,
    };
    paint_stack.append(allocator, .{ .stroke = .{
        .color = .{ .r = r, .g = g, .b = b, .a = 255 },
        .width = .{ .px = width },
        .opacity = opacity,
        .join = line_join,
        .position = stroke_position,
        .time_weight = time_weight,
    } }) catch return 0;
    return 1;
}

fn parseAaLevel(aa_level: u32) scanline_mod.AntiAliasLevel {
    return switch (aa_level) {
        4 => .aa_4,
        16 => .aa_16,
        32 => .aa_32,
        else => .aa_8,
    };
}

fn parseSamplePattern(sample_pattern: u32) scanline_mod.SamplePattern {
    return switch (sample_pattern) {
        1 => .rotated_grid,
        else => .regular,
    };
}

fn parseRasterMethod(raster_method: u32) scanline_mod.RasterMethod {
    return switch (raster_method) {
        1 => .analytical,
        else => .supersampling,
    };
}

export fn wasm_render(
    text_ptr: [*]const u8,
    text_len: usize,
    pixel_size: f32,
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    aa_level: u32,
    sample_pattern: u32,
    adaptive: u32,
    raster_method: u32,
    stem_darkening: u32,
    cff_hinting: u32,
    auto_hinting: u32,
) i32 {
    const font = current_font orelse return 0;
    free_last_bitmap();
    const text = text_ptr[0..text_len];
    const fonts = [_]cappan.font.Font{font};
    last_bitmap = cappan.render.renderer.renderText(
        allocator,
        &fonts,
        text,
        .{
            .pixel_size = pixel_size,
            .fg_color = .{ .r = fg_r, .g = fg_g, .b = fg_b, .a = 255 },
            .bg_color = .{ .r = bg_r, .g = bg_g, .b = bg_b, .a = 255 },
            .paint_stack = if (paint_stack.items.len > 0) paint_stack.items else null,
            .raster_options = .{
                .aa_level = parseAaLevel(aa_level),
                .sample_pattern = parseSamplePattern(sample_pattern),
                .adaptive = if (adaptive != 0) .{} else null,
                .method = parseRasterMethod(raster_method),
            },
            .stem_darkening = stem_darkening != 0,
            .cff_hinting = cff_hinting != 0,
            .auto_hinting = auto_hinting != 0,
        },
    ) catch return 0;
    return 1;
}

export fn wasm_init_animator(
    text_ptr: [*]const u8,
    text_len: usize,
    pixel_size: f32,
    strategy: u32,
    timing: u32,
    paint_layer_timing: u32,
    fg_r: u8,
    fg_g: u8,
    fg_b: u8,
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    aa_level: u32,
    sample_pattern: u32,
    adaptive: u32,
    raster_method: u32,
    stem_darkening: u32,
    cff_hinting: u32,
    auto_hinting: u32,
) i32 {
    if (comptime !ft.enable_incremental) return 0;
    const font = current_font orelse return 0;
    wasm_free_animator();
    free_last_bitmap();
    const text = text_ptr[0..text_len];

    const reveal_strategy: cappan.render.incremental.RevealStrategy = switch (strategy) {
        0 => .{ .sweep = .{} },
        1 => .{ .fade = {} },
        2 => .{ .contour_trace = .{} },
        3 => .{ .medial_axis = .{} },
        4 => .{ .distance_field = .{} },
        5 => .{ .extrema_wave = .{} },
        6 => .{ .skeleton_grow = .{} },
        7 => .{ .tangent_flow = .{} },
        else => .{ .sweep = .{} },
    };

    const timing_mode: cappan.render.incremental.Timing = switch (timing) {
        0 => .sequential,
        1 => .simultaneous,
        2 => .weighted,
        else => .sequential,
    };

    const fonts = [_]cappan.font.Font{font};
    current_renderer = cappan.render.incremental.IncrementalRenderer.init(
        allocator,
        &fonts,
        text,
        .{
            .pixel_size = pixel_size,
            .strategy = reveal_strategy,
            .timing = timing_mode,
            .fg_color = .{ .r = fg_r, .g = fg_g, .b = fg_b, .a = 255 },
            .bg_color = .{ .r = bg_r, .g = bg_g, .b = bg_b, .a = 255 },
            .paint_stack = if (paint_stack.items.len > 0) paint_stack.items else null,
            .paint_layer_timing = if (paint_layer_timing == 1) .sequential else .simultaneous,
            .raster_options = .{
                .aa_level = parseAaLevel(aa_level),
                .sample_pattern = parseSamplePattern(sample_pattern),
                .adaptive = if (adaptive != 0) .{} else null,
                .method = parseRasterMethod(raster_method),
            },
            .stem_darkening = stem_darkening != 0,
            .cff_hinting = cff_hinting != 0,
            .auto_hinting = auto_hinting != 0,
        },
    ) catch return 0;
    return 1;
}

export fn wasm_render_frame(progress: f32) i32 {
    if (comptime !ft.enable_incremental) return 0;
    if (current_renderer) |*renderer| {
        free_last_bitmap();
        last_bitmap = renderer.renderFrame(progress) catch return 0;
        return 1;
    }
    return 0;
}

export fn wasm_free_animator() void {
    if (comptime !ft.enable_incremental) return;
    if (current_renderer) |*r| {
        r.deinit();
        current_renderer = null;
    }
}

export fn wasm_get_width() u32 {
    return if (last_bitmap) |b| b.width else 0;
}

export fn wasm_get_height() u32 {
    return if (last_bitmap) |b| b.height else 0;
}

export fn wasm_get_pixels() ?[*]const u8 {
    return if (last_bitmap) |b| b.pixels.ptr else null;
}

fn free_last_bitmap() void {
    if (last_bitmap) |*b| {
        b.deinit();
        last_bitmap = null;
    }
}
