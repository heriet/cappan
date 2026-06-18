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

            const start_glyph_index = parser.readU16(self.data, record_offset + 36) catch return null;
            const end_glyph_index = parser.readU16(self.data, record_offset + 38) catch return null;

            if (glyph_id >= start_glyph_index and glyph_id <= end_glyph_index) {
                const index_subtable_array_offset = parser.readU32(self.data, record_offset) catch return null;
                const number_of_index_subtables = parser.readU32(self.data, record_offset + 8) catch return null;
                const ppem_x = parser.readU8(self.data, record_offset + 40) catch return null;
                const ppem_y = parser.readU8(self.data, record_offset + 41) catch return null;
                const bit_depth = parser.readU8(self.data, record_offset + 42) catch return null;

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
                        .image_data_offset = image_data_offset + off_cur,
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
                        .image_data_offset = image_data_offset + off_cur,
                        .image_data_length = off_next - off_cur,
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
