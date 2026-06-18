const std = @import("std");

pub fn writePpm(width: u32, height: u32, row_renderer: anytype, writer: anytype) !void {
    // PPM header
    try writer.print("P6\n{d} {d}\n255\n", .{ width, height });

    // Pixel data (top-to-bottom, RGB)
    for (0..height) |y| {
        const row_data = row_renderer.renderRow(@intCast(y));
        // RGBA -> RGB
        for (0..width) |x| {
            const px = x * 4;
            try writer.writeAll(&[_]u8{ row_data[px], row_data[px + 1], row_data[px + 2] });
        }
    }
}
