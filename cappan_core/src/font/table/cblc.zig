const std = @import("std");
const parser = @import("../parser.zig");

pub const BitmapSize = struct {
    index_subtable_array_offset: u32,
    number_of_index_subtables: u32,
    start_glyph_index: u16,
    end_glyph_index: u16,
    ppem_x: u8,
    ppem_y: u8,
    bit_depth: u8,
};

pub const GlyphBitmapLocation = struct {
    image_format: u16,
    image_data_offset: u32, // offset into CBDT from start of CBDT table
    image_data_length: u32,
};

// BitmapSize record is 48 bytes in the CBLC table.
// Layout:
//   u32 indexSubTableArrayOffset
//   u32 indexTablesSize
//   u32 numberOfIndexSubTables
//   u32 colorRef (unused)
//   SbitLineMetrics hori (12 bytes)
//   SbitLineMetrics vert (12 bytes)
//   u16 startGlyphIndex
//   u16 endGlyphIndex
//   u8  ppemX
//   u8  ppemY
//   u8  bitDepth
//   i8  flags
// Total: 4+4+4+4+12+12+2+2+1+1+1+1 = 48

const BITMAP_SIZE_RECORD_SIZE: usize = 48;
const HEADER_SIZE: usize = 8; // majorVersion(2) + minorVersion(2) + numSizes(4)

