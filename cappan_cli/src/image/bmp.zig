const std = @import("std");

pub fn writeBmp(allocator: std.mem.Allocator, width: u32, height: u32, row_renderer: anytype, writer: anytype) !void {
    const row_stride = ((width * 3 + 3) / 4) * 4; // 4-byte aligned
    const pixel_data_size = row_stride * height;
    const file_size: u32 = 14 + 40 + pixel_data_size;

    // File header (14 bytes)
    try writer.writeAll("BM");
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, file_size)));
    try writer.writeAll(&[_]u8{ 0, 0, 0, 0 }); // reserved
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @as(u32, 54)))); // pixel data offset

    // DIB header - BITMAPINFOHEADER (40 bytes)
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @as(u32, 40)))); // header size
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, @as(i32, @intCast(width))))); // width
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, @as(i32, @intCast(height))))); // height
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u16, @as(u16, 1)))); // planes
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u16, @as(u16, 24)))); // bpp
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @as(u32, 0)))); // compression (none)
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, pixel_data_size))); // image size
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, @as(i32, 2835)))); // x pixels/meter (72 DPI)
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, @as(i32, 2835)))); // y pixels/meter
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @as(u32, 0)))); // colors used
    try writer.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @as(u32, 0)))); // important colors

    // Pixel data (bottom-to-top): render all rows first, then write in reverse order.
    const all_rows = try allocator.alloc(u8, @as(usize, height) * @as(usize, width) * 4);
    defer allocator.free(all_rows);

    for (0..height) |y| {
        const row_data = row_renderer.renderRow(@intCast(y));
        const dest_offset = y * @as(usize, width) * 4;
        @memcpy(all_rows[dest_offset .. dest_offset + @as(usize, width) * 4], row_data);
    }

    const padding_size = row_stride - width * 3;
    const padding = [_]u8{ 0, 0, 0 };

    var y: usize = height;
    while (y > 0) {
        y -= 1;
        const src_offset = y * @as(usize, width) * 4;
        // RGBA -> BGR
        for (0..width) |x| {
            const px = src_offset + x * 4;
            try writer.writeAll(&[_]u8{ all_rows[px + 2], all_rows[px + 1], all_rows[px + 0] });
        }
        if (padding_size > 0) {
            try writer.writeAll(padding[0..padding_size]);
        }
    }
}
