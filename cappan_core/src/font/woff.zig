const std = @import("std");
const parser = @import("parser.zig");
const flate = std.compress.flate;

const WOFF_SIGNATURE: u32 = 0x774F4646; // "wOFF"

pub fn isWoffFile(data: []const u8) bool {
    if (data.len < 4) return false;
    const sig = parser.readU32(data, 0) catch return false;
    return sig == WOFF_SIGNATURE;
}

/// Decompress zlib-compressed data into dest.
/// dest must be exactly the expected decompressed size.
fn zlibDecompress(compressed: []const u8, dest: []u8) !void {
    var reader: std.Io.Reader = .fixed(compressed);
    var decompress_buffer: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&reader, .zlib, &decompress_buffer);
    try decompress.reader.readSliceAll(dest);
}

/// Convert WOFF data to SFNT (TTF/OTF) format.
/// Caller owns the returned slice and must free it with allocator.free().
pub fn woffToSfnt(allocator: std.mem.Allocator, woff_data: []const u8) ![]u8 {
    if (woff_data.len < 44) return error.UnexpectedEof;

    const sig = try parser.readU32(woff_data, 0);
    if (sig != WOFF_SIGNATURE) return error.InvalidSfntVersion;

    const flavor = try parser.readU32(woff_data, 4);
    const num_tables = try parser.readU16(woff_data, 12);
    const total_sfnt_size = try parser.readU32(woff_data, 16);

    const sfnt = try allocator.alloc(u8, @intCast(total_sfnt_size));
    errdefer allocator.free(sfnt);
    @memset(sfnt, 0);

    // Write SFNT offset table header (12 bytes)
    std.mem.writeInt(u32, sfnt[0..4], flavor, .big);
    std.mem.writeInt(u16, sfnt[4..6], num_tables, .big);

    // Calculate searchRange, entrySelector, rangeShift
    var search_range: u16 = 1;
    var entry_selector: u16 = 0;
    while (search_range * 2 <= num_tables) {
        search_range *= 2;
        entry_selector += 1;
    }
    search_range *= 16;
    const range_shift = @as(u16, num_tables) * 16 - search_range;

    std.mem.writeInt(u16, sfnt[6..8], search_range, .big);
    std.mem.writeInt(u16, sfnt[8..10], entry_selector, .big);
    std.mem.writeInt(u16, sfnt[10..12], range_shift, .big);

    // SFNT table data starts after: 12 (header) + num_tables * 16 (table records)
    // aligned to 4-byte boundary
    var sfnt_data_offset: u32 = 12 + @as(u32, num_tables) * 16;
    sfnt_data_offset = (sfnt_data_offset + 3) & ~@as(u32, 3);

    // Process each WOFF table directory entry (20 bytes each, starting at offset 44)
    var woff_dir_offset: usize = 44;
    for (0..num_tables) |i| {
        if (woff_dir_offset + 20 > woff_data.len) return error.UnexpectedEof;

        const tag = woff_data[woff_dir_offset..][0..4].*;
        const comp_offset = try parser.readU32(woff_data, woff_dir_offset + 4);
        const comp_length = try parser.readU32(woff_data, woff_dir_offset + 8);
        const orig_length = try parser.readU32(woff_data, woff_dir_offset + 12);
        const orig_checksum = try parser.readU32(woff_data, woff_dir_offset + 16);

        // Write SFNT table record (16 bytes): tag, checksum, offset, length
        const sfnt_dir_offset = 12 + i * 16;
        @memcpy(sfnt[sfnt_dir_offset..][0..4], &tag);
        std.mem.writeInt(u32, sfnt[sfnt_dir_offset + 4 ..][0..4], orig_checksum, .big);
        std.mem.writeInt(u32, sfnt[sfnt_dir_offset + 8 ..][0..4], sfnt_data_offset, .big);
        std.mem.writeInt(u32, sfnt[sfnt_dir_offset + 12 ..][0..4], orig_length, .big);

        // Decompress/copy table data
        const comp_start: usize = @intCast(comp_offset);
        const comp_data_end = std.math.add(usize, comp_start, @as(usize, comp_length)) catch return error.UnexpectedEof;
        if (comp_data_end > woff_data.len) return error.UnexpectedEof;
        const compressed = woff_data[comp_start..comp_data_end];

        const dest_start: usize = @intCast(sfnt_data_offset);
        const dest_end = std.math.add(usize, dest_start, @as(usize, orig_length)) catch return error.UnexpectedEof;
        if (dest_end > sfnt.len) return error.UnexpectedEof;

        if (comp_length == orig_length) {
            // Uncompressed: copy directly
            @memcpy(sfnt[dest_start..dest_end], compressed);
        } else {
            // zlib compressed: decompress
            try zlibDecompress(compressed, sfnt[dest_start..dest_end]);
        }

        // Advance past data + 4-byte alignment padding
        sfnt_data_offset += orig_length;
        const padding = (4 - (sfnt_data_offset % 4)) % 4;
        sfnt_data_offset += @intCast(padding);

        woff_dir_offset += 20;
    }

    return sfnt;
}

test "isWoffFile returns false for regular TTF" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    try std.testing.expect(!isWoffFile(font_data));
}

test "isWoffFile returns false for empty data" {
    try std.testing.expect(!isWoffFile(&.{}));
}
