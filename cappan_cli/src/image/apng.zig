const std = @import("std");
const cappan_core = @import("cappan_core");
const RgbaBitmap = cappan_core.render.rgba_bitmap.RgbaBitmap;
const png = @import("png.zig");

/// Build raw image data (filter byte + RGBA row data) for a single frame.
fn buildRawFrameData(allocator: std.mem.Allocator, bitmap: RgbaBitmap) ![]u8 {
    const row_size = @as(usize, bitmap.width) * 4 + 1; // +1 for filter byte
    const raw_size = row_size * @as(usize, bitmap.height);
    const raw_data = try allocator.alloc(u8, raw_size);
    errdefer allocator.free(raw_data);

    for (0..bitmap.height) |y| {
        const row_offset = y * row_size;
        raw_data[row_offset] = 0; // filter type = None
        const src_offset = y * @as(usize, bitmap.width) * 4;
        const src_end = src_offset + @as(usize, bitmap.width) * 4;
        @memcpy(raw_data[row_offset + 1 .. row_offset + row_size], bitmap.pixels[src_offset..src_end]);
    }

    return raw_data;
}

/// Write an animated PNG (APNG) file.
/// All frames must have the same dimensions.
/// delay_num/delay_den controls frame delay (e.g. 1/10 = 100ms per frame = 10fps).
pub fn writeApngRgba(
    allocator: std.mem.Allocator,
    frames: []const RgbaBitmap,
    delay_num: u16,
    delay_den: u16,
    writer: anytype,
) !void {
    if (frames.len == 0) return error.NoFrames;

    const width = frames[0].width;
    const height = frames[0].height;
    const num_frames: u32 = @intCast(frames.len);

    // PNG signature
    try writer.writeAll(&[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

    // IHDR chunk (RGBA, 8-bit)
    {
        var ihdr_data: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr_data[0..4], width, .big);
        std.mem.writeInt(u32, ihdr_data[4..8], height, .big);
        ihdr_data[8] = 8; // bit depth
        ihdr_data[9] = 6; // color type (RGBA)
        ihdr_data[10] = 0; // compression method
        ihdr_data[11] = 0; // filter method
        ihdr_data[12] = 0; // interlace method
        try png.writeChunk(writer, "IHDR", &ihdr_data);
    }

    // acTL chunk (Animation Control)
    {
        var actl_data: [8]u8 = undefined;
        std.mem.writeInt(u32, actl_data[0..4], num_frames, .big);
        std.mem.writeInt(u32, actl_data[4..8], 0, .big); // num_plays = 0 (infinite loop)
        try png.writeChunk(writer, "acTL", &actl_data);
    }

    // Global sequence counter for fcTL and fdAT chunks
    var seq: u32 = 0;

    for (frames, 0..) |frame, i| {
        // fcTL chunk (Frame Control)
        {
            var fctl_data: [26]u8 = undefined;
            std.mem.writeInt(u32, fctl_data[0..4], seq, .big); // sequence_number
            seq += 1;
            std.mem.writeInt(u32, fctl_data[4..8], frame.width, .big); // width
            std.mem.writeInt(u32, fctl_data[8..12], frame.height, .big); // height
            std.mem.writeInt(u32, fctl_data[12..16], 0, .big); // x_offset
            std.mem.writeInt(u32, fctl_data[16..20], 0, .big); // y_offset
            std.mem.writeInt(u16, fctl_data[20..22], delay_num, .big); // delay_num
            std.mem.writeInt(u16, fctl_data[22..24], delay_den, .big); // delay_den
            fctl_data[24] = 0; // dispose_op = APNG_DISPOSE_OP_NONE
            fctl_data[25] = 0; // blend_op = APNG_BLEND_OP_SOURCE
            try png.writeChunk(writer, "fcTL", &fctl_data);
        }

        // Build and compress frame image data
        const raw_data = try buildRawFrameData(allocator, frame);
        defer allocator.free(raw_data);

        const compressed = try png.zlibCompress(allocator, raw_data);
        defer allocator.free(compressed);

        if (i == 0) {
            // First frame uses regular IDAT chunk (backward compatible)
            try png.writeChunk(writer, "IDAT", compressed);
        } else {
            // Subsequent frames use fdAT chunk with sequence_number prefix
            const fdat_data = try allocator.alloc(u8, 4 + compressed.len);
            defer allocator.free(fdat_data);

            std.mem.writeInt(u32, fdat_data[0..4], seq, .big); // sequence_number
            seq += 1;
            @memcpy(fdat_data[4..], compressed);

            try png.writeChunk(writer, "fdAT", fdat_data);
        }
    }

    // IEND chunk
    try png.writeChunk(writer, "IEND", &[_]u8{});
}

/// Helper: find the byte offset of a chunk with the given type tag in PNG binary data.
/// Returns the offset of the 4-byte length field before the type tag, or null if not found.
fn findChunkOffset(data: []const u8, chunk_type: *const [4]u8) ?usize {
    var i: usize = 8; // skip PNG signature
    while (i + 8 <= data.len) {
        const chunk_len = std.mem.readInt(u32, data[i..][0..4], .big);
        const type_offset = i + 4;
        if (type_offset + 4 <= data.len and std.mem.eql(u8, data[type_offset..][0..4], chunk_type)) {
            return i;
        }
        // Move to next chunk: length(4) + type(4) + data(chunk_len) + crc(4)
        i += 4 + 4 + @as(usize, chunk_len) + 4;
    }
    return null;
}

/// Helper: collect all chunk type tags in order from PNG binary data.
fn collectChunkTypes(allocator: std.mem.Allocator, data: []const u8) ![]const [4]u8 {
    var types: std.ArrayList([4]u8) = .empty;
    errdefer types.deinit(allocator);

    var i: usize = 8; // skip PNG signature
    while (i + 8 <= data.len) {
        const chunk_len = std.mem.readInt(u32, data[i..][0..4], .big);
        const type_offset = i + 4;
        if (type_offset + 4 > data.len) break;
        var tag: [4]u8 = undefined;
        @memcpy(&tag, data[type_offset..][0..4]);
        try types.append(allocator, tag);
        // Move to next chunk
        i += 4 + 4 + @as(usize, chunk_len) + 4;
    }

    return types.toOwnedSlice(allocator);
}

test "single frame APNG has acTL, fcTL, IDAT chunks" {
    const Color = cappan_core.render.rgba_bitmap.Color;
    var bmp = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.white);
    defer bmp.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeApngRgba(std.testing.allocator, &[_]RgbaBitmap{bmp}, 1, 10, &output.writer);

    const written = output.writer.buffered();

    // PNG signature
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, written[0..8]);

    try std.testing.expect(findChunkOffset(written, "acTL") != null);
    try std.testing.expect(findChunkOffset(written, "fcTL") != null);
    try std.testing.expect(findChunkOffset(written, "IDAT") != null);
    try std.testing.expect(findChunkOffset(written, "IEND") != null);
}

