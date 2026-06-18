const std = @import("std");
const parser = @import("../parser.zig");

// ============================================================
// Coverage
// ============================================================

pub const Coverage = struct {
    data: []const u8,
    format: u16,

    /// Returns the coverage index for glyph_id, or null if not covered.
    pub fn getCoverageIndex(self: Coverage, glyph_id: u16) ?u16 {
        switch (self.format) {
            1 => {
                // Format 1: glyphCount + glyphArray[] (ascending order)
                const glyph_count = parser.readU16(self.data, 2) catch return null;
                if (glyph_count == 0) return null;

                // Binary search in glyphArray starting at offset 4
                var lo: usize = 0;
                var hi: usize = glyph_count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const g = parser.readU16(self.data, 4 + mid * 2) catch return null;
                    if (g < glyph_id) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                if (lo >= glyph_count) return null;
                const found = parser.readU16(self.data, 4 + lo * 2) catch return null;
                if (found != glyph_id) return null;
                return @intCast(lo);
            },
            2 => {
                // Format 2: rangeCount + rangeRecords[](startGlyph, endGlyph, startCoverageIndex)
                const range_count = parser.readU16(self.data, 2) catch return null;
                if (range_count == 0) return null;

                // Binary search on startGlyphID (each record is 6 bytes)
                var lo: usize = 0;
                var hi: usize = range_count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const start_glyph = parser.readU16(self.data, 4 + mid * 6) catch return null;
                    if (start_glyph <= glyph_id) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                // lo is now the first record with startGlyph > glyph_id
                // we want the record just before that
                if (lo == 0) return null;
                const rec_idx = lo - 1;
                const start_glyph = parser.readU16(self.data, 4 + rec_idx * 6) catch return null;
                const end_glyph = parser.readU16(self.data, 4 + rec_idx * 6 + 2) catch return null;
                const start_cov_idx = parser.readU16(self.data, 4 + rec_idx * 6 + 4) catch return null;
                if (glyph_id < start_glyph or glyph_id > end_glyph) return null;
                return start_cov_idx + (glyph_id - start_glyph);
            },
            else => return null,
        }
    }
};

/// Parse a Coverage table. data is the full font/table data; offset points to the
/// beginning of the Coverage subtable within data.
pub fn parseCoverage(data: []const u8, offset: usize) !Coverage {
    if (offset + 4 > data.len) return error.UnexpectedEof;
    const format = try parser.readU16(data, offset);
    return Coverage{
        .data = data[offset..],
        .format = format,
    };
}

// ============================================================
// ClassDef
// ============================================================

pub const ClassDef = struct {
    data: []const u8,
    format: u16,

    /// Returns the class for glyph_id. Returns 0 if not classified.
    pub fn getClass(self: ClassDef, glyph_id: u16) u16 {
        switch (self.format) {
            1 => {
                // Format 1: startGlyphID + glyphCount + classValueArray[]
                const start_glyph = parser.readU16(self.data, 2) catch return 0;
                const glyph_count = parser.readU16(self.data, 4) catch return 0;
                if (glyph_id < start_glyph) return 0;
                const idx = glyph_id - start_glyph;
                if (idx >= glyph_count) return 0;
                return parser.readU16(self.data, 6 + @as(usize, idx) * 2) catch 0;
            },
            2 => {
                // Format 2: classRangeCount + classRangeRecords[](start, end, class)
                const range_count = parser.readU16(self.data, 2) catch return 0;
                if (range_count == 0) return 0;

                // Binary search on startGlyphID (each record is 6 bytes)
                var lo: usize = 0;
                var hi: usize = range_count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const start_glyph = parser.readU16(self.data, 4 + mid * 6) catch return 0;
                    if (start_glyph <= glyph_id) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                if (lo == 0) return 0;
                const rec_idx = lo - 1;
                const start_glyph = parser.readU16(self.data, 4 + rec_idx * 6) catch return 0;
                const end_glyph = parser.readU16(self.data, 4 + rec_idx * 6 + 2) catch return 0;
                const class = parser.readU16(self.data, 4 + rec_idx * 6 + 4) catch return 0;
                if (glyph_id < start_glyph or glyph_id > end_glyph) return 0;
                return class;
            },
            else => return 0,
        }
    }
};

