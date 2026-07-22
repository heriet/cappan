const std = @import("std");
const cappan_core = @import("cappan_core");
const cli_common = @import("../cli_common.zig");
const main = @import("../main.zig");
const ft = cappan_core.features.features;
const CommonOptions = cli_common.CommonOptions;
const parseCommonOption = cli_common.parseCommonOption;
const resolveFontPath = cli_common.resolveFontPath;
const loadFont = cli_common.loadFont;
const loadFontSet = cli_common.loadFontSet;
const buildVariationCoords = cli_common.buildVariationCoords;
const getFileExtension = cli_common.getFileExtension;
const writePngFile = cli_common.writePngFile;
const writeImageByExtension = cli_common.writeImageByExtension;
const BitmapRowAdapter = cli_common.BitmapRowAdapter;
const printUsage = main.printUsage;

pub const usage_text =
    \\render options:
    \\  --output             Output PNG file path
    \\  --sdf                Render as a single-channel signed distance field (grayscale PNG)
    \\  --msdf               Render as a multi-channel SDF (MTSDF: RGB=MSDF, A=true SDF; RGBA PNG)
    \\  --sdf-spread         SDF distance range in pixels (default: 8, requires --sdf or --msdf)
    \\
++ "\n";

pub fn cmdRender(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
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
