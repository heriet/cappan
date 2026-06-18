/// Minimal PNG decoder for CBDT embedded bitmaps.
/// Supports 8-bit RGBA (color type 6) and 8-bit RGB (color type 2) PNGs with
/// any standard filter type. This covers the RGBA bitmaps typically embedded
/// in color emoji fonts.
const std = @import("std");

pub const DecodedImage = struct {
    pixels: []u8, // RGBA, 4 bytes per pixel, row-major
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.pixels);
    }
};

const PNG_SIGNATURE = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub const DecodeError = error{
    InvalidPngSignature,
    InvalidChunkLayout,
    MissingIhdrChunk,
    UnsupportedColorType,
    UnsupportedBitDepth,
    UnsupportedInterlace,
    InvalidFilterType,
    UnexpectedEof,
    OutOfMemory,
    DecompressFailed,
};

pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!DecodedImage {
    if (data.len < 8) return error.UnexpectedEof;
    if (!std.mem.eql(u8, data[0..8], &PNG_SIGNATURE)) return error.InvalidPngSignature;

    var pos: usize = 8;

    // Read IHDR
    if (pos + 12 > data.len) return error.MissingIhdrChunk;
    const ihdr_len = readU32Be(data, pos);
    pos += 4;
    if (!std.mem.eql(u8, data[pos..][0..4], "IHDR")) return error.MissingIhdrChunk;
    pos += 4;
    if (ihdr_len < 13 or pos + ihdr_len > data.len) return error.MissingIhdrChunk;

    const width = readU32Be(data, pos);
    const height = readU32Be(data, pos + 4);
    const bit_depth = data[pos + 8];
    const color_type = data[pos + 9];
    // compression_method = data[pos + 10]; // must be 0
    // filter_method      = data[pos + 11]; // must be 0
    const interlace_method = data[pos + 12];

    if (bit_depth != 8) return error.UnsupportedBitDepth;
    if (color_type != 2 and color_type != 6) return error.UnsupportedColorType;
    if (interlace_method != 0) return error.UnsupportedInterlace;

    pos += @as(usize, ihdr_len) + 4; // skip chunk data + CRC

    const channels: u8 = if (color_type == 6) 4 else 3;
    const stride = @as(usize, width) * @as(usize, channels);

    // Collect all IDAT chunks into a single buffer
    var idat_buf: std.ArrayList(u8) = .empty;
    defer idat_buf.deinit(allocator);

    while (pos + 8 <= data.len) {
        const chunk_len = readU32Be(data, pos);
        const chunk_type = data[pos + 4 .. pos + 8];
        const chunk_data_start = pos + 8;
        const chunk_data_end = chunk_data_start + @as(usize, chunk_len);
        if (chunk_data_end + 4 > data.len) break;

        if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat_buf.appendSlice(allocator, data[chunk_data_start..chunk_data_end]);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        pos = chunk_data_end + 4; // skip CRC
    }

    // Decompress the IDAT data (zlib format)
    const filtered_size = @as(usize, height) * (stride + 1); // +1 for filter byte per row
    var decompressed = try allocator.alloc(u8, filtered_size);
    defer allocator.free(decompressed);

    {
        var in: std.Io.Reader = .fixed(idat_buf.items);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
        _ = decompress.reader.streamRemaining(&aw.writer) catch return error.DecompressFailed;

        const written = aw.written();
        if (written.len < filtered_size) return error.DecompressFailed;
        @memcpy(decompressed[0..filtered_size], written[0..filtered_size]);
    }

    // Allocate output RGBA buffer
    const out_size = @as(usize, width) * @as(usize, height) * 4;
    const pixels = try allocator.alloc(u8, out_size);
    errdefer allocator.free(pixels);

    // Unfilter each scanline and convert to RGBA
    var row_src: usize = 0;
    for (0..@as(usize, height)) |y| {
        const filter_type = decompressed[row_src];
        row_src += 1;
        const src_row = decompressed[row_src .. row_src + stride];
        const dst_row_start = y * @as(usize, width) * 4;
        const prev_row_start: ?usize = if (y > 0) (y - 1) * @as(usize, width) * 4 else null;

        // Apply PNG filter reconstruction
        switch (filter_type) {
            0 => { // None
                reconstructRow(src_row, channels, null, null);
            },
            1 => { // Sub
                reconstructSub(src_row, channels);
            },
            2 => { // Up
                if (prev_row_start) |pr| {
                    reconstructUp(src_row, pixels[pr .. pr + stride], channels);
                }
                // If no previous row, Up filter means add 0 (no change)
            },
            3 => { // Average
                const prev_opt: ?[]u8 = if (prev_row_start) |pr| pixels[pr .. pr + stride] else null;
                reconstructAverage(src_row, prev_opt, channels);
            },
            4 => { // Paeth
                const prev_opt: ?[]u8 = if (prev_row_start) |pr| pixels[pr .. pr + stride] else null;
                reconstructPaeth(src_row, prev_opt, channels);
            },
            else => return error.InvalidFilterType,
        }

        // Write to output RGBA buffer
        if (channels == 4) {
            // RGBA -> RGBA
            @memcpy(pixels[dst_row_start .. dst_row_start + @as(usize, width) * 4], src_row[0 .. @as(usize, width) * 4]);
        } else {
            // RGB -> RGBA (add alpha=255)
            for (0..@as(usize, width)) |x| {
                const s = x * 3;
                const d = dst_row_start + x * 4;
                pixels[d] = src_row[s];
                pixels[d + 1] = src_row[s + 1];
                pixels[d + 2] = src_row[s + 2];
                pixels[d + 3] = 255;
            }
        }

        row_src += stride;
    }

    return DecodedImage{
        .pixels = pixels,
        .width = width,
        .height = height,
        .allocator = allocator,
    };
}

