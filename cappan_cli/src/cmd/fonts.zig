const std = @import("std");
const discover = @import("cappan_discover");

pub const usage_text = "";

pub fn cmdListFonts(allocator: std.mem.Allocator, io: std.Io) !void {
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
