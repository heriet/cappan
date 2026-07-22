const std = @import("std");
const cappan_metrics = @import("cappan_metrics");
const cappan_inspect = @import("cappan_inspect");
const cli_common = @import("../cli_common.zig");
const main = @import("../main.zig");
const CommonOptions = cli_common.CommonOptions;
const parseCommonOption = cli_common.parseCommonOption;
const warnVariationUnsupported = cli_common.warnVariationUnsupported;
const resolveFontPath = cli_common.resolveFontPath;
const loadFont = cli_common.loadFont;
const printUsage = main.printUsage;

pub const usage_text = "";

pub fn cmdMetrics(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
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