fn readU32Be(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

fn reconstructRow(row: []u8, channels: u8, _: ?[]u8, _: ?[]u8) void {
    _ = row;
    _ = channels;
    // None filter: no reconstruction needed
}

fn reconstructSub(row: []u8, channels: u8) void {
    var i: usize = channels;
    while (i < row.len) : (i += 1) {
        row[i] = row[i] +% row[i - channels];
    }
}

fn reconstructUp(row: []u8, prev: []u8, _: u8) void {
    for (row, 0..) |*v, i| {
        v.* = v.* +% prev[i];
    }
}

fn reconstructAverage(row: []u8, prev: ?[]u8, channels: u8) void {
    for (row, 0..) |*v, i| {
        const a: u16 = if (i >= channels) row[i - channels] else 0;
        const b: u16 = if (prev) |p| p[i] else 0;
        v.* = v.* +% @as(u8, @intCast((a + b) / 2));
    }
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const ai: i16 = a;
    const bi: i16 = b;
    const ci: i16 = c;
    const p: i16 = ai + bi - ci;
    const pa: i16 = if (p > ai) p - ai else ai - p;
    const pb: i16 = if (p > bi) p - bi else bi - p;
    const pc: i16 = if (p > ci) p - ci else ci - p;
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn reconstructPaeth(row: []u8, prev: ?[]u8, channels: u8) void {
    for (row, 0..) |*v, i| {
        const a: u8 = if (i >= channels) row[i - channels] else 0;
        const b: u8 = if (prev) |p| p[i] else 0;
        const c: u8 = if (prev) |p| (if (i >= channels) p[i - channels] else 0) else 0;
        v.* = v.* +% paethPredictor(a, b, c);
    }
}

test "png decoder returns error on invalid signature" {
    const bad_data = [_]u8{0} ** 20;
    const result = decode(std.testing.allocator, &bad_data);
    try std.testing.expectError(error.InvalidPngSignature, result);
}

test "png decoder returns error on short data" {
    const result = decode(std.testing.allocator, &[_]u8{0} ** 4);
    try std.testing.expectError(error.UnexpectedEof, result);
}