pub const CblcTable = struct {
    data: []const u8,
    num_sizes: u32,

    pub fn findBitmapSize(self: CblcTable, glyph_id: u16) ?BitmapSize {
        var i: u32 = 0;
        while (i < self.num_sizes) : (i += 1) {
            const record_offset = HEADER_SIZE + @as(usize, i) * BITMAP_SIZE_RECORD_SIZE;
            if (record_offset + BITMAP_SIZE_RECORD_SIZE > self.data.len) return null;

            // Per the BitmapSize layout above: 4 u32s (16) + 2 SbitLineMetrics
            // (24) = 40 bytes precede startGlyphIndex.
            const start_glyph_index = parser.readU16(self.data, record_offset + 40) catch return null;
            const end_glyph_index = parser.readU16(self.data, record_offset + 42) catch return null;

            if (glyph_id >= start_glyph_index and glyph_id <= end_glyph_index) {
                const index_subtable_array_offset = parser.readU32(self.data, record_offset) catch return null;
                const number_of_index_subtables = parser.readU32(self.data, record_offset + 8) catch return null;
                const ppem_x = parser.readU8(self.data, record_offset + 44) catch return null;
                const ppem_y = parser.readU8(self.data, record_offset + 45) catch return null;
                const bit_depth = parser.readU8(self.data, record_offset + 46) catch return null;

                return BitmapSize{
                    .index_subtable_array_offset = index_subtable_array_offset,
                    .number_of_index_subtables = number_of_index_subtables,
                    .start_glyph_index = start_glyph_index,
                    .end_glyph_index = end_glyph_index,
                    .ppem_x = ppem_x,
                    .ppem_y = ppem_y,
                    .bit_depth = bit_depth,
                };
            }
        }
        return null;
    }

    pub fn findGlyphBitmap(self: CblcTable, glyph_id: u16) ?GlyphBitmapLocation {
        const bitmap_size = self.findBitmapSize(glyph_id) orelse return null;

        // IndexSubTableArray entries are 8 bytes each:
        //   u16 firstGlyphIndex
        //   u16 lastGlyphIndex
        //   u32 additionalOffsetToIndexSubtable (from indexSubTableArrayOffset)
        const array_base: usize = @intCast(bitmap_size.index_subtable_array_offset);
        var j: u32 = 0;
        while (j < bitmap_size.number_of_index_subtables) : (j += 1) {
            const entry_offset = array_base + @as(usize, j) * 8;
            if (entry_offset + 8 > self.data.len) return null;

            const first_glyph = parser.readU16(self.data, entry_offset) catch return null;
            const last_glyph = parser.readU16(self.data, entry_offset + 2) catch return null;

            if (glyph_id < first_glyph or glyph_id > last_glyph) continue;

            const additional_offset = parser.readU32(self.data, entry_offset + 4) catch return null;
            // The IndexSubTable starts at: indexSubTableArrayOffset + additionalOffset
            const subtable_offset: usize = @as(usize, bitmap_size.index_subtable_array_offset) + @as(usize, additional_offset);

            if (subtable_offset + 8 > self.data.len) return null;

            const index_format = parser.readU16(self.data, subtable_offset) catch return null;
            const image_format = parser.readU16(self.data, subtable_offset + 2) catch return null;
            const image_data_offset = parser.readU32(self.data, subtable_offset + 4) catch return null;

            // glyph_offset_in_run is the index within this sub-table's glyph range
            const glyph_run_index = @as(usize, glyph_id - first_glyph);
            const num_glyphs_in_range = @as(usize, last_glyph - first_glyph + 1);

            switch (index_format) {
                1 => {
                    // Format 1: uint32 offsets array, size = num_glyphs_in_range + 1
                    // offsets start at subtable_offset + 8
                    const offsets_base = subtable_offset + 8;
                    const offset_needed = offsets_base + (glyph_run_index + 2) * 4;
                    if (offset_needed > self.data.len) return null;

                    const off_cur = parser.readU32(self.data, offsets_base + glyph_run_index * 4) catch return null;
                    const off_next = parser.readU32(self.data, offsets_base + (glyph_run_index + 1) * 4) catch return null;

                    if (off_next <= off_cur) return null;

                    return GlyphBitmapLocation{
                        .image_format = image_format,
                        .image_data_offset = std.math.add(u32, image_data_offset, off_cur) catch return null,
                        .image_data_length = off_next - off_cur,
                    };
                },
                3 => {
                    // Format 3: uint16 offsets array, size = num_glyphs_in_range + 1
                    // offsets start at subtable_offset + 8
                    const offsets_base = subtable_offset + 8;
                    const offset_needed = offsets_base + (glyph_run_index + 2) * 2;
                    if (offset_needed > self.data.len) return null;

                    const off_cur_u16 = parser.readU16(self.data, offsets_base + glyph_run_index * 2) catch return null;
                    const off_next_u16 = parser.readU16(self.data, offsets_base + (glyph_run_index + 1) * 2) catch return null;

                    const off_cur: u32 = off_cur_u16;
                    const off_next: u32 = off_next_u16;

                    if (off_next <= off_cur) return null;

                    return GlyphBitmapLocation{
                        .image_format = image_format,
                        .image_data_offset = std.math.add(u32, image_data_offset, off_cur) catch return null,
                        .image_data_length = off_next - off_cur,
                    };
                },
                2 => {
                    // Format 2: all glyphs in the range share one constant image
                    // size and one BigGlyphMetrics. Layout after the common
                    // header (8 bytes): imageSize(u32) + BigGlyphMetrics(8
                    // bytes, unused here -- only the image location/size is
                    // needed to locate CBDT data) = 20 bytes total (I12).
                    const image_size = parser.readU32(self.data, subtable_offset + 8) catch return null;
                    const image_offset_in_run = std.math.mul(u32, image_size, @as(u32, @intCast(glyph_run_index))) catch return null;

                    return GlyphBitmapLocation{
                        .image_format = image_format,
                        .image_data_offset = std.math.add(u32, image_data_offset, image_offset_in_run) catch return null,
                        .image_data_length = image_size,
                    };
                },
                4 => {
                    // Format 4: sparse glyph array. Layout after the common
                    // header: numGlyphs(u32) followed by (numGlyphs + 1)
                    // GlyphIdOffsetPair entries (glyphID:u16, offset:u16),
                    // sorted ascending by glyphID. The trailing sentinel
                    // entry's offset gives the end of the last glyph's image,
                    // so entries [0, numGlyphs) are searchable glyphs and
                    // entry[i+1].offset - entry[i].offset is glyph i's image
                    // length (I12).
                    const num_glyphs_offset_f4 = subtable_offset + 8;
                    if (num_glyphs_offset_f4 + 4 > self.data.len) return null;
                    const num_glyphs = parser.readU32(self.data, num_glyphs_offset_f4) catch return null;
                    if (num_glyphs == 0) return null;
                    const pairs_base = num_glyphs_offset_f4 + 4;

                    var lo: u32 = 0;
                    var hi: u32 = num_glyphs;
                    var found_idx: ?u32 = null;
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        const pair_offset = pairs_base + @as(usize, mid) * 4;
                        if (pair_offset + 4 > self.data.len) return null;
                        const gid = parser.readU16(self.data, pair_offset) catch return null;
                        if (gid == glyph_id) {
                            found_idx = mid;
                            break;
                        } else if (gid < glyph_id) {
                            lo = mid + 1;
                        } else {
                            hi = mid;
                        }
                    }
                    const idx = found_idx orelse return null;

                    const cur_pair_offset = pairs_base + @as(usize, idx) * 4;
                    const next_pair_offset = pairs_base + @as(usize, idx + 1) * 4;
                    if (next_pair_offset + 4 > self.data.len) return null;
                    const off_cur = parser.readU16(self.data, cur_pair_offset + 2) catch return null;
                    const off_next = parser.readU16(self.data, next_pair_offset + 2) catch return null;
                    if (off_next <= off_cur) return null;

                    return GlyphBitmapLocation{
                        .image_format = image_format,
                        .image_data_offset = std.math.add(u32, image_data_offset, off_cur) catch return null,
                        .image_data_length = off_next - off_cur,
                    };
                },
                5 => {
                    // Format 5: sparse glyph ID list with constant-size images.
                    // Layout after the common header: imageSize(u32) +
                    // BigGlyphMetrics(8 bytes, unused) + numGlyphs(u32) +
                    // glyphIdArray[numGlyphs](u16 each, sorted ascending).
                    // The glyph's position in the sorted array (not its ID)
                    // determines its offset within the constant-size run (I12).
                    const image_size = parser.readU32(self.data, subtable_offset + 8) catch return null;
                    const num_glyphs_offset = subtable_offset + 8 + 4 + 8;
                    if (num_glyphs_offset + 4 > self.data.len) return null;
                    const num_glyphs = parser.readU32(self.data, num_glyphs_offset) catch return null;
                    if (num_glyphs == 0) return null;
                    const glyph_array_base = num_glyphs_offset + 4;

                    var lo: u32 = 0;
                    var hi: u32 = num_glyphs;
                    var found_idx: ?u32 = null;
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        const gid_offset = glyph_array_base + @as(usize, mid) * 2;
                        if (gid_offset + 2 > self.data.len) return null;
                        const gid = parser.readU16(self.data, gid_offset) catch return null;
                        if (gid == glyph_id) {
                            found_idx = mid;
                            break;
                        } else if (gid < glyph_id) {
                            lo = mid + 1;
                        } else {
                            hi = mid;
                        }
                    }
                    const idx = found_idx orelse return null;
                    const image_offset_in_run = std.math.mul(u32, image_size, idx) catch return null;

                    return GlyphBitmapLocation{
                        .image_format = image_format,
                        .image_data_offset = std.math.add(u32, image_data_offset, image_offset_in_run) catch return null,
                        .image_data_length = image_size,
                    };
                },
                else => return null,
            }
            _ = num_glyphs_in_range;
        }
        return null;
    }
};

