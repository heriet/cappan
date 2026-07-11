const std = @import("std");
const parser = @import("parser.zig");
const brotli = @import("../compress/brotli.zig");
const woff2_glyf = @import("woff2_glyf.zig");

pub const WOFF2_SIGNATURE: u32 = 0x774F4632; // "wOF2"

pub const Woff2Error = error{
    InvalidWoff2,
    UnexpectedEof,
    OutOfMemory,
    BrotliDecompressFailed,
};

pub const Woff2Header = struct {
    signature: u32,
    flavor: u32,
    length: u32,
    num_tables: u16,
    reserved: u16,
    total_sfnt_size: u32,
    total_compressed_size: u32,
    major_version: u16,
    minor_version: u16,
    meta_offset: u32,
    meta_length: u32,
    meta_orig_length: u32,
    priv_offset: u32,
    priv_length: u32,
};

pub const Woff2TableEntry = struct {
    tag: [4]u8,
    flags: u8,
    transform_version: u2,
    orig_length: u32,
    transform_length: u32,
};

const known_tags = [63][4]u8{
    "cmap".*, "head".*, "hhea".*, "hmtx".*, "maxp".*, "name".*, "OS/2".*, "post".*,
    "cvt ".*, "fpgm".*, "glyf".*, "loca".*, "prep".*, "CFF ".*, "VORG".*, "EBDT".*,
    "EBLC".*, "gasp".*, "hdmx".*, "kern".*, "LTSH".*, "PCLT".*, "VDMX".*, "vhea".*,
    "vmtx".*, "BASE".*, "GDEF".*, "GPOS".*, "GSUB".*, "EBSC".*, "JSTF".*, "MATH".*,
    "CBDT".*, "CBLC".*, "COLR".*, "CPAL".*, "SVG ".*, "sbix".*, "acnt".*, "avar".*,
    "bdat".*, "bloc".*, "bsln".*, "cvar".*, "fdsc".*, "feat".*, "fmtx".*, "fvar".*,
    "gvar".*, "hsty".*, "just".*, "lcar".*, "mort".*, "morx".*, "opbd".*, "prop".*,
    "trak".*, "Zapf".*, "Silf".*, "Glat".*, "Gloc".*, "Feat".*, "Sill".*,
};

const GLYF_INDEX: u6 = 10;
const LOCA_INDEX: u6 = 11;

pub fn isWoff2File(data: []const u8) bool {
    if (data.len < 4) return false;
    const sig = parser.readU32(data, 0) catch return false;
    return sig == WOFF2_SIGNATURE;
}

fn readUIntBase128(data: []const u8, offset: usize) Woff2Error!struct { value: u32, bytes_read: usize } {
    var result: u32 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        if (offset + i >= data.len) return error.UnexpectedEof;
        const byte = data[offset + i];
        if (i == 0 and byte == 0x80) return error.InvalidWoff2;
        if (result & 0xFE000000 != 0) return error.InvalidWoff2;
        result = (result << 7) | @as(u32, byte & 0x7F);
        if (byte & 0x80 == 0) return .{ .value = result, .bytes_read = i + 1 };
    }
    return error.InvalidWoff2;
}

fn parseHeader(data: []const u8) Woff2Error!Woff2Header {
    if (data.len < 48) return error.UnexpectedEof;
    const sig = parser.readU32(data, 0) catch return error.UnexpectedEof;
    if (sig != WOFF2_SIGNATURE) return error.InvalidWoff2;
    return .{
        .signature = sig,
        .flavor = parser.readU32(data, 4) catch return error.UnexpectedEof,
        .length = parser.readU32(data, 8) catch return error.UnexpectedEof,
        .num_tables = parser.readU16(data, 12) catch return error.UnexpectedEof,
        .reserved = parser.readU16(data, 14) catch return error.UnexpectedEof,
        .total_sfnt_size = parser.readU32(data, 16) catch return error.UnexpectedEof,
        .total_compressed_size = parser.readU32(data, 20) catch return error.UnexpectedEof,
        .major_version = parser.readU16(data, 24) catch return error.UnexpectedEof,
        .minor_version = parser.readU16(data, 26) catch return error.UnexpectedEof,
        .meta_offset = parser.readU32(data, 28) catch return error.UnexpectedEof,
        .meta_length = parser.readU32(data, 32) catch return error.UnexpectedEof,
        .meta_orig_length = parser.readU32(data, 36) catch return error.UnexpectedEof,
        .priv_offset = parser.readU32(data, 40) catch return error.UnexpectedEof,
        .priv_length = parser.readU32(data, 44) catch return error.UnexpectedEof,
    };
}

