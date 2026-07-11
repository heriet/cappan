const std = @import("std");
const cappan_core = @import("cappan_core");
const Bitmap = cappan_core.render.bitmap.Bitmap;
const RgbaBitmap = cappan_core.render.rgba_bitmap.RgbaBitmap;

fn writePngInternal(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u8, bytes_per_pixel: u8, color_type: u8, writer: anytype) !void {
    // PNG signature
    try writer.writeAll(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

    // IHDR chunk
    {
        var ihdr_data: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr_data[0..4], width, .big);
        std.mem.writeInt(u32, ihdr_data[4..8], height, .big);
        ihdr_data[8] = 8; // bit depth
        ihdr_data[9] = color_type;
        ihdr_data[10] = 0; // compression method
        ihdr_data[11] = 0; // filter method
        ihdr_data[12] = 0; // interlace method
        try writeChunk(writer, "IHDR", &ihdr_data);
    }

    // IDAT chunk
    {
        // Build raw image data (filter byte + row data for each row)
        const bpp = @as(usize, bytes_per_pixel);
        const row_size = @as(usize, width) * bpp + 1; // +1 for filter byte
        const raw_size = row_size * @as(usize, height);
        const raw_data = try allocator.alloc(u8, raw_size);
        defer allocator.free(raw_data);

        for (0..height) |y| {
            const row_offset = y * row_size;
            raw_data[row_offset] = 0; // filter type = None
            const src_offset = y * @as(usize, width) * bpp;
            const src_end = src_offset + @as(usize, width) * bpp;
            @memcpy(raw_data[row_offset + 1 .. row_offset + row_size], pixels[src_offset..src_end]);
        }

        // Compress with zlib format
        const compressed = try zlibCompress(allocator, raw_data);
        defer allocator.free(compressed);

        try writeChunk(writer, "IDAT", compressed);
    }

    // IEND chunk
    try writeChunk(writer, "IEND", &[_]u8{});
}

pub fn writePng(allocator: std.mem.Allocator, bitmap: Bitmap, writer: anytype) !void {
    try writePngInternal(allocator, bitmap.width, bitmap.height, bitmap.pixels, 1, 0, writer);
}

pub fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Allocating writer needs an initial capacity of at least 9 bytes (8 for Compress assert + header)
    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, std.compress.flate.max_window_len);
    errdefer output.deinit();

    // Compress.init needs an intermediate buffer of at least max_window_len bytes
    const buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(buf);

    // Use full LZ77 compressor with zlib container (header + adler32 footer)
    var comp = try std.compress.flate.Compress.init(&output.writer, buf, .zlib, .default);
    try comp.writer.writeAll(data);
    try comp.finish();

    return output.toOwnedSlice();
}

pub fn writeChunk(writer: anytype, chunk_type: *const [4]u8, data: []const u8) !void {
    // Length
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    try writer.writeAll(&len_bytes);

    // Type
    try writer.writeAll(chunk_type);

    // Data
    if (data.len > 0) {
        try writer.writeAll(data);
    }

    // CRC32 (over type + data)
    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    if (data.len > 0) {
        crc.update(data);
    }
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try writer.writeAll(&crc_bytes);
}

pub fn writePngRgba(allocator: std.mem.Allocator, bitmap: RgbaBitmap, writer: anytype) !void {
    try writePngInternal(allocator, bitmap.width, bitmap.height, bitmap.pixels, 4, 6, writer);
}

pub fn writePngRgbaStreaming(allocator: std.mem.Allocator, width: u32, height: u32, row_renderer: anytype, writer: anytype) !void {
    // PNG signature
    try writer.writeAll(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

    // IHDR chunk
    {
        var ihdr_data: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr_data[0..4], width, .big);
        std.mem.writeInt(u32, ihdr_data[4..8], height, .big);
        ihdr_data[8] = 8; // bit depth
        ihdr_data[9] = 6; // color type (RGBA)
        ihdr_data[10] = 0; // compression method
        ihdr_data[11] = 0; // filter method
        ihdr_data[12] = 0; // interlace method
        try writeChunk(writer, "IHDR", &ihdr_data);
    }

    // IDAT chunk: streaming row-by-row compression
    {
        var output: std.Io.Writer.Allocating = try .initCapacity(allocator, std.compress.flate.max_window_len);
        errdefer output.deinit();

        const buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(buf);

        var comp = try std.compress.flate.Compress.init(&output.writer, buf, .zlib, .default);

        const filter_byte = [_]u8{0};
        for (0..height) |y| {
            try comp.writer.writeAll(&filter_byte);
            const row_data = row_renderer.renderRow(@intCast(y));
            try comp.writer.writeAll(row_data);
        }
        try comp.finish();

        const compressed = try output.toOwnedSlice();
        defer allocator.free(compressed);

        try writeChunk(writer, "IDAT", compressed);
    }

    // IEND chunk
    try writeChunk(writer, "IEND", &[_]u8{});
}

test "write RGBA PNG and verify signature and color_type" {
    const RgbaBitmapType = cappan_core.render.rgba_bitmap.RgbaBitmap;
    const Color = cappan_core.render.rgba_bitmap.Color;
    var bmp = try RgbaBitmapType.init(std.testing.allocator, 4, 4, Color.white);
    defer bmp.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writePngRgba(std.testing.allocator, bmp, &output.writer);

    const written = output.writer.buffered();

    // PNG signature
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, written[0..8]);

    // IHDR chunk type at offset 12
    try std.testing.expectEqualSlices(u8, "IHDR", written[12..16]);

    // IHDR color_type at offset 25:
    // PNG signature(8) + chunk_length(4) + "IHDR"(4) + width(4) + height(4) + bit_depth(1) = 25
    try std.testing.expectEqual(@as(u8, 6), written[25]);
}

test "write PNG and verify signature" {
    var bmp = try Bitmap.init(std.testing.allocator, 16, 16);
    defer bmp.deinit();

    // Draw a simple pattern
    for (0..16) |y| {
        for (0..16) |x| {
            bmp.setPixel(@intCast(x), @intCast(y), @intCast(x * 16));
        }
    }

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writePng(std.testing.allocator, bmp, &output.writer);

    const written = output.writer.buffered();
    // Verify PNG signature
    try std.testing.expect(written.len > 8);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, written[0..8]);

    // Verify IHDR chunk type at offset 12
    try std.testing.expectEqualSlices(u8, "IHDR", written[12..16]);
}