pub fn parse(data: []const u8) !CblcTable {
    if (data.len < HEADER_SIZE) return error.UnexpectedEof;
    const major_version = try parser.readU16(data, 0);
    if (major_version != 2 and major_version != 3) return error.UnsupportedVersion;
    const num_sizes = try parser.readU32(data, 4);
    return CblcTable{
        .data = data,
        .num_sizes = num_sizes,
    };
}

test "cblc parse returns error on short data" {
    const result = parse(&[_]u8{0} ** 5);
    try std.testing.expectError(error.UnexpectedEof, result);
}

test "cblc parse returns error on unsupported version" {
    const data = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = parse(&data);
    try std.testing.expectError(error.UnsupportedVersion, result);
}

test "cblc parse valid header with zero sizes" {
    // majorVersion=3, minorVersion=0, numSizes=0
    const data = [_]u8{ 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const table = try parse(&data);
    try std.testing.expectEqual(@as(u32, 0), table.num_sizes);
}

// ============================================================
// I12: synthetic CBLC test data for index-subtable formats 2/4/5.
//
// No CBDT/CBLC-bearing font fixture is available in this repo (see
// script/fetch-asset.sh / .font/), so these tests build minimal synthetic
// CBLC buffers at runtime -- one CBLC header, one BitmapSize record, one
// single-entry IndexSubTableArray, followed by the format-under-test's
// IndexSubTable bytes -- and exercise `findGlyphBitmap` end-to-end.
// The BitmapSize record fields are placed at their spec offsets (startGlyphIndex
// at 40, after the 4 leading uint32s and two 12-byte SbitLineMetrics), matching
// `findBitmapSize` -- a prior 4-byte offset error there was fixed alongside I12.
// ============================================================

fn appendU8(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u8) !void {
    try list.append(allocator, v);
}

fn appendU16(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .big);
    try list.appendSlice(allocator, &buf);
}

