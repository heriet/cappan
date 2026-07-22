const std = @import("std");
const cappan_core = @import("cappan_core");
const discover = @import("cappan_discover");
const Color = cappan_core.render.rgba_bitmap.Color;
const RgbaBitmap = cappan_core.render.rgba_bitmap.RgbaBitmap;
const ft = cappan_core.features.features;
const paint_mod = cappan_core.render.paint;
const scanline_mod = cappan_core.raster.scanline;
const png_mod = @import("image/png.zig");
const bmp_mod = @import("image/bmp.zig");
const ppm_mod = @import("image/ppm.zig");

pub const CommonOptions = struct {
    font_path: ?[]const u8 = null,
    font_name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    size: f32 = 48.0,
    fg_color: Color = Color.black,
    bg_color: Color = Color.white,
    font_index: ?u32 = null,
    gamma_correction: bool = false,
    fractional_positioning: bool = false,
    max_width: ?f32 = null,
    text_align: cappan_core.layout.shaper.TextAlign = .left,
    lcd_rendering: bool = false,
    stem_darkening: bool = false,
    cff_hinting: bool = false,
    auto_hinting: bool = false,
    vertical: bool = false,
    variation_spec: ?[]const u8 = null,
    raster_options: scanline_mod.RasterOptions = .{},
    paint_ops: std.ArrayListUnmanaged(paint_mod.PaintOperation) = .empty,
};

