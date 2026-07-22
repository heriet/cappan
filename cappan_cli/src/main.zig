const std = @import("std");
const cappan_core = @import("cappan_core");
const ft = cappan_core.features.features;
const png_mod = @import("image/png.zig");

const render_cmd = @import("cmd/render.zig");
const animate_cmd = @import("cmd/animate.zig");
const fonts_cmd = @import("cmd/fonts.zig");
const subset_cmd = @import("cmd/subset.zig");
const inspect_cmd = @import("cmd/inspect.zig");
const svg_cmd = @import("cmd/svg.zig");
const metrics_cmd = @import("cmd/metrics.zig");
const atlas_cmd = @import("cmd/atlas.zig");

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

    if (std.mem.eql(u8, subcmd, "version") or
        std.mem.eql(u8, subcmd, "--version") or
        std.mem.eql(u8, subcmd, "-V"))
    {
        std.debug.print("cappan {s}\n", .{cappan_core.version});
        return;
    } else if (std.mem.eql(u8, subcmd, "render")) {
        try render_cmd.cmdRender(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "animate")) {
        if (comptime !ft.enable_incremental) {
            std.debug.print("Error: incremental rendering is disabled at compile time\n", .{});
            return;
        }
        try animate_cmd.cmdRenderIncremental(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "fonts")) {
        try fonts_cmd.cmdListFonts(allocator, io);
    } else if (std.mem.eql(u8, subcmd, "subset")) {
        try subset_cmd.cmdSubset(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "inspect")) {
        try inspect_cmd.cmdInspect(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "svg")) {
        try svg_cmd.cmdSvg(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "metrics")) {
        try metrics_cmd.cmdMetrics(allocator, io, &args);
    } else if (std.mem.eql(u8, subcmd, "atlas")) {
        try atlas_cmd.cmdAtlas(allocator, io, &args);
    } else {
        printUsage();
    }
}

const usage_header =
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
    \\  version    Print the cappan version
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
    \\  --aa-level           Anti-aliasing level: 4, 8 (default), 16, 32 (supersampling only)
    \\  --sample-pattern     Sample pattern: regular (default), rotated-grid (supersampling only)
    \\  --adaptive           Enable adaptive supersampling (4x + 32x refine; supersampling only)
    \\  --raster-method      Rasterizer: analytical (default), supersampling
    \\  --stroke             Add stroke: WIDTH,RRGGBB[,position=outside|center|inside]
    \\                                   [,join=round|miter|bevel][,opacity=0-1][,miter-limit=N]
    \\                                   [,time-weight=N]
    \\  --fill               Add fill: RRGGBB[,opacity=0-1][,time-weight=N] (render only)
    \\
++ "\n";

pub fn printUsage() void {
    std.debug.print(usage_header ++ render_cmd.usage_text ++ animate_cmd.usage_text ++ fonts_cmd.usage_text ++ subset_cmd.usage_text ++ inspect_cmd.usage_text ++ svg_cmd.usage_text ++ metrics_cmd.usage_text ++ atlas_cmd.usage_text, .{});
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