/// Parse a ClassDef table. data is the full font/table data; offset points to the
/// beginning of the ClassDef subtable within data.
pub fn parseClassDef(data: []const u8, offset: usize) !ClassDef {
    if (offset + 4 > data.len) return error.UnexpectedEof;
    const format = try parser.readU16(data, offset);
    return ClassDef{
        .data = data[offset..],
        .format = format,
    };
}

// ============================================================
// ValueRecord
// ============================================================

pub const ValueRecord = struct {
    x_placement: i16 = 0,
    y_placement: i16 = 0,
    x_advance: i16 = 0,
    y_advance: i16 = 0,
};

/// Compute the byte size of a ValueRecord given a ValueFormat bitmask.
/// Bits 0-3 correspond to x_placement, y_placement, x_advance, y_advance (2 bytes each).
/// Bits 4-7 correspond to device table offsets (2 bytes each, not parsed but counted).
pub fn valueRecordSize(value_format: u16) usize {
    var size: usize = 0;
    var i: u4 = 0;
    while (i < 8) : (i += 1) {
        if (value_format & (@as(u16, 1) << i) != 0) size += 2;
    }
    return size;
}

/// Read a ValueRecord from data[offset..] according to value_format.
pub fn readValueRecord(data: []const u8, offset: usize, value_format: u16) !ValueRecord {
    var result: ValueRecord = .{};
    var pos = offset;
    if (value_format & 0x0001 != 0) {
        result.x_placement = try parser.readI16(data, pos);
        pos += 2;
    }
    if (value_format & 0x0002 != 0) {
        result.y_placement = try parser.readI16(data, pos);
        pos += 2;
    }
    if (value_format & 0x0004 != 0) {
        result.x_advance = try parser.readI16(data, pos);
        pos += 2;
    }
    if (value_format & 0x0008 != 0) {
        result.y_advance = try parser.readI16(data, pos);
        pos += 2;
    }
    // Bits 4-7: device table offsets — not parsed, not returned
    return result;
}

// ============================================================
// Tests
// ============================================================

test "Coverage Format 1: getCoverageIndex" {
    // format=1, glyphCount=3, glyphs=[10, 20, 30]
    const data = [_]u8{
        0x00, 0x01, // format = 1
        0x00, 0x03, // glyphCount = 3
        0x00, 0x0A, // glyph 10
        0x00, 0x14, // glyph 20
        0x00, 0x1E, // glyph 30
    };
    const cov = try parseCoverage(&data, 0);
    try std.testing.expectEqual(@as(?u16, 1), cov.getCoverageIndex(20));
    try std.testing.expectEqual(@as(?u16, null), cov.getCoverageIndex(15));
    try std.testing.expectEqual(@as(?u16, 0), cov.getCoverageIndex(10));
    try std.testing.expectEqual(@as(?u16, 2), cov.getCoverageIndex(30));
}

test "Coverage Format 2: getCoverageIndex" {
    // format=2, rangeCount=1, range=[startGlyph=10, endGlyph=20, startCoverageIndex=0]
    const data = [_]u8{
        0x00, 0x02, // format = 2
        0x00, 0x01, // rangeCount = 1
        0x00, 0x0A, // startGlyphID = 10
        0x00, 0x14, // endGlyphID = 20
        0x00, 0x00, // startCoverageIndex = 0
    };
    const cov = try parseCoverage(&data, 0);
    // glyph 15 is at position 15-10=5, so coverage index = 0+5 = 5
    try std.testing.expectEqual(@as(?u16, 5), cov.getCoverageIndex(15));
    try std.testing.expectEqual(@as(?u16, null), cov.getCoverageIndex(25));
    try std.testing.expectEqual(@as(?u16, 0), cov.getCoverageIndex(10));
    try std.testing.expectEqual(@as(?u16, 10), cov.getCoverageIndex(20));
}

