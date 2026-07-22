const std = @import("std");
const parser = @import("../parser.zig");

pub const HMetrics = struct {
    advance_width: u16,
    lsb: i16,
};

pub const HmtxTable = struct {
    data: []const u8,
    number_of_h_metrics: u16,

    pub fn getMetrics(self: HmtxTable, glyph_id: u16) !HMetrics {
        // The spec requires numberOfHMetrics >= 1; a malformed value of 0 would
        // make the else-branch compute (0 - 1) * 4 and underflow usize.
        if (self.number_of_h_metrics == 0) return error.UnexpectedEof;
        if (glyph_id < self.number_of_h_metrics) {
            const offset = @as(usize, glyph_id) * 4;
            return .{
                .advance_width = try parser.readU16(self.data, offset),
                .lsb = try parser.readI16(self.data, offset + 2),
            };
        } else {
            // Use last advance width, read lsb from extended array
            const last_aw_offset = (@as(usize, self.number_of_h_metrics) - 1) * 4;
            const advance_width = try parser.readU16(self.data, last_aw_offset);
            const lsb_offset = @as(usize, self.number_of_h_metrics) * 4 + (@as(usize, glyph_id) - @as(usize, self.number_of_h_metrics)) * 2;
            const lsb = try parser.readI16(self.data, lsb_offset);
            return .{
                .advance_width = advance_width,
                .lsb = lsb,
            };
        }
    }
};

pub fn parse(data: []const u8, number_of_h_metrics: u16) HmtxTable {
    return .{
        .data = data,
        .number_of_h_metrics = number_of_h_metrics,
    };
}

test "getMetrics with numberOfHMetrics=0 errors instead of underflowing" {
    // Malformed hhea would give numberOfHMetrics == 0; the extended-array
    // branch used to compute (0 - 1) * 4 and underflow usize. It must now
    // return an error for any glyph rather than crashing.
    const data = [_]u8{0} ** 8;
    const hmtx = parse(&data, 0);
    try std.testing.expectError(error.UnexpectedEof, hmtx.getMetrics(0));
    try std.testing.expectError(error.UnexpectedEof, hmtx.getMetrics(5));
}

test "parse hmtx table from DejaVuSans" {
    const font_data = @embedFile("../../fixture/DejaVuSans.ttf");
    const p = @import("../parser.zig");
    const offset_table = try p.parseOffsetTable(std.testing.allocator, font_data);
    defer std.testing.allocator.free(offset_table.table_records);

    const hhea_record = p.findTable(offset_table, "hhea".*) orelse return error.TableNotFound;
    const hhea_data = try p.getTableData(font_data, hhea_record);
    const hhea_mod = @import("hhea.zig");
    const hhea = try hhea_mod.parse(hhea_data);

    const cmap_record = p.findTable(offset_table, "cmap".*) orelse return error.TableNotFound;
    const cmap_data = try p.getTableData(font_data, cmap_record);
    const cmap_mod = @import("cmap.zig");
    const cmap = try cmap_mod.parse(cmap_data);

    const hmtx_record = p.findTable(offset_table, "hmtx".*) orelse return error.TableNotFound;
    const hmtx_data = try p.getTableData(font_data, hmtx_record);
    const hmtx = parse(hmtx_data, hhea.number_of_h_metrics);

    // 'A' should have positive advance width
    const glyph_a = try cmap.charToGlyphId(0x0041);
    const metrics_a = try hmtx.getMetrics(glyph_a);
    try std.testing.expect(metrics_a.advance_width > 0);

    // 'i' should have smaller advance width than 'M'
    const glyph_i = try cmap.charToGlyphId(0x0069);
    const glyph_m = try cmap.charToGlyphId(0x004D);
    const metrics_i = try hmtx.getMetrics(glyph_i);
    const metrics_m = try hmtx.getMetrics(glyph_m);
    try std.testing.expect(metrics_i.advance_width < metrics_m.advance_width);
}