fn parseTableDirectory(
    allocator: std.mem.Allocator,
    data: []const u8,
    num_tables: u16,
    dir_start: usize,
) Woff2Error!struct { entries: []Woff2TableEntry, bytes_read: usize } {
    var entries = try allocator.alloc(Woff2TableEntry, num_tables);
    errdefer allocator.free(entries);

    var pos: usize = dir_start;
    for (0..num_tables) |i| {
        if (pos >= data.len) return error.UnexpectedEof;
        const flags = data[pos];
        pos += 1;

        const tag_index: u6 = @truncate(flags & 0x3F);
        const transform_version: u2 = @truncate(flags >> 6);

        const tag: [4]u8 = if (tag_index == 63) blk: {
            if (pos + 4 > data.len) return error.UnexpectedEof;
            const t = data[pos..][0..4].*;
            pos += 4;
            break :blk t;
        } else known_tags[tag_index];

        const orig_result = try readUIntBase128(data, pos);
        pos += orig_result.bytes_read;
        const orig_length = orig_result.value;

        // transformLength is present for glyf/loca with transform version 0,
        // or any other table with a non-zero transform version.
        const has_transform = if (tag_index == GLYF_INDEX or tag_index == LOCA_INDEX)
            transform_version == 0
        else
            transform_version != 0;

        const transform_length: u32 = if (has_transform) blk: {
            const tl_result = try readUIntBase128(data, pos);
            pos += tl_result.bytes_read;
            break :blk tl_result.value;
        } else orig_length;

        entries[i] = .{
            .tag = tag,
            .flags = flags,
            .transform_version = transform_version,
            .orig_length = orig_length,
            .transform_length = transform_length,
        };
    }

    return .{ .entries = entries, .bytes_read = pos - dir_start };
}

fn calcChecksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        sum +%= std.mem.readInt(u32, data[i..][0..4], .big);
    }
    // Handle trailing bytes (< 4)
    if (i < data.len) {
        var tmp: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(tmp[0 .. data.len - i], data[i..]);
        sum +%= std.mem.readInt(u32, &tmp, .big);
    }
    return sum;
}