test "ClassDef Format 1: getClass" {
    // format=1, startGlyphID=10, glyphCount=3, classes=[1, 2, 3]
    const data = [_]u8{
        0x00, 0x01, // format = 1
        0x00, 0x0A, // startGlyphID = 10
        0x00, 0x03, // glyphCount = 3
        0x00, 0x01, // class 1 (glyph 10)
        0x00, 0x02, // class 2 (glyph 11)
        0x00, 0x03, // class 3 (glyph 12)
    };
    const cd = try parseClassDef(&data, 0);
    try std.testing.expectEqual(@as(u16, 2), cd.getClass(11));
    try std.testing.expectEqual(@as(u16, 0), cd.getClass(5));
    try std.testing.expectEqual(@as(u16, 1), cd.getClass(10));
    try std.testing.expectEqual(@as(u16, 3), cd.getClass(12));
    try std.testing.expectEqual(@as(u16, 0), cd.getClass(13));
}

test "ClassDef Format 2: getClass" {
    // format=2, classRangeCount=1, range=[startGlyph=10, endGlyph=20, class=5]
    const data = [_]u8{
        0x00, 0x02, // format = 2
        0x00, 0x01, // classRangeCount = 1
        0x00, 0x0A, // startGlyphID = 10
        0x00, 0x14, // endGlyphID = 20
        0x00, 0x05, // class = 5
    };
    const cd = try parseClassDef(&data, 0);
    try std.testing.expectEqual(@as(u16, 5), cd.getClass(15));
    try std.testing.expectEqual(@as(u16, 0), cd.getClass(25));
    try std.testing.expectEqual(@as(u16, 5), cd.getClass(10));
    try std.testing.expectEqual(@as(u16, 5), cd.getClass(20));
    try std.testing.expectEqual(@as(u16, 0), cd.getClass(9));
}

test "ValueRecord: valueRecordSize and readValueRecord" {
    // value_format = 0x0005 means xPlacement (bit0) + xAdvance (bit2)
    try std.testing.expectEqual(@as(usize, 4), valueRecordSize(0x0005));
    try std.testing.expectEqual(@as(usize, 2), valueRecordSize(0x0001));
    try std.testing.expectEqual(@as(usize, 0), valueRecordSize(0x0000));
    try std.testing.expectEqual(@as(usize, 8), valueRecordSize(0x000F));

    // data: xPlacement = 10, xAdvance = 20 (value_format = 0x0005)
    const data = [_]u8{
        0x00, 0x0A, // xPlacement = 10
        0x00, 0x14, // xAdvance = 20
    };
    const vr = try readValueRecord(&data, 0, 0x0005);
    try std.testing.expectEqual(@as(i16, 10), vr.x_placement);
    try std.testing.expectEqual(@as(i16, 0), vr.y_placement);
    try std.testing.expectEqual(@as(i16, 20), vr.x_advance);
    try std.testing.expectEqual(@as(i16, 0), vr.y_advance);
}

test "ValueRecord: all fields" {
    // value_format = 0x000F: xPlacement, yPlacement, xAdvance, yAdvance
    const data = [_]u8{
        0x00, 0x01, // xPlacement = 1
        0x00, 0x02, // yPlacement = 2
        0x00, 0x03, // xAdvance = 3
        0x00, 0x04, // yAdvance = 4
    };
    const vr = try readValueRecord(&data, 0, 0x000F);
    try std.testing.expectEqual(@as(i16, 1), vr.x_placement);
    try std.testing.expectEqual(@as(i16, 2), vr.y_placement);
    try std.testing.expectEqual(@as(i16, 3), vr.x_advance);
    try std.testing.expectEqual(@as(i16, 4), vr.y_advance);
}
