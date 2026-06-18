const std = @import("std");

pub const TableRecord = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,
};

pub const OffsetTable = struct {
    sfnt_version: u32,
    num_tables: u16,
    table_records: []TableRecord,
};

// Big-endian read helpers
pub fn readU16(data: []const u8, offset: usize) !u16 {
    if (offset + 2 > data.len) return error.UnexpectedEof;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

pub fn readI16(data: []const u8, offset: usize) !i16 {
    if (offset + 2 > data.len) return error.UnexpectedEof;
    return std.mem.readInt(i16, data[offset..][0..2], .big);
}

pub fn readU32(data: []const u8, offset: usize) !u32 {
    if (offset + 4 > data.len) return error.UnexpectedEof;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

pub fn readI32(data: []const u8, offset: usize) !i32 {
    if (offset + 4 > data.len) return error.UnexpectedEof;
    return std.mem.readInt(i32, data[offset..][0..4], .big);
}

pub fn readU8(data: []const u8, offset: usize) !u8 {
    if (offset >= data.len) return error.UnexpectedEof;
    return data[offset];
}

pub fn readI8(data: []const u8, offset: usize) !i8 {
    if (offset >= data.len) return error.UnexpectedEof;
    return @bitCast(data[offset]);
}

/// Read a 16-bit F2Dot14 fixed-point value and return it as f32.
/// F2Dot14: 1 sign bit + 1 integer bit + 14 fractional bits.
pub fn readF2Dot14(data: []const u8, offset: usize) !f32 {
    const raw = try readI16(data, offset);
    return @as(f32, @floatFromInt(raw)) / 16384.0;
}

pub const ParseError = error{
    InvalidSfntVersion,
    UnexpectedEof,
    TableNotFound,
    OutOfMemory,
};

// sfnt version 0x00010000 = TrueType
const SFNT_VERSION_TRUETYPE: u32 = 0x00010000;
// sfnt version 0x4F54544F = "OTTO" = CFF/OpenType
const SFNT_VERSION_CFF: u32 = 0x4F54544F;
const TTC_TAG: u32 = 0x74746366; // "ttcf"

pub const TtcHeader = struct {
    major_version: u16,
    minor_version: u16,
    num_fonts: u32,
    offsets: []const u32,
};

pub fn parseTtcHeader(allocator: std.mem.Allocator, data: []const u8) ParseError!TtcHeader {
    if (data.len < 12) return error.UnexpectedEof;
    const tag = readU32(data, 0) catch return error.UnexpectedEof;
    if (tag != TTC_TAG) return error.InvalidSfntVersion;

    const major = readU16(data, 4) catch return error.UnexpectedEof;
    const minor = readU16(data, 6) catch return error.UnexpectedEof;
    const num_fonts = readU32(data, 8) catch return error.UnexpectedEof;
    const num_fonts_usize: usize = @intCast(num_fonts);

    const offsets = try allocator.alloc(u32, num_fonts_usize);
    errdefer allocator.free(offsets);

    for (0..num_fonts_usize) |i| {
        offsets[i] = readU32(data, 12 + i * 4) catch return error.UnexpectedEof;
    }

    return .{
        .major_version = major,
        .minor_version = minor,
        .num_fonts = num_fonts,
        .offsets = offsets,
    };
}

pub fn parseOffsetTableAt(allocator: std.mem.Allocator, data: []const u8, start_offset: u32) ParseError!OffsetTable {
    const start: usize = @intCast(start_offset);
    if (start + 12 > data.len) return error.UnexpectedEof;
    const sfnt_version = readU32(data, start) catch return error.UnexpectedEof;
    if (sfnt_version != SFNT_VERSION_TRUETYPE and sfnt_version != SFNT_VERSION_CFF) return error.InvalidSfntVersion;

    const num_tables = readU16(data, start + 4) catch return error.UnexpectedEof;

    const records = try allocator.alloc(TableRecord, num_tables);
    errdefer allocator.free(records);

    var offset: usize = start + 12;
    for (0..num_tables) |i| {
        if (offset + 16 > data.len) return error.UnexpectedEof;
        records[i] = .{
            .tag = data[offset..][0..4].*,
            .checksum = readU32(data, offset + 4) catch return error.UnexpectedEof,
            .offset = readU32(data, offset + 8) catch return error.UnexpectedEof,
            .length = readU32(data, offset + 12) catch return error.UnexpectedEof,
        };
        offset += 16;
    }

    return .{
        .sfnt_version = sfnt_version,
        .num_tables = num_tables,
        .table_records = records,
    };
}

pub fn parseOffsetTable(allocator: std.mem.Allocator, data: []const u8) ParseError!OffsetTable {
    return parseOffsetTableAt(allocator, data, 0);
}

pub fn isTtcFile(data: []const u8) bool {
    if (data.len < 4) return false;
    const tag = readU32(data, 0) catch return false;
    return tag == TTC_TAG;
}

pub fn findTable(offset_table: OffsetTable, tag: [4]u8) ?TableRecord {
    for (offset_table.table_records) |record| {
        if (std.mem.eql(u8, &record.tag, &tag)) return record;
    }
    return null;
}

pub fn getTableData(data: []const u8, record: TableRecord) ![]const u8 {
    const start = @as(usize, record.offset);
    const end = std.math.add(usize, start, @as(usize, record.length)) catch return error.UnexpectedEof;
    if (end > data.len) return error.UnexpectedEof;
    return data[start..end];
}

test "parse offset table from DejaVuSans" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    const offset_table = try parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    try std.testing.expect(offset_table.sfnt_version == 0x00010000);
    try std.testing.expect(offset_table.num_tables > 0);

    // Verify essential tables exist
    try std.testing.expect(findTable(offset_table, "cmap".*) != null);
    try std.testing.expect(findTable(offset_table, "glyf".*) != null);
    try std.testing.expect(findTable(offset_table, "head".*) != null);
    try std.testing.expect(findTable(offset_table, "hhea".*) != null);
    try std.testing.expect(findTable(offset_table, "hmtx".*) != null);
    try std.testing.expect(findTable(offset_table, "loca".*) != null);
    try std.testing.expect(findTable(offset_table, "maxp".*) != null);
}

test "isTtcFile returns false for regular TTF" {
    const font_data = @embedFile("../fixture/DejaVuSans.ttf");
    try std.testing.expect(!isTtcFile(font_data));
}