pub fn parseCommonOption(allocator: std.mem.Allocator, opts: *CommonOptions, arg: []const u8, args: *std.process.Args.Iterator) bool {
    if (std.mem.eql(u8, arg, "--font")) {
        opts.font_path = args.next();
        return true;
    } else if (std.mem.eql(u8, arg, "--font-name")) {
        opts.font_name = args.next();
        return true;
    } else if (std.mem.eql(u8, arg, "--text")) {
        opts.text = args.next();
        return true;
    } else if (std.mem.eql(u8, arg, "--size")) {
        if (args.next()) |s| {
            opts.size = std.fmt.parseFloat(f32, s) catch {
                std.debug.print("Error: invalid size '{s}'\n", .{s});
                return true;
            };
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--variation")) {
        opts.variation_spec = args.next();
        return true;
    } else if (std.mem.eql(u8, arg, "--fg-color")) {
        if (args.next()) |hex| {
            opts.fg_color = parseHexColor(hex) orelse {
                std.debug.print("Error: invalid color '{s}', expected RRGGBB\n", .{hex});
                return true;
            };
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--bg-color")) {
        if (args.next()) |hex| {
            opts.bg_color = parseHexColor(hex) orelse {
                std.debug.print("Error: invalid color '{s}', expected RRGGBB\n", .{hex});
                return true;
            };
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--font-index")) {
        if (args.next()) |s| {
            opts.font_index = std.fmt.parseInt(u32, s, 10) catch {
                std.debug.print("Error: invalid font-index '{s}'\n", .{s});
                return true;
            };
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--gamma")) {
        opts.gamma_correction = true;
        return true;
    } else if (std.mem.eql(u8, arg, "--fractional")) {
        opts.fractional_positioning = true;
        return true;
    } else if (std.mem.eql(u8, arg, "--max-width")) {
        if (args.next()) |s| {
            opts.max_width = std.fmt.parseFloat(f32, s) catch {
                std.debug.print("Error: invalid max-width '{s}'\n", .{s});
                return true;
            };
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--text-align")) {
        if (args.next()) |s| {
            if (std.mem.eql(u8, s, "left")) {
                opts.text_align = .left;
            } else if (std.mem.eql(u8, s, "center")) {
                opts.text_align = .center;
            } else if (std.mem.eql(u8, s, "right")) {
                opts.text_align = .right;
            } else if (std.mem.eql(u8, s, "justify")) {
                opts.text_align = .justify;
            } else {
                std.debug.print("Error: invalid text-align '{s}', expected left/center/right/justify\n", .{s});
            }
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--lcd")) {
        opts.lcd_rendering = true;
        return true;
    } else if (std.mem.eql(u8, arg, "--vertical")) {
        opts.vertical = true;
        return true;
    } else if (std.mem.eql(u8, arg, "--stem-darkening")) {
        opts.stem_darkening = true;
        return true;
    } else if (std.mem.eql(u8, arg, "--cff-hinting")) {
        opts.cff_hinting = true;
        return true;
    } else if (std.mem.eql(u8, arg, "--auto-hinting")) {
        opts.auto_hinting = true;
        return true;
    } else if (std.mem.eql(u8, arg, "--aa-level")) {
        if (args.next()) |s| {
            if (std.mem.eql(u8, s, "4")) {
                opts.raster_options.aa_level = .aa_4;
            } else if (std.mem.eql(u8, s, "8")) {
                opts.raster_options.aa_level = .aa_8;
            } else if (std.mem.eql(u8, s, "16")) {
                opts.raster_options.aa_level = .aa_16;
            } else if (std.mem.eql(u8, s, "32")) {
                opts.raster_options.aa_level = .aa_32;
            } else {
                std.debug.print("Error: invalid aa-level '{s}', expected 4, 8, 16, or 32\n", .{s});
            }
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--sample-pattern")) {
        if (args.next()) |s| {
            if (std.mem.eql(u8, s, "regular")) {
                opts.raster_options.sample_pattern = .regular;
            } else if (std.mem.eql(u8, s, "rotated-grid")) {
                opts.raster_options.sample_pattern = .rotated_grid;
            } else {
                std.debug.print("Error: invalid sample-pattern '{s}', expected regular or rotated-grid\n", .{s});
            }
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--adaptive")) {
        opts.raster_options.adaptive = .{};
        return true;
    } else if (std.mem.eql(u8, arg, "--raster-method")) {
        if (args.next()) |s| {
            if (std.mem.eql(u8, s, "supersampling")) {
                opts.raster_options.method = .supersampling;
            } else if (std.mem.eql(u8, s, "analytical")) {
                opts.raster_options.method = .analytical;
            } else {
                std.debug.print("Error: invalid raster-method '{s}', expected supersampling or analytical\n", .{s});
            }
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--stroke")) {
        const spec = args.next() orelse {
            std.debug.print("Error: --stroke requires an argument: WIDTH,RRGGBB[,options...]\n", .{});
            return true;
        };
        {
            const comma_pos = std.mem.indexOfScalar(u8, spec, ',') orelse {
                std.debug.print("Error: invalid stroke '{s}', expected WIDTH,RRGGBB[,options...]\n", .{spec});
                return true;
            };
            const width_part = spec[0..comma_pos];
            const rest = spec[comma_pos + 1 ..];

            // Color is always the first 6 characters after the first comma
            if (rest.len < 6) {
                std.debug.print("Error: invalid stroke color in '{s}', expected RRGGBB\n", .{spec});
                return true;
            }
            const color_hex = rest[0..6];

            const width = parseStrokeWidth(width_part) orelse {
                std.debug.print("Error: invalid stroke width '{s}'\n", .{width_part});
                return true;
            };
            const color = parseHexColor(color_hex) orelse {
                std.debug.print("Error: invalid stroke color '{s}', expected RRGGBB\n", .{color_hex});
                return true;
            };

            var stroke_paint: paint_mod.StrokePaint = .{ .color = color, .width = width };

            // Parse optional key=value pairs after color
            const options_start = if (rest.len > 6 and rest[6] == ',') rest[7..] else "";
            if (options_start.len > 0) {
                if (!parseStrokeOptions(options_start, &stroke_paint)) {
                    return true;
                }
            }

            opts.paint_ops.append(allocator, .{ .stroke = stroke_paint }) catch |err| {
                std.debug.print("Error: could not store stroke paint operation: {}\n", .{err});
                return true;
            };
        }
        return true;
    } else if (std.mem.eql(u8, arg, "--fill")) {
        const spec = args.next() orelse {
            std.debug.print("Error: --fill requires an argument: RRGGBB[,options...]\n", .{});
            return true;
        };
        {
            if (spec.len < 6) {
                std.debug.print("Error: invalid fill color '{s}', expected RRGGBB[,options...]\n", .{spec});
                return true;
            }
            const color_hex = spec[0..6];
            const color = parseHexColor(color_hex) orelse {
                std.debug.print("Error: invalid fill color '{s}', expected RRGGBB\n", .{color_hex});
                return true;
            };

            var fill_paint: paint_mod.FillPaint = .{ .color = color };

            const options_start = if (spec.len > 6 and spec[6] == ',') spec[7..] else "";
            if (options_start.len > 0) {
                if (!parseFillOptions(options_start, &fill_paint)) {
                    return true;
                }
            }

            opts.paint_ops.append(allocator, .{ .fill = fill_paint }) catch |err| {
                std.debug.print("Error: could not store fill paint operation: {}\n", .{err});
                return true;
            };
        }
        return true;
    }
    return false;
}

pub fn loadFont(allocator: std.mem.Allocator, io: std.Io, font_path: []const u8, font_index: ?u32) ?struct { data: []u8, font: cappan_core.font.Font } {
    const cwd = std.Io.Dir.cwd();
    const font_data = cwd.readFileAlloc(io, font_path, allocator, .limited(50 * 1024 * 1024)) catch |read_err| {
        std.debug.print("Error: could not read font file '{s}': {}\n", .{ font_path, read_err });
        return null;
    };
    var diag: cappan_core.err.Diagnostics = .{};
    defer diag.deinit(allocator);
    const font = blk: {
        if (font_index) |idx| {
            break :blk cappan_core.font.Font.initCollectionIndex(allocator, font_data, idx, &diag) catch |parse_err| {
                std.debug.print("Error: could not parse font at index {}: {}\n", .{ idx, parse_err });
                for (diag.entries.items) |entry| {
                    const formatted = cappan_core.err.formatEntry(allocator, entry) catch continue;
                    defer allocator.free(formatted);
                    std.debug.print("  {s}\n", .{formatted});
                }
                allocator.free(font_data);
                return null;
            };
        } else {
            break :blk cappan_core.font.Font.init(allocator, font_data, &diag) catch |parse_err| {
                std.debug.print("Error: could not parse font: {}\n", .{parse_err});
                for (diag.entries.items) |entry| {
                    const formatted = cappan_core.err.formatEntry(allocator, entry) catch continue;
                    defer allocator.free(formatted);
                    std.debug.print("  {s}\n", .{formatted});
                }
                allocator.free(font_data);
                return null;
            };
        }
    };
    return .{ .data = font_data, .font = font };
}

/// Primary font plus any successfully-loaded fallback fonts, ready to pass to the renderer.
/// Owns the fallback fonts/data; call `deinit` when done. The primary font/data passed in
/// remains owned by the caller.
pub const FontSet = struct {
    fonts_list: std.ArrayListUnmanaged(cappan_core.font.Font) = .empty,
    fallback_fonts: std.ArrayListUnmanaged(cappan_core.font.Font) = .empty,
    fallback_data_list: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *FontSet, allocator: std.mem.Allocator) void {
        self.fonts_list.deinit(allocator);
        for (self.fallback_fonts.items) |*f| f.deinit();
        self.fallback_fonts.deinit(allocator);
        for (self.fallback_data_list.items) |d| allocator.free(d);
        self.fallback_data_list.deinit(allocator);
    }
};

/// Loads fallback fonts (best-effort, skipping any that fail) and combines them with
/// `primary_font` into a single fonts list suitable for rendering.
pub fn loadFontSet(
    allocator: std.mem.Allocator,
    io: std.Io,
    primary_font: cappan_core.font.Font,
    fallback_font_paths: []const []const u8,
) !FontSet {
    var result: FontSet = .{};
    errdefer result.deinit(allocator);

    for (fallback_font_paths) |fb_path| {
        const fb_loaded = loadFont(allocator, io, fb_path, null) orelse continue;
        result.fallback_data_list.append(allocator, fb_loaded.data) catch continue;
        result.fallback_fonts.append(allocator, fb_loaded.font) catch continue;
    }

    try result.fonts_list.append(allocator, primary_font);
    try result.fonts_list.appendSlice(allocator, result.fallback_fonts.items);

    return result;
}

/// Extracts the unique Unicode codepoints referenced by `text`, in first-seen
/// (insertion) order. Falls back to treating `text` as raw bytes if it is not
/// valid UTF-8, matching the codepoint-set-from-text convention shared by
/// cmdSubset and cmdAtlas. Caller owns the returned slice.
pub fn collectUniqueCodepoints(allocator: std.mem.Allocator, text: []const u8) ![]u21 {
    var set: std.AutoArrayHashMapUnmanaged(u21, void) = .empty;
    defer set.deinit(allocator);

    if (std.unicode.Utf8View.init(text)) |view| {
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            try set.put(allocator, cp, {});
        }
    } else |_| {
        for (text) |byte| {
            try set.put(allocator, @as(u21, byte), {});
        }
    }

    return try allocator.dupe(u21, set.keys());
}

pub const BitmapRowAdapter = struct {
    bitmap: *const cappan_core.render.rgba_bitmap.RgbaBitmap,

    pub fn renderRow(self: *BitmapRowAdapter, y: u32) []const u8 {
        const offset = @as(usize, y) * @as(usize, self.bitmap.width) * 4;
        return self.bitmap.pixels[offset .. offset + @as(usize, self.bitmap.width) * 4];
    }
};

/// Selects how a PNG should be written: `.whole` hands the fully-materialized bitmap to
/// `writePngRgba`, `.streaming` drives `writePngRgbaStreaming` off of `row_source`.
pub const PngWriteMode = union(enum) {
    whole: RgbaBitmap,
    streaming,
};

/// Creates `output_path`, dispatches to the BMP/PPM/PNG writer based on file extension,
/// flushes, and prints the "Rendered to ..." summary line. Mirrors the write skeleton
/// shared by cmdRender's two output branches; error messages are verbatim matches of the
/// original inlined code.
pub fn writeImageByExtension(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_path: []const u8,
    width: u32,
    height: u32,
    row_source: anytype,
    png_mode: PngWriteMode,
) void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, output_path, .{}) catch |err| {
        std.debug.print("Error: could not create output file '{s}': {}\n", .{ output_path, err });
        return;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const ext = getFileExtension(output_path);
    if (std.mem.eql(u8, ext, ".bmp")) {
        bmp_mod.writeBmp(allocator, width, height, row_source, &writer.interface) catch |err| {
            std.debug.print("Error: could not write BMP: {}\n", .{err});
            return;
        };
    } else if (std.mem.eql(u8, ext, ".ppm")) {
        ppm_mod.writePpm(width, height, row_source, &writer.interface) catch |err| {
            std.debug.print("Error: could not write PPM: {}\n", .{err});
            return;
        };
    } else {
        switch (png_mode) {
            .whole => |bitmap| png_mod.writePngRgba(allocator, bitmap, &writer.interface) catch |err| {
                std.debug.print("Error: could not write PNG: {}\n", .{err});
                return;
            },
            .streaming => png_mod.writePngRgbaStreaming(allocator, width, height, row_source, &writer.interface) catch |err| {
                std.debug.print("Error: could not write PNG: {}\n", .{err});
                return;
            },
        }
    }
    writer.interface.flush() catch |err| {
        std.debug.print("Error: could not flush output: {}\n", .{err});
        return;
    };

    std.debug.print("Rendered to {s} ({d}x{d})\n", .{ output_path, width, height });
}

/// Writes a grayscale (Bitmap) or RGBA (RgbaBitmap) PNG -- createFile -> buffered
/// writer -> writePng/writePngRgba (dispatched on `bitmap`'s comptime type) -> flush,
/// mirroring writeImageByExtension's skeleton above. Errors are printed to stderr and
/// `false` is returned so the caller can bail out without duplicating the
/// error-reporting boilerplate; the caller is still responsible for any "wrote N bytes"
/// success message, since that varies (render vs. atlas page N).
pub fn writePngFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bitmap: anytype,
) bool {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, path, .{}) catch |err| {
        std.debug.print("Error: could not create output file '{s}': {}\n", .{ path, err });
        return false;
    };
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const write_result = switch (@TypeOf(bitmap)) {
        cappan_core.render.bitmap.Bitmap => png_mod.writePng(allocator, bitmap, &writer.interface),
        cappan_core.render.rgba_bitmap.RgbaBitmap => png_mod.writePngRgba(allocator, bitmap, &writer.interface),
        else => @compileError("writePngFile: unsupported bitmap type " ++ @typeName(@TypeOf(bitmap))),
    };
    write_result catch |err| {
        std.debug.print("Error: could not write PNG: {}\n", .{err});
        return false;
    };
    writer.interface.flush() catch |err| {
        std.debug.print("Error: could not flush output: {}\n", .{err});
        return false;
    };
    return true;
}

pub const VariationSetting = struct {
    tag: [4]u8,
    value: f32,
    matched: bool = false,
};

pub fn parseVariationSettings(allocator: std.mem.Allocator, spec: []const u8) ![]VariationSetting {
    var settings: std.ArrayListUnmanaged(VariationSetting) = .empty;
    errdefer settings.deinit(allocator);

    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse {
            std.debug.print("Warning: ignoring invalid variation token '{s}'\n", .{part});
            continue;
        };
        const tag_raw = std.mem.trim(u8, part[0..eq], " \t\r\n");
        const value_raw = std.mem.trim(u8, part[eq + 1 ..], " \t\r\n");
        if (tag_raw.len == 0 or tag_raw.len > 4) {
            std.debug.print("Warning: ignoring invalid variation axis tag '{s}'\n", .{tag_raw});
            continue;
        }
        var tag: [4]u8 = .{ ' ', ' ', ' ', ' ' };
        @memcpy(tag[0..tag_raw.len], tag_raw);
        const value = std.fmt.parseFloat(f32, value_raw) catch {
            std.debug.print("Warning: ignoring invalid variation value '{s}'\n", .{value_raw});
            continue;
        };
        if (!std.math.isFinite(value)) {
            std.debug.print("Warning: ignoring non-finite variation value '{s}'\n", .{value_raw});
            continue;
        }
        try settings.append(allocator, .{ .tag = tag, .value = value });
    }

    return settings.toOwnedSlice(allocator);
}

/// Warn when --variation was given to a subcommand that does not apply it.
/// Only `render` consumes it (COLR v1 paints); every other subcommand ignores it.
pub fn warnVariationUnsupported(common: CommonOptions, subcommand: []const u8) void {
    if (common.variation_spec != null) {
        std.debug.print("Warning: --variation is not supported by {s}; ignoring\n", .{subcommand});
    }
}

/// What the normalized coords will be applied to. The regular render path only
/// feeds them to COLR v1 paint variation, so it warns and bails for fonts
/// without COLR v1; the SDF paths apply them to glyph outlines (gvar), where
/// any fvar font qualifies.
pub const VariationTarget = enum { colr_paint, glyph_outline };

pub fn buildVariationCoords(
    allocator: std.mem.Allocator,
    font: cappan_core.font.Font,
    spec: []const u8,
    target: VariationTarget,
) !?[]f32 {
    if (comptime !ft.enable_variable) {
        std.debug.print("Warning: --variation ignored because variable font support is disabled\n", .{});
        return null;
    }
    if (!font.isVariableFont()) {
        std.debug.print("Warning: --variation ignored because the primary font has no fvar table\n", .{});
        return null;
    }
    if (target == .colr_paint and !font.hasColrV1()) {
        std.debug.print("Warning: --variation currently affects COLR v1 paints only; this font has no COLR v1 table\n", .{});
        return null;
    }

    const axis_count = font.getAxisCount();
    const settings = try parseVariationSettings(allocator, spec);
    defer allocator.free(settings);

    const user_coords = try allocator.alloc(f32, axis_count);
    defer allocator.free(user_coords);

    for (0..axis_count) |i| {
        const axis = try font.getAxis(@intCast(i));
        user_coords[i] = axis.default_value;
        for (settings) |*setting| {
            if (std.mem.eql(u8, &setting.tag, &axis.tag)) {
                user_coords[i] = setting.value;
                setting.matched = true;
            }
        }
    }

    for (settings) |setting| {
        if (!setting.matched) {
            std.debug.print("Warning: unknown variation axis '{s}' ignored\n", .{&setting.tag});
        }
    }

    return try font.computeNormalizedCoords(allocator, user_coords);
}

pub const ResolvedFont = struct {
    path: []const u8,
    font_index: ?u32,
    owned_path: ?[]u8 = null,
};

pub fn resolveFontPath(allocator: std.mem.Allocator, io: std.Io, common: CommonOptions) ?ResolvedFont {
    if (common.font_name) |font_name| {
        var fonts = discover.scanSystemFonts(allocator, io) catch |err| {
            std.debug.print("Error: could not scan system fonts: {}\n", .{err});
            return null;
        };
        defer fonts.deinit();

        const entry = fonts.findByName(font_name) orelse {
            std.debug.print("Error: system font '{s}' was not found\n", .{font_name});
            return null;
        };
        const path = allocator.dupe(u8, entry.path) catch |err| {
            std.debug.print("Error: could not store resolved font path: {}\n", .{err});
            return null;
        };
        const fi: ?u32 = if (entry.font_index > 0) entry.font_index else null;
        return .{ .path = path, .font_index = fi, .owned_path = path };
    }

    return .{ .path = common.font_path.?, .font_index = common.font_index };
}

pub fn parseHexColor(hex: []const u8) ?Color {
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

pub fn parseStrokeWidth(width: []const u8) ?paint_mod.StrokeWidth {
    if (width.len == 0) return null;
    if (std.mem.endsWith(u8, width, "em")) {
        const value = std.fmt.parseFloat(f32, width[0 .. width.len - 2]) catch return null;
        if (value <= 0.0) return null;
        return .{ .em = value };
    }
    if (std.mem.endsWith(u8, width, "px")) {
        const value = std.fmt.parseFloat(f32, width[0 .. width.len - 2]) catch return null;
        if (value <= 0.0) return null;
        return .{ .px = value };
    }
    const value = std.fmt.parseFloat(f32, width) catch return null;
    if (value <= 0.0) return null;
    return .{ .px = value };
}

pub fn parseStrokeOptions(options_str: []const u8, stroke: *paint_mod.StrokePaint) bool {
    var remaining = options_str;
    while (remaining.len > 0) {
        const end = std.mem.indexOfScalar(u8, remaining, ',') orelse remaining.len;
        const pair = remaining[0..end];
        remaining = if (end < remaining.len) remaining[end + 1 ..] else "";

        const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse {
            std.debug.print("Error: invalid stroke option '{s}', expected key=value\n", .{pair});
            return false;
        };
        const key = pair[0..eq_pos];
        const value = pair[eq_pos + 1 ..];

        if (std.mem.eql(u8, key, "position")) {
            if (std.mem.eql(u8, value, "outside")) {
                stroke.position = .outside;
            } else if (std.mem.eql(u8, value, "center")) {
                stroke.position = .center;
            } else if (std.mem.eql(u8, value, "inside")) {
                stroke.position = .inside;
            } else {
                std.debug.print("Error: invalid stroke position '{s}', expected outside|center|inside\n", .{value});
                return false;
            }
        } else if (std.mem.eql(u8, key, "join")) {
            if (std.mem.eql(u8, value, "round")) {
                stroke.join = .round;
            } else if (std.mem.eql(u8, value, "miter")) {
                stroke.join = .miter;
            } else if (std.mem.eql(u8, value, "bevel")) {
                stroke.join = .bevel;
            } else {
                std.debug.print("Error: invalid stroke join '{s}', expected round|miter|bevel\n", .{value});
                return false;
            }
        } else if (std.mem.eql(u8, key, "opacity")) {
            const opacity = std.fmt.parseFloat(f32, value) catch {
                std.debug.print("Error: invalid stroke opacity '{s}'\n", .{value});
                return false;
            };
            if (opacity < 0.0 or opacity > 1.0) {
                std.debug.print("Error: stroke opacity must be between 0.0 and 1.0, got '{s}'\n", .{value});
                return false;
            }
            stroke.opacity = opacity;
        } else if (std.mem.eql(u8, key, "miter-limit")) {
            const limit = std.fmt.parseFloat(f32, value) catch {
                std.debug.print("Error: invalid miter-limit '{s}'\n", .{value});
                return false;
            };
            if (!(limit > 0.0)) {
                std.debug.print("Error: miter-limit must be positive, got '{s}'\n", .{value});
                return false;
            }
            stroke.miter_limit = limit;
        } else if (std.mem.eql(u8, key, "time-weight")) {
            const tw = std.fmt.parseFloat(f32, value) catch {
                std.debug.print("Error: invalid time-weight '{s}'\n", .{value});
                return false;
            };
            if (!(tw > 0.0)) {
                std.debug.print("Error: time-weight must be positive, got '{s}'\n", .{value});
                return false;
            }
            stroke.time_weight = tw;
        } else {
            std.debug.print("Error: unknown stroke option '{s}'\n", .{key});
            return false;
        }
    }
    return true;
}

pub fn parseFillOptions(options_str: []const u8, fill: *paint_mod.FillPaint) bool {
    var remaining = options_str;
    while (remaining.len > 0) {
        const end = std.mem.indexOfScalar(u8, remaining, ',') orelse remaining.len;
        const pair = remaining[0..end];
        remaining = if (end < remaining.len) remaining[end + 1 ..] else "";

        const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse {
            std.debug.print("Error: invalid fill option '{s}', expected key=value\n", .{pair});
            return false;
        };
        const key = pair[0..eq_pos];
        const value = pair[eq_pos + 1 ..];

        if (std.mem.eql(u8, key, "opacity")) {
            const opacity = std.fmt.parseFloat(f32, value) catch {
                std.debug.print("Error: invalid fill opacity '{s}'\n", .{value});
                return false;
            };
            if (opacity < 0.0 or opacity > 1.0) {
                std.debug.print("Error: fill opacity must be between 0.0 and 1.0, got '{s}'\n", .{value});
                return false;
            }
            fill.opacity = opacity;
        } else if (std.mem.eql(u8, key, "time-weight")) {
            const tw = std.fmt.parseFloat(f32, value) catch {
                std.debug.print("Error: invalid time-weight '{s}'\n", .{value});
                return false;
            };
            if (!(tw > 0.0)) {
                std.debug.print("Error: time-weight must be positive, got '{s}'\n", .{value});
                return false;
            }
            fill.time_weight = tw;
        } else {
            std.debug.print("Error: unknown fill option '{s}'\n", .{key});
            return false;
        }
    }
    return true;
}

/// Returns the extension (including the leading dot) of the file name at the end of
/// `path`, or "" if it has none. Delegates to std.fs.path.extension so it only looks at
/// the basename: a dot in a parent directory component (e.g. "out.v2/atlas") no longer
/// gets misread as the file's extension the way a naive `lastIndexOfScalar(path, '.')`
/// would.
pub fn getFileExtension(path: []const u8) []const u8 {
    return std.fs.path.extension(path);
}
