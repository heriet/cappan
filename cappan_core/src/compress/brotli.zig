const std = @import("std");
const decoder = @import("brotli/decoder.zig");

pub const BrotliError = error{
    BrotliDecompressFailed,
    OutputBufferTooSmall,
};

pub fn decompress(allocator: std.mem.Allocator, compressed: []const u8, dest: []u8) !usize {
    const result = decoder.decompress(allocator, compressed) catch return BrotliError.BrotliDecompressFailed;
    defer allocator.free(result);

    if (result.len > dest.len) return BrotliError.OutputBufferTooSmall;
    @memcpy(dest[0..result.len], result);
    return result.len;
}

pub fn decompressAlloc(allocator: std.mem.Allocator, compressed: []const u8, max_size: usize) ![]u8 {
    const result = decoder.decompress(allocator, compressed) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => BrotliError.BrotliDecompressFailed,
        };
    };
    if (result.len > max_size) {
        allocator.free(result);
        return BrotliError.OutputBufferTooSmall;
    }
    return result;
}

test "decompress returns error for invalid data" {
    const invalid_data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    var dest: [256]u8 = undefined;
    const result = decompress(std.testing.allocator, &invalid_data, &dest);
    try std.testing.expectError(BrotliError.BrotliDecompressFailed, result);
}

test "decompress returns error for empty input" {
    var dest: [256]u8 = undefined;
    const result = decompress(std.testing.allocator, &.{}, &dest);
    try std.testing.expectError(BrotliError.BrotliDecompressFailed, result);
}

test "decompressAlloc returns error for invalid data" {
    const allocator = std.testing.allocator;
    const invalid_data = [_]u8{ 0xFF, 0xFE, 0xFD };
    const result = decompressAlloc(allocator, &invalid_data, 1024);
    try std.testing.expectError(BrotliError.BrotliDecompressFailed, result);
}

test "decompress known brotli payload" {
    const compressed = [_]u8{
        0x8f, 0x06, 0x80, 0x48, 0x65, 0x6c, 0x6c, 0x6f,
        0x2c, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21,
        0x0a, 0x03,
    };
    var dest: [64]u8 = undefined;
    const size = try decompress(std.testing.allocator, &compressed, &dest);
    try std.testing.expectEqualStrings("Hello, World!\n", dest[0..size]);
}

test {
    _ = @import("brotli/bit_reader.zig");
    _ = @import("brotli/huffman.zig");
    _ = @import("brotli/context.zig");
    _ = @import("brotli/dictionary.zig");
    _ = @import("brotli/decoder.zig");
}
