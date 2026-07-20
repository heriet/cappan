const std = @import("std");
const cappan_core = @import("cappan_core");
const cappan_subset = @import("cappan_subset");
const cappan_inspect = @import("cappan_inspect");
const cappan_pathify = @import("cappan_pathify");
const cappan_metrics = @import("cappan_metrics");
const discover = @import("cappan_discover");
const Color = cappan_core.render.rgba_bitmap.Color;
const RgbaBitmap = cappan_core.render.rgba_bitmap.RgbaBitmap;
const ft = cappan_core.features.features;
const incremental_mod = cappan_core.render.incremental;
const paint_mod = cappan_core.render.paint;
const scanline_mod = cappan_core.raster.scanline;
const png_mod = @import("image/png.zig");
const apng_mod = @import("image/apng.zig");
const bmp_mod = @import("image/bmp.zig");
const ppm_mod = @import("image/ppm.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    const subcmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, subcmd, "render")) {
        try cmdRender(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "animate")) {
        if (comptime !ft.enable_incremental) {
            std.debug.print("Error: incremental rendering is disabled at compile time\n", .{});
            return;
        }
        try cmdRenderIncremental(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "fonts")) {
        try cmdListFonts(allocator, io);
    } else if (std.mem.eql(u8, subcmd, "subset")) {
        try cmdSubset(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "inspect")) {
        try cmdInspect(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "svg")) {
        try cmdSvg(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "metrics")) {
        try cmdMetrics(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "atlas")) {
        try cmdAtlas(allocator, io, &args);
    } else {
        printUsage();
    }
}