test "multi-frame APNG chunk ordering" {
    const Color = cappan_core.render.rgba_bitmap.Color;
    var bmp1 = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.white);
    defer bmp1.deinit();
    var bmp2 = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.black);
    defer bmp2.deinit();
    var bmp3 = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.white);
    defer bmp3.deinit();

    const frames = [_]RgbaBitmap{ bmp1, bmp2, bmp3 };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeApngRgba(std.testing.allocator, &frames, 1, 10, &output.writer);

    const written = output.writer.buffered();

    const types = try collectChunkTypes(std.testing.allocator, written);
    defer std.testing.allocator.free(types);

    // Expected order: IHDR, acTL, fcTL, IDAT, fcTL, fdAT, fcTL, fdAT, IEND
    try std.testing.expectEqual(@as(usize, 9), types.len);
    try std.testing.expectEqualSlices(u8, "IHDR", &types[0]);
    try std.testing.expectEqualSlices(u8, "acTL", &types[1]);
    try std.testing.expectEqualSlices(u8, "fcTL", &types[2]);
    try std.testing.expectEqualSlices(u8, "IDAT", &types[3]);
    try std.testing.expectEqualSlices(u8, "fcTL", &types[4]);
    try std.testing.expectEqualSlices(u8, "fdAT", &types[5]);
    try std.testing.expectEqualSlices(u8, "fcTL", &types[6]);
    try std.testing.expectEqualSlices(u8, "fdAT", &types[7]);
    try std.testing.expectEqualSlices(u8, "IEND", &types[8]);
}

test "acTL num_frames matches input frame count" {
    const Color = cappan_core.render.rgba_bitmap.Color;
    var bmp1 = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.white);
    defer bmp1.deinit();
    var bmp2 = try RgbaBitmap.init(std.testing.allocator, 2, 2, Color.black);
    defer bmp2.deinit();

    const frames = [_]RgbaBitmap{ bmp1, bmp2 };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeApngRgba(std.testing.allocator, &frames, 1, 10, &output.writer);

    const written = output.writer.buffered();

    // Find acTL chunk and read num_frames
    const actl_offset = findChunkOffset(written, "acTL") orelse {
        try std.testing.expect(false); // acTL not found
        return;
    };
    // acTL data starts at offset + 4 (length) + 4 (type) = offset + 8
    const data_offset = actl_offset + 8;
    const num_frames_actual = std.mem.readInt(u32, written[data_offset..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 2), num_frames_actual);
}
