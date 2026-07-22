const std = @import("std");
const cappan_pathify = @import("cappan_pathify");
const cli_common = @import("../cli_common.zig");
const main = @import("../main.zig");
const CommonOptions = cli_common.CommonOptions;
const parseCommonOption = cli_common.parseCommonOption;
const warnVariationUnsupported = cli_common.warnVariationUnsupported;
const resolveFontPath = cli_common.resolveFontPath;
const loadFont = cli_common.loadFont;
const printUsage = main.printUsage;

pub const usage_text = "";

pub fn cmdSvg(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
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
