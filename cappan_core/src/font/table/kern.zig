const std = @import("std");
const parser = @import("../parser.zig");

pub const KernTable = struct {
    pairs_data: []const u8,
    n_pairs: u16,

    pub fn getKerning(self: KernTable, left_glyph: u16, right_glyph: u16) i16 {
        if (self.n_pairs == 0) return 0;

        const key: u32 = (@as(u32, left_glyph) << 16) | @as(u32, right_glyph);

        var lo: usize = 0;
        var hi: usize = @as(usize, self.n_pairs);

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const pair_offset = mid * 6;
            const left = parser.readU16(self.pairs_data, pair_offset) catch return 0;
            const right = parser.readU16(self.pairs_data, pair_offset + 2) catch return 0;
            const pair_key: u32 = (@as(u32, left) << 16) | @as(u32, right);

            if (pair_key == key) {
                return parser.readI16(self.pairs_data, pair_offset + 4) catch 0;
            } else if (pair_key < key) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        return 0;
    }
};

pub fn parse(data: []const u8) !KernTable {
    const n_tables = try parser.readU16(data, 2);

    var offset: usize = 4;
    var i: u16 = 0;
    while (i < n_tables) : (i += 1) {
        if (offset + 6 > data.len) return error.UnexpectedEof;

        const length = try parser.readU16(data, offset + 2);
        const coverage = try parser.readU16(data, offset + 4);

        const format = coverage >> 8;
        const horizontal = (coverage & 0x0001) != 0;
        const cross_stream = ((coverage >> 2) & 0x0001) != 0;

        if (format == 0 and horizontal and !cross_stream) {
            const pairs_header_offset = offset + 6;
            if (pairs_header_offset + 8 > data.len) return error.UnexpectedEof;
            const n_pairs = try parser.readU16(data, pairs_header_offset);
            const pairs_data_offset = pairs_header_offset + 8;
            const pairs_data_end = pairs_data_offset + @as(usize, n_pairs) * 6;
            if (pairs_data_end > data.len) return error.UnexpectedEof;

            return .{
                .pairs_data = data[pairs_data_offset..pairs_data_end],
                .n_pairs = n_pairs,
            };
        }

        offset += @as(usize, length);
    }

    return error.TableNotFound;
}

test "parse kern table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const kern_record = p.findTable(offset_table, "kern".*);
    if (kern_record == null) {
        return;
    }
    const kern_data = try p.getTableData(font_data, kern_record.?);
    const kern = try parse(kern_data);

    try std.testing.expectEqual(@as(i16, 0), kern.getKerning(0, 0));
}
