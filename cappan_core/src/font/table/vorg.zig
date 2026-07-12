const std = @import("std");
const parser = @import("../parser.zig");

pub const VorgTable = struct {
    data: []const u8,
    default_vert_origin_y: i16,
    num_metrics: u16,

    pub fn getVertOriginY(self: VorgTable, glyph_id: u16) i16 {
        var lo: usize = 0;
        var hi: usize = self.num_metrics;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec_offset = 8 + mid * 4;
            const rec_glyph = parser.readU16(self.data, rec_offset) catch return self.default_vert_origin_y;
            if (rec_glyph == glyph_id) {
                return parser.readI16(self.data, rec_offset + 2) catch self.default_vert_origin_y;
            } else if (rec_glyph < glyph_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return self.default_vert_origin_y;
    }
};

pub fn parse(data: []const u8) !VorgTable {
    if (data.len < 8) return error.UnexpectedEof;
    const major = try parser.readU16(data, 0);
    if (major != 1) return error.InvalidVersion;
    const default_y = try parser.readI16(data, 4);
    const num = try parser.readU16(data, 6);
    return .{
        .data = data,
        .default_vert_origin_y = default_y,
        .num_metrics = num,
    };
}

test "parse vorg table with synthetic data" {
    var data = [_]u8{0} ** 16;
    data[0] = 0x00;
    data[1] = 0x01; // majorVersion = 1
    data[2] = 0x00;
    data[3] = 0x00; // minorVersion = 0
    data[4] = 0x03;
    data[5] = 0x70; // defaultVertOriginY = 880
    data[6] = 0x00;
    data[7] = 0x02; // numVertOriginYMetrics = 2
    data[8] = 0x00;
    data[9] = 0x03; // glyphIndex = 3
    data[10] = 0x03;
    data[11] = 0x84; // vertOriginY = 900
    data[12] = 0x00;
    data[13] = 0x07; // glyphIndex = 7
    data[14] = 0x03;
    data[15] = 0xE8; // vertOriginY = 1000

    const vorg = try parse(&data);
    try std.testing.expectEqual(@as(i16, 900), vorg.getVertOriginY(3));
    try std.testing.expectEqual(@as(i16, 1000), vorg.getVertOriginY(7));
    try std.testing.expectEqual(@as(i16, 880), vorg.getVertOriginY(5));
}
