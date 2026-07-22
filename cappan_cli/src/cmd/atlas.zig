const std = @import("std");
const cappan_core = @import("cappan_core");
const cli_common = @import("../cli_common.zig");
const main = @import("../main.zig");
const ft = cappan_core.features.features;
const CommonOptions = cli_common.CommonOptions;
const parseCommonOption = cli_common.parseCommonOption;
const resolveFontPath = cli_common.resolveFontPath;
const loadFont = cli_common.loadFont;
const buildVariationCoords = cli_common.buildVariationCoords;
const collectUniqueCodepoints = cli_common.collectUniqueCodepoints;
const getFileExtension = cli_common.getFileExtension;
const writePngFile = cli_common.writePngFile;
const printUsage = main.printUsage;

pub const usage_text =
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
;

pub fn buildAtlasPagePath(allocator: std.mem.Allocator, output_path: []const u8, page_index: u16) ![]u8 {
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

pub fn cmdAtlas(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
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