const CommonOptions = struct {
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

fn parseCommonOption(allocator: std.mem.Allocator, opts: *CommonOptions, arg: []const u8, args: *std.process.Args.Iterator) bool {
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

fn loadFont(allocator: std.mem.Allocator, io: std.Io, font_path: []const u8, font_index: ?u32) ?struct { data: []u8, font: cappan_core.font.Font } {
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
const FontSet = struct {
    fonts_list: std.ArrayListUnmanaged(cappan_core.font.Font) = .empty,
    fallback_fonts: std.ArrayListUnmanaged(cappan_core.font.Font) = .empty,
    fallback_data_list: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *FontSet, allocator: std.mem.Allocator) void {
        self.fonts_list.deinit(allocator);
        for (self.fallback_fonts.items) |*f| f.deinit();
        self.fallback_fonts.deinit(allocator);
        for (self.fallback_data_list.items) |d| allocator.free(d);
        self.fallback_data_list.deinit(allocator);
    }
};

/// Loads fallback fonts (best-effort, skipping any that fail) and combines them with
/// `primary_font` into a single fonts list suitable for rendering.
fn loadFontSet(
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
fn collectUniqueCodepoints(allocator: std.mem.Allocator, text: []const u8) ![]u21 {
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

// --- cappan render ---

const BitmapRowAdapter = struct {
    bitmap: *const cappan_core.render.rgba_bitmap.RgbaBitmap,

    pub fn renderRow(self: *BitmapRowAdapter, y: u32) []const u8 {
        const offset = @as(usize, y) * @as(usize, self.bitmap.width) * 4;
        return self.bitmap.pixels[offset .. offset + @as(usize, self.bitmap.width) * 4];
    }
};

/// Selects how a PNG should be written: `.whole` hands the fully-materialized bitmap to
/// `writePngRgba`, `.streaming` drives `writePngRgbaStreaming` off of `row_source`.
const PngWriteMode = union(enum) {
    whole: RgbaBitmap,
    streaming,
};

/// Creates `output_path`, dispatches to the BMP/PPM/PNG writer based on file extension,
/// flushes, and prints the "Rendered to ..." summary line. Mirrors the write skeleton
/// shared by cmdRender's two output branches; error messages are verbatim matches of the
/// original inlined code.
fn writeImageByExtension(
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
fn writePngFile(
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

const VariationSetting = struct {
    tag: [4]u8,
    value: f32,
    matched: bool = false,
};

fn parseVariationSettings(allocator: std.mem.Allocator, spec: []const u8) ![]VariationSetting {
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
fn warnVariationUnsupported(common: CommonOptions, subcommand: []const u8) void {
    if (common.variation_spec != null) {
        std.debug.print("Warning: --variation is not supported by {s}; ignoring\n", .{subcommand});
    }
}

/// What the normalized coords will be applied to. The regular render path only
/// feeds them to COLR v1 paint variation, so it warns and bails for fonts
/// without COLR v1; the SDF paths apply them to glyph outlines (gvar), where
/// any fvar font qualifies.
const VariationTarget = enum { colr_paint, glyph_outline };

fn buildVariationCoords(
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

fn cmdRender(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var common: CommonOptions = .{};
    defer common.paint_ops.deinit(allocator);
    var output_path: ?[]const u8 = null;
    var fallback_font_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer fallback_font_paths.deinit(allocator);
    var sdf = false;
    var msdf = false;
    var sdf_spread: ?f32 = null;

    while (args.next()) |arg| {
        if (parseCommonOption(allocator, &common, arg, args)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        } else if (std.mem.eql(u8, arg, "--fallback-font")) {
            if (args.next()) |path| {
                fallback_font_paths.append(allocator, path) catch {
                    std.debug.print("Error: could not store fallback font path\n", .{});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--sdf")) {
            sdf = true;
        } else if (std.mem.eql(u8, arg, "--msdf")) {
            msdf = true;
        } else if (std.mem.eql(u8, arg, "--sdf-spread")) {
            if (args.next()) |s| {
                const parsed = std.fmt.parseFloat(f32, s) catch {
                    std.debug.print("Error: invalid sdf-spread '{s}'\n", .{s});
                    return;
                };
                if (!(parsed > 0) or !std.math.isFinite(parsed)) {
                    std.debug.print("Error: --sdf-spread must be a positive number\n", .{});
                    return;
                }
                sdf_spread = parsed;
            }
        }
    }

    if ((common.font_path == null and common.font_name == null) or common.text == null or output_path == null) {
        std.debug.print("Error: --font or --font-name, --text, and --output are required\n", .{});
        printUsage();
        return;
    }

    if (sdf and msdf) {
        std.debug.print("Error: --sdf and --msdf cannot be combined\n", .{});
        return;
    }

    if (sdf_spread != null and !sdf and !msdf) {
        std.debug.print("Error: --sdf-spread requires --sdf or --msdf\n", .{});
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    var font_set = loadFontSet(allocator, io, font, fallback_font_paths.items) catch return;
    defer font_set.deinit(allocator);
    const fonts = font_set.fonts_list.items;

    var normalized_coords: ?[]f32 = null;
    defer if (normalized_coords) |coords| allocator.free(coords);
    if (common.variation_spec) |spec| {
        normalized_coords = buildVariationCoords(allocator, fonts[0], spec, if (sdf or msdf) .glyph_outline else .colr_paint) catch |err| blk: {
            std.debug.print("Warning: could not apply variation '{s}': {}\n", .{ spec, err });
            break :blk null;
        };
    }

    if (common.vertical and comptime !ft.enable_vertical) {
        std.debug.print("Error: vertical layout is disabled at compile time\n", .{});
        return;
    }

    if (sdf or msdf) {
        if (comptime !ft.enable_sdf) {
            std.debug.print("Error: SDF support is disabled in this build\n", .{});
            return;
        }
        if (common.lcd_rendering) {
            std.debug.print("Error: --sdf/--msdf cannot be combined with --lcd\n", .{});
            return;
        }
        if (common.paint_ops.items.len > 0) {
            std.debug.print("Error: --sdf/--msdf cannot be combined with --stroke or --fill\n", .{});
            return;
        }
        const ext = getFileExtension(output_path.?);
        if (!std.mem.eql(u8, ext, ".png")) {
            std.debug.print("Error: --sdf/--msdf output must be a .png file\n", .{});
            return;
        }

        // Shared by both branches below: MtsdfTextOptions is a type alias for
        // SdfTextOptions, so renderTextMtsdf and renderTextSdf take identical options.
        const text_options: cappan_core.raster.sdf.SdfTextOptions = .{
            .pixel_size = common.size,
            .spread = sdf_spread orelse 8.0,
            .max_width = common.max_width,
            .text_align = common.text_align,
            .vertical = common.vertical,
            .normalized_coords = normalized_coords,
        };

        if (msdf) {
            var msdf_bitmap = cappan_core.raster.msdf.renderTextMtsdf(allocator, fonts, common.text.?, text_options) catch |err| {
                std.debug.print("Error: MSDF rendering failed: {}\n", .{err});
                return;
            };
            defer msdf_bitmap.deinit();

            if (!writePngFile(allocator, io, output_path.?, msdf_bitmap)) return;
            std.debug.print("Rendered to {s} ({d}x{d})\n", .{ output_path.?, msdf_bitmap.width, msdf_bitmap.height });
            return;
        }

        var sdf_bitmap = cappan_core.raster.sdf.renderTextSdf(allocator, fonts, common.text.?, text_options) catch |err| {
            std.debug.print("Error: SDF rendering failed: {}\n", .{err});
            return;
        };
        defer sdf_bitmap.deinit();

        if (!writePngFile(allocator, io, output_path.?, sdf_bitmap)) return;

        std.debug.print("Rendered to {s} ({d}x{d})\n", .{ output_path.?, sdf_bitmap.width, sdf_bitmap.height });
        return;
    }

    if (common.lcd_rendering and common.paint_ops.items.len > 0) {
        std.debug.print("Warning: LCD rendering is not supported with paint stack, LCD will be disabled\n", .{});
        common.lcd_rendering = false;
    }
    if (common.vertical and common.lcd_rendering) {
        std.debug.print("Warning: LCD rendering is not supported with vertical layout, LCD will be disabled\n", .{});
        common.lcd_rendering = false;
    }
    if (common.lcd_rendering or common.paint_ops.items.len > 0 or normalized_coords != null) {
        var bitmap = cappan_core.render.renderer.renderText(allocator, fonts, common.text.?, .{
            .pixel_size = common.size,
            .fg_color = common.fg_color,
            .bg_color = common.bg_color,
            .lcd_rendering = common.lcd_rendering,
            .gamma_correction = common.gamma_correction,
            .fractional_positioning = common.fractional_positioning,
            .max_width = common.max_width,
            .text_align = common.text_align,
            .paint_stack = if (common.paint_ops.items.len > 0) common.paint_ops.items else null,
            .raster_options = common.raster_options,
            .stem_darkening = common.stem_darkening,
            .cff_hinting = common.cff_hinting,
            .auto_hinting = common.auto_hinting,
            .vertical = common.vertical,
            .normalized_coords = normalized_coords orelse &.{},
        }) catch |err| {
            std.debug.print("Error: rendering failed: {}\n", .{err});
            return;
        };
        defer bitmap.deinit();

        var adapter = BitmapRowAdapter{ .bitmap = &bitmap };
        writeImageByExtension(allocator, io, output_path.?, bitmap.width, bitmap.height, &adapter, .{ .whole = bitmap });
    } else {
        var row_renderer = cappan_core.render.renderer.RowRenderer.init(allocator, fonts, common.text.?, .{
            .pixel_size = common.size,
            .fg_color = common.fg_color,
            .bg_color = common.bg_color,
            .gamma_correction = common.gamma_correction,
            .fractional_positioning = common.fractional_positioning,
            .max_width = common.max_width,
            .text_align = common.text_align,
            .raster_options = common.raster_options,
            .stem_darkening = common.stem_darkening,
            .cff_hinting = common.cff_hinting,
            .auto_hinting = common.auto_hinting,
            .vertical = common.vertical,
            .normalized_coords = normalized_coords orelse &.{},
        }) catch |err| {
            std.debug.print("Error: rendering failed: {}\n", .{err});
            return;
        };
        defer row_renderer.deinit();

        writeImageByExtension(allocator, io, output_path.?, row_renderer.width, row_renderer.height, &row_renderer, .streaming);
    }
}

// --- cappan atlas ---

fn buildAtlasPagePath(allocator: std.mem.Allocator, output_path: []const u8, page_index: u16) ![]u8 {
    const ext = getFileExtension(output_path);
    const stem = output_path[0 .. output_path.len - ext.len];
    return std.fmt.allocPrint(allocator, "{s}_{d}{s}", .{ stem, page_index, ext });
}

const AtlasGlyphMetric = struct {
    codepoint: u21,
    glyph_id: u16,
    advance_px: f32,
    region: cappan_core.raster.atlas.AtlasRegion,
};

/// The generateGlyphSdf/generateGlyphMtsdf result fields cmdAtlas's glyph loop
/// actually needs, common to both so it can branch on generation only and then
/// share the empty-check/insert/warning logic afterward. Owns `pixels` (must be
/// freed once by the caller); the source SdfResult/MtsdfResult is intentionally
/// NOT deinit'd inside the branch that produces this, since that would free the
/// same memory this struct still points at.
const GeneratedGlyphField = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    offset_x: f32,
    offset_y: f32,
};

fn cmdAtlas(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    if (comptime !ft.enable_sdf) {
        std.debug.print("Error: SDF support is disabled in this build\n", .{});
        return;
    }

    var common: CommonOptions = .{ .size = 64.0 };
    defer common.paint_ops.deinit(allocator);
    var output_path: ?[]const u8 = null;
    var metrics_path: ?[]const u8 = null;
    var sdf_spread: f32 = 8.0;
    var page_size: u32 = 1024;
    var msdf = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--msdf")) {
            msdf = true;
        } else if (std.mem.eql(u8, arg, "--sdf-spread")) {
            if (args.next()) |s| {
                const parsed = std.fmt.parseFloat(f32, s) catch {
                    std.debug.print("Error: invalid sdf-spread '{s}'\n", .{s});
                    return;
                };
                if (!(parsed > 0) or !std.math.isFinite(parsed)) {
                    std.debug.print("Error: --sdf-spread must be a positive number\n", .{});
                    return;
                }
                sdf_spread = parsed;
            }
        } else if (std.mem.eql(u8, arg, "--page-size")) {
            if (args.next()) |s| {
                page_size = std.fmt.parseInt(u32, s, 10) catch {
                    std.debug.print("Error: invalid page-size '{s}'\n", .{s});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        } else if (std.mem.eql(u8, arg, "--metrics")) {
            metrics_path = args.next();
        } else if (parseCommonOption(allocator, &common, arg, args)) {
            continue;
        }
    }

    if ((common.font_path == null and common.font_name == null) or common.text == null or output_path == null or metrics_path == null) {
        std.debug.print("Error: --font or --font-name, --text, --output, and --metrics are required for atlas\n", .{});
        printUsage();
        return;
    }

    const output_ext = getFileExtension(output_path.?);
    if (!std.mem.eql(u8, output_ext, ".png")) {
        std.debug.print("Error: --output must be a .png file\n", .{});
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    // Same construction cmdRender uses, but targeting glyph outlines (gvar): null unless
    // --variation was given and the font has fvar (see buildVariationCoords).
    var normalized_coords: ?[]f32 = null;
    defer if (normalized_coords) |coords| allocator.free(coords);
    if (common.variation_spec) |spec| {
        normalized_coords = buildVariationCoords(allocator, font, spec, .glyph_outline) catch |err| blk: {
            std.debug.print("Warning: could not apply variation '{s}': {}\n", .{ spec, err });
            break :blk null;
        };
    }

    // Codepoints sorted ascending (collectUniqueCodepoints itself returns first-seen
    // order, shared with cmdSubset; atlas glyph ordering is sorted on top of that).
    const codepoints = try collectUniqueCodepoints(allocator, common.text.?);
    defer allocator.free(codepoints);
    std.mem.sort(u21, codepoints, {}, std.sort.asc(u21));

    var atlas = cappan_core.raster.atlas.GlyphAtlas.init(allocator, .{ .page_width = page_size, .page_height = page_size, .bytes_per_pixel = if (msdf) 4 else 1 });
    defer atlas.deinit();

    var glyph_metrics: std.ArrayListUnmanaged(AtlasGlyphMetric) = .empty;
    defer glyph_metrics.deinit(allocator);

    var skipped: usize = 0;
    const scale = common.size / @as(f32, @floatFromInt(font.getUnitsPerEm()));

    for (codepoints) |cp| {
        const glyph_id = font.getGlyphId(@as(u32, cp)) catch 0;
        if (glyph_id == 0) {
            skipped += 1;
            continue;
        }

        const outline_opt = (if (normalized_coords) |coords|
            font.getGlyphOutlineWithVariation(allocator, glyph_id, coords)
        else
            font.getGlyphOutline(allocator, glyph_id)) catch |err| {
            std.debug.print("Warning: could not get outline for U+{X:0>4}: {}\n", .{ cp, err });
            skipped += 1;
            continue;
        };
        if (outline_opt == null) {
            skipped += 1;
            continue;
        }
        var outline = outline_opt.?;
        defer outline.deinit();

        // getHMetrics before atlas.insert: if this fails we skip the glyph entirely
        // (via `continue`) instead of leaving it packed into the page pixels but
        // missing from the metrics JSON. With --variation, HVAR advance deltas are
        // applied so advancePx matches the varied outlines.
        const hmetrics = (if (normalized_coords) |coords|
            font.getHMetricsWithVariation(glyph_id, coords)
        else
            font.getHMetrics(glyph_id)) catch |err| {
            std.debug.print("Warning: could not get advance width for U+{X:0>4}: {}\n", .{ cp, err });
            skipped += 1;
            continue;
        };
        const advance_px = @as(f32, @floatFromInt(hmetrics.advance_width)) * scale;

        // Generation is the only part that differs between MSDF and SDF; the
        // empty check, atlas.insert, and warning text below are shared. Neither
        // branch deinits its own result -- ownership of `.pixels` moves into
        // `generated`, freed once by the defer right after.
        const label: []const u8 = if (msdf) "MSDF" else "SDF";
        const generated: GeneratedGlyphField = if (msdf) blk: {
            const mtsdf_result = cappan_core.raster.msdf.generateGlyphMtsdf(allocator, outline, scale, .{ .spread = sdf_spread }) catch |err| {
                std.debug.print("Warning: could not generate {s} for U+{X:0>4}: {}\n", .{ label, cp, err });
                skipped += 1;
                continue;
            };
            break :blk .{ .pixels = mtsdf_result.pixels, .width = mtsdf_result.width, .height = mtsdf_result.height, .offset_x = mtsdf_result.offset_x, .offset_y = mtsdf_result.offset_y };
        } else blk: {
            const sdf_result = cappan_core.raster.sdf.generateGlyphSdf(allocator, outline, scale, .{ .spread = sdf_spread }) catch |err| {
                std.debug.print("Warning: could not generate {s} for U+{X:0>4}: {}\n", .{ label, cp, err });
                skipped += 1;
                continue;
            };
            break :blk .{ .pixels = sdf_result.pixels, .width = sdf_result.width, .height = sdf_result.height, .offset_x = sdf_result.offset_x, .offset_y = sdf_result.offset_y };
        };
        defer allocator.free(generated.pixels);

        if (generated.width == 0 or generated.height == 0) {
            skipped += 1;
            continue;
        }

        const region = atlas.insert(0, glyph_id, common.size, generated.pixels, generated.width, generated.height, generated.offset_x, generated.offset_y) catch |err| {
            std.debug.print("Warning: could not pack glyph for U+{X:0>4}: {}\n", .{ cp, err });
            skipped += 1;
            continue;
        };

        try glyph_metrics.append(allocator, .{ .codepoint = cp, .glyph_id = glyph_id, .advance_px = advance_px, .region = region });
    }

    std.debug.print("Atlas: {d} glyphs packed, {d} codepoints skipped\n", .{ glyph_metrics.items.len, skipped });

    if (glyph_metrics.items.len == 0) {
        std.debug.print("Error: no glyphs could be packed into the atlas\n", .{});
        return;
    }

    const page_count = atlas.pageCount();

    var page_index: u16 = 0;
    while (page_index < page_count) : (page_index += 1) {
        // Page 0 writes directly to --output; later pages own an allocated <stem>_<n> path.
        const page_path: []const u8 = if (page_index == 0)
            output_path.?
        else
            try buildAtlasPagePath(allocator, output_path.?, page_index);
        defer if (page_index != 0) allocator.free(page_path);

        if (msdf) {
            var page_bitmap = (try atlas.exportPageRgba(allocator, page_index)) orelse continue;
            defer page_bitmap.deinit();
            if (!writePngFile(allocator, io, page_path, page_bitmap)) return;
        } else {
            var page_bitmap = (try atlas.exportPageRaw(allocator, page_index)) orelse continue;
            defer page_bitmap.deinit();
            if (!writePngFile(allocator, io, page_path, page_bitmap)) return;
        }

        std.debug.print("Atlas page {d} written to {s} ({d}x{d})\n", .{ page_index, page_path, page_size, page_size });
    }

    // Metrics JSON (hand-written, matching cmdInspect's json style), printed straight to
    // a buffered file writer rather than staged through an intermediate ArrayList.
    const cwd = std.Io.Dir.cwd();
    const metrics_file = cwd.createFile(io, metrics_path.?, .{}) catch |err| {
        std.debug.print("Error: could not create metrics file '{s}': {}\n", .{ metrics_path.?, err });
        return;
    };
    defer metrics_file.close(io);

    var metrics_buf: [4096]u8 = undefined;
    var metrics_writer = metrics_file.writer(io, &metrics_buf);
    const w = &metrics_writer.interface;

    w.print(
        \\{{
        \\  "atlas": {{"type": "{s}", "pageWidth": {d}, "pageHeight": {d}, "pageCount": {d}, "size": {d}, "spread": {d}}},
        \\  "font": {{"unitsPerEm": {d}, "ascender": {d}, "descender": {d}, "lineGap": {d}}},
        \\  "glyphs": [
    , .{ if (msdf) "mtsdf" else "sdf", page_size, page_size, page_count, common.size, sdf_spread, font.getUnitsPerEm(), font.getAscender(), font.getDescender(), font.getLineGap() }) catch |err| {
        std.debug.print("Error: could not write metrics JSON: {}\n", .{err});
        return;
    };

    for (glyph_metrics.items, 0..) |gm, i| {
        if (i > 0) {
            w.writeAll(",") catch |err| {
                std.debug.print("Error: could not write metrics JSON: {}\n", .{err});
                return;
            };
        }
        w.print(
            \\
            \\    {{"codepoint": {d}, "glyphId": {d}, "advancePx": {d}, "page": {d}, "atlasX": {d}, "atlasY": {d}, "width": {d}, "height": {d}, "offsetX": {d}, "offsetY": {d}}}
        , .{ gm.codepoint, gm.glyph_id, gm.advance_px, gm.region.page, gm.region.x, gm.region.y, gm.region.width, gm.region.height, gm.region.offset_x, gm.region.offset_y }) catch |err| {
            std.debug.print("Error: could not write metrics JSON: {}\n", .{err});
            return;
        };
    }

    w.writeAll("\n  ]\n}\n") catch |err| {
        std.debug.print("Error: could not write metrics JSON: {}\n", .{err});
        return;
    };

    w.flush() catch |err| {
        std.debug.print("Error: could not flush metrics output: {}\n", .{err});
        return;
    };

    std.debug.print("Metrics written to {s}\n", .{metrics_path.?});
}

// --- cappan render-incremental ---

fn cmdRenderIncremental(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var common: CommonOptions = .{};
    defer common.paint_ops.deinit(allocator);
    var output_path: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var num_frames: u32 = 10;
    var fps: u16 = 10;
    var strategy_name: []const u8 = "sweep";
    var sweep_dir_name: []const u8 = "left-to-right";
    var timing_name: []const u8 = "sequential";
    var contour_ordering_name: []const u8 = "font-order";
    var hold_frames: u32 = 0;
    var reverse = false;
    var extrema_invert = true;
    var easing_name: []const u8 = "linear";
    var paint_layer_timing_name: []const u8 = "simultaneous";
    var fallback_font_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer fallback_font_paths.deinit(allocator);

    while (args.next()) |arg| {
        if (parseCommonOption(allocator, &common, arg, args)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            output_dir = args.next();
        } else if (std.mem.eql(u8, arg, "--frames")) {
            if (args.next()) |s| {
                num_frames = std.fmt.parseInt(u32, s, 10) catch {
                    std.debug.print("Error: invalid frames count '{s}'\n", .{s});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--fps")) {
            if (args.next()) |s| {
                fps = std.fmt.parseInt(u16, s, 10) catch {
                    std.debug.print("Error: invalid fps '{s}'\n", .{s});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--strategy")) {
            strategy_name = args.next() orelse "sweep";
        } else if (std.mem.eql(u8, arg, "--sweep-direction")) {
            sweep_dir_name = args.next() orelse "left-to-right";
        } else if (std.mem.eql(u8, arg, "--timing")) {
            timing_name = args.next() orelse "sequential";
        } else if (std.mem.eql(u8, arg, "--contour-ordering")) {
            contour_ordering_name = args.next() orelse "font-order";
        } else if (std.mem.eql(u8, arg, "--hold")) {
            if (args.next()) |s| {
                hold_frames = std.fmt.parseInt(u32, s, 10) catch {
                    std.debug.print("Error: invalid hold frames '{s}'\n", .{s});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            reverse = true;
        } else if (std.mem.eql(u8, arg, "--extrema-invert")) {
            extrema_invert = false;
        } else if (std.mem.eql(u8, arg, "--easing")) {
            easing_name = args.next() orelse "linear";
        } else if (std.mem.eql(u8, arg, "--paint-layer-timing")) {
            paint_layer_timing_name = args.next() orelse "simultaneous";
        } else if (std.mem.eql(u8, arg, "--fallback-font")) {
            if (args.next()) |path| {
                fallback_font_paths.append(allocator, path) catch {
                    std.debug.print("Error: could not store fallback font path\n", .{});
                    return;
                };
            }
        }
    }

    warnVariationUnsupported(common, "animate");

    if ((common.font_path == null and common.font_name == null) or common.text == null) {
        std.debug.print("Error: --font or --font-name and --text are required\n", .{});
        printUsage();
        return;
    }

    if (output_path == null and output_dir == null) {
        std.debug.print("Error: either --output (APNG) or --output-dir (frame sequence) is required\n", .{});
        printUsage();
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    var font_set = loadFontSet(allocator, io, font, fallback_font_paths.items) catch return;
    defer font_set.deinit(allocator);
    const fonts = font_set.fonts_list.items;

    // Parse sweep direction
    const sweep_dir: incremental_mod.SweepDirection = if (std.mem.eql(u8, sweep_dir_name, "right-to-left"))
        .right_to_left
    else if (std.mem.eql(u8, sweep_dir_name, "top-to-bottom"))
        .top_to_bottom
    else if (std.mem.eql(u8, sweep_dir_name, "bottom-to-top"))
        .bottom_to_top
    else
        .left_to_right;

    // Parse contour ordering
    const contour_ordering: incremental_mod.ContourOrdering =
        if (std.mem.eql(u8, contour_ordering_name, "stroke-heuristic"))
            .stroke_heuristic
        else if (std.mem.eql(u8, contour_ordering_name, "area-priority"))
            .area_priority
        else if (std.mem.eql(u8, contour_ordering_name, "writing-order"))
            .writing_order
        else
            .font_order;

    // Parse strategy
    const strategy: incremental_mod.RevealStrategy = if (std.mem.eql(u8, strategy_name, "fade"))
        .fade
    else if (std.mem.eql(u8, strategy_name, "contour-trace"))
        .{ .contour_trace = .{ .ordering = contour_ordering } }
    else if (std.mem.eql(u8, strategy_name, "medial-axis"))
        .{ .medial_axis = .{ .ordering = contour_ordering } }
    else if (std.mem.eql(u8, strategy_name, "distance-field"))
        .{ .distance_field = .{} }
    else if (std.mem.eql(u8, strategy_name, "extrema-wave"))
        .{ .extrema_wave = .{ .invert = extrema_invert } }
    else if (std.mem.eql(u8, strategy_name, "skeleton-grow"))
        .{ .skeleton_grow = .{} }
    else if (std.mem.eql(u8, strategy_name, "tangent-flow"))
        .{ .tangent_flow = .{} }
    else
        .{ .sweep = .{ .direction = sweep_dir } };

    // Parse easing
    const easing: incremental_mod.Easing = if (std.mem.eql(u8, easing_name, "ease-in"))
        .ease_in
    else if (std.mem.eql(u8, easing_name, "ease-out"))
        .ease_out
    else if (std.mem.eql(u8, easing_name, "ease-in-out"))
        .ease_in_out
    else if (std.mem.eql(u8, easing_name, "ease-in-cubic"))
        .ease_in_cubic
    else if (std.mem.eql(u8, easing_name, "ease-out-cubic"))
        .ease_out_cubic
    else if (std.mem.eql(u8, easing_name, "ease-in-out-cubic"))
        .ease_in_out_cubic
    else
        .linear;

    // Parse timing
    const timing: incremental_mod.Timing = blk: {
        if (std.mem.eql(u8, timing_name, "simultaneous")) {
            break :blk .simultaneous;
        } else if (std.mem.eql(u8, timing_name, "weighted")) {
            break :blk .weighted;
        } else if (std.mem.startsWith(u8, timing_name, "overlap:")) {
            const val_str = timing_name["overlap:".len..];
            const val = std.fmt.parseFloat(f32, val_str) catch 0.5;
            break :blk .{ .overlap = val };
        } else {
            break :blk .sequential;
        }
    };

    var inc = incremental_mod.IncrementalRenderer.init(allocator, fonts, common.text.?, .{
        .pixel_size = common.size,
        .fg_color = common.fg_color,
        .bg_color = common.bg_color,
        .gamma_correction = common.gamma_correction,
        .fractional_positioning = common.fractional_positioning,
        .strategy = strategy,
        .timing = timing,
        .easing = easing,
        .max_width = common.max_width,
        .text_align = common.text_align,
        .paint_stack = if (common.paint_ops.items.len > 0) common.paint_ops.items else null,
        .paint_layer_timing = if (std.mem.eql(u8, paint_layer_timing_name, "sequential")) .sequential else .simultaneous,
        .raster_options = common.raster_options,
        .stem_darkening = common.stem_darkening,
        .cff_hinting = common.cff_hinting,
        .auto_hinting = common.auto_hinting,
    }) catch |err| {
        std.debug.print("Error: could not create incremental renderer: {}\n", .{err});
        return;
    };
    defer inc.deinit();

    const cwd = std.Io.Dir.cwd();

    // Build the sequence of animation frame indices (shared by both output modes)
    var frame_indices: std.ArrayListUnmanaged(u32) = .empty;
    defer frame_indices.deinit(allocator);

    // Phase 1: Animation frames (forward or reverse)
    if (reverse) {
        var rev: u32 = num_frames;
        while (rev > 0) {
            rev -= 1;
            frame_indices.append(allocator, rev) catch |err| {
                std.debug.print("Error: could not build frame index list: {}\n", .{err});
                return;
            };
        }
    } else {
        for (0..num_frames) |f| {
            frame_indices.append(allocator, @intCast(f)) catch |err| {
                std.debug.print("Error: could not build frame index list: {}\n", .{err});
                return;
            };
        }
    }
    // Phase 2: Hold frames (repeat final frame)
    {
        const hold_frame: u32 = if (reverse) 0 else num_frames - 1;
        for (0..hold_frames) |_| {
            frame_indices.append(allocator, hold_frame) catch |err| {
                std.debug.print("Error: could not build hold frame index list: {}\n", .{err});
                return;
            };
        }
    }

    if (output_path != null) {
        // APNG mode: collect all frames and write as a single APNG file
        var frame_bitmaps: std.ArrayList(RgbaBitmap) = .empty;
        defer {
            for (frame_bitmaps.items) |*bmp| {
                bmp.deinit();
            }
            frame_bitmaps.deinit(allocator);
        }

        for (frame_indices.items) |anim_frame| {
            const bitmap = inc.renderFrameByIndex(anim_frame, num_frames) catch |err| {
                std.debug.print("Error: could not render frame {d}: {}\n", .{ anim_frame, err });
                return;
            };
            frame_bitmaps.append(allocator, bitmap) catch |err| {
                std.debug.print("Error: could not collect frame {d}: {}\n", .{ anim_frame, err });
                return;
            };
        }

        const file = cwd.createFile(io, output_path.?, .{}) catch |err| {
            std.debug.print("Error: could not create output file '{s}': {}\n", .{ output_path.?, err });
            return;
        };
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        apng_mod.writeApngRgba(allocator, frame_bitmaps.items, 1, fps, &writer.interface) catch |err| {
            std.debug.print("Error: could not write APNG: {}\n", .{err});
            return;
        };
        writer.interface.flush() catch |err| {
            std.debug.print("Error: could not flush output: {}\n", .{err});
            return;
        };

        const total_output_frames = frame_bitmaps.items.len;
        std.debug.print("Rendered {d} frames to {s} ({d}x{d}, {d}fps)\n", .{ total_output_frames, output_path.?, inc.width, inc.height, fps });
    } else {
        // Frame sequence mode: write individual PNG files to output_dir
        cwd.createDir(io, output_dir.?, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("Error: could not create output directory '{s}': {}\n", .{ output_dir.?, err });
                return;
            }
        };

        var path_buf: [4096]u8 = undefined;

        for (frame_indices.items, 0..) |anim_frame, output_idx| {
            var bitmap = inc.renderFrameByIndex(anim_frame, num_frames) catch |err| {
                std.debug.print("Error: could not render frame {d}: {}\n", .{ anim_frame, err });
                return;
            };
            defer bitmap.deinit();

            const frame_path = std.fmt.bufPrint(&path_buf, "{s}/frame_{d:0>4}.png", .{ output_dir.?, output_idx }) catch {
                std.debug.print("Error: path too long\n", .{});
                return;
            };

            const file = cwd.createFile(io, frame_path, .{}) catch |err| {
                std.debug.print("Error: could not create file '{s}': {}\n", .{ frame_path, err });
                return;
            };
            defer file.close(io);

            var buf: [4096]u8 = undefined;
            var writer = file.writer(io, &buf);
            png_mod.writePngRgba(allocator, bitmap, &writer.interface) catch |err| {
                std.debug.print("Error: could not write PNG for frame {d}: {}\n", .{ output_idx, err });
                return;
            };
            writer.interface.flush() catch |err| {
                std.debug.print("Error: could not flush frame {d}: {}\n", .{ output_idx, err });
                return;
            };
        }

        std.debug.print("Rendered {d} frames to {s}/ ({d}x{d})\n", .{ frame_indices.items.len, output_dir.?, inc.width, inc.height });
    }
}

// --- cappan subset ---

fn cmdSubset(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var common = CommonOptions{};
    defer common.paint_ops.deinit(allocator);
    var output_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (parseCommonOption(allocator, &common, arg, args)) {
            // handled
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        }
    }

    warnVariationUnsupported(common, "subset");

    if ((common.font_path == null and common.font_name == null) or common.text == null or output_path == null) {
        std.debug.print("Error: --font or --font-name, --text, and --output are required for subset\n", .{});
        printUsage();
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    // Collect unique codepoints from text, in first-seen order (subsetFont doesn't care
    // about ordering, but preserving it keeps behavior identical to the old inline loop).
    const codepoints = try collectUniqueCodepoints(allocator, common.text.?);
    defer allocator.free(codepoints);

    const subset_data = cappan_subset.subsetter.subsetFont(
        allocator,
        font,
        codepoints,
        .{},
    ) catch |err| {
        if (err == error.CffNotSupported) {
            std.debug.print("Error: CFF/OTF font subsetting is not supported. Use a TrueType (.ttf) font.\n", .{});
        } else {
            std.debug.print("Error: subsetting failed: {}\n", .{err});
        }
        return;
    };
    defer allocator.free(subset_data);

    // Write to output file
    const cwd = std.Io.Dir.cwd();
    const out_file = cwd.createFile(io, output_path.?, .{}) catch |err| {
        std.debug.print("Error: could not create output file: {}\n", .{err});
        return;
    };
    defer out_file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = out_file.writer(io, &buf);
    writer.interface.writeAll(subset_data) catch |err| {
        std.debug.print("Error: could not write output file: {}\n", .{err});
        return;
    };
    writer.interface.flush() catch |err| {
        std.debug.print("Error: could not flush output file: {}\n", .{err});
        return;
    };

    std.debug.print("Subset font written to {s} ({d} bytes, {d} codepoints)\n", .{
        output_path.?,
        subset_data.len,
        codepoints.len,
    });
}

// --- cappan fonts ---

fn cmdListFonts(allocator: std.mem.Allocator, io: std.Io) !void {
    var fonts = discover.scanSystemFonts(allocator, io) catch |err| {
        std.debug.print("Error: could not scan system fonts: {}\n", .{err});
        return;
    };
    defer fonts.deinit();

    for (fonts.entries.items) |entry| {
        const family = entry.family orelse "(unknown)";
        if (entry.subfamily) |subfamily| {
            std.debug.print("  {s} [{s}]\n", .{ family, subfamily });
        } else {
            std.debug.print("  {s}\n", .{family});
        }
        std.debug.print("    {s} [index {d}]\n", .{ entry.path, entry.font_index });
    }
}

fn jsonEscapeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const hex = "0123456789ABCDEF";
                buf[0] = '\\';
                buf[1] = 'u';
                buf[2] = '0';
                buf[3] = '0';
                buf[4] = hex[c >> 4];
                buf[5] = hex[c & 0xF];
                try out.appendSlice(allocator, &buf);
            },
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

// --- cappan inspect ---

fn cmdInspect(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var common: CommonOptions = .{};
    defer common.paint_ops.deinit(allocator);
    var show_summary = false;
    var show_tables = false;
    var show_validate = false;
    var show_coverage = false;
    var show_features = false;
    var show_glyphs = false;
    var glyph_text: ?[]const u8 = null;
    var glyph_ids_raw: ?[]const u8 = null;
    const OutputFormat = enum { text, json, yaml };
    var format: OutputFormat = .text;

    while (args.next()) |arg| {
        if (parseCommonOption(allocator, &common, arg, args)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            show_summary = true;
        } else if (std.mem.eql(u8, arg, "--tables")) {
            show_tables = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            show_validate = true;
        } else if (std.mem.eql(u8, arg, "--coverage")) {
            show_coverage = true;
        } else if (std.mem.eql(u8, arg, "--features")) {
            show_features = true;
        } else if (std.mem.eql(u8, arg, "--glyphs")) {
            show_glyphs = true;
        } else if (std.mem.eql(u8, arg, "--glyph")) {
            show_glyphs = true;
            glyph_text = args.next();
        } else if (std.mem.eql(u8, arg, "--glyph-id")) {
            show_glyphs = true;
            glyph_ids_raw = args.next();
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (args.next()) |fmt_str| {
                if (std.mem.eql(u8, fmt_str, "json")) {
                    format = .json;
                } else if (std.mem.eql(u8, fmt_str, "yaml")) {
                    format = .yaml;
                } else if (std.mem.eql(u8, fmt_str, "text")) {
                    format = .text;
                } else {
                    std.debug.print("Error: unknown format '{s}', expected text, json, or yaml\n", .{fmt_str});
                    return;
                }
            }
        }
    }

    const show_all = !show_summary and !show_tables and !show_validate and !show_coverage and !show_features and !show_glyphs;
    const do_summary = show_all or show_summary;
    const do_tables = show_all or show_tables;
    const do_validate = show_all or show_validate;
    const do_coverage = show_all or show_coverage;
    const do_features = show_all or show_features;
    const do_glyphs = show_glyphs;

    warnVariationUnsupported(common, "inspect");

    if (common.font_path == null and common.font_name == null) {
        std.debug.print("Error: --font or --font-name is required\n", .{});
        printUsage();
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    var summary_opt: ?cappan_inspect.FontSummary = null;
    defer if (summary_opt) |*s| s.deinit();
    if (do_summary or do_tables) {
        summary_opt = cappan_inspect.getSummary(allocator, font) catch |err| {
            std.debug.print("Error: could not get font summary: {}\n", .{err});
            return;
        };
    }

    var validation_opt: ?cappan_core.err.Diagnostics = null;
    defer if (validation_opt) |*v| v.deinit(allocator);
    if (do_validate) {
        validation_opt = cappan_inspect.validate(allocator, font) catch |err| {
            std.debug.print("Error: could not validate font: {}\n", .{err});
            return;
        };
    }

    var blocks_opt: ?[]cappan_inspect.UnicodeBlock = null;
    defer if (blocks_opt) |b| allocator.free(b);
    if (do_coverage) {
        blocks_opt = cappan_inspect.analyzeCoverage(allocator, font) catch |err| {
            std.debug.print("Error: could not analyze coverage: {}\n", .{err});
            return;
        };
    }

    var features_opt: ?[]cappan_inspect.FeatureInfo = null;
    defer if (features_opt) |f| allocator.free(f);
    if (do_features) {
        features_opt = cappan_inspect.listFeatures(allocator, font) catch |err| {
            std.debug.print("Error: could not list features: {}\n", .{err});
            return;
        };
    }

    var glyph_infos: std.ArrayList(cappan_inspect.GlyphInfo) = .empty;
    defer glyph_infos.deinit(allocator);

    if (do_glyphs) {
        if (glyph_text) |text| {
            const view = std.unicode.Utf8View.init(text) catch blk: {
                break :blk std.unicode.Utf8View.initUnchecked(text);
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                const glyph_id = font.getGlyphId(@as(u32, cp)) catch continue;
                const info = cappan_inspect.getGlyphInfo(allocator, font, glyph_id, @as(u32, cp)) catch continue;
                glyph_infos.append(allocator, info) catch continue;
            }
        } else if (glyph_ids_raw) |ids_str| {
            var iter = std.mem.splitScalar(u8, ids_str, ',');
            while (iter.next()) |id_str| {
                const trimmed = std.mem.trim(u8, id_str, " ");
                const glyph_id = std.fmt.parseInt(u16, trimmed, 10) catch continue;
                const info = cappan_inspect.getGlyphInfo(allocator, font, glyph_id, null) catch continue;
                glyph_infos.append(allocator, info) catch continue;
            }
        }
    }

    switch (format) {
        .text => {
            if (do_summary) {
                if (summary_opt) |summary| {
                    const family = summary.family_name orelse "(unknown)";
                    std.debug.print("Font: {s}\n", .{family});
                    if (summary.subfamily_name) |sub| {
                        std.debug.print("  Family: {s} [{s}]\n", .{ family, sub });
                    } else {
                        std.debug.print("  Family: {s}\n", .{family});
                    }
                    std.debug.print("  Glyphs: {d}\n", .{summary.num_glyphs});
                    std.debug.print("  Units per em: {d}\n", .{summary.units_per_em});
                    std.debug.print("  Ascender: {d} / Descender: {d} / Line gap: {d}\n", .{ summary.ascender, summary.descender, summary.line_gap });
                    std.debug.print("  Bounding box: [{d}, {d}, {d}, {d}]\n", .{ summary.x_min, summary.y_min, summary.x_max, summary.y_max });
                }
            }
            if (do_tables) {
                if (summary_opt) |summary| {
                    std.debug.print("\nTables ({d}):\n", .{summary.tables.len});
                    for (summary.tables) |tbl| {
                        std.debug.print("  {s}  offset={d:<8} length={d}\n", .{ tbl.tag, tbl.offset, tbl.length });
                    }
                }
            }
            if (do_validate) {
                if (validation_opt) |validation| {
                    std.debug.print("\nValidation:\n", .{});
                    for (validation.entries.items) |msg| {
                        const prefix: []const u8 = switch (msg.severity) {
                            .info => "INFO",
                            .warning => "WARN",
                            .@"error" => "ERR ",
                        };
                        if (msg.location.table_tag) |tag| {
                            const trimmed = std.mem.trimEnd(u8, &tag, " ");
                            std.debug.print("  {s}  {s}: {s}\n", .{ prefix, trimmed, msg.message });
                        } else {
                            std.debug.print("  {s}  {s}\n", .{ prefix, msg.message });
                        }
                    }
                    if (validation.entries.items.len == 0) {
                        std.debug.print("  (no issues found)\n", .{});
                    }
                }
            }
            if (do_coverage) {
                if (blocks_opt) |blocks| {
                    std.debug.print("\nUnicode coverage:\n", .{});
                    for (blocks) |blk| {
                        if (blk.covered == 0) continue;
                        const pct = @as(f64, @floatFromInt(blk.covered)) / @as(f64, @floatFromInt(blk.total)) * 100.0;
                        std.debug.print("  {s:<28} {d}/{d}   ({d:.1}%)\n", .{ blk.name, blk.covered, blk.total, pct });
                    }
                }
            }
            if (do_features) {
                if (features_opt) |features| {
                    if (features.len > 0) {
                        std.debug.print("\nOpenType features:\n", .{});
                        for (features) |feat| {
                            std.debug.print("  {s} {s} ({s}/{s})\n", .{ feat.table_tag, feat.feature_tag, feat.script_tag, feat.language_tag });
                        }
                    }
                }
            }
            if (do_glyphs and glyph_infos.items.len > 0) {
                std.debug.print("\nGlyph details:\n", .{});
                for (glyph_infos.items) |info| {
                    if (info.codepoint) |cp| {
                        if (cp >= 0x20 and cp < 0x7F) {
                            std.debug.print("  Glyph {d} (U+{X:0>4} '{c}')\n", .{ info.glyph_id, cp, @as(u8, @intCast(cp)) });
                        } else {
                            std.debug.print("  Glyph {d} (U+{X:0>4})\n", .{ info.glyph_id, cp });
                        }
                    } else {
                        std.debug.print("  Glyph {d}\n", .{info.glyph_id});
                    }
                    std.debug.print("    Advance width: {d}  LSB: {d}\n", .{ info.advance_width, info.lsb });
                    if (info.has_outline) {
                        std.debug.print("    Bounding box: [{d}, {d}, {d}, {d}]\n", .{ info.x_min, info.y_min, info.x_max, info.y_max });
                        std.debug.print("    Contours: {d}  Points: {d}\n", .{ info.contour_count, info.point_count });
                        if (info.is_compound) {
                            std.debug.print("    Type: compound\n", .{});
                        }
                    } else {
                        std.debug.print("    (no outline)\n", .{});
                    }
                }
            }
        },
        .json => {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            try buf.appendSlice(allocator, "{\n");
            var first_section = true;

            if (do_summary) {
                if (summary_opt) |summary| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    const family_raw = summary.family_name orelse "";
                    const subfam_raw = summary.subfamily_name orelse "";
                    const family_esc = try jsonEscapeString(allocator, family_raw);
                    defer allocator.free(family_esc);
                    const subfam_esc = try jsonEscapeString(allocator, subfam_raw);
                    defer allocator.free(subfam_esc);
                    try buf.print(allocator,
                        \\  "summary": {{
                        \\    "family": "{s}",
                        \\    "subfamily": "{s}",
                        \\    "num_glyphs": {d},
                        \\    "units_per_em": {d},
                        \\    "ascender": {d},
                        \\    "descender": {d},
                        \\    "line_gap": {d},
                        \\    "bbox": [{d}, {d}, {d}, {d}]
                        \\  }}
                    , .{ family_esc, subfam_esc, summary.num_glyphs, summary.units_per_em, summary.ascender, summary.descender, summary.line_gap, summary.x_min, summary.y_min, summary.x_max, summary.y_max });
                }
            }

            if (do_tables) {
                if (summary_opt) |summary| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    try buf.appendSlice(allocator, "  \"tables\": [\n");
                    for (summary.tables, 0..) |tbl, i| {
                        const tag_trimmed = std.mem.trimEnd(u8, &tbl.tag, " ");
                        const tag_esc = try jsonEscapeString(allocator, tag_trimmed);
                        defer allocator.free(tag_esc);
                        if (i > 0) try buf.appendSlice(allocator, ",\n");
                        try buf.print(allocator,
                            \\    {{"tag": "{s}", "offset": {d}, "length": {d}, "checksum": {d}}}
                        , .{ tag_esc, tbl.offset, tbl.length, tbl.checksum });
                    }
                    try buf.appendSlice(allocator, "\n  ]");
                }
            }

            if (do_validate) {
                if (validation_opt) |validation| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    const status_str = if (validation.hasErrors()) "error" else "ok";
                    try buf.print(allocator,
                        \\  "validation": {{
                        \\    "status": "{s}",
                        \\    "messages": [
                    , .{status_str});
                    for (validation.entries.items, 0..) |msg, i| {
                        const sev_str: []const u8 = switch (msg.severity) {
                            .info => "info",
                            .warning => "warning",
                            .@"error" => "error",
                        };
                        const message_esc = try jsonEscapeString(allocator, msg.message);
                        defer allocator.free(message_esc);
                        if (i > 0) try buf.appendSlice(allocator, ",");
                        try buf.print(allocator, "\n      {{\"severity\": \"{s}\", \"message\": \"{s}\"", .{ sev_str, message_esc });
                        if (msg.location.table_tag) |tag| {
                            const tag_trimmed = std.mem.trimEnd(u8, &tag, " ");
                            const tag_esc = try jsonEscapeString(allocator, tag_trimmed);
                            defer allocator.free(tag_esc);
                            try buf.print(allocator, ", \"table\": \"{s}\"", .{tag_esc});
                        }
                        if (msg.location.glyph_id) |gid| {
                            try buf.print(allocator, ", \"glyph_id\": {d}", .{gid});
                        }
                        try buf.appendSlice(allocator, "}");
                    }
                    try buf.appendSlice(allocator, "\n    ]\n  }");
                }
            }

            if (do_coverage) {
                if (blocks_opt) |blocks| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    try buf.appendSlice(allocator, "  \"coverage\": [\n");
                    for (blocks, 0..) |blk, i| {
                        const pct = @as(f64, @floatFromInt(blk.covered)) / @as(f64, @floatFromInt(blk.total)) * 100.0;
                        const name_esc = try jsonEscapeString(allocator, blk.name);
                        defer allocator.free(name_esc);
                        if (i > 0) try buf.appendSlice(allocator, ",\n");
                        try buf.print(allocator,
                            \\    {{"name": "{s}", "start": {d}, "end": {d}, "covered": {d}, "total": {d}, "percentage": {d:.1}}}
                        , .{ name_esc, blk.start, blk.end, blk.covered, blk.total, pct });
                    }
                    try buf.appendSlice(allocator, "\n  ]");
                }
            }

            if (do_features) {
                if (features_opt) |features| {
                    if (!first_section) try buf.appendSlice(allocator, ",\n");
                    first_section = false;
                    try buf.appendSlice(allocator, "  \"features\": [\n");
                    for (features, 0..) |feat, i| {
                        const table_trimmed = std.mem.trimEnd(u8, &feat.table_tag, " ");
                        const feature_trimmed = std.mem.trimEnd(u8, &feat.feature_tag, " ");
                        const script_trimmed = std.mem.trimEnd(u8, &feat.script_tag, " ");
                        const language_trimmed = std.mem.trimEnd(u8, &feat.language_tag, " ");
                        const table_esc = try jsonEscapeString(allocator, table_trimmed);
                        defer allocator.free(table_esc);
                        const feature_esc = try jsonEscapeString(allocator, feature_trimmed);
                        defer allocator.free(feature_esc);
                        const script_esc = try jsonEscapeString(allocator, script_trimmed);
                        defer allocator.free(script_esc);
                        const language_esc = try jsonEscapeString(allocator, language_trimmed);
                        defer allocator.free(language_esc);
                        if (i > 0) try buf.appendSlice(allocator, ",\n");
                        try buf.print(allocator,
                            \\    {{"table": "{s}", "feature": "{s}", "script": "{s}", "language": "{s}"}}
                        , .{ table_esc, feature_esc, script_esc, language_esc });
                    }
                    try buf.appendSlice(allocator, "\n  ]");
                }
            }

            if (do_glyphs and glyph_infos.items.len > 0) {
                if (!first_section) try buf.appendSlice(allocator, ",\n");
                first_section = false;
                try buf.appendSlice(allocator, "  \"glyphs\": [\n");
                for (glyph_infos.items, 0..) |info, i| {
                    if (i > 0) try buf.appendSlice(allocator, ",\n");
                    if (info.codepoint) |cp| {
                        try buf.print(allocator,
                            \\    {{"glyph_id": {d}, "codepoint": {d}, "advance_width": {d}, "lsb": {d}, "has_outline": {s}, "is_compound": {s}
                        , .{ info.glyph_id, cp, info.advance_width, info.lsb, if (info.has_outline) "true" else "false", if (info.is_compound) "true" else "false" });
                    } else {
                        try buf.print(allocator,
                            \\    {{"glyph_id": {d}, "codepoint": null, "advance_width": {d}, "lsb": {d}, "has_outline": {s}, "is_compound": {s}
                        , .{ info.glyph_id, info.advance_width, info.lsb, if (info.has_outline) "true" else "false", if (info.is_compound) "true" else "false" });
                    }
                    if (info.has_outline) {
                        try buf.print(allocator, ", \"bbox\": [{d}, {d}, {d}, {d}], \"contours\": {d}, \"points\": {d}}}", .{ info.x_min, info.y_min, info.x_max, info.y_max, info.contour_count, info.point_count });
                    } else {
                        try buf.appendSlice(allocator, "}");
                    }
                }
                try buf.appendSlice(allocator, "\n  ]");
            }

            try buf.appendSlice(allocator, "\n}\n");
            std.debug.print("{s}", .{buf.items});
        },
        .yaml => {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            if (do_summary) {
                if (summary_opt) |summary| {
                    const family_raw = summary.family_name orelse "";
                    const subfam_raw = summary.subfamily_name orelse "";
                    try buf.print(allocator,
                        \\summary:
                        \\  family: "{s}"
                        \\  subfamily: "{s}"
                        \\  num_glyphs: {d}
                        \\  units_per_em: {d}
                        \\  ascender: {d}
                        \\  descender: {d}
                        \\  line_gap: {d}
                        \\  bbox: [{d}, {d}, {d}, {d}]
                        \\
                    , .{ family_raw, subfam_raw, summary.num_glyphs, summary.units_per_em, summary.ascender, summary.descender, summary.line_gap, summary.x_min, summary.y_min, summary.x_max, summary.y_max });
                }
            }

            if (do_tables) {
                if (summary_opt) |summary| {
                    try buf.appendSlice(allocator, "tables:\n");
                    if (summary.tables.len == 0) {
                        try buf.appendSlice(allocator, "  []\n");
                    } else {
                        for (summary.tables) |tbl| {
                            const tag_trimmed = std.mem.trimEnd(u8, &tbl.tag, " ");
                            try buf.print(allocator,
                                \\  - tag: "{s}"
                                \\    offset: {d}
                                \\    length: {d}
                                \\    checksum: {d}
                                \\
                            , .{ tag_trimmed, tbl.offset, tbl.length, tbl.checksum });
                        }
                    }
                }
            }

            if (do_validate) {
                if (validation_opt) |validation| {
                    const status_str = if (validation.hasErrors()) "error" else "ok";
                    try buf.print(allocator, "validation:\n  status: \"{s}\"\n  messages:\n", .{status_str});
                    if (validation.entries.items.len == 0) {
                        try buf.appendSlice(allocator, "    []\n");
                    } else {
                        for (validation.entries.items) |msg| {
                            const sev_str: []const u8 = switch (msg.severity) {
                                .info => "info",
                                .warning => "warning",
                                .@"error" => "error",
                            };
                            try buf.print(allocator,
                                \\    - severity: "{s}"
                                \\      message: "{s}"
                                \\
                            , .{ sev_str, msg.message });
                            if (msg.location.table_tag) |tag| {
                                const tag_trimmed = std.mem.trimEnd(u8, &tag, " ");
                                try buf.print(allocator, "      table: \"{s}\"\n", .{tag_trimmed});
                            }
                            if (msg.location.glyph_id) |gid| {
                                try buf.print(allocator, "      glyph_id: {d}\n", .{gid});
                            }
                        }
                    }
                }
            }

            if (do_coverage) {
                if (blocks_opt) |blocks| {
                    try buf.appendSlice(allocator, "coverage:\n");
                    if (blocks.len == 0) {
                        try buf.appendSlice(allocator, "  []\n");
                    } else {
                        for (blocks) |blk| {
                            const pct = @as(f64, @floatFromInt(blk.covered)) / @as(f64, @floatFromInt(blk.total)) * 100.0;
                            try buf.print(allocator,
                                \\  - name: "{s}"
                                \\    start: {d}
                                \\    end: {d}
                                \\    covered: {d}
                                \\    total: {d}
                                \\    percentage: {d:.1}
                                \\
                            , .{ blk.name, blk.start, blk.end, blk.covered, blk.total, pct });
                        }
                    }
                }
            }

            if (do_features) {
                if (features_opt) |features| {
                    try buf.appendSlice(allocator, "features:\n");
                    if (features.len == 0) {
                        try buf.appendSlice(allocator, "  []\n");
                    } else {
                        for (features) |feat| {
                            const table_trimmed = std.mem.trimEnd(u8, &feat.table_tag, " ");
                            const feature_trimmed = std.mem.trimEnd(u8, &feat.feature_tag, " ");
                            const script_trimmed = std.mem.trimEnd(u8, &feat.script_tag, " ");
                            const language_trimmed = std.mem.trimEnd(u8, &feat.language_tag, " ");
                            try buf.print(allocator,
                                \\  - table: "{s}"
                                \\    feature: "{s}"
                                \\    script: "{s}"
                                \\    language: "{s}"
                                \\
                            , .{ table_trimmed, feature_trimmed, script_trimmed, language_trimmed });
                        }
                    }
                }
            }

            if (do_glyphs and glyph_infos.items.len > 0) {
                try buf.appendSlice(allocator, "glyphs:\n");
                for (glyph_infos.items) |info| {
                    try buf.print(allocator, "  - glyph_id: {d}\n", .{info.glyph_id});
                    if (info.codepoint) |cp| {
                        try buf.print(allocator, "    codepoint: {d}\n", .{cp});
                    } else {
                        try buf.appendSlice(allocator, "    codepoint: null\n");
                    }
                    try buf.print(allocator,
                        \\    advance_width: {d}
                        \\    lsb: {d}
                        \\    has_outline: {s}
                        \\    is_compound: {s}
                        \\
                    , .{ info.advance_width, info.lsb, if (info.has_outline) "true" else "false", if (info.is_compound) "true" else "false" });
                    if (info.has_outline) {
                        try buf.print(allocator,
                            \\    bbox: [{d}, {d}, {d}, {d}]
                            \\    contours: {d}
                            \\    points: {d}
                            \\
                        , .{ info.x_min, info.y_min, info.x_max, info.y_max, info.contour_count, info.point_count });
                    }
                }
            }

            std.debug.print("{s}", .{buf.items});
        },
    }
}

// --- cappan svg ---

fn cmdSvg(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var common: CommonOptions = .{};
    defer common.paint_ops.deinit(allocator);
    var output_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (parseCommonOption(allocator, &common, arg, args)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        }
    }

    warnVariationUnsupported(common, "svg");

    if ((common.font_path == null and common.font_name == null) or common.text == null or output_path == null) {
        std.debug.print("Error: --font or --font-name, --text, and --output are required for svg\n", .{});
        printUsage();
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    const pixel_size = common.size;
    const paths = cappan_pathify.textToSvgPaths(allocator, font, common.text.?, pixel_size) catch |err| {
        std.debug.print("Error: could not convert text to SVG paths: {}\n", .{err});
        return;
    };
    defer {
        for (paths) |*p| {
            @constCast(p).deinit();
        }
        allocator.free(paths);
    }

    if (paths.len == 0) {
        std.debug.print("Error: no glyphs found for the given text\n", .{});
        return;
    }

    // Calculate dimensions
    const units_per_em = @as(f32, @floatFromInt(font.getUnitsPerEm()));
    const scale = pixel_size / units_per_em;
    const ascender_px = @as(f32, @floatFromInt(font.hhea.ascender)) * scale;
    const descender_px = @abs(@as(f32, @floatFromInt(font.hhea.descender)) * scale);
    const total_height = ascender_px + descender_px;

    const last = paths[paths.len - 1];
    const total_width = last.x_offset + last.advance_width;

    // Build SVG
    var svg_buf: std.ArrayList(u8) = .empty;
    defer svg_buf.deinit(allocator);

    try svg_buf.print(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d:.2}" height="{d:.2}" viewBox="0 0 {d:.2} {d:.2}">
        \\  <g transform="translate(0, {d:.2})">
        \\
    , .{ total_width, total_height, total_width, total_height, ascender_px });

    for (paths) |gp| {
        if (gp.path_data.len > 0) {
            try svg_buf.print(allocator,
                \\    <path d="{s}" transform="translate({d:.2}, 0)" fill="black"/>
                \\
            , .{ gp.path_data, gp.x_offset });
        }
    }

    try svg_buf.print(allocator,
        \\  </g>
        \\</svg>
        \\
    , .{});

    // Write to output file
    const cwd = std.Io.Dir.cwd();
    const out_file = cwd.createFile(io, output_path.?, .{}) catch |err| {
        std.debug.print("Error: could not create output file '{s}': {}\n", .{ output_path.?, err });
        return;
    };
    defer out_file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = out_file.writer(io, &buf);
    writer.interface.writeAll(svg_buf.items) catch |err| {
        std.debug.print("Error: could not write SVG: {}\n", .{err});
        return;
    };
    writer.interface.flush() catch |err| {
        std.debug.print("Error: could not flush SVG output: {}\n", .{err});
        return;
    };

    std.debug.print("SVG written to {s} ({d} glyphs, {d:.0}x{d:.0}px)\n", .{ output_path.?, paths.len, total_width, total_height });
}

// --- cappan metrics ---

fn cmdMetrics(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var common: CommonOptions = .{};
    defer common.paint_ops.deinit(allocator);
    var compare_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (parseCommonOption(allocator, &common, arg, args)) {
            continue;
        } else if (std.mem.eql(u8, arg, "--compare")) {
            compare_path = args.next();
        }
    }

    warnVariationUnsupported(common, "metrics");

    if (common.font_path == null and common.font_name == null) {
        std.debug.print("Error: --font or --font-name is required\n", .{});
        printUsage();
        return;
    }

    const resolved_font = resolveFontPath(allocator, io, common) orelse return;
    defer if (resolved_font.owned_path) |path| allocator.free(path);
    const loaded = loadFont(allocator, io, resolved_font.path, resolved_font.font_index) orelse return;
    defer allocator.free(loaded.data);
    var font = loaded.font;
    defer font.deinit();

    const css_metrics = cappan_metrics.getCssFontMetrics(font);
    const source_name: []const u8 = switch (css_metrics.source) {
        .os2_typo => "os2_typo",
        .os2_win => "os2_win",
        .hhea => "hhea",
    };

    std.debug.print("CSS @font-face metrics (source: {s}):\n", .{source_name});
    std.debug.print("  ascent-override:   {d:.1}%\n", .{css_metrics.ascent_override});
    std.debug.print("  descent-override:  {d:.1}%\n", .{css_metrics.descent_override});
    std.debug.print("  line-gap-override: {d:.1}%\n", .{css_metrics.line_gap_override});

    if (compare_path) |cmp_path| {
        const loaded_b = loadFont(allocator, io, cmp_path, null) orelse return;
        defer allocator.free(loaded_b.data);
        var font_b = loaded_b.font;
        defer font_b.deinit();

        const cmp = cappan_metrics.compareFonts(allocator, font, font_b);

        // Get font names for display
        var summary_a = cappan_inspect.getSummary(allocator, font) catch null;
        defer if (summary_a) |*s| s.deinit();
        var summary_b = cappan_inspect.getSummary(allocator, font_b) catch null;
        defer if (summary_b) |*s| s.deinit();

        const name_a = if (summary_a) |s| (s.family_name orelse "FontA") else "FontA";
        const name_b = if (summary_b) |s| (s.family_name orelse "FontB") else "FontB";

        std.debug.print("\nFont comparison ({s} vs {s}):\n", .{ name_a, name_b });
        std.debug.print("  x-height ratio:    {d:.2}\n", .{cmp.x_height_ratio});
        std.debug.print("  avg width ratio:   {d:.2}\n", .{cmp.avg_width_ratio});
        std.debug.print("  size-adjust:       {d:.1}%\n", .{cmp.size_adjust});
    }
}

// --- shared ---

const ResolvedFont = struct {
    path: []const u8,
    font_index: ?u32,
    owned_path: ?[]u8 = null,
};

fn resolveFontPath(allocator: std.mem.Allocator, io: std.Io, common: CommonOptions) ?ResolvedFont {
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

fn parseHexColor(hex: []const u8) ?Color {
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn parseStrokeWidth(width: []const u8) ?paint_mod.StrokeWidth {
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

fn parseStrokeOptions(options_str: []const u8, stroke: *paint_mod.StrokePaint) bool {
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

fn parseFillOptions(options_str: []const u8, fill: *paint_mod.FillPaint) bool {
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
fn getFileExtension(path: []const u8) []const u8 {
    return std.fs.path.extension(path);
}

test {
    _ = @import("image/png.zig");
    _ = @import("image/apng.zig");
    _ = @import("image/bmp.zig");
    _ = @import("image/ppm.zig");
}

test "PNG output structure" {
    const Bitmap = cappan_core.render.bitmap.Bitmap;
    var bmp = try Bitmap.init(std.testing.allocator, 4, 4);
    defer bmp.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try png_mod.writePng(std.testing.allocator, bmp, &output.writer);

    const written = output.writer.buffered();

    // PNG signature
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, written[0..8]);

    // IHDR chunk type at offset 12
    try std.testing.expectEqualSlices(u8, "IHDR", written[12..16]);

    // IHDR width (offset 16..20) = 4
    const width = std.mem.readInt(u32, written[16..20], .big);
    try std.testing.expectEqual(@as(u32, 4), width);

    // IHDR height (offset 20..24) = 4
    const height = std.mem.readInt(u32, written[20..24], .big);
    try std.testing.expectEqual(@as(u32, 4), height);

    // Last 12 bytes: IEND chunk
    const tail = written[written.len - 12 ..];
    // length = 0
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, tail[0..4], .big));
    // type = "IEND"
    try std.testing.expectEqualSlices(u8, "IEND", tail[4..8]);
    // CRC32 of "IEND" = 0xAE426082
    try std.testing.expectEqual(@as(u32, 0xAE426082), std.mem.readInt(u32, tail[8..12], .big));
}

fn printUsage() void {
    std.debug.print(
        \\cappan: font rendering engine
        \\
        \\Subcommands:
        \\  render     Render text to a single PNG image
        \\  animate    Render text as incremental animation (APNG or frame sequence)
        \\  fonts      List system fonts
        \\  subset     Subset a font to include only glyphs for given text
        \\  inspect    Inspect font metadata, validate tables, show coverage
        \\  svg        Convert text to SVG file with vector paths
        \\  metrics    Show CSS font metrics and compare fonts
        \\  atlas      Generate an SDF/MSDF glyph atlas (PNG pages + metrics JSON)
        \\
        \\cappan render --font <path> --text <string> --output <path.png> [options]
        \\cappan animate --font <path> --text <string> --output <path.apng> [options]
        \\cappan animate --font <path> --text <string> --output-dir <dir> [options]
        \\cappan fonts
        \\cappan subset --font <path> --text <string> --output <path.ttf>
        \\cappan inspect --font <path> [--summary] [--tables] [--validate] [--coverage] [--features] [--format text|json|yaml]
        \\cappan svg --font <path> --text <string> --output <path.svg> [--size <n>]
        \\cappan metrics --font <path> [--compare <path>]
        \\cappan atlas --font <path> --text <string> --output <atlas.png> --metrics <atlas.json> [options]
        \\
        \\Common options:
        \\  --font               Path to a TrueType/OpenType font file
        \\  --font-name          System font family or full name
        \\  --text               Text to render
        \\  --size               Font size in pixels (default: 48)
        \\  --variation          Variable font axes applied to COLR v1 paints, e.g. "wght=700" (glyph outlines are not affected)
        \\  --fg-color           Foreground color in RRGGBB hex (default: 000000)
        \\  --bg-color           Background color in RRGGBB hex (default: FFFFFF)
        \\  --fallback-font      Fallback font file path (can be specified multiple times)
        \\  --font-index         Font index within a TTC file (default: 0 = first)
        \\  --gamma              Enable gamma correction (blend in sRGB linear space)
        \\  --fractional         Enable fractional pixel positioning (sub-pixel glyph placement)
        \\  --max-width          Maximum text width in pixels; lines wrap automatically if exceeded
        \\  --text-align         Text alignment: left (default), center, right, justify
        \\  --lcd                Enable LCD sub-pixel rendering (render only)
        \\  --vertical           Use vertical-rl layout (render only)
        \\  --stem-darkening     Enable stem darkening for small text
        \\  --cff-hinting        Enable CFF hinting
        \\  --auto-hinting       Enable auto-hinting for unhinted fonts
        \\  --aa-level           Anti-aliasing level: 4, 8 (default), 16, 32
        \\  --sample-pattern     Sample pattern: regular (default), rotated-grid
        \\  --adaptive           Enable adaptive supersampling (4x + 32x refine)
        \\  --raster-method      Rasterizer: supersampling (default), analytical
        \\  --stroke             Add stroke: WIDTH,RRGGBB[,position=outside|center|inside]
        \\                                   [,join=round|miter|bevel][,opacity=0-1][,miter-limit=N]
        \\                                   [,time-weight=N]
        \\  --fill               Add fill: RRGGBB[,opacity=0-1][,time-weight=N] (render only)
        \\
        \\render options:
        \\  --output             Output PNG file path
        \\  --sdf                Render as a single-channel signed distance field (grayscale PNG)
        \\  --msdf               Render as a multi-channel SDF (MTSDF: RGB=MSDF, A=true SDF; RGBA PNG)
        \\  --sdf-spread         SDF distance range in pixels (default: 8, requires --sdf or --msdf)
        \\
        \\animate options (APNG mode — default):
        \\  --output             Output APNG file path
        \\  --fps                Frames per second (default: 10)
        \\
        \\animate options (frame sequence mode):
        \\  --output-dir         Output directory for individual frame PNGs
        \\
        \\animate common options:
        \\  --frames             Number of frames (default: 10)
        \\  --strategy           Reveal strategy: sweep (default), fade, contour-trace, medial-axis, distance-field, extrema-wave, skeleton-grow, tangent-flow
        \\  --sweep-direction    left-to-right (default), right-to-left, top-to-bottom, bottom-to-top
        \\  --timing             sequential (default), simultaneous, weighted, overlap:<value>
        \\  --contour-ordering   font-order (default), stroke-heuristic, area-priority, writing-order
        \\  --hold               Number of frames to hold completed state at end (default: 0)
        \\  --easing             Easing: linear (default), ease-in, ease-out, ease-in-out, ease-in-cubic, ease-out-cubic, ease-in-out-cubic
        \\  --reverse            Play animation in reverse (progress 1.0 to 0.0)
        \\  --extrema-invert     Invert extrema-wave reveal (near extrema first)
        \\  --paint-layer-timing Paint layer timing: simultaneous (default), sequential
        \\
        \\inspect options:
        \\  --summary            Show font summary
        \\  --tables             Show font tables
        \\  --validate           Validate font tables
        \\  --coverage           Show Unicode block coverage
        \\  --features           Show OpenType features
        \\  --format             Output format: text (default), json, yaml
        \\
        \\atlas options:
        \\  --font               Path to a TrueType/OpenType font file (required)
        \\  --text               Text whose codepoints populate the atlas (required)
        \\  --size               Glyph generation size in pixels (default: 64)
        \\  --msdf               Generate a multi-channel SDF atlas (MTSDF RGBA pages, JSON type "mtsdf")
        \\  --sdf-spread         SDF distance range in pixels (default: 8)
        \\  --page-size          Atlas page width/height in pixels (default: 1024)
        \\  --output             Output PNG path for page 0 (required); page N>0 is written to <stem>_<N>.png
        \\  --metrics            Output metrics JSON path (required)
        \\
    , .{});
}