fn appendU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try list.appendSlice(allocator, &buf);
}

/// Builds a synthetic CBLC buffer with a single BitmapSize covering
/// [start_glyph, end_glyph] and a single IndexSubTableArray entry (same
/// range) pointing at `subtable_bytes` (the IndexSubTable's raw bytes,
/// starting with its own indexFormat/imageFormat/imageDataOffset header).
fn buildSyntheticCblc(
    allocator: std.mem.Allocator,
    start_glyph: u16,
    end_glyph: u16,
    subtable_bytes: []const u8,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // CBLC header (8 bytes)
    try appendU16(&list, allocator, 3); // majorVersion
    try appendU16(&list, allocator, 0); // minorVersion
    try appendU32(&list, allocator, 1); // numSizes

    const record_start = list.items.len; // 8
    const index_subtable_array_offset: u32 = @intCast(record_start + BITMAP_SIZE_RECORD_SIZE);

    // BitmapSize record (48 bytes)
    try appendU32(&list, allocator, index_subtable_array_offset); // rel0: indexSubTableArrayOffset
    try appendU32(&list, allocator, 0); // rel4: indexTablesSize (unused)
    try appendU32(&list, allocator, 1); // rel8: numberOfIndexSubTables
    try appendU32(&list, allocator, 0); // rel12: colorRef (unused)
    try list.appendNTimes(allocator, 0, 24); // rel16..39: hori + vert SbitLineMetrics (12+12)
    try appendU16(&list, allocator, start_glyph); // rel40: startGlyphIndex
    try appendU16(&list, allocator, end_glyph); // rel42: endGlyphIndex
    try appendU8(&list, allocator, 0); // rel44: ppemX
    try appendU8(&list, allocator, 0); // rel45: ppemY
    try appendU8(&list, allocator, 0); // rel46: bitDepth
    try appendU8(&list, allocator, 0); // rel47: flags (fills 48 bytes)

    std.debug.assert(list.items.len == record_start + BITMAP_SIZE_RECORD_SIZE);

    // IndexSubTableArray: one entry, additionalOffset skips past this
    // 8-byte entry so the subtable starts right after it.
    try appendU16(&list, allocator, start_glyph); // firstGlyphIndex
    try appendU16(&list, allocator, end_glyph); // lastGlyphIndex
    try appendU32(&list, allocator, 8); // additionalOffsetToIndexSubtable

    try list.appendSlice(allocator, subtable_bytes);

    return try list.toOwnedSlice(allocator);
}

test "cblc findGlyphBitmap format 2: constant-size images over a contiguous range (I12)" {
    // Format 2 subtable: header(8) + imageSize(4) + bigMetrics(8, unused) = 20 bytes.
    var subtable: std.ArrayList(u8) = .empty;
    defer subtable.deinit(std.testing.allocator);
    try appendU16(&subtable, std.testing.allocator, 2); // indexFormat = 2
    try appendU16(&subtable, std.testing.allocator, 17); // imageFormat (arbitrary)
    try appendU32(&subtable, std.testing.allocator, 1000); // imageDataOffset
    try appendU32(&subtable, std.testing.allocator, 50); // imageSize (constant per glyph)
    try subtable.appendNTimes(std.testing.allocator, 0, 8); // bigMetrics (unused)

    const data = try buildSyntheticCblc(std.testing.allocator, 10, 12, subtable.items);
    defer std.testing.allocator.free(data);
    const table = try parse(data);

    const loc10 = table.findGlyphBitmap(10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 17), loc10.image_format);
    try std.testing.expectEqual(@as(u32, 1000), loc10.image_data_offset);
    try std.testing.expectEqual(@as(u32, 50), loc10.image_data_length);

    const loc11 = table.findGlyphBitmap(11) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1050), loc11.image_data_offset);
    try std.testing.expectEqual(@as(u32, 50), loc11.image_data_length);

    const loc12 = table.findGlyphBitmap(12) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1100), loc12.image_data_offset);
    try std.testing.expectEqual(@as(u32, 50), loc12.image_data_length);

    try std.testing.expectEqual(@as(?GlyphBitmapLocation, null), table.findGlyphBitmap(13));
}