/// Convert WOFF2 data to SFNT (TTF/OTF) format.
/// Caller owns the returned slice and must free it with allocator.free().
pub fn woff2ToSfnt(allocator: std.mem.Allocator, woff2_data: []const u8) ![]u8 {
    const header = try parseHeader(woff2_data);
    if (header.num_tables > 256) return error.InvalidWoff2;

    const dir_result = try parseTableDirectory(allocator, woff2_data, header.num_tables, 48);
    const entries = dir_result.entries;
    defer allocator.free(entries);

    const compressed_offset: usize = 48 + dir_result.bytes_read;
    const compressed_end = compressed_offset + @as(usize, header.total_compressed_size);
    if (compressed_end > woff2_data.len) return error.UnexpectedEof;
    const compressed = woff2_data[compressed_offset..compressed_end];

    // Sum all transform lengths to get the max decompressed size
    var total_decomp_size: usize = 0;
    for (entries) |e| {
        total_decomp_size += e.transform_length;
    }

    const decompressed = brotli.decompressAlloc(allocator, compressed, total_decomp_size) catch |err| switch (err) {
        error.BrotliDecompressFailed, error.OutputBufferTooSmall => return error.BrotliDecompressFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(decompressed);

    // Split decompressed stream into per-table chunks
    // Find glyf and loca entries for transform handling
    var glyf_entry_idx: ?usize = null;
    var loca_entry_idx: ?usize = null;
    {
        var decomp_pos_scan: usize = 0;
        for (entries, 0..) |e, i| {
            if (decomp_pos_scan + e.transform_length > decompressed.len) return error.InvalidWoff2;
            const tag_index: u6 = @truncate(e.flags & 0x3F);
            if (tag_index == GLYF_INDEX) glyf_entry_idx = i;
            if (tag_index == LOCA_INDEX) loca_entry_idx = i;
            decomp_pos_scan += e.transform_length;
        }
    }

    // If glyf has transform version 0, reconstruct glyf and loca
    var glyf_reconstructed: ?woff2_glyf.GlyfLocaResult = null;
    defer if (glyf_reconstructed) |r| r.deinit(allocator);

    if (glyf_entry_idx) |gi| {
        const glyf_entry = entries[gi];
        const tag_index: u6 = @truncate(glyf_entry.flags & 0x3F);
        if (tag_index == GLYF_INDEX and glyf_entry.transform_version == 0) {
            // Compute offset of glyf chunk in decompressed stream
            var glyf_decomp_offset: usize = 0;
            for (entries[0..gi]) |e| {
                glyf_decomp_offset += e.transform_length;
            }
            const glyf_chunk = decompressed[glyf_decomp_offset .. glyf_decomp_offset + glyf_entry.transform_length];

            const loca_orig_length: u32 = if (loca_entry_idx) |li| entries[li].orig_length else 0;
            glyf_reconstructed = try woff2_glyf.reconstructGlyfLoca(allocator, glyf_chunk, loca_orig_length);
        }
    }

    const num_tables = header.num_tables;

    // SFNT layout: 12-byte header + num_tables*16-byte directory + aligned table data
    const sfnt_dir_end: u32 = 12 + @as(u32, num_tables) * 16;
    const sfnt_data_start: u32 = (sfnt_dir_end + 3) & ~@as(u32, 3);

    // Compute total SFNT size using actual (possibly reconstructed) table sizes
    var total_sfnt_size: u32 = sfnt_data_start;
    for (entries, 0..) |e, i| {
        const actual_len: u32 = if (glyf_reconstructed) |r| blk: {
            if (glyf_entry_idx != null and i == glyf_entry_idx.?)
                break :blk std.math.cast(u32, r.glyf_data.len) orelse return error.InvalidWoff2
            else if (loca_entry_idx != null and i == loca_entry_idx.?)
                break :blk std.math.cast(u32, r.loca_data.len) orelse return error.InvalidWoff2
            else
                break :blk e.orig_length;
        } else e.orig_length;
        total_sfnt_size = std.math.add(u32, total_sfnt_size, actual_len) catch return error.InvalidWoff2;
        const padding = (4 - (total_sfnt_size % 4)) % 4;
        total_sfnt_size = std.math.add(u32, total_sfnt_size, padding) catch return error.InvalidWoff2;
    }

    const sfnt = try allocator.alloc(u8, total_sfnt_size);
    errdefer allocator.free(sfnt);
    @memset(sfnt, 0);

    // Write SFNT offset table header (12 bytes)
    std.mem.writeInt(u32, sfnt[0..4], header.flavor, .big);
    std.mem.writeInt(u16, sfnt[4..6], num_tables, .big);

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

    // Write table records and data
    var decomp_pos: usize = 0;
    var sfnt_table_offset: u32 = sfnt_data_start;
    var head_sfnt_offset: ?u32 = null;
    for (entries, 0..) |e, i| {
        const chunk = decompressed[decomp_pos .. decomp_pos + e.transform_length];
        decomp_pos += e.transform_length;

        const dest_start: usize = sfnt_table_offset;

        const actual_len: u32 = blk: {
            if (glyf_reconstructed) |r| {
                if (glyf_entry_idx != null and i == glyf_entry_idx.?) {
                    @memcpy(sfnt[dest_start .. dest_start + r.glyf_data.len], r.glyf_data);
                    break :blk std.math.cast(u32, r.glyf_data.len) orelse return error.InvalidWoff2;
                } else if (loca_entry_idx != null and i == loca_entry_idx.?) {
                    @memcpy(sfnt[dest_start .. dest_start + r.loca_data.len], r.loca_data);
                    break :blk std.math.cast(u32, r.loca_data.len) orelse return error.InvalidWoff2;
                }
            }
            // For untransformed tables, copy directly
            @memcpy(sfnt[dest_start .. dest_start + e.orig_length], chunk[0..e.orig_length]);
            break :blk e.orig_length;
        };

        const checksum = calcChecksum(sfnt[dest_start .. dest_start + actual_len]);

        if (std.mem.eql(u8, &e.tag, "head")) {
            head_sfnt_offset = sfnt_table_offset;
        }

        const rec_offset = 12 + i * 16;
        @memcpy(sfnt[rec_offset..][0..4], &e.tag);
        std.mem.writeInt(u32, sfnt[rec_offset + 4 ..][0..4], checksum, .big);
        std.mem.writeInt(u32, sfnt[rec_offset + 8 ..][0..4], sfnt_table_offset, .big);
        std.mem.writeInt(u32, sfnt[rec_offset + 12 ..][0..4], actual_len, .big);

        sfnt_table_offset += actual_len;
        const padding = (4 - (sfnt_table_offset % 4)) % 4;
        sfnt_table_offset += @intCast(padding);
    }

    // Patch head.indexToLocFormat if glyf was reconstructed
    if (glyf_reconstructed) |r| {
        if (head_sfnt_offset) |head_off| {
            // head table: indexToLocFormat is at offset 50 within the table
            const loc_fmt_off = head_off + 50;
            if (loc_fmt_off + 2 <= sfnt.len) {
                std.mem.writeInt(i16, sfnt[loc_fmt_off..][0..2], @intCast(r.index_format), .big);

                // Recalculate head table checksum in its directory record
                // Find the head entry index
                for (entries, 0..) |e, i| {
                    if (std.mem.eql(u8, &e.tag, "head")) {
                        const rec_offset = 12 + i * 16;
                        const head_actual_len = std.mem.readInt(u32, sfnt[rec_offset + 12 ..][0..4], .big);
                        const new_checksum = calcChecksum(sfnt[head_off .. head_off + head_actual_len]);
                        std.mem.writeInt(u32, sfnt[rec_offset + 4 ..][0..4], new_checksum, .big);
                        break;
                    }
                }
            }
        }
    }

    // Calculate and write global checksum adjustment in head table
    if (head_sfnt_offset) |head_off| {
        // Zero out the checkSumAdjustment field (offset 8 within head table) before computing
        const adjustment_off = head_off + 8;
        if (adjustment_off + 4 <= sfnt.len) {
            std.mem.writeInt(u32, sfnt[adjustment_off..][0..4], 0, .big);
            const total_checksum = calcChecksum(sfnt);
            const adjustment: u32 = 0xB1B0AFBA -% total_checksum;
            std.mem.writeInt(u32, sfnt[adjustment_off..][0..4], adjustment, .big);
        }
    }

    return sfnt;
}

test "isWoff2File returns false for regular TTF" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    try std.testing.expect(!isWoff2File(font_data));
}

