const std = @import("std");
const parser = @import("../parser.zig");

pub const ColorLayer = struct {
    glyph_id: u16,
    palette_index: u16,
};

pub const BaseGlyphRecord = struct {
    glyph_id: u16,
    first_layer_idx: u16,
    num_layers: u16,
};

pub const ColrTable = struct {
    data: []const u8,
    num_base_glyphs: u16,
    base_glyph_offset: u32,
    layer_offset: u32,
    num_layers: u16,

    pub fn findBaseGlyph(self: ColrTable, glyph_id: u16) ?BaseGlyphRecord {
        var lo: u32 = 0;
        var hi: u32 = self.num_base_glyphs;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const offset = std.math.add(u32, self.base_glyph_offset, mid * 6) catch return null;
            const offset_usize: usize = @intCast(offset);
            const id = parser.readU16(self.data, offset_usize) catch return null;
            if (id < glyph_id) {
                lo = mid + 1;
            } else if (id > glyph_id) {
                hi = mid;
            } else {
                return BaseGlyphRecord{
                    .glyph_id = id,
                    .first_layer_idx = parser.readU16(self.data, offset_usize + 2) catch return null,
                    .num_layers = parser.readU16(self.data, offset_usize + 4) catch return null,
                };
            }
        }
        return null;
    }

    pub fn getLayer(self: ColrTable, layer_idx: u16) ?ColorLayer {
        if (layer_idx >= self.num_layers) return null;
        const offset = std.math.add(u32, self.layer_offset, @as(u32, layer_idx) * 4) catch return null;
        const offset_usize: usize = @intCast(offset);
        return ColorLayer{
            .glyph_id = parser.readU16(self.data, offset_usize) catch return null,
            .palette_index = parser.readU16(self.data, offset_usize + 2) catch return null,
        };
    }
};

pub fn parse(data: []const u8) !ColrTable {
    if (data.len < 14) return error.UnexpectedEof;
    const version = try parser.readU16(data, 0);
    if (version != 0) return error.UnsupportedVersion;
    const num_base_glyphs = try parser.readU16(data, 2);
    const base_glyph_offset = try parser.readU32(data, 4);
    const layer_offset = try parser.readU32(data, 8);
    const num_layers = try parser.readU16(data, 12);
    return ColrTable{
        .data = data,
        .num_base_glyphs = num_base_glyphs,
        .base_glyph_offset = base_glyph_offset,
        .layer_offset = layer_offset,
        .num_layers = num_layers,
    };
}

test "colr parse does not crash on missing table" {
    const result = parse(&[_]u8{0} ** 5);
    try std.testing.expectError(error.UnexpectedEof, result);
}
