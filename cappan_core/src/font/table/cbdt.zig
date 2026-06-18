const std = @import("std");
const parser = @import("../parser.zig");
const cblc_mod = @import("cblc.zig");

pub const BitmapMetrics = struct {
    width: u8,
    height: u8,
    bearing_x: i8,
    bearing_y: i8,
    advance: u8,
};

pub const GlyphBitmap = struct {
    metrics: BitmapMetrics,
    png_data: []const u8, // slice into CBDT table data
};

const HEADER_SIZE: usize = 4; // majorVersion(2) + minorVersion(2)

pub const CbdtTable = struct {
    data: []const u8,

    pub fn getGlyphBitmap(self: CbdtTable, location: cblc_mod.GlyphBitmapLocation) ?GlyphBitmap {
        const data_start: usize = @intCast(location.image_data_offset);
        if (data_start >= self.data.len) return null;

        switch (location.image_format) {
            17 => {
                // SmallGlyphMetrics (5 bytes) + uint32 dataLen + PNG data
                if (data_start + 9 > self.data.len) return null;
                const height = parser.readU8(self.data, data_start) catch return null;
                const width = parser.readU8(self.data, data_start + 1) catch return null;
                const bearing_x = parser.readI8(self.data, data_start + 2) catch return null;
                const bearing_y = parser.readI8(self.data, data_start + 3) catch return null;
                const advance = parser.readU8(self.data, data_start + 4) catch return null;
                const data_len = parser.readU32(self.data, data_start + 5) catch return null;
                const png_start = data_start + 9;
                const png_end = png_start + @as(usize, data_len);
                if (png_end > self.data.len) return null;
                return GlyphBitmap{
                    .metrics = BitmapMetrics{
                        .width = width,
                        .height = height,
                        .bearing_x = bearing_x,
                        .bearing_y = bearing_y,
                        .advance = advance,
                    },
                    .png_data = self.data[png_start..png_end],
                };
            },
            18 => {
                // BigGlyphMetrics (8 bytes) + uint32 dataLen + PNG data
                if (data_start + 12 > self.data.len) return null;
                const height = parser.readU8(self.data, data_start) catch return null;
                const width = parser.readU8(self.data, data_start + 1) catch return null;
                const hori_bearing_x = parser.readI8(self.data, data_start + 2) catch return null;
                const hori_bearing_y = parser.readI8(self.data, data_start + 3) catch return null;
                const hori_advance = parser.readU8(self.data, data_start + 4) catch return null;
                // vertBearingX, vertBearingY, vertAdvance at +5,+6,+7
                const data_len = parser.readU32(self.data, data_start + 8) catch return null;
                const png_start = data_start + 12;
                const png_end = png_start + @as(usize, data_len);
                if (png_end > self.data.len) return null;
                return GlyphBitmap{
                    .metrics = BitmapMetrics{
                        .width = width,
                        .height = height,
                        .bearing_x = hori_bearing_x,
                        .bearing_y = hori_bearing_y,
                        .advance = hori_advance,
                    },
                    .png_data = self.data[png_start..png_end],
                };
            },
            19 => {
                // No per-glyph metrics (metrics come from CBLC) — just uint32 dataLen + PNG data
                if (data_start + 4 > self.data.len) return null;
                const data_len = parser.readU32(self.data, data_start) catch return null;
                const png_start = data_start + 4;
                const png_end = png_start + @as(usize, data_len);
                if (png_end > self.data.len) return null;
                return GlyphBitmap{
                    .metrics = BitmapMetrics{
                        .width = 0,
                        .height = 0,
                        .bearing_x = 0,
                        .bearing_y = 0,
                        .advance = 0,
                    },
                    .png_data = self.data[png_start..png_end],
                };
            },
            else => return null,
        }
    }
};

pub fn parse(data: []const u8) !CbdtTable {
    if (data.len < HEADER_SIZE) return error.UnexpectedEof;
    const major_version = try parser.readU16(data, 0);
    if (major_version != 2 and major_version != 3) return error.UnsupportedVersion;
    return CbdtTable{
        .data = data,
    };
}

test "cbdt parse returns error on short data" {
    const result = parse(&[_]u8{0} ** 3);
    try std.testing.expectError(error.UnexpectedEof, result);
}

test "cbdt parse returns error on unsupported version" {
    const data = [_]u8{ 0x00, 0x01, 0x00, 0x00 };
    const result = parse(&data);
    try std.testing.expectError(error.UnsupportedVersion, result);
}

test "cbdt parse valid header" {
    // majorVersion=3, minorVersion=0
    const data = [_]u8{ 0x00, 0x03, 0x00, 0x00 };
    const table = try parse(&data);
    try std.testing.expectEqual(@as(usize, 4), table.data.len);
}