test "isWoff2File returns false for empty data" {
    try std.testing.expect(!isWoff2File(&.{}));
}

test "isWoff2File returns false for short data" {
    try std.testing.expect(!isWoff2File(&.{ 0x77, 0x4F }));
}

test "readUIntBase128 single byte" {
    const data = [_]u8{0x3F};
    const result = try readUIntBase128(&data, 0);
    try std.testing.expectEqual(@as(u32, 0x3F), result.value);
    try std.testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "readUIntBase128 multi byte" {
    // 0x80 | 0x01 = continuation, 0x00 = final => value = (1 << 7) | 0 = 128
    const data = [_]u8{ 0x81, 0x00 };
    const result = try readUIntBase128(&data, 0);
    try std.testing.expectEqual(@as(u32, 128), result.value);
    try std.testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "readUIntBase128 leading zero invalid" {
    const data = [_]u8{ 0x80, 0x01 };
    const result = readUIntBase128(&data, 0);
    try std.testing.expectError(error.InvalidWoff2, result);
}

test "readUIntBase128 overflow" {
    // 5 bytes all with continuation bit set — overflows before finishing
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const result = readUIntBase128(&data, 0);
    try std.testing.expectError(error.InvalidWoff2, result);
}

test "readUIntBase128 unexpected eof" {
    const data = [_]u8{};
    const result = readUIntBase128(&data, 0);
    try std.testing.expectError(error.UnexpectedEof, result);
}

test "parseWoff2Header rejects TTF data" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    const result = parseHeader(font_data);
    try std.testing.expectError(error.InvalidWoff2, result);
}

test "parseWoff2Header rejects short data" {
    const data = [_]u8{ 0x77, 0x4F, 0x46, 0x32 }; // correct sig, too short
    const result = parseHeader(&data);
    try std.testing.expectError(error.UnexpectedEof, result);
}

test "woff2ToSfnt roundtrip with DejaVuSans" {
    const allocator = std.testing.allocator;
    const woff2_data = @embedFile("../fixture/DejaVuSans.woff2");

    try std.testing.expect(isWoff2File(woff2_data));

    const sfnt_data = try woff2ToSfnt(allocator, woff2_data);
    defer allocator.free(sfnt_data);

    // Verify the SFNT can be parsed as a font
    const font_mod = @import("font.zig");
    var font = try font_mod.Font.init(allocator, sfnt_data, null);
    defer font.deinit();

    // Basic sanity checks
    try std.testing.expect(font.getUnitsPerEm() > 0);
    try std.testing.expect(font.getAscender() > 0);

    // Look up a glyph
    const glyph_id = try font.getGlyphId(0x0041); // 'A'
    try std.testing.expect(glyph_id > 0);

    // Get outline
    var outline = (try font.getGlyphOutline(allocator, glyph_id)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try std.testing.expect(outline.contours.len > 0);
}