test "cblc findGlyphBitmap format 4: sparse glyph array with u32 offsets (I12)" {
    // Format 4 subtable: header(8) + numGlyphs(4) + (numGlyphs+1) pairs of
    // (glyphID:u16, offset:u16), sorted by glyphID, last pair is a sentinel
    // whose offset marks the end of the last real glyph's image.
    var subtable: std.ArrayList(u8) = .empty;
    defer subtable.deinit(std.testing.allocator);
    try appendU16(&subtable, std.testing.allocator, 4); // indexFormat = 4
    try appendU16(&subtable, std.testing.allocator, 17); // imageFormat
    try appendU32(&subtable, std.testing.allocator, 2000); // imageDataOffset
    try appendU32(&subtable, std.testing.allocator, 3); // numGlyphs (real entries; sparse within [10,20])
    try appendU16(&subtable, std.testing.allocator, 10);
    try appendU16(&subtable, std.testing.allocator, 0);
    try appendU16(&subtable, std.testing.allocator, 15);
    try appendU16(&subtable, std.testing.allocator, 30);
    try appendU16(&subtable, std.testing.allocator, 18);
    try appendU16(&subtable, std.testing.allocator, 70);
    try appendU16(&subtable, std.testing.allocator, 0xFFFF); // sentinel glyphID (unused)
    try appendU16(&subtable, std.testing.allocator, 100); // sentinel offset (end of glyph 18's image)

    const data = try buildSyntheticCblc(std.testing.allocator, 10, 20, subtable.items);
    defer std.testing.allocator.free(data);
    const table = try parse(data);

    const loc10 = table.findGlyphBitmap(10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2000), loc10.image_data_offset);
    try std.testing.expectEqual(@as(u32, 30), loc10.image_data_length);

    const loc15 = table.findGlyphBitmap(15) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2030), loc15.image_data_offset);
    try std.testing.expectEqual(@as(u32, 40), loc15.image_data_length);

    const loc18 = table.findGlyphBitmap(18) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2070), loc18.image_data_offset);
    try std.testing.expectEqual(@as(u32, 30), loc18.image_data_length);

    // Within the nominal [10,20] range but absent from the sparse array.
    try std.testing.expectEqual(@as(?GlyphBitmapLocation, null), table.findGlyphBitmap(12));
}

test "cblc findGlyphBitmap format 5: sparse glyph ID list with constant-size images (I12)" {
    // Format 5 subtable: header(8) + imageSize(4) + bigMetrics(8, unused) +
    // numGlyphs(4) + glyphIdArray[numGlyphs](u16 each, sorted ascending).
    var subtable: std.ArrayList(u8) = .empty;
    defer subtable.deinit(std.testing.allocator);
    try appendU16(&subtable, std.testing.allocator, 5); // indexFormat = 5
    try appendU16(&subtable, std.testing.allocator, 17); // imageFormat
    try appendU32(&subtable, std.testing.allocator, 3000); // imageDataOffset
    try appendU32(&subtable, std.testing.allocator, 20); // imageSize (constant per glyph)
    try subtable.appendNTimes(std.testing.allocator, 0, 8); // bigMetrics (unused)
    try appendU32(&subtable, std.testing.allocator, 3); // numGlyphs
    try appendU16(&subtable, std.testing.allocator, 10);
    try appendU16(&subtable, std.testing.allocator, 12);
    try appendU16(&subtable, std.testing.allocator, 14);

    const data = try buildSyntheticCblc(std.testing.allocator, 10, 14, subtable.items);
    defer std.testing.allocator.free(data);
    const table = try parse(data);

    const loc10 = table.findGlyphBitmap(10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3000), loc10.image_data_offset);
    try std.testing.expectEqual(@as(u32, 20), loc10.image_data_length);

    const loc12 = table.findGlyphBitmap(12) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3020), loc12.image_data_offset);
    try std.testing.expectEqual(@as(u32, 20), loc12.image_data_length);

    const loc14 = table.findGlyphBitmap(14) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3040), loc14.image_data_offset);
    try std.testing.expectEqual(@as(u32, 20), loc14.image_data_length);

    // Within the nominal [10,14] range but absent from the sparse list.
    try std.testing.expectEqual(@as(?GlyphBitmapLocation, null), table.findGlyphBitmap(13));
}
