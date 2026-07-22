const std = @import("std");
const cappan_subset = @import("cappan_subset");
const cli_common = @import("../cli_common.zig");
const main = @import("../main.zig");
const CommonOptions = cli_common.CommonOptions;
const parseCommonOption = cli_common.parseCommonOption;
const warnVariationUnsupported = cli_common.warnVariationUnsupported;
const resolveFontPath = cli_common.resolveFontPath;
const loadFont = cli_common.loadFont;
const collectUniqueCodepoints = cli_common.collectUniqueCodepoints;
const printUsage = main.printUsage;

pub const usage_text = "";

pub fn cmdSubset(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
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
